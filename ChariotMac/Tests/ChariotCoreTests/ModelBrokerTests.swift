import XCTest
import Network
@testable import ChariotCore

/// The host-side model broker: request-head rewriting (pure) and the full
/// pipe path over a socketpair standing in for the guest's vsock connection,
/// against a scripted local TCP upstream.
final class ModelBrokerTests: XCTestCase {

    private let chariotRoute = ModelBrokerRoute(
        upstreamHost: "app.chariots.sh", upstreamPort: 443, useTLS: true,
        basePath: "/proxy/v1", bearerToken: "tok-secret")
    private let localRoute = ModelBrokerRoute(
        upstreamHost: "127.0.0.1", upstreamPort: 11434, useTLS: false,
        basePath: "/v1", bearerToken: nil)

    // MARK: - Head rewriting (pure)

    func testChariotRewriteMapsPathHostAndToken() throws {
        let head = "POST /v1/chat/completions HTTP/1.1\r\n"
            + "Host: 127.0.0.1:8090\r\n"
            + "Authorization: Bearer chariot-broker\r\n"
            + "Content-Type: application/json"
        let out = try XCTUnwrap(ModelBroker.rewriteHead(head, route: chariotRoute))
        let lines = out.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "POST /proxy/v1/chat/completions HTTP/1.1")
        XCTAssertTrue(lines.contains("Host: app.chariots.sh"))
        XCTAssertTrue(lines.contains("Authorization: Bearer tok-secret"))
        XCTAssertFalse(out.contains("chariot-broker"))
        XCTAssertTrue(lines.contains("Connection: close"))
    }

    func testLocalRewriteKeepsDummyAuthAndSplicesBasePath() throws {
        let head = "POST /v1/responses HTTP/1.1\r\n"
            + "Host: 127.0.0.1:8090\r\n"
            + "Authorization: Bearer chariot-broker\r\n"
            + "Connection: keep-alive"
        let out = try XCTUnwrap(ModelBroker.rewriteHead(head, route: localRoute))
        let lines = out.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "POST /v1/responses HTTP/1.1")
        XCTAssertTrue(lines.contains("Host: 127.0.0.1:11434"))
        // The guest's dummy key passes through untouched for local servers.
        XCTAssertTrue(lines.contains("Authorization: Bearer chariot-broker"))
        // A keep-alive request is forced to one exchange per connection.
        XCTAssertTrue(lines.contains("Connection: close"))
        XCTAssertFalse(lines.contains("Connection: keep-alive"))
    }

    func testTokenIsInjectedEvenWithoutAGuestAuthHeader() throws {
        let head = "GET /v1/models HTTP/1.1\r\nHost: x"
        let out = try XCTUnwrap(ModelBroker.rewriteHead(head, route: chariotRoute))
        XCTAssertTrue(out.contains("Authorization: Bearer tok-secret"))
        XCTAssertTrue(out.hasPrefix("GET /proxy/v1/models HTTP/1.1"))
    }

    func testNonHTTPHeadIsRejected() {
        XCTAssertNil(ModelBroker.rewriteHead("garbage", route: localRoute))
        XCTAssertNil(ModelBroker.rewriteHead("SSH-2.0-OpenSSH_9.6", route: localRoute))
    }

    // MARK: - Route construction

    func testRouteForChariotPower() throws {
        let power = ResolvedPower(source: .chariot, model: "m", localBaseURL: nil)
        let credential = ChariotAgentCredential(agentID: "id", slug: "agent-1", agentToken: "tok")
        let route = try ModelBrokerRoute.forPower(
            power, agentCredential: credential,
            backendBaseURL: URL(string: "https://app.chariots.sh")!)
        XCTAssertEqual(route.basePath, "/proxy/v1")
        XCTAssertEqual(route.upstreamPort, 443)
        XCTAssertTrue(route.useTLS)
        XCTAssertEqual(route.bearerToken, "tok")
    }

    func testRouteForChariotWithoutTokenFailsLoudly() {
        let power = ResolvedPower(source: .chariot, model: "m", localBaseURL: nil)
        XCTAssertThrowsError(try ModelBrokerRoute.forPower(
            power, agentCredential: nil,
            backendBaseURL: URL(string: "https://app.chariots.sh")!))
    }

    func testRouteForLocalOllama() throws {
        let power = ResolvedPower(source: .local, model: "muse-glimmer:30b",
                                  localBaseURL: URL(string: "http://127.0.0.1:11434/v1"))
        let route = try ModelBrokerRoute.forPower(power, agentCredential: nil,
                                                  backendBaseURL: URL(string: "https://app.chariots.sh")!)
        XCTAssertEqual(route.upstreamHost, "127.0.0.1")
        XCTAssertEqual(route.upstreamPort, 11434)
        XCTAssertFalse(route.useTLS)
        XCTAssertEqual(route.basePath, "/v1")
        XCTAssertNil(route.bearerToken)
    }

    // MARK: - End-to-end over a socketpair + scripted upstream

    /// Minimal TCP upstream: accepts one connection, captures the request
    /// bytes until the header/body arrive, then writes scripted chunks.
    private final class FakeUpstream: @unchecked Sendable {
        let port: UInt16
        private let listenerFD: Int32
        private(set) var received = Data()
        private let chunks: [Data]
        private let done = DispatchSemaphore(value: 0)

        init(chunks: [Data]) throws {
            self.chunks = chunks
            listenerFD = socket(AF_INET, SOCK_STREAM, 0)
            var yes: Int32 = 1
            setsockopt(listenerFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            addr.sin_port = 0
            let fd = listenerFD
            let bindResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0, listen(fd, 1) == 0 else {
                throw ChariotError.io("fake upstream bind/listen failed")
            }
            var bound = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &bound) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(fd, $0, &len)
                }
            }
            port = UInt16(bigEndian: bound.sin_port)
        }

        func start() {
            DispatchQueue.global().async { [self] in serve() }
        }

        private func serve() {
            let conn = accept(listenerFD, nil, nil)
            guard conn >= 0 else { done.signal(); return }
            // Read until the head terminator (these tests send bodyless or
            // small-bodied requests in one write).
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while !received.contains("\r\n\r\n".data(using: .utf8)!) {
                let n = read(conn, &buffer, buffer.count)
                guard n > 0 else { break }
                received.append(contentsOf: buffer[0..<n])
            }
            for chunk in chunks {
                chunk.withUnsafeBytes { _ = write(conn, $0.baseAddress, $0.count) }
                usleep(20_000)  // distinct writes, so buffering bugs would show
            }
            close(conn)
            done.signal()
        }

        func waitDone() { _ = done.wait(timeout: .now() + 10) }
        deinit { close(listenerFD) }
    }

    private func runThroughBroker(request: String, route: ModelBrokerRoute) -> Data {
        var fds = [Int32](repeating: 0, count: 2)
        socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        let guestFD = fds[0], brokerFD = fds[1]
        let broker = ModelBroker(route: route, label: "test")
        let closed = DispatchSemaphore(value: 0)
        broker.handle(fd: brokerFD) {
            close(brokerFD)
            closed.signal()
        }
        request.data(using: .utf8)!.withUnsafeBytes {
            _ = write(guestFD, $0.baseAddress, $0.count)
        }
        // Half-close the guest write side so the broker sees request EOF.
        shutdown(guestFD, SHUT_WR)
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(guestFD, &buffer, buffer.count)
            if n <= 0 { break }
            response.append(contentsOf: buffer[0..<n])
        }
        _ = closed.wait(timeout: .now() + 10)
        close(guestFD)
        return response
    }

    func testForwardsRewrittenRequestAndStreamsChunksBack() throws {
        let sse = ["data: {\"delta\":\"a\"}\n\n", "data: {\"delta\":\"b\"}\n\n", "data: [DONE]\n\n"]
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n"
        let upstream = try FakeUpstream(chunks: ([header] + sse).map { Data($0.utf8) })
        upstream.start()
        let route = ModelBrokerRoute(upstreamHost: "127.0.0.1", upstreamPort: upstream.port,
                                     useTLS: false, basePath: "/proxy/v1", bearerToken: "tok-secret")

        let body = #"{"model":"m","stream":true}"#
        let request = "POST /v1/chat/completions HTTP/1.1\r\n"
            + "Host: 127.0.0.1:8090\r\n"
            + "Authorization: Bearer chariot-broker\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let response = runThroughBroker(request: request, route: route)
        upstream.waitDone()

        let sent = String(data: upstream.received, encoding: .utf8) ?? ""
        XCTAssertTrue(sent.hasPrefix("POST /proxy/v1/chat/completions HTTP/1.1"), sent)
        XCTAssertTrue(sent.contains("Authorization: Bearer tok-secret"))
        XCTAssertTrue(sent.contains(body), "body must arrive with the head")

        let got = String(data: response, encoding: .utf8) ?? ""
        XCTAssertTrue(got.hasPrefix("HTTP/1.1 200 OK"))
        // All SSE chunks arrive, in order, verbatim.
        XCTAssertTrue(got.contains(sse.joined()), got)
    }

    func testMuseCatalogProbeIsAnsweredLocally() throws {
        // No upstream at all: the probe must never leave the broker.
        let route = ModelBrokerRoute(upstreamHost: "192.0.2.1", upstreamPort: 9,
                                     useTLS: false, basePath: "/v1", bearerToken: nil)
        let response = runThroughBroker(
            request: "GET /muse-code/models HTTP/1.1\r\nHost: 127.0.0.1:8090\r\n\r\n",
            route: route)
        let got = String(data: response, encoding: .utf8) ?? ""
        XCTAssertTrue(got.hasPrefix("HTTP/1.1 200 OK"), got)
        XCTAssertTrue(got.contains(#"{"object":"list","data":[]}"#))
    }
}
