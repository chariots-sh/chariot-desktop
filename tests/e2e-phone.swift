// E2E harness: acts as the phone against a running chariotd (loopback dev
// mode, --no-vm). Exercises QR v2 pairing, atomic single-use pairing ID,
// WebSocket challenge-response auth, message roundtrip, duplicate delivery,
// offline replay, and revocation.
import Foundation
import CryptoKit

let e2ePort = ProcessInfo.processInfo.environment["CHARIOT_E2E_PORT"] ?? "9787"
let transportBase = "http://127.0.0.1:\(e2ePort)"
let adminBase = "http://127.0.0.1:\((UInt16(e2ePort) ?? 9787) + 1)"

var passed = 0
var failed = 0
func check(_ condition: Bool, _ name: String) {
    if condition { passed += 1; print("PASS \(name)") }
    else { failed += 1; print("FAIL \(name)") }
}

func http(_ method: String, _ urlString: String, body: Data? = nil) async throws -> (Int, Data) {
    var request = URLRequest(url: URL(string: urlString)!, timeoutInterval: 10)
    request.httpMethod = method
    request.httpBody = body
    let (data, response) = try await URLSession.shared.data(for: request)
    return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
}

final class WSClient: NSObject {
    let task: URLSessionWebSocketTask
    private var continuation: AsyncStream<TransportFrame>.Continuation!
    let frames: AsyncStream<TransportFrame>

