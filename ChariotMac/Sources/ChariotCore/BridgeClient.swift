import Foundation
import Virtualization

/// Agent runtime state reported by the guest (design goal: the agent is Codex).
public struct AgentRuntimeStatus: Sendable, Equatable {
    public let name: String
    public let installed: Bool
    public let version: String?
    public let loggedIn: Bool
    public let installError: String?
}

/// Which audience a chunk of agent output is for. `reply` is what the agent
/// deliberately addressed to its person (written through its reply tool) and
/// is all the phone ever sees; `trace` is the working transcript — commands,
/// edits, mid-turn chatter — which stays on the Mac.
public enum OutputChannel: String, Sendable {
    case reply
    case trace
}

/// Events emitted by the guest bridge over the typed vsock channel.
public enum BridgeEvent: Sendable {
    case status(state: String, uptimeSeconds: Int, kernel: String, hostname: String,
                agent: AgentRuntimeStatus?)
    case outputDelta(requestID: String, conversationID: String, channel: OutputChannel, text: String)
    case outputCompleted(requestID: String, conversationID: String, exitCode: Int)
    case oauthRequested(provider: String, purpose: String, authURL: String)
    case oauthCompleted(success: Bool, message: String)
    case pong
    case error(String)
    case disconnected(String)
}

/// JSON-lines client for the guest bridge on vsock port 1024 (design §1.4).
final class BridgeClient: @unchecked Sendable {
    private let connection: VZVirtioSocketConnection
    private let fd: Int32
    private let writeLock = NSLock()
    private let handler: @Sendable (BridgeEvent) -> Void
    private var readerThread: Thread?
    // file.put replies correlated by request ID (Milestone 1: pack pushes).
    private let putLock = NSLock()
    private var pendingFilePuts: [String: @Sendable (Result<Bool, ChariotError>) -> Void] = [:]
    // agent.configure acks, correlated the same way.
    private var pendingConfigures: [String: @Sendable (Result<Void, ChariotError>) -> Void] = [:]

    init(connection: VZVirtioSocketConnection, handler: @escaping @Sendable (BridgeEvent) -> Void) {
        self.connection = connection
        self.fd = connection.fileDescriptor
        self.handler = handler
        disableSIGPIPE(on: fd)
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "chariot.bridge.reader"
        readerThread = thread
        thread.start()
    }

    func close() {
        connection.close()
    }

    // MARK: Sending

    private func sendObject(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        writeLock.lock()
        defer { writeLock.unlock() }
        var payload = data
        payload.append(0x0A)
        let ok = payload.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
        if !ok { throw ChariotError.bridgeUnavailable("write failed: \(String(cString: strerror(errno)))") }
    }

    func sendConversation(requestID: String, conversationID: String, text: String) throws {
        try sendObject([
            "type": "conversation.send",
            "request_id": requestID,
            "conversation_id": conversationID,
            "body": ["text": text]
        ])
    }

    func cancel(conversationID: String) throws {
        try sendObject(["type": "conversation.cancel", "conversation_id": conversationID])
    }

    func requestStatus() throws {
        try sendObject(["type": "sandbox.status"])
    }

    func startLogin() throws {
        try sendObject(["type": "oauth.start"])
    }

    func cancelLogin() throws {
        try sendObject(["type": "oauth.cancel"])
    }

    func ping() throws {
        try sendObject(["type": "ping"])
    }

