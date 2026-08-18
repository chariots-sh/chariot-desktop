import Foundation
import Network

/// Host-side model endpoint broker (one per running chariot/local agent).
///
/// Guest harnesses all point at `http://127.0.0.1:8090/v1` with a dummy API
/// key; the guest bridge tunnels that loopback port over vsock to this
/// broker, which rewrites the HTTP/1.1 request head — path prefix, Host, and
/// (for chariot) the real bearer token — and then blindly pipes bytes both
/// ways. The credential therefore exists only on the Mac, and SSE streams
/// pass through unbuffered. `Connection: close` is forced so one guest
/// connection maps to exactly one upstream exchange; every harness client
/// reconnects per call.
public struct ModelBrokerRoute: Sendable, Equatable {
    public let upstreamHost: String
    public let upstreamPort: UInt16
    public let useTLS: Bool
    /// Replaces the guest's `/v1` prefix, e.g. "/proxy/v1" (chariot) or "/v1"
    /// (typical local server). No trailing slash.
    public let basePath: String
    /// When set, the Authorization header is replaced with this bearer token
    /// (chariot). When nil the guest's header passes through (local servers
    /// ignore or accept the dummy).
    public let bearerToken: String?

    public init(upstreamHost: String, upstreamPort: UInt16, useTLS: Bool,
                basePath: String, bearerToken: String?) {
        self.upstreamHost = upstreamHost
        self.upstreamPort = upstreamPort
        self.useTLS = useTLS
        self.basePath = basePath
        self.bearerToken = bearerToken
    }

    /// Route for a resolved power source. Chariot routes to the backend's
    /// proxy (base URL shared with ChariotAccountClient, so
    /// CHARIOT_BACKEND_URL overrides both together).
    public static func forPower(_ power: ResolvedPower,
                                agentCredential: ChariotAgentCredential?,
                                backendBaseURL: URL) throws -> ModelBrokerRoute {
        switch power.source {
        case .chatgpt:
            throw ChariotError.invalidState("chatgpt agents do not use the model broker")
        case .chariot:
            guard let token = agentCredential?.agentToken else {
                throw ChariotError.invalidState("chariot agent has no stored token — recreate the agent")
            }
            let tls = backendBaseURL.scheme != "http"
            return ModelBrokerRoute(
                upstreamHost: backendBaseURL.host ?? "app.chariots.sh",
                upstreamPort: UInt16(backendBaseURL.port ?? (tls ? 443 : 80)),
                useTLS: tls,
                basePath: normalizedBasePath(backendBaseURL.path) + "/proxy/v1",
                bearerToken: token)
        case .local:
            guard let base = power.localBaseURL, let host = base.host else {
                throw ChariotError.invalidState("local power source has no base URL")
            }
            let tls = base.scheme == "https"
            return ModelBrokerRoute(
                upstreamHost: host,
                upstreamPort: UInt16(base.port ?? (tls ? 443 : 80)),
                useTLS: tls,
                basePath: normalizedBasePath(base.path),
                bearerToken: nil)
        }
    }