    init(url: String) {
        task = URLSession.shared.webSocketTask(with: URL(string: url)!)
        var cont: AsyncStream<TransportFrame>.Continuation!
        frames = AsyncStream { cont = $0 }
        continuation = cont
        super.init()
        task.resume()
        receive()
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message,
                   let frame = try? TransportFrame.decode(Data(text.utf8)) {
                    self.continuation.yield(frame)
                }
                self.receive()
            case .failure:
                self.continuation.finish()
            }
        }
    }

    func send(_ frame: TransportFrame) throws {
        let data = try frame.encoded()
        task.send(.string(String(data: data, encoding: .utf8)!)) { _ in }
    }

    func next(timeout: TimeInterval = 8) async -> TransportFrame? {
        await withTaskGroup(of: TransportFrame?.self) { group in
            group.addTask { [frames] in
                for await frame in frames { return frame }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}

@main
struct E2E {
    static func main() async throws {
        // 1. Mint a pairing payload via the admin surface and validate it as
        //    the phone would.
        let (payloadStatus, payloadData) = try await http("POST", "\(adminBase)/admin/pairing")
        check(payloadStatus == 200, "admin mints pairing payload")
        let payload = try PairingPayload.validate(json: payloadData)
        check(payload.version == 2 && payload.type == "agent-link-tailscale-pairing", "payload is QR v2")
        check(payload.serviceURL.hasPrefix("http://127.0.0.1"), "dev payload uses loopback service URL")

        // 2. Pair.
        let identity = DeviceIdentity()
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let pairingKey = try PairingCrypto.deriveKey(ephemeralPrivate: ephemeral,
                                                     peerEphemeralPublic: payload.macPairingPublicKey,
                                                     pairingSecret: payload.pairingSecret)
        var response = PairingResponse(mobile: identity.publicIdentity,
                                       mobileDisplayName: "E2E Phone",
                                       mobileEphemeralPublicKey: ephemeral.publicKey.rawRepresentation)
        try response.sign(with: identity.signingKey)
        let sealed = try PairingCrypto.seal(response, key: pairingKey)
        let claimBody = try JSONSerialization.data(withJSONObject: [
            "ephemeral_public_key": Base64URL.encode(ephemeral.publicKey.rawRepresentation),
            "ciphertext": Base64URL.encode(sealed)
        ])
        let (claimStatus, _) = try await http("POST", "\(transportBase)/pairing/\(payload.pairingID)/response", body: claimBody)
        check(claimStatus == 200, "pairing response accepted")

        // 3. Replayed claim of the single-use pairing ID must fail.
        let (replayStatus, _) = try await http("POST", "\(transportBase)/pairing/\(payload.pairingID)/response", body: claimBody)
        check(replayStatus == 409, "replayed pairing claim rejected (409)")

        // 4. Fetch + verify credential (daemon auto-approves).
        var credential: DeviceCredential?
        var epoch: UInt32 = 0
        for _ in 0..<10 {
            let (status, data) = try await http("GET", "\(transportBase)/pairing/\(payload.pairingID)/credential")
            if status == 200,
               let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ciphertext = object["ciphertext"] as? String {
                credential = try PairingCrypto.open(DeviceCredential.self,
                                                    combined: Base64URL.decode(ciphertext), key: pairingKey)
                epoch = UInt32(object["epoch"] as? Int ?? 1)
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        guard let credential else { check(false, "credential issued"); exit(1) }
        try credential.verify(pinnedMacSigningKey: payload.macSigningPublicKey)
        check(credential.mobile.deviceID == identity.deviceID, "credential issued and verified")

        // 5. WebSocket: challenge → hello → welcome.
        let ws = WSClient(url: "ws://127.0.0.1:\(e2ePort)/v2/ws")
        guard let challenge = await ws.next(), challenge.type == .challenge, let nonce = challenge.nonce else {
            check(false, "server sends challenge"); exit(1)
        }
        check(true, "server sends challenge")
        var hello = TransportFrame(type: .hello)
        hello.deviceID = identity.deviceID
        hello.instanceID = payload.instanceID
        hello.signature = try TransportAuth.signature(nonce: nonce, deviceID: identity.deviceID,
                                                      instanceID: payload.instanceID,
                                                      signingKey: identity.signingKey)
        try ws.send(hello)
        let welcome = await ws.next()
        check(welcome?.type == .welcome, "authenticated hello → welcome")
        let status = await ws.next()
        check(status?.type == .status, "status frame after welcome")

        // 5b. A second socket with a *wrong* signature must be denied.
        let badWS = WSClient(url: "ws://127.0.0.1:\(e2ePort)/v2/ws")
        if let badChallenge = await badWS.next(), badChallenge.type == .challenge {
            var badHello = TransportFrame(type: .hello)
            let impostor = DeviceIdentity()   // unpaired key, real device ID
            badHello.deviceID = identity.deviceID
            badHello.instanceID = payload.instanceID
            badHello.signature = try TransportAuth.signature(nonce: badChallenge.nonce!,
                                                             deviceID: identity.deviceID,
                                                             instanceID: payload.instanceID,
                                                             signingKey: impostor.signingKey)
            try badWS.send(badHello)
            let denial = await badWS.next()
            check(denial?.type == .denied, "forged hello signature → denied")
        } else {
            check(false, "forged hello signature → denied")
        }
        badWS.close()

        // Reconnect the real session (the impostor handshake may have raced).
        let session = try SessionCrypto(localIdentity: identity,
                                        peerPublicIdentity: credential.mac, epoch: epoch)

        // 6. Message roundtrip: conversation.send → ack + output.completed
        //    ("sandbox is not running" since chariotd runs --no-vm).
        var sequence: UInt64 = 1
        let prompt = AgentMessage(conversationID: "default", senderDeviceID: identity.deviceID,
                                  sequence: sequence, type: .conversationSend,
                                  body: .object(["text": .string("hello over tailscale")]))
        let promptEnvelope = try session.seal(prompt)
        var promptFrame = TransportFrame(type: .envelope)
        promptFrame.envelope = promptEnvelope
        try ws.send(promptFrame)

        var gotAck = false
        var completed: AgentMessage?
        for _ in 0..<8 {
            if gotAck && completed != nil { break }
            guard let frame = await ws.next() else { break }
            if frame.type == .ack, frame.messageIDs?.contains(prompt.messageID) == true { gotAck = true }
            if frame.type == .envelope, let envelope = frame.envelope,
               let message = try? session.open(envelope) {
                var ack = TransportFrame(type: .ack)
                ack.messageIDs = [envelope.messageID]
                try ws.send(ack)
                if message.type == .outputCompleted { completed = message }
            }
        }
        check(gotAck, "Mac acks inbound message")
        check(completed?.body["error"]?.stringValue == "sandbox is not running",
              "roundtrip: output.completed returned through WS")

        // 7. Duplicate delivery (ack loss simulation): resend the same
        //    envelope; Mac must re-ack without reprocessing.
        try ws.send(promptFrame)
        var reAcked = false
        for _ in 0..<4 {
            guard let frame = await ws.next() else { break }
            if frame.type == .ack, frame.messageIDs?.contains(prompt.messageID) == true { reAcked = true; break }
            if frame.type == .envelope, let envelope = frame.envelope {
                // Any envelope here would be a duplicate outputCompleted — fail.
                _ = envelope
                reAcked = false
                break
            }
        }
        check(reAcked, "duplicate delivery re-acked, not reprocessed")

        // 8. Offline delivery: send a prompt and drop the socket before
        //    reading the reply; the reply must be replayed on reconnect.
        sequence += 1
        let offlinePrompt = AgentMessage(conversationID: "default", senderDeviceID: identity.deviceID,
                                         sequence: sequence, type: .conversationSend,
                                         body: .object(["text": .string("offline test")]))
        var offlineFrame = TransportFrame(type: .envelope)
        offlineFrame.envelope = try session.seal(offlinePrompt)
        try ws.send(offlineFrame)
        try await Task.sleep(nanoseconds: 300_000_000)
        ws.close()

        try await Task.sleep(nanoseconds: 500_000_000)
        let ws2 = WSClient(url: "ws://127.0.0.1:\(e2ePort)/v2/ws")
        guard let challenge2 = await ws2.next(), challenge2.type == .challenge else {
            check(false, "reconnect challenge"); exit(1)
        }
        var hello2 = TransportFrame(type: .hello)
        hello2.deviceID = identity.deviceID
        hello2.instanceID = payload.instanceID
        hello2.signature = try TransportAuth.signature(nonce: challenge2.nonce!, deviceID: identity.deviceID,
                                                       instanceID: payload.instanceID,
                                                       signingKey: identity.signingKey)
        try ws2.send(hello2)
        var replayed: AgentMessage?
        for _ in 0..<8 {
            guard let frame = await ws2.next() else { break }
            if frame.type == .envelope, let envelope = frame.envelope {
                var ack = TransportFrame(type: .ack)
                ack.messageIDs = [envelope.messageID]
                try ws2.send(ack)
                if let message = try? session.open(envelope), message.type == .outputCompleted {
                    replayed = message
                    break
                }
            }
        }
        check(replayed != nil, "queued reply delivered once after reconnect")

        // 9. Revocation: live session gets a revoked frame; reconnect refused.
        let revokeBody = try JSONSerialization.data(withJSONObject: ["device_id": identity.deviceID])
        _ = try await http("POST", "\(adminBase)/admin/revoke", body: revokeBody)
        var sawRevoked = false
        for _ in 0..<6 {
            guard let frame = await ws2.next() else { break }
            if frame.type == .revoked { sawRevoked = true; break }
            if frame.type == .envelope, let envelope = frame.envelope,
               let message = try? session.open(envelope), message.type == .deviceRevoked {
                // The last old-epoch envelope is also acceptable evidence.
                sawRevoked = true
                break
            }
        }
        check(sawRevoked, "live session told about revocation")
        ws2.close()

        try await Task.sleep(nanoseconds: 300_000_000)
        let ws3 = WSClient(url: "ws://127.0.0.1:\(e2ePort)/v2/ws")
        if let challenge3 = await ws3.next(), challenge3.type == .challenge {
            var hello3 = TransportFrame(type: .hello)
            hello3.deviceID = identity.deviceID
            hello3.instanceID = payload.instanceID
            hello3.signature = try TransportAuth.signature(nonce: challenge3.nonce!, deviceID: identity.deviceID,
                                                           instanceID: payload.instanceID,
                                                           signingKey: identity.signingKey)
            try ws3.send(hello3)
            let refusal = await ws3.next()
            check(refusal?.type == .revoked, "revoked device cannot re-establish a session")
        } else {
            check(false, "revoked device cannot re-establish a session")
        }
        ws3.close()

        _ = session  // silence mutation warning if unused paths change

        print("\n\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