    /// Install one file into the guest workspace via the bridge's `file.put`
    /// op. Returns true when the file was written, false when `ifAbsent` was
    /// set and the guest already had it (seed-only semantics).
    func putFile(path: String, contents: Data, mode: Int = 0o644,
                 ifAbsent: Bool = false, timeout: TimeInterval = 30) async throws -> Bool {
        let requestID = UUID().uuidString.lowercased()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            putLock.lock()
            pendingFilePuts[requestID] = { cont.resume(with: $0) }
            putLock.unlock()
            do {
                try sendObject([
                    "type": "file.put",
                    "request_id": requestID,
                    "path": path,
                    "content_b64": contents.base64EncodedString(),
                    "mode": mode,
                    "if_absent": ifAbsent
                ])
            } catch {
                resolveFilePut(requestID: requestID,
                               result: .failure(.bridgeUnavailable("file.put send failed: \(error)")))
                return
            }
            // An old guest bridge (pre-file.put) answers with an untyped error
            // and no request ID; the timeout keeps the host from hanging.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resolveFilePut(requestID: requestID,
                                     result: .failure(.bridgeUnavailable(
                                        "file.put timed out — guest bridge may predate pack support (Reset the agent)")))
            }
        }
    }

    /// Push the agent's power configuration into the guest: the bridge
    /// persists it outside /workspace, renders the harness-native config, and
    /// starts its loopback model forwarder before acking.
    func configure(_ settings: [String: Any], timeout: TimeInterval = 20) async throws {
        let requestID = UUID().uuidString.lowercased()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            putLock.lock()
            pendingConfigures[requestID] = { cont.resume(with: $0) }
            putLock.unlock()
            var object = settings
            object["type"] = "agent.configure"
            object["request_id"] = requestID
            do {
                try sendObject(object)
            } catch {
                resolveConfigure(requestID: requestID,
                                 result: .failure(.bridgeUnavailable("agent.configure send failed: \(error)")))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resolveConfigure(requestID: requestID,
                                       result: .failure(.bridgeUnavailable(
                                          "agent.configure timed out — guest bridge may predate harness support (Reset the agent)")))
            }
        }
    }

    /// Resolution is exactly-once: whichever of reply / send-failure / timeout
    /// removes the pending entry first gets to resume the continuation.
    private func resolveFilePut(requestID: String, result: Result<Bool, ChariotError>) {
        putLock.lock()
        let completion = pendingFilePuts.removeValue(forKey: requestID)
        putLock.unlock()
        completion?(result)
    }

    private func resolveConfigure(requestID: String, result: Result<Void, ChariotError>) {
        putLock.lock()
        let completion = pendingConfigures.removeValue(forKey: requestID)
        putLock.unlock()
        completion?(result)
    }

    private func failAllFilePuts(_ reason: String) {
        putLock.lock()
        let pendingPuts = pendingFilePuts.values
        pendingFilePuts.removeAll()
        let pendingConfs = pendingConfigures.values
        pendingConfigures.removeAll()
        putLock.unlock()
        pendingPuts.forEach { $0(.failure(.bridgeUnavailable(reason))) }
        pendingConfs.forEach { $0(.failure(.bridgeUnavailable(reason))) }
    }

    // MARK: Receiving

    private func readLoop() {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 {
                failAllFilePuts("bridge disconnected")
                handler(.disconnected(count == 0 ? "eof" : String(cString: strerror(errno))))
                return
            }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !line.isEmpty else { continue }
                dispatch(line)
            }
            if buffer.count > 4 * 1024 * 1024 {
                handler(.disconnected("oversized bridge frame"))
                return
            }
        }
    }

    private func dispatch(_ line: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = object["type"] as? String else {
            handler(.error("malformed bridge message"))
            return
        }
        switch type {
        case "sandbox.status":
            var agent: AgentRuntimeStatus?
            if let info = object["agent"] as? [String: Any] {
                agent = AgentRuntimeStatus(name: info["name"] as? String ?? "agent",
                                           installed: info["installed"] as? Bool ?? false,
                                           version: info["version"] as? String,
                                           loggedIn: info["logged_in"] as? Bool ?? false,
                                           installError: info["install_error"] as? String)
            }
            handler(.status(state: object["state"] as? String ?? "unknown",
                            uptimeSeconds: object["uptime_seconds"] as? Int ?? 0,
                            kernel: object["kernel"] as? String ?? "?",
                            hostname: object["hostname"] as? String ?? "?",
                            agent: agent))
        case "oauth.requested":
            handler(.oauthRequested(provider: object["provider"] as? String ?? "?",
                                    purpose: object["purpose"] as? String ?? "",
                                    authURL: object["auth_url"] as? String ?? ""))
        case "oauth.completed":
            handler(.oauthCompleted(success: object["success"] as? Bool ?? false,
                                    message: object["message"] as? String ?? ""))
        case "output.delta":
            // A guest bridge that predates channels sends everything unlabelled;
            // treat that as a reply so an old sandbox still answers its phone.
            let channel = (object["channel"] as? String).flatMap(OutputChannel.init(rawValue:)) ?? .reply
            handler(.outputDelta(requestID: object["request_id"] as? String ?? "",
                                 conversationID: object["conversation_id"] as? String ?? "",
                                 channel: channel,
                                 text: object["text"] as? String ?? ""))
        case "output.completed":
            handler(.outputCompleted(requestID: object["request_id"] as? String ?? "",
                                     conversationID: object["conversation_id"] as? String ?? "",
                                     exitCode: object["exit_code"] as? Int ?? 0))
        case "file.put.result":
            let requestID = object["request_id"] as? String ?? ""
            if object["ok"] as? Bool == true {
                resolveFilePut(requestID: requestID, result: .success(object["written"] as? Bool ?? true))
            } else {
                resolveFilePut(requestID: requestID,
                               result: .failure(.io(object["error"] as? String ?? "file.put failed")))
            }
        case "agent.configure.result":
            let requestID = object["request_id"] as? String ?? ""
            if object["ok"] as? Bool == true {
                resolveConfigure(requestID: requestID, result: .success(()))
            } else {
                resolveConfigure(requestID: requestID,
                                 result: .failure(.io(object["error"] as? String ?? "agent.configure failed")))
            }
        case "pong":
            handler(.pong)
        case "error":
            handler(.error(object["error"] as? String ?? "unknown bridge error"))
        default:
            handler(.error("unknown bridge message type \(type)"))
        }
    }
}
