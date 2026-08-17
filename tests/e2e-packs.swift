// E2E harness: agent packs on the Mac (Guardian on Chariot, Milestone 1).
// Drives a running chariotd (loopback dev mode) whose packs directory holds
// guardian.pack and scribe.pack, and proves the acceptance criteria:
//   1. two packs → two concurrently running VMs, each with its own workspace
//   2. prompts to one agent never touch the other's VM/session/files
//   3. per-agent pairing: a device paired to guardian converses with guardian
//      only; the same device is denied on scribe's endpoint
//   4. editing guardian.pack/AGENTS.md lands on the next turn, no rebuild
//   5. an agent runs a bash tool shipped in its pack
//   6. reset re-clones guardian, re-seeds MEMORY.md, leaves scribe undisturbed
//   7. a second turn continues the first one's Codex session
//   8. the phone sees the agent's reply and none of its working transcript
// Persona checks that need a signed-in Codex run only when
// CHARIOT_E2E_CODEX_AUTH points at a host auth.json to install into each VM.
import Foundation
import CryptoKit

let e2ePort = ProcessInfo.processInfo.environment["CHARIOT_E2E_PORT"] ?? "9787"
let dataDir = ProcessInfo.processInfo.environment["CHARIOT_E2E_DATA_DIR"] ?? ""
let codexAuthPath = ProcessInfo.processInfo.environment["CHARIOT_E2E_CODEX_AUTH"] ?? ""
let transportBase = "http://127.0.0.1:\(e2ePort)"
let adminBase = "http://127.0.0.1:\((UInt16(e2ePort) ?? 9787) + 1)"

var passed = 0
var failed = 0
var skipped = 0
func check(_ condition: Bool, _ name: String) {
    if condition { passed += 1; print("PASS \(name)") }
    else { failed += 1; print("FAIL \(name)") }
}
func skip(_ name: String) {
    skipped += 1
    print("SKIP \(name)")
}

func http(_ method: String, _ urlString: String, body: Data? = nil,
          timeout: TimeInterval = 30) async throws -> (Int, Data) {
    var request = URLRequest(url: URL(string: urlString)!, timeoutInterval: timeout)
    request.httpMethod = method
    request.httpBody = body
    let (data, response) = try await URLSession.shared.data(for: request)
    return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
}

