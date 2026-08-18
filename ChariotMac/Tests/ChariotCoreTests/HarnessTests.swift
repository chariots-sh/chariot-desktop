import XCTest
@testable import ChariotCore

/// Harness/power-source types: backward-compatible agents.json decoding and
/// the model resolution chain (record → app default → harness default).
final class HarnessTests: XCTestCase {

    // MARK: agents.json compatibility

    /// The exact shape ChariotHub persisted before harness selection existed.
    /// It must decode with codex+chatgpt semantics, or existing fleets break
    /// on upgrade.
    func testLegacyAgentRecordDecodesAsCodexChatGPT() throws {
        let legacy = """
        [{
          "instance_id": "0b6c7a54-9d6e-4c2c-8f43-8f2f7e6f0a11",
          "pack_id": "sh.chariots.guardian",
          "display_name": "Guardian",
          "pack_directory": "guardian.pack",
          "created_at": "2026-07-01T12:00:00Z"
        }]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try decoder.decode([AgentRecord].self, from: Data(legacy.utf8))
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertNil(record.harness)
        XCTAssertNil(record.powerSource)
        XCTAssertEqual(record.effectiveHarness, .codex)
        XCTAssertEqual(record.effectivePowerSource, .chatgpt)
        XCTAssertNil(record.model)
    }

    func testExtendedAgentRecordRoundTrips() throws {
        var record = AgentRecord(instanceID: UUID().uuidString.lowercased(),
                                 packID: "test.pack",
                                 displayName: "Muse Agent",
                                 packDirectoryName: "test.pack",
                                 createdAt: Date())
        record.harness = .muse
        record.powerSource = .local
        record.model = "muse-glimmer:30b"
        record.localBaseURL = "http://127.0.0.1:11434/v1"

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        // Persisted keys are snake_case, matching the file's existing grammar.
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["harness"] as? String, "muse")
        XCTAssertEqual(json["power_source"] as? String, "local")
        XCTAssertEqual(json["local_base_url"] as? String, "http://127.0.0.1:11434/v1")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AgentRecord.self, from: data)
        XCTAssertEqual(decoded.effectiveHarness, .muse)
        XCTAssertEqual(decoded.effectivePowerSource, .local)
        XCTAssertEqual(decoded.model, "muse-glimmer:30b")
    }

    // MARK: Model resolution chain

    private func record(_ harness: HarnessKind, _ power: PowerSourceKind,
                        model: String? = nil, localBaseURL: String? = nil) -> AgentRecord {
        var record = AgentRecord(instanceID: "i", packID: "p", displayName: "d",
                                 packDirectoryName: "p.pack", createdAt: Date())
        record.harness = harness
        record.powerSource = power
        record.model = model
        record.localBaseURL = localBaseURL
        return record
    }

    func testChatGPTOnlyPowersCodex() throws {
        XCTAssertNoThrow(try resolvePower(record: record(.codex, .chatgpt), settings: nil))
        XCTAssertThrowsError(try resolvePower(record: record(.zeroclaw, .chatgpt), settings: nil)) {
            XCTAssertEqual($0 as? HarnessError, .chatgptRequiresCodex(.zeroclaw))
        }
    }

    func testLocalPrecedence_RecordOverridesAppDefaultOverridesHarness() throws {
        let settings = HostSettings.LocalModel(baseURL: "http://127.0.0.1:11434/v1",
                                               model: "muse-glimmer:30b")
        // Record override wins.
        var resolved = try resolvePower(
            record: record(.muse, .local, model: "qwen3:8b"), settings: settings)
        XCTAssertEqual(resolved.model, "qwen3:8b")
        // Then the app default.
        resolved = try resolvePower(record: record(.openclaw, .local), settings: settings)
        XCTAssertEqual(resolved.model, "muse-glimmer:30b")
        XCTAssertEqual(resolved.localBaseURL?.absoluteString, "http://127.0.0.1:11434/v1")
        // Then the harness default (muse is the only harness with one).
        let bare = HostSettings.LocalModel(baseURL: "http://127.0.0.1:11434/v1", model: nil)
        resolved = try resolvePower(record: record(.muse, .local), settings: bare)
        XCTAssertEqual(resolved.model, "meta/muse-spark-1.2")
        // No model anywhere → typed error.
        XCTAssertThrowsError(try resolvePower(record: record(.hermes, .local), settings: bare)) {
            XCTAssertEqual($0 as? HarnessError, .noModelConfigured(.hermes))
        }
    }

    func testLocalRequiresBaseURL() {
        XCTAssertThrowsError(try resolvePower(
            record: record(.codex, .local, model: "m"), settings: nil)) {
            XCTAssertEqual($0 as? HarnessError, .localBaseURLMissing)
        }
    }

    func testChariotFallsBackToHarnessDefault() throws {
        let resolved = try resolvePower(record: record(.muse, .chariot), settings: nil)
        XCTAssertEqual(resolved.model, "meta/muse-spark-1.2")
        // A chariot agent with no model anywhere is still valid — the backend
        // resolves the account/server default.
        let codex = try resolvePower(record: record(.codex, .chariot), settings: nil)
        XCTAssertNil(codex.model)
    }

    func testBackendNameSanitization() {
        XCTAssertEqual(ChariotAccountManager.backendName(from: "Guardian"), "guardian")
        XCTAssertEqual(ChariotAccountManager.backendName(from: "My Muse Agent"), "my-muse-agent")
        XCTAssertNil(ChariotAccountManager.backendName(from: "агент"))  // nothing safe remains
        XCTAssertNil(ChariotAccountManager.backendName(from: "agent-000001"))  // reserved shape
    }
}
