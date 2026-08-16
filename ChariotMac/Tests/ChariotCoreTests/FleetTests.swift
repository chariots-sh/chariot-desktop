import XCTest
import CryptoKit
import AgentLinkKit
@testable import ChariotCore

/// Fleet + per-agent pairing (Milestone 1), without booting VMs: agents are
/// created against a tiny fake base image, and the pairing/WS-auth paths run
/// over the real loopback transport exactly as the phone reaches them.
final class FleetTests: XCTestCase {
    var dataDir: URL!
    var hub: ChariotHub!

    /// bridge.py + user-data.template from the repo checkout (needed by the
    /// seed ISO builder when instances are created).
    static let guestResources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ChariotCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // ChariotMac
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("guest")

    override func setUpWithError() throws {
        dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chariot-fleet-\(UUID().uuidString)")
        let paths = ChariotPaths(dataDirectory: dataDir, guestResources: Self.guestResources)
        hub = try ChariotHub(paths: paths, displayName: "Test Mac")
        hub.tailscaleEnabled = false
        hub.autoApprovePairing = true

        // A tiny stand-in base image: cloning and sparse-growing it is all
        // that agent creation needs.
        let baseImage = dataDir.appendingPathComponent("base.raw")
        try Data(repeating: 0xAB, count: 4096).write(to: baseImage)
        hub.defaultBaseImagePath = baseImage.path

        for pack in ["guardian.pack", "scribe.pack"] {
            let dir = hub.paths.packsDirectory.appendingPathComponent(pack)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try """
            { "id": "test.\(pack)", "name": "\(pack.replacingOccurrences(of: ".pack", with: ""))",
              "version": "1.0.0",
              "vm": { "cpus": 3, "memoryMB": 2048, "diskGB": 1 },
              "workspace": [ { "src": "AGENTS.md", "dest": "/workspace/AGENTS.md" } ] }
            """.write(to: dir.appendingPathComponent("pack.json"), atomically: true, encoding: .utf8)
            try "# \(pack)".write(to: dir.appendingPathComponent("AGENTS.md"),
                                  atomically: true, encoding: .utf8)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dataDir)
    }

    func testCreateAgentMintsUUIDAppliesSizingAndPersists() async throws {
        let guardian = try await hub.createAgent(fromPackDirectory: "guardian.pack")
        let scribe = try await hub.createAgent(fromPackDirectory: "scribe.pack", displayName: "My Scribe")

        // The instance UUID is the durable identity: distinct, full-length,
        // and it names the on-disk instance.
        XCTAssertNotEqual(guardian.instanceID, scribe.instanceID)
        XCTAssertNotNil(UUID(uuidString: guardian.instanceID))
        XCTAssertEqual(scribe.displayName, "My Scribe")
        let instanceDir = hub.paths.instanceDirectory(guardian.instanceID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: instanceDir.path))

        // Per-pack VM sizing lands in the instance configuration.
        let configData = try Data(contentsOf: InstancePaths(directory: instanceDir).configuration)
        let config = try JSONDecoder().decode(SandboxConfiguration.self, from: configData)
        XCTAssertEqual(config.cpuCount, 3)
        XCTAssertEqual(config.memoryBytes, 2048 * 1024 * 1024)
        XCTAssertEqual(config.diskBytes, 1024 * 1024 * 1024)

        // A fresh hub over the same data dir reloads the fleet.
        let reloaded = try ChariotHub(paths: hub.paths, displayName: "Test Mac")
        XCTAssertEqual(Set(reloaded.agentRecords().map(\.instanceID)),
                       [guardian.instanceID, scribe.instanceID])
        XCTAssertEqual(reloaded.agentSummaries().count, 2)

