import Foundation

/// Minimal blocking HTTP/1.1 server bound to 127.0.0.1 only, with WebSocket
/// upgrade support. It never listens on a LAN or public interface: tailnet
/// clients reach it exclusively through the agent-tailnet helper's tsnet
/// listener, which proxies to this loopback socket.
final class HTTPServer: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]  // keys lowercased
        let body: Data
    }

    struct Response {
        let status: Int
        let body: Data
        var contentType: String = "application/json"
        /// When set, the connection is upgraded to a WebSocket after the
        /// handshake and handed to this callback; status/body are ignored.
        var webSocket: ((WebSocketConnection) -> Void)?

        static func json(_ object: Any, status: Int = 200) -> Response {
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
            return Response(status: status, body: data)
        }

        static func data(_ data: Data, status: Int = 200) -> Response {
            Response(status: status, body: data)
        }

        static func error(_ status: Int, _ message: String) -> Response {
            .json(["error": message], status: status)
        }

        static func upgrade(_ handler: @escaping (WebSocketConnection) -> Void) -> Response {
            Response(status: 101, body: Data(), webSocket: handler)
        }
    }

    private let handler: @Sendable (Request) -> Response
    private var listenerFD: Int32 = -1
    private(set) var port: UInt16 = 0
    private var running = false

    init(handler: @escaping @Sendable (Request) -> Response) {
        self.handler = handler
    }

    func start(port requestedPort: UInt16) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ChariotError.io("socket failed") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = requestedPort.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard ok, listen(fd, 32) == 0 else {
            Darwin.close(fd)
            throw ChariotError.io("bind/listen on 127.0.0.1:\(requestedPort): \(String(cString: strerror(errno)))")
        }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &len) }
        }
        listenerFD = fd
        port = UInt16(bigEndian: bound.sin_port)
        running = true
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "chariot.http.accept"
        thread.start()
    }

    func stop() {
        running = false
        if listenerFD >= 0 { Darwin.close(listenerFD) }
        listenerFD = -1
    }

    private func acceptLoop() {
        while running {
            let client = accept(listenerFD, nil, nil)
            guard client >= 0 else { break }
            let thread = Thread { [weak self] in self?.handle(client: client) }
            thread.name = "chariot.http.connection"
            thread.start()
        }
    }

    private func handle(client: Int32) {
        var closeOnExit = true
        defer { if closeOnExit { Darwin.close(client) } }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)

        // Read until we have headers, then until content-length is satisfied.
        var headerEnd: Range<Data.Index>?
        var contentLength = 0
        while true {
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = end
                let headerText = String(data: buffer.subdata(in: buffer.startIndex..<end.lowerBound), encoding: .utf8) ?? ""
                for line in headerText.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
                    contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
                }
                if buffer.count - end.upperBound >= contentLength { break }
            }
            if buffer.count > 32 * 1024 * 1024 { return }  // bounded payloads
            let n = read(client, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
        }
        guard let end = headerEnd else { return }
        let headerData = buffer.subdata(in: buffer.startIndex..<end.lowerBound)
        let body = buffer.subdata(in: end.upperBound..<buffer.index(end.upperBound, offsetBy: contentLength))
        guard let headerText = String(data: headerData, encoding: .utf8) else { return }
        let headerLines = headerText.split(separator: "\r\n")
        guard let requestLine = headerLines.first else { return }
        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        let method = String(parts[0])
        let target = String(parts[1])

        var path = target
        var query: [String: String] = [:]
        if let qIndex = target.firstIndex(of: "?") {
            path = String(target[target.startIndex..<qIndex])
            for pair in target[target.index(after: qIndex)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    query[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                }
            }
        }

        let request = Request(method: method, path: path, query: query, headers: headers, body: body)
        let response = handler(request)

        if let wsHandler = response.webSocket {
            guard headers["upgrade"]?.lowercased() == "websocket",
                  let clientKey = headers["sec-websocket-key"] else {
                let out = Data("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                _ = out.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                return
            }
            let accept = WebSocketConnection.acceptKey(for: clientKey)
            let handshake = "HTTP/1.1 101 Switching Protocols\r\n"
                + "Upgrade: websocket\r\n"
                + "Connection: Upgrade\r\n"
                + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
            let out = Data(handshake.utf8)
            _ = out.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
            let connection = WebSocketConnection(fd: client)
            wsHandler(connection)
            closeOnExit = true  // run() returns when the socket is done
            connection.run()
            return
        }

        let statusText = response.status == 200 ? "OK" : (response.status == 404 ? "Not Found" : "Error")
        var out = Data("HTTP/1.1 \(response.status) \(statusText)\r\n".utf8)
        out.append(Data("Content-Type: \(response.contentType)\r\n".utf8))
        out.append(Data("Content-Length: \(response.body.count)\r\n".utf8))
        out.append(Data("Connection: close\r\n\r\n".utf8))
        out.append(response.body)
        out.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let w = write(client, buf.baseAddress!.advanced(by: off), buf.count - off)
                if w <= 0 { return }
                off += w
            }
        }
    }
}
