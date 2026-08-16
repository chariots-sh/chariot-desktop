import Foundation
import Virtualization

/// Forwards a localhost-only TCP port into a guest vsock port. Used for the
/// Codex OAuth callback: the browser on the Mac redirects to 127.0.0.1:1455,
/// which lands on the guest's login server (design §3.1) — never a LAN port.
final class VsockPortForwarder: @unchecked Sendable {
    private let controller: VMController
    private let listenPort: UInt16
    private let vsockPort: UInt32
    private var listenerFD: Int32 = -1
    private(set) var isActive = false

    init(controller: VMController, listenPort: UInt16, vsockPort: UInt32) {
        self.controller = controller
        self.listenPort = listenPort
        self.vsockPort = vsockPort
    }

    func start() throws {
        guard !isActive else { return }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ChariotError.io("socket: \(String(cString: strerror(errno)))") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = listenPort.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard ok, listen(fd, 8) == 0 else {
            Darwin.close(fd)
            throw ChariotError.io("bind 127.0.0.1:\(listenPort): \(String(cString: strerror(errno)))")
        }
        listenerFD = fd
        isActive = true
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "chariot.forwarder.\(listenPort)"
        thread.start()
        ChariotLog.log("forwarding 127.0.0.1:\(listenPort) → vsock:\(vsockPort)")
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        if listenerFD >= 0 { Darwin.close(listenerFD) }
        listenerFD = -1
    }

    private func acceptLoop() {
        while isActive {
            let client = accept(listenerFD, nil, nil)
            guard client >= 0 else { break }
            Task { [weak self] in
                await self?.tunnel(clientFD: client)
            }
        }
    }

    private func tunnel(clientFD: Int32) async {
        do {
            let connection = try await controller.connectSocket(port: vsockPort, timeout: 10)
            let guestFD = connection.fileDescriptor
            let copyAll: @Sendable (Int32, Int32) -> Void = { src, dst in
                var buf = [UInt8](repeating: 0, count: 65536)
                outer: while true {
                    let n = read(src, &buf, buf.count)
                    if n <= 0 { break }
                    let ok = buf.withUnsafeBufferPointer { pointer -> Bool in
                        var off = 0
                        while off < n {
                            let w = write(dst, pointer.baseAddress!.advanced(by: off), n - off)
                            if w <= 0 { return false }
                            off += w
                        }
                        return true
                    }
                    if !ok { break outer }
                }
                shutdown(dst, SHUT_WR)
            }
            let forward = Thread { copyAll(clientFD, guestFD) }
            forward.start()
            let back = Thread {
                copyAll(guestFD, clientFD)
                Darwin.close(clientFD)
                connection.close()
            }
            back.start()
        } catch {
            ChariotLog.log("forwarder tunnel failed: \(error)")
            Darwin.close(clientFD)
        }
    }
}