        // The legacy single-VM flow must never adopt an agent's instance.
        let legacy = try await reloaded.ensureInstance(
            configuration: SandboxConfiguration(baseImagePath: hub.defaultBaseImagePath!))
        XCTAssertFalse([guardian.instanceID, scribe.instanceID].contains(legacy))
    }

    // MARK: Per-agent pairing over the real transport

    /// Phone-side pairing handshake against the loopback transport, exactly
    /// as the E2E harness does it.
    private func pair(identity: DeviceIdentity, payload: PairingPayload,
                      transportBase: String) async throws {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let key = try PairingCrypto.deriveKey(ephemeralPrivate: ephemeral,
                                              peerEphemeralPublic: payload.macPairingPublicKey,
                                              pairingSecret: payload.pairingSecret)
        var response = PairingResponse(mobile: identity.publicIdentity,
                                       mobileDisplayName: "Fleet Test Phone",
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

    func testPairingBindsToOneAgentOnly() async throws {
        let guardian = try await hub.createAgent(fromPackDirectory: "guardian.pack")
        let scribe = try await hub.createAgent(fromPackDirectory: "scribe.pack")
        try hub.startTransportServer(port: 0, adminPort: 0)
        let transportBase = "http://127.0.0.1:\(hub.transportPort)"

        // The QR targets guardian: its instance UUID rides in the payload.
        let payload = try hub.startPairingSession(instanceID: guardian.instanceID)
        XCTAssertEqual(payload.instanceID, guardian.instanceID)
        _ = try PairingPayload.validate(json: CanonicalCoding.encode(payload))

        let phone = DeviceIdentity()
        try await pair(identity: phone, payload: payload, transportBase: transportBase)

        // The credential lives in guardian's registry — and only there.
        XCTAssertEqual(hub.pairedDevices(instanceID: guardian.instanceID).map(\.id), [phone.deviceID])
        XCTAssertTrue(hub.pairedDevices(instanceID: scribe.instanceID).isEmpty)

        // WS hello against guardian: welcome.
        let guardianWS = WSProbe(url: "ws://127.0.0.1:\(hub.transportPort)/v2/ws")
        let welcome = try await hello(guardianWS, identity: phone, instanceID: guardian.instanceID)
        XCTAssertEqual(welcome?.type, .welcome)

        // An envelope through the authenticated session routes to guardian's
        // context: with no VM running, guardian itself answers with the
        // "sandbox is not running" completion.
        var session = try SessionCrypto(localIdentity: phone,
                                        peerPublicIdentity: hub.macPublicIdentity, epoch: 1)
        let prompt = AgentMessage(conversationID: "default", senderDeviceID: phone.deviceID,
                                  sequence: 1, type: .conversationSend,
                                  body: .object(["text": .string("hello guardian")]))
        var envelopeFrame = TransportFrame(type: .envelope)
        envelopeFrame.envelope = try session.seal(prompt)
        try await guardianWS.send(envelopeFrame)
        var completed: AgentMessage?
        for _ in 0..<6 {
            guard let frame = await guardianWS.next() else { break }
            if frame.type == .envelope, let envelope = frame.envelope,
               let message = try? session.open(envelope), message.type == .outputCompleted {
                completed = message
                break
            }
        }
        XCTAssertEqual(completed?.body["error"]?.stringValue, "sandbox is not running")
        guardianWS.close()

        // The same (validly signed) device is denied on scribe's endpoint:
        // per-agent pairing means the other agent treats it as unpaired.
        let scribeWS = WSProbe(url: "ws://127.0.0.1:\(hub.transportPort)/v2/ws")
        let denial = try await hello(scribeWS, identity: phone, instanceID: scribe.instanceID)
        XCTAssertEqual(denial?.type, .denied)
        scribeWS.close()

        // Pairing scribe separately works and keeps its own epoch/registry.
        let scribePayload = try hub.startPairingSession(instanceID: scribe.instanceID)
        let secondPhone = DeviceIdentity()
        try await pair(identity: secondPhone, payload: scribePayload, transportBase: transportBase)
        XCTAssertEqual(hub.pairedDevices(instanceID: scribe.instanceID).map(\.id),
                       [secondPhone.deviceID])
        XCTAssertEqual(hub.pairedDevices(instanceID: guardian.instanceID).map(\.id),
                       [phone.deviceID])

        // Revocation is per agent: revoking the phone on guardian advances
        // guardian's epoch only.
        hub.revokeDevice(phone.deviceID, instanceID: guardian.instanceID)
        XCTAssertTrue(hub.pairedDevices(instanceID: guardian.instanceID)[0].revoked)
        XCTAssertFalse(hub.pairedDevices(instanceID: scribe.instanceID)[0].revoked)
    }

    /// file.write envelopes (phone → workspace): deflated contents decode
    /// and route to the bridge (whose absence is reported honestly), and
    /// path traversal is rejected outright. The two distinct errors prove
    /// where each request got to.
    func testFileWriteEnvelopeDecodesDeflateAndGuardsPaths() async throws {
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

        var session = try SessionCrypto(localIdentity: phone,
                                        peerPublicIdentity: hub.macPublicIdentity, epoch: 1)
        func sendFileWrite(sequence: UInt64, body: JSONValue) async throws -> AgentMessage? {
            let message = AgentMessage(conversationID: "guardian", senderDeviceID: phone.deviceID,
                                       sequence: sequence, type: .fileWrite, body: body)
            var frame = TransportFrame(type: .envelope)
            frame.envelope = try session.seal(message)
            try await ws.send(frame)
            for _ in 0..<6 {
                guard let reply = await ws.next() else { break }
                if reply.type == .envelope, let envelope = reply.envelope,
                   let opened = try? session.open(envelope), opened.type == .fileWriteResult,
                   opened.body["request_id"]?.stringValue == message.messageID {
                    return opened
                }
            }
            return nil
        }

        // Deflated contents for a valid path decode fine and make it all the
        // way to the (absent) bridge — a decode failure would surface as
        // "invalid path or contents" instead.
        let raw = Data(String(repeating: "phone data ", count: 4096).utf8)
        let deflated = try (raw as NSData).compressed(using: .zlib) as Data
        let accepted = try await sendFileWrite(sequence: 1, body: .object([
            "path": .string("/workspace/data/archive.json"),
            "contents_b64": .string(deflated.base64EncodedString()),
            "encoding": .string("deflate")
        ]))
        XCTAssertEqual(accepted?.body["ok"]?.boolValue, false)
        XCTAssertEqual(accepted?.body["error"]?.stringValue, "sandbox is not running")

        // Path traversal out of /workspace is refused before any bridge work.
        let rejected = try await sendFileWrite(sequence: 2, body: .object([
            "path": .string("/workspace/../etc/passwd"),
            "contents_b64": .string(Data("nope".utf8).base64EncodedString())
        ]))
        XCTAssertEqual(rejected?.body["ok"]?.boolValue, false)
        XCTAssertEqual(rejected?.body["error"]?.stringValue, "invalid path or contents")
    }
}
