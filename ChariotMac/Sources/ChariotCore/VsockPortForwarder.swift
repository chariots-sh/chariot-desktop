import Foundation
import Virtualization

/// Forwards a localhost-only TCP port into a guest vsock port. Used for the
/// Codex OAuth callback: the browser on the Mac redirects to 127.0.0.1:1455,
/// which lands on the guest's login server (design §3.1) — never a LAN port.
final class VsockPortForwarder: @unchecked Sendable {
    private let controller: VMController
    private let listenPort: UInt16
    private let vsockPort: UInt32
    private var listenerFDs: [Int32] = []
    private(set) var isActive = false

    init(controller: VMController, listenPort: UInt16, vsockPort: UInt32) {
        self.controller = controller
        self.listenPort = listenPort
        self.vsockPort = vsockPort
    }

    func start() throws {
        guard !isActive else { return }
        // The OAuth redirect targets "localhost", which browsers commonly
        // resolve to ::1 before 127.0.0.1. Owning only the IPv4 loopback
        // leaves ::1:1455 free for another process — a Codex app or CLI
        // sign-in running on the Mac — to answer the callback with a code
        // that belongs to the guest's PKCE session ("token_exchange_failed").
        // So take both loopbacks, and fail loudly if either is taken.
        var fds: [Int32] = []
        do {
            fds.append(try makeListener(v6: false))
            if let v6 = try makeListener6IfSupported() { fds.append(v6) }
        } catch {
            fds.forEach { Darwin.close($0) }
            throw error
        }
        listenerFDs = fds
        isActive = true
        for fd in fds {
            let thread = Thread { [weak self] in self?.acceptLoop(fd) }
            thread.name = "chariot.forwarder.\(listenPort)"
            thread.start()
        }
        ChariotLog.log("forwarding loopback:\(listenPort) → vsock:\(vsockPort)")
    }

    private func makeListener(v6: Bool) throws -> Int32 {
        let fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ChariotError.io("socket: \(String(cString: strerror(errno)))") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        let ok: Bool
        if v6 {
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = listenPort.bigEndian
            addr.sin6_addr = in6addr_loopback
            ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
                }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = listenPort.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
        }
        guard ok, listen(fd, 8) == 0 else {
            let cause = errno  // before close(), which may clobber it
            Darwin.close(fd)
            throw ChariotError.io("bind \(v6 ? "[::1]" : "127.0.0.1"):\(listenPort): \(String(cString: strerror(cause)))")
        }
        return fd
    }

    /// nil when the host has no IPv6 stack at all — then nothing can squat
    /// on ::1 either, and IPv4-only is safe.
    private func makeListener6IfSupported() throws -> Int32? {
        let probe = socket(AF_INET6, SOCK_STREAM, 0)
        guard probe >= 0 else { return nil }
        Darwin.close(probe)
        return try makeListener(v6: true)
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        listenerFDs.forEach { Darwin.close($0) }
        listenerFDs = []
    }

    private func acceptLoop(_ listenerFD: Int32) {
        while isActive {
            let client = accept(listenerFD, nil, nil)
            guard client >= 0 else { break }
            disableSIGPIPE(on: client)
            Task { [weak self] in
                await self?.tunnel(clientFD: client)
            }
        }
    }

    private func tunnel(clientFD: Int32) async {
        do {
            let connection = try await controller.connectSocket(port: vsockPort, timeout: 10)
            let guestFD = connection.fileDescriptor
            disableSIGPIPE(on: guestFD)
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
