import Foundation
import Virtualization

/// Optional developer access (design §1.5): a localhost-only TCP listener whose
/// connections are forwarded over vsock to sshd inside the guest. Nothing is
/// ever bound to a LAN or public interface.
final class DeveloperAccess: @unchecked Sendable {
    private let controller: VMController
    private let instance: InstancePaths
    private var listenerFD: Int32 = -1
    private var acceptThread: Thread?
    private(set) var port: UInt16 = 0
    private(set) var isActive = false

    init(controller: VMController, instance: InstancePaths) {
        self.controller = controller
        self.instance = instance
    }

    struct Info {
        let port: UInt16
        let sshConfigPath: String
        let command: String
        let codexInstructions: String
    }

    func enable() throws -> Info {
        guard !isActive else { return info() }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ChariotError.io("socket: \(String(cString: strerror(errno)))") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        // Bind 127.0.0.1 on an ephemeral port — never a real interface.
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 8) == 0 else {
            Darwin.close(fd)
            throw ChariotError.io("bind/listen: \(String(cString: strerror(errno)))")
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(fd, $0, &length)
            }
        }
        listenerFD = fd
        port = UInt16(bigEndian: bound.sin_port)
        isActive = true

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "chariot.devaccess.accept"
        acceptThread = thread
        thread.start()

        try writeSSHConfig()
        ChariotLog.log("developer access enabled on 127.0.0.1:\(port)")
        return info()
    }

    func disable() {
        guard isActive else { return }
        isActive = false
        if listenerFD >= 0 { Darwin.close(listenerFD) }
        listenerFD = -1
        ChariotLog.log("developer access disabled")
    }

    private func acceptLoop() {
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
            let connection = try await controller.connectSocket(port: 1023, timeout: 10)
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
            ChariotLog.log("developer access tunnel failed: \(error)")
            Darwin.close(clientFD)
        }
    }

    private func writeSSHConfig() throws {
        let config = """
        Host chariot-development
            HostName 127.0.0.1
            Port \(port)
            User agent
            IdentityFile \(instance.accessKey.path)
            UserKnownHostsFile \(instance.knownHosts.path)
            StrictHostKeyChecking accept-new
            IdentitiesOnly yes
            PasswordAuthentication no
            ForwardAgent no
            ForwardX11 no
        """
        try config.write(to: instance.sshConfig, atomically: true, encoding: .utf8)
        if !FileManager.default.fileExists(atPath: instance.knownHosts.path) {
            try Data().write(to: instance.knownHosts)
        }
    }

    private func info() -> Info {
        let command = "ssh -F \"\(instance.sshConfig.path)\" chariot-development"
        let instructions = """
        The development environment is available over SSH.

        SSH configuration: \(instance.sshConfig.path)
        Remote host: chariot-development
        Remote workspace: /workspace

        Run project commands remotely using:
          ssh -F "\(instance.sshConfig.path)" \\
            chariot-development \\
            'cd /workspace && <command>'

        Use scp with the same -F configuration to transfer files. Do not run the
        project's builds or tests on the local Mac.
        """
        return Info(port: port, sshConfigPath: instance.sshConfig.path,
                    command: command, codexInstructions: instructions)
    }
}
