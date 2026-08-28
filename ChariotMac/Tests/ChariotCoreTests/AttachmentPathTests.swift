import XCTest
@testable import ChariotCore

final class AttachmentPathTests: XCTestCase {

    /// Everything after the random prefix, for asserting on the sanitized name.
    private func name(_ filename: String) -> String {
        let path = ChariotHub.attachmentGuestPath(for: filename)
        XCTAssertTrue(path.hasPrefix(ChariotHub.attachmentsGuestDirectory + "/"))
        let component = path.split(separator: "/").last!
        return String(component.dropFirst("12345678-".count))
    }

    func testPlainFilenameSurvives() {
        XCTAssertEqual(name("notes.txt"), "notes.txt")
        XCTAssertEqual(name("IMG_2041.HEIC"), "IMG_2041.HEIC")
    }

    func testTraversalAndSeparatorsAreStripped() {
        // Only the last path component is kept, and it cannot escape the
        // attachments directory or smuggle in a new one.
        XCTAssertEqual(name("../../etc/passwd"), "passwd")
        XCTAssertEqual(name("/etc/shadow"), "shadow")
        let dotty = name("..")
        XCTAssertFalse(dotty.contains(".."))
        XCTAssertEqual(dotty, "file")
    }

    func testHostileCharactersAreReplaced() {
        XCTAssertEqual(name("my report (final).pdf"), "my_report__final_.pdf")
        XCTAssertEqual(name("a\nb\"c.txt"), "a_b_c.txt")
        // Non-ASCII collapses to underscores rather than risking guest-side
        // encoding surprises.
        XCTAssertEqual(name("résumé.pdf"), "r_sum_.pdf")
    }

    func testEmptyAndDegenerateNames() {
        XCTAssertEqual(name(""), "file")
        XCTAssertEqual(name("***"), "file")
        XCTAssertEqual(name("."), "file")
    }

    func testLongNamesKeepTheirExtension() {
        let long = String(repeating: "a", count: 300) + ".png"
        let result = name(long)
        XCTAssertLessThanOrEqual(result.count, 80)
        XCTAssertTrue(result.hasSuffix(".png"))
    }

    func testCollidingNamesGetDistinctPaths() {
        XCTAssertNotEqual(ChariotHub.attachmentGuestPath(for: "notes.txt"),
                          ChariotHub.attachmentGuestPath(for: "notes.txt"))
    }

    func testResultPassesTheTurnAttachmentFilter() {
        // The path we generate must survive the same guard phone-sent paths
        // go through, or the citation would be silently dropped from a turn.
        let path = ChariotHub.attachmentGuestPath(for: "../weird name*.dat")
        let sanitized = ChariotHub.sanitizedAttachments(.object(["attachments": .array([.string(path)])]))
        XCTAssertEqual(sanitized, [path])
    }
}
