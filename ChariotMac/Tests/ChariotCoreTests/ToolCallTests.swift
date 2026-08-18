import XCTest
import CryptoKit
import AgentLinkKit
@testable import ChariotCore

/// Phone tool calls (guest → phone → guest) at the hub boundary, without a
/// VM: bridge events are injected through the test seam, and the phone side
/// runs over the real loopback transport exactly as a paired device would.
final class ToolCallTests: XCTestCase {
    var dataDir: URL!
    var hub: ChariotHub!

    static let guestResources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ChariotCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // ChariotMac
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("guest")

    override func setUpWithError() throws {
        dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chariot-toolcall-\(UUID().uuidString)")
        let paths = ChariotPaths(dataDirectory: dataDir, guestResources: Self.guestResources)
        hub = try ChariotHub(paths: paths, displayName: "Test Mac")
        hub.tailscaleEnabled = false
        hub.autoApprovePairing = true

        let baseImage = dataDir.appendingPathComponent("base.raw")
        try Data(repeating: 0xAB, count: 4096).write(to: baseImage)
        hub.defaultBaseImagePath = baseImage.path

        let dir = hub.paths.packsDirectory.appendingPathComponent("guardian.pack")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        { "id": "test.guardian", "name": "guardian", "version": "1.0.0",
          "vm": { "cpus": 2, "memoryMB": 1024, "diskGB": 1 },
          "workspace": [ { "src": "AGENTS.md", "dest": "/workspace/AGENTS.md" } ] }
        """.write(to: dir.appendingPathComponent("pack.json"), atomically: true, encoding: .utf8)
        try "# guardian".write(to: dir.appendingPathComponent("AGENTS.md"),
                               atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dataDir)
    }

    // MARK: Phone-side helpers (same shape as FleetTests)

    private func pair(identity: DeviceIdentity, payload: PairingPayload,
                      transportBase: String) async throws {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let key = try PairingCrypto.deriveKey(ephemeralPrivate: ephemeral,
                                              peerEphemeralPublic: payload.macPairingPublicKey,
                                              pairingSecret: payload.pairingSecret)
        var response = PairingResponse(mobile: identity.publicIdentity,
                                       mobileDisplayName: "Tool Test Phone",
                                       mobileEphemeralPublicKey: ephemeral.publicKey.rawRepresentation)
        try response.sign(with: identity.signingKey)
        let body = try JSONSerialization.data(withJSONObject: [
            "ephemeral_public_key": Base64URL.encode(ephemeral.publicKey.rawRepresentation),
            "ciphertext": Base64URL.encode(try PairingCrypto.seal(response, key: key))
        ])
        var request = URLRequest(url: URL(string: "\(transportBase)/pairing/\(payload.pairingID)/response")!)
        request.httpMethod = "POST"
        request.httpBody = body
        let (_, httpResponse) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((httpResponse as? HTTPURLResponse)?.statusCode, 200)
    }

    private final class WSProbe: NSObject {
        let task: URLSessionWebSocketTask
        init(url: String) {
            task = URLSession.shared.webSocketTask(with: URL(string: url)!)
            task.resume()
        }
        func next(timeout: TimeInterval = 5) async -> TransportFrame? {
            let receive = Task { () -> TransportFrame? in
                guard let message = try? await task.receive(),
                      case .string(let text) = message else { return nil }
                return try? TransportFrame.decode(Data(text.utf8))
            }
            let timer = Task { () -> TransportFrame? in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                receive.cancel()
                return nil
            }
            let frame = await receive.value
            timer.cancel()
            return frame
        }
        func send(_ frame: TransportFrame) async throws {
            let data = try frame.encoded()
            try await task.send(.string(String(data: data, encoding: .utf8)!))
        }
        func close() { task.cancel(with: .goingAway, reason: nil) }
    }

    private func hello(_ probe: WSProbe, identity: DeviceIdentity,
                       instanceID: String) async throws -> TransportFrame? {
        guard let challenge = await probe.next(), challenge.type == .challenge,
              let nonce = challenge.nonce else {
            XCTFail("no challenge frame")
            return nil
        }
        var hello = TransportFrame(type: .hello)
        hello.deviceID = identity.deviceID
        hello.instanceID = instanceID
        hello.signature = try TransportAuth.signature(nonce: nonce, deviceID: identity.deviceID,
                                                      instanceID: instanceID,
                                                      signingKey: identity.signingKey)
        try await probe.send(hello)
        return await probe.next()
    }

    /// Read frames until an envelope this session can open with the given
    /// message type arrives (status frames and acks are interleaved).
    private func nextMessage(_ probe: WSProbe, session: inout SessionCrypto,
                             type: AgentMessageType) async -> AgentMessage? {
        for _ in 0..<8 {
            guard let frame = await probe.next() else { break }
            if frame.type == .envelope, let envelope = frame.envelope,
               let message = try? session.open(envelope), message.type == type {
                return message
            }
        }
        return nil
    }

    private func waitUntil(timeout: TimeInterval = 3,
                           _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    // MARK: Tests

    func testToolCallRoundTrip() async throws {
        let guardian = try await hub.createAgent(fromPackDirectory: "guardian.pack")
        try hub.startTransportServer(port: 0, adminPort: 0)
        let transportBase = "http://127.0.0.1:\(hub.transportPort)"

        let phone = DeviceIdentity()
        let payload = try hub.startPairingSession(instanceID: guardian.instanceID)
        try await pair(identity: phone, payload: payload, transportBase: transportBase)
        let ws = WSProbe(url: "ws://127.0.0.1:\(hub.transportPort)/v2/ws")
        let welcome = try await hello(ws, identity: phone, instanceID: guardian.instanceID)
        XCTAssertEqual(welcome?.type, .welcome)
        defer { ws.close() }

        // The guest asks for a phone tool. The turn id has no live stream
        // (locally started turn), so the hub routes to the context's sole
        // paired device — this probe.
        let before = Date().timeIntervalSince1970
        hub._injectBridgeEvent(instanceID: guardian.instanceID,
                               .toolCall(requestID: "call-1", turnRequestID: "turn-x",
                                         conversationID: "guardian", name: "log_water",
                                         arguments: .object(["millilitres": .number(600)])))

        var session = try SessionCrypto(localIdentity: phone,
                                        peerPublicIdentity: hub.macPublicIdentity, epoch: 1)
        let call = await nextMessage(ws, session: &session, type: .toolCall)
        XCTAssertNotNil(call, "the paired phone must receive the sealed tool.call envelope")
        XCTAssertEqual(call?.body["request_id"]?.stringValue, "call-1")
        XCTAssertEqual(call?.body["name"]?.stringValue, "log_water")
        XCTAssertEqual(call?.body["arguments"]?["millilitres"]?.numberValue, 600)
        XCTAssertEqual(call?.body["turn_id"]?.stringValue, "turn-x")
        let expiresAt = call?.body["expires_at"]?.numberValue ?? 0
        XCTAssertGreaterThan(expiresAt, before, "expires_at must be a future Unix timestamp")
        XCTAssertTrue(hub._hasPendingToolCall("call-1"))

        // The phone answers: the pending entry resolves exactly once.
        let result = AgentMessage(conversationID: "guardian", senderDeviceID: phone.deviceID,
                                  sequence: 1, type: .toolResult,
                                  body: .object(["request_id": .string("call-1"),
                                                 "ok": .bool(true),
                                                 "output": .string("logged 600 ml")]))
        var frame = TransportFrame(type: .envelope)
        frame.envelope = try session.seal(result)
        try await ws.send(frame)
        let resolved = await waitUntil { !self.hub._hasPendingToolCall("call-1") }
        XCTAssertTrue(resolved, "a valid result from the addressed phone must resolve the call")

        // A duplicate (and any unknown id) is dropped without error — the
        // hub logs it and keeps the session healthy.
        let duplicate = AgentMessage(conversationID: "guardian", senderDeviceID: phone.deviceID,
                                     sequence: 2, type: .toolResult,
                                     body: .object(["request_id": .string("call-1"),
                                                    "ok": .bool(true),
                                                    "output": .string("again")]))
        var duplicateFrame = TransportFrame(type: .envelope)
        duplicateFrame.envelope = try session.seal(duplicate)
        try await ws.send(duplicateFrame)
        let logged = await waitUntil {
            self.hub.eventBuffer.recent().contains { $0.contains("unknown/expired call call-1") }
        }
        XCTAssertTrue(logged, "a duplicate result must be logged and dropped")
    }

    func testToolCallTimesOutWhenPhoneSilent() async throws {
        let guardian = try await hub.createAgent(fromPackDirectory: "guardian.pack")
        try hub.startTransportServer(port: 0, adminPort: 0)
        hub.toolCallTimeout = 0.3

        // Paired but never connects: the envelope sits in the mailbox and
        // nobody answers.
        let phone = DeviceIdentity()
        let payload = try hub.startPairingSession(instanceID: guardian.instanceID)
        try await pair(identity: phone, payload: payload,
                       transportBase: "http://127.0.0.1:\(hub.transportPort)")

        hub._injectBridgeEvent(instanceID: guardian.instanceID,
                               .toolCall(requestID: "call-slow", turnRequestID: "turn-y",
                                         conversationID: "guardian", name: "day_summary",
                                         arguments: .object([:])))
        XCTAssertTrue(hub._hasPendingToolCall("call-slow"))

        let timedOut = await waitUntil { !self.hub._hasPendingToolCall("call-slow") }
        XCTAssertTrue(timedOut, "the hub must give up on a silent phone")
        let logged = await waitUntil {
            self.hub.eventBuffer.recent().contains { $0.contains("phone did not respond in time") }
        }
        XCTAssertTrue(logged)
    }

    func testToolCallWithNoPairedPhoneFailsImmediately() async throws {
        let guardian = try await hub.createAgent(fromPackDirectory: "guardian.pack")
        try hub.startTransportServer(port: 0, adminPort: 0)

        hub._injectBridgeEvent(instanceID: guardian.instanceID,
                               .toolCall(requestID: "call-none", turnRequestID: "turn-z",
                                         conversationID: "guardian", name: "recall",
                                         arguments: .object(["key": .string("goal")])))
        XCTAssertFalse(hub._hasPendingToolCall("call-none"),
                       "with nobody to answer, the call must not be left pending")
        let refused = await waitUntil {
            self.hub.eventBuffer.recent().contains { $0.contains("no phone to run it on") }
        }
        XCTAssertTrue(refused)
    }

    func testConversationSendRejectsBadAttachmentPaths() {
        let body = JSONValue.object([
            "text": .string("look at this"),
            "attachments": .array([
                .string("/workspace/data/attachments/abc-photo.png"),   // kept
                .string("/etc/passwd"),                                 // outside the guard
                .string("/workspace/../etc/shadow"),                    // traversal
                .string("workspace/data/relative.png"),                 // not absolute
                .number(7)                                              // not even a string
            ])
        ])
        XCTAssertEqual(ChariotHub.sanitizedAttachments(body),
                       ["/workspace/data/attachments/abc-photo.png"])
        XCTAssertEqual(ChariotHub.sanitizedAttachments(.object(["text": .string("plain")])), [])
    }
}