func jsonBody(_ object: [String: String]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

func json(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

/// One synchronous agent turn through the admin surface. Prompts starting
/// with "!" run a raw shell command in the agent's VM — the workhorse for
/// non-persona assertions, no Codex sign-in needed.
func converse(_ agentID: String, _ text: String, timeout: TimeInterval = 200) async throws -> (Int, String) {
    let (status, data) = try await http("POST", "\(adminBase)/admin/agents/\(agentID)/conversation",
                                        body: jsonBody(["text": text]), timeout: timeout)
    let object = json(data)
    guard status == 200 else { return (-1, object["error"] as? String ?? "http \(status)") }
    return (object["exit_code"] as? Int ?? -1, object["output"] as? String ?? "")
}

func agentsList() async throws -> [[String: Any]] {
    let (_, data) = try await http("GET", "\(adminBase)/admin/agents")
    return json(data)["agents"] as? [[String: Any]] ?? []
}

func agentInfo(_ id: String) async throws -> [String: Any] {
    try await agentsList().first { $0["instance_id"] as? String == id } ?? [:]
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
struct E2EPacks {
    static func main() async throws {
        // ---- Packs are visible to the hub.
        let (packsStatus, packsData) = try await http("GET", "\(adminBase)/admin/packs")
        let packDirs = (json(packsData)["packs"] as? [[String: Any]] ?? [])
            .compactMap { $0["dir"] as? String }
        check(packsStatus == 200 && packDirs.contains("guardian.pack") && packDirs.contains("scribe.pack"),
              "both packs discovered in packs/")

        // ---- Create one agent per pack: distinct instance UUIDs.
        let (gStatus, gData) = try await http("POST", "\(adminBase)/admin/agents",
                                              body: jsonBody(["pack_dir": "guardian.pack"]), timeout: 120)
        let (sStatus, sData) = try await http("POST", "\(adminBase)/admin/agents",
                                              body: jsonBody(["pack_dir": "scribe.pack"]), timeout: 120)
        guard gStatus == 200, sStatus == 200,
              let guardianID = json(gData)["instance_id"] as? String,
              let scribeID = json(sData)["instance_id"] as? String else {
            check(false, "agents created from packs"); exit(1)
        }
        check(guardianID != scribeID && UUID(uuidString: guardianID) != nil,
              "agents created with distinct instance UUIDs")

        // ---- Boot both VMs concurrently (AC1).
        print("booting both VMs (first boot provisions the guest — this takes a minute)…")
        async let startGuardian = http("POST", "\(adminBase)/admin/agents/\(guardianID)/vm",
                                       body: jsonBody(["action": "start"]), timeout: 420)
        async let startScribe = http("POST", "\(adminBase)/admin/agents/\(scribeID)/vm",
                                     body: jsonBody(["action": "start"]), timeout: 420)
        let (gStart, sStart) = try await (startGuardian, startScribe)
        check(json(gStart.1)["result"] as? String == "ok", "guardian VM started")
        check(json(sStart.1)["result"] as? String == "ok", "scribe VM started")

        let guardian = try await agentInfo(guardianID)
        let scribe = try await agentInfo(scribeID)
        check(guardian["vm_state"] as? String == "running" && scribe["vm_state"] as? String == "running"
              && guardian["bridge_connected"] as? Bool == true && scribe["bridge_connected"] as? Bool == true,
              "AC1: two VMs running concurrently, bridges connected")

        // ---- Workspace populated per pack.
        let (_, guardianAgents) = try await converse(guardianID, "!cat /workspace/AGENTS.md")
        let (_, scribeAgents) = try await converse(scribeID, "!cat /workspace/AGENTS.md")
        check(guardianAgents.contains("Guardian") && !guardianAgents.contains("Scribe"),
              "guardian workspace populated from guardian.pack")
        check(scribeAgents.contains("Scribe") && !scribeAgents.contains("Guardian"),
              "scribe workspace populated from scribe.pack")
        let (_, guardianMemory) = try await converse(guardianID, "!cat /workspace/MEMORY.md")
        check(guardianMemory.contains("GUARDIAN-SEED-MEMORY"), "MEMORY.md seeded from MEMORY.seed.md")

        // ---- AC5: pack-shipped tools run inside the VM.
        let (gToolExit, gToolOut) = try await converse(guardianID, "!bash /workspace/tools/checkin.sh")
        check(gToolExit == 0 && gToolOut.contains("GUARDIAN-CHECKIN-OK"),
              "AC5: guardian runs tools/checkin.sh from its pack")
        let (sToolExit, sToolOut) = try await converse(scribeID, "!bash /workspace/tools/rollup.sh")
        check(sToolExit == 0 && sToolOut.contains("SCRIBE-ROLLUP-OK"),
              "AC5: scribe runs tools/rollup.sh from its pack")

        // ---- AC2: separate VMs, separate files.
        _ = try await converse(guardianID, "!touch /workspace/guardian-marker && echo created")
        let (_, scribeLs) = try await converse(scribeID, "!ls /workspace")
        check(!scribeLs.contains("guardian-marker"), "AC2: guardian's files never appear in scribe's VM")
        let (_, scribeTools) = try await converse(scribeID, "!ls /workspace/tools")
        check(scribeTools.contains("rollup.sh") && !scribeTools.contains("checkin.sh"),
              "AC2: each VM has only its own pack's tools")

        // ---- AC3: per-agent pairing.
        let (payloadStatus, payloadData) = try await http("POST", "\(adminBase)/admin/agents/\(guardianID)/pairing")
        check(payloadStatus == 200, "pairing payload minted for guardian")
        let payload = try PairingPayload.validate(json: payloadData)
        check(payload.instanceID == guardianID, "AC3: QR payload carries guardian's instance UUID")

        let identity = DeviceIdentity()
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let pairingKey = try PairingCrypto.deriveKey(ephemeralPrivate: ephemeral,
                                                     peerEphemeralPublic: payload.macPairingPublicKey,
                                                     pairingSecret: payload.pairingSecret)
        var response = PairingResponse(mobile: identity.publicIdentity,
                                       mobileDisplayName: "E2E Packs Phone",
                                       mobileEphemeralPublicKey: ephemeral.publicKey.rawRepresentation)
        try response.sign(with: identity.signingKey)
        let claimBody = try JSONSerialization.data(withJSONObject: [
            "ephemeral_public_key": Base64URL.encode(ephemeral.publicKey.rawRepresentation),
            "ciphertext": Base64URL.encode(try PairingCrypto.seal(response, key: pairingKey))
        ])
        let (claimStatus, _) = try await http("POST", "\(transportBase)/pairing/\(payload.pairingID)/response",
                                              body: claimBody)
        check(claimStatus == 200, "device paired against guardian's endpoint")

        var credential: DeviceCredential?
        var credentialEpoch: UInt32 = 1
        for _ in 0..<10 {
            let (status, data) = try await http("GET", "\(transportBase)/pairing/\(payload.pairingID)/credential")
            if status == 200, let ciphertext = json(data)["ciphertext"] as? String {
                credential = try PairingCrypto.open(DeviceCredential.self,
                                                    combined: Base64URL.decode(ciphertext), key: pairingKey)
                credentialEpoch = UInt32(json(data)["epoch"] as? Int ?? 1)
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        guard let credential else { check(false, "credential issued for guardian pairing"); exit(1) }
        try credential.verify(pinnedMacSigningKey: payload.macSigningPublicKey)
        check(credential.mobile.deviceID == identity.deviceID, "credential issued and verified")

        // Converse with guardian over the paired WebSocket.
        let ws = WSClient(url: "ws://127.0.0.1:\(e2ePort)/v2/ws")
        guard let challenge = await ws.next(), challenge.type == .challenge, let nonce = challenge.nonce else {
            check(false, "guardian session challenge"); exit(1)
        }
        var hello = TransportFrame(type: .hello)
        hello.deviceID = identity.deviceID
        hello.instanceID = guardianID
        hello.signature = try TransportAuth.signature(nonce: nonce, deviceID: identity.deviceID,
                                                      instanceID: guardianID, signingKey: identity.signingKey)
        try ws.send(hello)
        let welcome = await ws.next()
        check(welcome?.type == .welcome, "AC3: paired device authenticates to guardian")

        let session = try SessionCrypto(localIdentity: identity,
                                        peerPublicIdentity: credential.mac,
                                        epoch: credentialEpoch)
        let prompt = AgentMessage(conversationID: "default", senderDeviceID: identity.deviceID,
                                  sequence: 1, type: .conversationSend,
                                  body: .object(["text": .string("!echo hello-from-phone")]))
        var promptFrame = TransportFrame(type: .envelope)
        promptFrame.envelope = try session.seal(prompt)
        try ws.send(promptFrame)
        var phoneOutput = ""
        var completedTurn = false
        for _ in 0..<20 {
            if completedTurn { break }
            guard let frame = await ws.next(timeout: 30) else { break }
            if frame.type == .envelope, let envelope = frame.envelope,
               let message = try? session.open(envelope) {
                var ack = TransportFrame(type: .ack)
                ack.messageIDs = [envelope.messageID]
                try ws.send(ack)
                if message.type == .outputDelta {
                    phoneOutput += message.body["text"]?.stringValue ?? ""
                }
                if message.type == .outputCompleted { completedTurn = true }
            }
        }
        check(completedTurn && phoneOutput.contains("hello-from-phone"),
              "AC3: paired device converses with guardian")
        ws.close()

        // One turn the way the phone takes it: its own WebSocket, a sealed
        // prompt, and only the deltas the Mac chose to forward.
        var phoneSequence: UInt64 = 1
        func phoneTurn(_ text: String, timeout: TimeInterval = 300) async throws -> String {
            let socket = WSClient(url: "ws://127.0.0.1:\(e2ePort)/v2/ws")
            defer { socket.close() }
            guard let challenge = await socket.next(), challenge.type == .challenge,
                  let nonce = challenge.nonce else { return "" }
            var turnHello = TransportFrame(type: .hello)
            turnHello.deviceID = identity.deviceID
            turnHello.instanceID = guardianID
            turnHello.signature = try TransportAuth.signature(nonce: nonce, deviceID: identity.deviceID,
                                                              instanceID: guardianID,
                                                              signingKey: identity.signingKey)
            try socket.send(turnHello)
            guard await socket.next()?.type == .welcome else { return "" }
            phoneSequence += 1
            let turnPrompt = AgentMessage(conversationID: "default", senderDeviceID: identity.deviceID,
                                          sequence: phoneSequence, type: .conversationSend,
                                          body: .object(["text": .string(text)]))
            var frame = TransportFrame(type: .envelope)
            frame.envelope = try session.seal(turnPrompt)
            try socket.send(frame)
            var output = ""
            for _ in 0..<80 {
                guard let received = await socket.next(timeout: timeout), received.type == .envelope,
                      let envelope = received.envelope,
                      let message = try? session.open(envelope) else { break }
                var ack = TransportFrame(type: .ack)
                ack.messageIDs = [envelope.messageID]
                try socket.send(ack)
                if message.type == .outputDelta { output += message.body["text"]?.stringValue ?? "" }
                if message.type == .outputCompleted { break }
            }
            return output
        }

        // The same device must be denied on scribe's endpoint.
        let wsScribe = WSClient(url: "ws://127.0.0.1:\(e2ePort)/v2/ws")
        if let scribeChallenge = await wsScribe.next(), scribeChallenge.type == .challenge {
            var scribeHello = TransportFrame(type: .hello)
            scribeHello.deviceID = identity.deviceID
            scribeHello.instanceID = scribeID
            scribeHello.signature = try TransportAuth.signature(nonce: scribeChallenge.nonce!,
                                                                deviceID: identity.deviceID,
                                                                instanceID: scribeID,
                                                                signingKey: identity.signingKey)
            try wsScribe.send(scribeHello)
            let denial = await wsScribe.next()
            check(denial?.type == .denied, "AC3: guardian-paired device rejected by scribe's endpoint")
        } else {
            check(false, "AC3: guardian-paired device rejected by scribe's endpoint")
        }
        wsScribe.close()

        // ---- AC4: pack edits land on the next turn.
        guard !dataDir.isEmpty else {
            check(false, "CHARIOT_E2E_DATA_DIR not set"); exit(1)
        }
        let guardianAgentsMD = URL(fileURLWithPath: dataDir)
            .appendingPathComponent("packs/guardian.pack/AGENTS.md")
        let original = try String(contentsOf: guardianAgentsMD, encoding: .utf8)
        try (original + "\nGUARDIAN-EDIT-MARKER: prefer the word 'steadfast'.\n")
            .write(to: guardianAgentsMD, atomically: true, encoding: .utf8)
        let (_, editedView) = try await converse(guardianID, "!cat /workspace/AGENTS.md")
        check(editedView.contains("GUARDIAN-EDIT-MARKER"),
              "AC4: edited AGENTS.md visible in guardian's VM on the next turn")
        let (_, scribeView) = try await converse(scribeID, "!cat /workspace/AGENTS.md")
        check(!scribeView.contains("GUARDIAN-EDIT-MARKER"), "AC4: scribe unaffected by guardian's pack edit")

        // seedOnly: the agent owns MEMORY.md after seeding — later syncs must
        // never overwrite it.
        _ = try await converse(guardianID, "!echo scribbled-by-agent > /workspace/MEMORY.md && echo done")
        let (_, memoryAfterTurn) = try await converse(guardianID, "!cat /workspace/MEMORY.md")
        check(memoryAfterTurn.contains("scribbled-by-agent") && !memoryAfterTurn.contains("GUARDIAN-SEED-MEMORY"),
              "seedOnly: agent-owned MEMORY.md survives re-populates")

        // ---- AC6: reset guardian; scribe keeps running undisturbed.
        print("resetting guardian (re-clone + reboot)…")
        let (_, resetData) = try await http("POST", "\(adminBase)/admin/agents/\(guardianID)/vm",
                                            body: jsonBody(["action": "reset"]), timeout: 420)
        check(json(resetData)["result"] as? String == "ok", "guardian reset (disk re-cloned)")
        let (_, restartData) = try await http("POST", "\(adminBase)/admin/agents/\(guardianID)/vm",
                                              body: jsonBody(["action": "start"]), timeout: 420)
        check(json(restartData)["result"] as? String == "ok", "guardian rebooted after reset")

        let (_, memoryAfterReset) = try await converse(guardianID, "!cat /workspace/MEMORY.md")
        check(memoryAfterReset.contains("GUARDIAN-SEED-MEMORY") && !memoryAfterReset.contains("scribbled-by-agent"),
              "AC6: MEMORY.md re-seeded after reset")
        let (_, lsAfterReset) = try await converse(guardianID, "!ls /workspace")
        check(!lsAfterReset.contains("guardian-marker") && lsAfterReset.contains("AGENTS.md"),
              "AC6: guardian workspace re-cloned and repopulated")
        let (_, editedAfterReset) = try await converse(guardianID, "!cat /workspace/AGENTS.md")
        check(editedAfterReset.contains("GUARDIAN-EDIT-MARKER"),
              "AC6: repopulate uses current pack content (edit included)")
        let (scribeToolExit, scribeToolAgain) = try await converse(scribeID, "!bash /workspace/tools/rollup.sh")
        check(scribeToolExit == 0 && scribeToolAgain.contains("SCRIBE-ROLLUP-OK"),
              "AC6: scribe undisturbed by guardian's reset")

        // ---- Persona checks through real Codex (optional, needs auth).
        if codexAuthPath.isEmpty {
            skip("persona checks (set CHARIOT_E2E_CODEX_AUTH=<path to codex auth.json> to run them)")
        } else {
            let auth = try Data(contentsOf: URL(fileURLWithPath: codexAuthPath))
            let authB64 = auth.base64EncodedString()
            for (agentID, name) in [(guardianID, "guardian"), (scribeID, "scribe")] {
                let (code, out) = try await converse(agentID,
                    "!mkdir -p ~/.codex && printf '%s' '\(authB64)' | base64 -d > ~/.codex/auth.json && echo AUTH-INSTALLED")
                check(code == 0 && out.contains("AUTH-INSTALLED"), "codex auth installed in \(name)'s VM")
            }
            print("running persona turns through Codex (can take a few minutes)…")
            let (gPersonaExit, gPersona) = try await converse(guardianID,
                "In one short line, state your name and what you are.", timeout: 300)
            check(gPersonaExit == 0 && gPersona.lowercased().contains("guardian"),
                  "AC1: guardian answers in its own persona")
            let (sPersonaExit, sPersona) = try await converse(scribeID,
                "In one short line, state your name and what you are.", timeout: 300)
            check(sPersonaExit == 0 && sPersona.lowercased().contains("scribe"),
                  "AC1: scribe answers in its own persona")

            let (_, gTool) = try await converse(guardianID,
                "Run your daily check-in tool now and include its full output verbatim.", timeout: 300)
            check(gTool.contains("GUARDIAN-CHECKIN-OK"),
                  "AC5: guardian invokes its pack tool through Codex and uses the output")

            // Session isolation: a secret told to guardian must not exist in
            // scribe's conversation (separate VM, separate `codex exec
            // resume --last`).
            _ = try await converse(guardianID,
                "Remember this: the codeword is BLUEFALCON. Just acknowledge.", timeout: 300)
            let (_, scribeCodeword) = try await converse(scribeID,
                "What is the codeword? If you have never been told one, say NO-CODEWORD.", timeout: 300)
            check(!scribeCodeword.contains("BLUEFALCON"),
                  "AC2: guardian's conversation never leaks into scribe's session")

            // …and the other half of that: guardian's own next turn resumes
            // the same Codex session rather than starting cold.
            let (_, gRecall) = try await converse(guardianID,
                "What codeword did I give you? Answer with just the word.", timeout: 300)
            check(gRecall.contains("BLUEFALCON"),
                  "AC7: guardian's next turn continues the same session")

            // AC8: the phone gets the reply the agent addressed to its person,
            // and nothing else. checkin.sh prints GUARDIAN-CHECKIN-OK, so that
            // token showing up on the phone means the transcript leaked.
            let phoneReply = try await phoneTurn("""
                Run `bash /workspace/tools/checkin.sh` now. Keep its output to \
                yourself — reply with exactly: PHONE-REPLY-OK
                """)
            check(phoneReply.contains("PHONE-REPLY-OK"),
                  "AC8: the phone receives the agent's reply")
            check(!phoneReply.contains("GUARDIAN-CHECKIN-OK"),
                  "AC8: the phone never sees the agent's working transcript")
        }

        print("\n\(passed) passed, \(failed) failed, \(skipped) skipped")
        exit(failed == 0 ? 0 : 1)
    }
}