    private static func normalizedBasePath(_ path: String) -> String {
        var path = path
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

public final class ModelBroker: @unchecked Sendable {
    private let route: ModelBrokerRoute
    private let label: String
    private let queue = DispatchQueue(label: "chariot.modelbroker", attributes: .concurrent)

    public init(route: ModelBrokerRoute, label: String = "agent") {
        self.route = route
        self.label = label
    }

    /// Serve one guest connection on a stream fd. `close` releases the
    /// underlying connection when the exchange finishes. Never blocks the
    /// caller; all IO runs on the broker's own queue.
    public func handle(fd: Int32, close: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            defer { close() }
            guard let (head, extra) = readHead(fd: fd) else { return }

            // Muse resolves its model catalog from the origin of its base URL
            // before the first turn; answer locally (the backend's muse image
            // shim does the same) so both power sources satisfy the probe.
            if head.hasPrefix("GET /muse-code/models") {
                let body = #"{"object":"list","data":[]}"#
                let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                    + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                _ = response.withCString { write(fd, $0, strlen($0)) }
                return
            }

            guard let rewritten = ModelBroker.rewriteHead(head, route: route) else {
                let response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                _ = response.withCString { write(fd, $0, strlen($0)) }
                return
            }
            forward(fd: fd, head: rewritten, bodyPrefix: extra)
        }
    }

    /// Rewrite the request head for the upstream: request-line path, Host,
    /// Authorization (chariot), forced `Connection: close`. Pure — unit-tested
    /// directly. Returns nil for a head that is not plausible HTTP/1.x.
    static func rewriteHead(_ head: String, route: ModelBrokerRoute) -> String? {
        var lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let pieces = requestLine.split(separator: " ")
        guard pieces.count == 3, pieces[2].hasPrefix("HTTP/1.") else { return nil }
        let method = String(pieces[0])
        var path = String(pieces[1])
        if path.hasPrefix("/v1/") || path == "/v1" {
            path = route.basePath + path.dropFirst("/v1".count)
        } else {
            path = route.basePath + path
        }
        if path.isEmpty { path = "/" }
        lines[0] = "\(method) \(path) \(pieces[2])"

        let defaultPort: UInt16 = route.useTLS ? 443 : 80
        let hostValue = route.upstreamPort == defaultPort
            ? route.upstreamHost : "\(route.upstreamHost):\(route.upstreamPort)"
        var sawAuth = false
        lines = lines.map { line in
            let lower = line.lowercased()
            if lower.hasPrefix("host:") { return "Host: \(hostValue)" }
            if lower.hasPrefix("connection:") { return "Connection: close" }
            if lower.hasPrefix("authorization:"), let token = route.bearerToken {
                sawAuth = true
                return "Authorization: Bearer \(token)"
            }
            return line
        }
        if !lines.contains(where: { $0.lowercased().hasPrefix("connection:") }) {
            lines.insert("Connection: close", at: 1)
        }
        if !sawAuth, let token = route.bearerToken {
            lines.insert("Authorization: Bearer \(token)", at: 1)
        }
        return lines.joined(separator: "\r\n")
    }

    // MARK: - IO

    /// Read up to the end of the request head. Returns the head string and
    /// any body bytes that arrived in the same reads.
    private func readHead(fd: Int32) -> (String, Data)? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while buffer.count < 128 * 1024 {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<n])
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                guard let head = String(data: buffer[..<range.lowerBound], encoding: .utf8) else {
                    return nil
                }
                return (head, Data(buffer[range.upperBound...]))
            }
        }
        return nil
    }

    /// Open the upstream, send the rewritten head + any early body bytes,
    /// then pipe blindly in both directions until EOF on each side.
    private func forward(fd: Int32, head: String, bodyPrefix: Data) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(route.upstreamHost),
            port: NWEndpoint.Port(rawValue: route.upstreamPort)!)
        let parameters: NWParameters = route.useTLS ? .tls : .tcp
        let upstream = NWConnection(to: endpoint, using: parameters)
        let done = DispatchSemaphore(value: 0)
        let ready = DispatchSemaphore(value: 0)

        upstream.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed, .cancelled: ready.signal(); done.signal()
            default: break
            }
        }
        upstream.start(queue: queue)
        _ = ready.wait(timeout: .now() + 30)
        guard upstream.state == .ready else {
            let response = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            _ = response.withCString { write(fd, $0, strlen($0)) }
            upstream.cancel()
            return
        }

        upstream.send(content: Data((head + "\r\n\r\n").utf8) + bodyPrefix,
                      completion: .contentProcessed { _ in })

        // Guest → upstream: blocking reads on this queue; EOF half-closes.
        queue.async {
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n <= 0 {
                    upstream.send(content: nil, contentContext: .finalMessage,
                                  isComplete: true, completion: .contentProcessed { _ in })
                    return
                }
                upstream.send(content: Data(chunk[0..<n]), completion: .contentProcessed { _ in })
            }
        }

        // Upstream → guest: written verbatim as it arrives (SSE-safe).
        func pump() {
            upstream.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, complete, error in
                if let data, !data.isEmpty {
                    data.withUnsafeBytes { raw in
                        var offset = 0
                        while offset < raw.count {
                            let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                            if n <= 0 { return }
                            offset += n
                        }
                    }
                }
                if complete || error != nil {
                    done.signal()
                } else {
                    pump()
                }
            }
        }
        pump()

        _ = done.wait(timeout: .now() + 600)
        upstream.cancel()
        // Closing fd (via the caller's `close`) ends the guest side; the
        // bridge's forwarder propagates it to the harness client.
    }
}
