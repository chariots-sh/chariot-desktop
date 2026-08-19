import XCTest
@testable import ChariotCore

/// The forwarder must own BOTH loopbacks. The Codex OAuth redirect targets
/// "localhost", which browsers commonly resolve to ::1 first — an IPv4-only
/// listener leaves ::1:1455 free for a locally running Codex sign-in server
/// to answer the guest's callback ("token_exchange_failed" in the browser).
final class VsockPortForwarderTests: XCTestCase {
    private func makeForwarder(port: UInt16) -> VsockPortForwarder {
        let controller = VMController(
            instanceID: "test",
            paths: InstancePaths(directory: FileManager.default.temporaryDirectory),
            configuration: SandboxConfiguration(baseImagePath: "/nonexistent"))
        return VsockPortForwarder(controller: controller, listenPort: port, vsockPort: 1022)
    }

    /// An ephemeral port that is free on both loopbacks at bind time.
    private func freePort() -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        return UInt16(bigEndian: out.sin_port)
    }

    private func connect(v6: Bool, port: UInt16) -> Bool {
        let fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        let result: Int32
        if v6 {
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = port.bigEndian
            addr.sin6_addr = in6addr_loopback
            result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return result == 0
    }

    func testOwnsBothLoopbacks() throws {
        let port = freePort()
        let forwarder = makeForwarder(port: port)
        try forwarder.start()
        defer { forwarder.stop() }
        XCTAssertTrue(connect(v6: false, port: port), "127.0.0.1:\(port) should accept")
        XCTAssertTrue(connect(v6: true, port: port), "[::1]:\(port) should accept — an unclaimed IPv6 loopback lets another process intercept the OAuth callback")
    }

    func testStartFailsWhenIPv6LoopbackIsTaken() throws {
        let port = freePort()
        // Squat on ::1:port the way a locally running Codex login server does.
        let squatter = socket(AF_INET6, SOCK_STREAM, 0)
        try XCTSkipIf(squatter < 0, "no IPv6 stack on this host")
        defer { close(squatter) }
        var yes: Int32 = 1
        setsockopt(squatter, IPPROTO_IPV6, IPV6_V6ONLY, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_loopback
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(squatter, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
            }
        }
        XCTAssertTrue(bound && Darwin.listen(squatter, 1) == 0)

        let forwarder = makeForwarder(port: port)
        XCTAssertThrowsError(try forwarder.start()) { error in
            XCTAssertTrue("\(error)".contains("::1"), "error should name the taken loopback: \(error)")
        }
        // The failed start must not leak the IPv4 listener it bound first.
        XCTAssertFalse(connect(v6: false, port: port), "127.0.0.1:\(port) should be closed after a failed start")
    }

    func testStartFailsWhenIPv4LoopbackIsTaken() throws {
        let port = freePort()
        let squatter = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(squatter) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(squatter, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        XCTAssertTrue(bound && Darwin.listen(squatter, 1) == 0)

        let forwarder = makeForwarder(port: port)
        XCTAssertThrowsError(try forwarder.start())
    }
}
