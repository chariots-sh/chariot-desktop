import XCTest
@testable import ChariotCore

/// Integration tests for the loopback HTTP/WebSocket transport: a real server
/// on an ephemeral 127.0.0.1 port, exercised with URLSession as the client the
/// same way the phone (via the tailnet proxy) and the E2E harness reach it.
final class TransportServerTests: XCTestCase {

    func testAcceptKeyMatchesRFC6455Example() {
        // Known-answer vector from RFC 6455 §1.3.
        XCTAssertEqual(WebSocketConnection.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ=="),
                       "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    func startServer(_ handler: @escaping @Sendable (HTTPServer.Request) -> HTTPServer.Response) throws -> HTTPServer {
        let server = HTTPServer(handler: handler)
        try server.start(port: 0)
        XCTAssertGreaterThan(server.port, 0)
        return server
    }

    func testRequestParsingAndJSONResponse() throws {
        let server = try startServer { request in
            guard request.method == "GET", request.path == "/status" else {
                return .error(404, "not found")
            }
            return .json(["query": request.query["name"] ?? "",
                          "agent": request.headers["x-agent"] ?? ""])
        }
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/status?name=phone%201&extra")!)
        request.setValue("chariot-test", forHTTPHeaderField: "X-Agent")
        let done = expectation(description: "response")
        URLSession.shared.dataTask(with: request) { data, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"),
                           "application/json")
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: String]
            // Query values are percent-decoded; header keys are lowercased.
            XCTAssertEqual(object?["query"], "phone 1")
            XCTAssertEqual(object?["agent"], "chariot-test")
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
    }

    func testPostBodyRoundTripAndErrorStatus() throws {
        let server = try startServer { request in
            if request.path == "/echo" {
                return .data(request.body)
            }
            return .error(404, "not found")
        }
        defer { server.stop() }

        let body = Data((0..<100_000).map { UInt8($0 % 251) })
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/echo")!)
        request.httpMethod = "POST"
        request.httpBody = body
        let done = expectation(description: "echo")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(data, body)
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)

        let missing = expectation(description: "404")
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(server.port)/nope")!) { data, response, _ in
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: String]
            XCTAssertEqual(object?["error"], "not found")
            missing.fulfill()
        }.resume()
        wait(for: [missing], timeout: 5)
    }

    func testWebSocketUpgradeAndEcho() throws {
        let server = try startServer { request in
            guard request.path == "/ws" else { return .error(404, "not found") }
            return .upgrade { connection in
                connection.onText = { text in
                    connection.send(text: "echo:" + text)
                }
            }
        }
        defer { server.stop() }

        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(server.port)/ws")!)
        task.resume()

        // A payload beyond 125 bytes exercises the extended-length framing on
        // both sides (client frames arrive masked; replies leave unmasked).
        let long = String(repeating: "chariot ", count: 64)
        let done = expectation(description: "echoed")
        task.send(.string(long)) { error in
            XCTAssertNil(error)
            task.receive { result in
                guard case .success(.string(let text)) = result else {
                    XCTFail("expected text frame, got \(result)")
                    done.fulfill()
                    return
                }
                XCTAssertEqual(text, "echo:" + long)
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 5)
        task.cancel(with: .normalClosure, reason: nil)
    }

    func testNonWebSocketRequestToUpgradeEndpointRejected() throws {
        let server = try startServer { _ in .upgrade { _ in } }
        defer { server.stop() }

        // Plain GET without the upgrade headers must get 400, not a hang.
        let done = expectation(description: "rejected")
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(server.port)/ws")!) { _, response, _ in
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
    }

    func testClientVanishingMidResponseDoesNotKillTheProcess() throws {
        // Regression: writes are raw `write(2)` on the socket, so a peer that
        // disappears mid-response used to raise SIGPIPE and take the whole app
        // down (the phone dropping during a multi-MB file.put snapshot). The
        // write must fail instead, leaving the server able to serve the next
        // request. Without the SO_NOSIGPIPE guard this kills the test runner.
        let big = Data(repeating: 0x41, count: 16 * 1024 * 1024)
        let server = try startServer { _ in .data(big) }
        defer { server.stop() }

        // Raw socket so we can send a request and hang up before reading — a
        // URLSession client drains the response for us.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = server.port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        XCTAssertTrue(connected)
        let request = Data("GET /big HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
        _ = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        // Close while the 16 MiB response is still being written.
        Thread.sleep(forTimeInterval: 0.05)
        Darwin.close(fd)

        // The server survived the broken pipe and still answers.
        let done = expectation(description: "still serving")
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(server.port)/again")!) { data, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(data?.count, big.count)
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 30)
    }
}
