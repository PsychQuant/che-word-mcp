import XCTest
import MCP
import ZIPFoundation
@testable import CheWordMCP

/// #170 — `create_document` shipped every new document with track changes ON.
///
/// The visible symptom is not red text in the file. `insert_paragraph` produced
/// clean runs, and `get_revisions` reported none. What shipped was the *mode*:
/// `<w:trackChanges/>` in `settings.xml`, so the recipient opened the document
/// in Word with the Track Changes button lit and their first keystroke became a
/// revision mark.
///
/// A brand-new document has nothing to track — "review mode" means marking
/// changes against existing content, and there is none.
///
/// v3.0.0 (#13) already flipped this default for `open_document` and stopped
/// there. This pins both halves so the two entry points cannot drift again.
final class CreateDocumentTrackChangesDefaultTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreateTC-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func text(_ r: CallTool.Result?) -> String {
        guard let c = r?.content.first, case .text(let t) = c else { return "" }
        return t.text
    }

    /// The claim that matters is about the saved bytes, not the session flag:
    /// what the recipient gets is `settings.xml`.
    private func settingsXML(of path: String) throws -> String {
        let archive = try Archive(url: URL(fileURLWithPath: path), accessMode: .read)
        guard let entry = archive["word/settings.xml"] else { return "" }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return String(decoding: data, as: UTF8.self)
    }

    func testNewDocumentDoesNotShipInTrackChangesMode() async throws {
        let server = await WordMCPServer()
        let out = text(await server.invokeToolForTesting(
            name: "create_document", arguments: ["doc_id": .string("d")]))
        XCTAssertTrue(out.contains("disabled"),
                      "the response SHALL state the default plainly, got: \(out)")

        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("d"), "text": .string("delivered content")])

        let path = tempDir.appendingPathComponent("out.docx").path
        _ = await server.invokeToolForTesting(
            name: "save_document",
            arguments: ["doc_id": .string("d"), "path": .string(path)])

        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "the document SHALL be saved")
        let settings = try settingsXML(of: path)
        XCTAssertFalse(settings.contains("<w:trackChanges/>"),
                       "a new document SHALL NOT ship with track-changes mode on")
    }

    /// Opting in must still work — the fix is a changed default, not a removed
    /// capability.
    func testTrackChangesCanStillBeRequestedExplicitly() async throws {
        let server = await WordMCPServer()
        let out = text(await server.invokeToolForTesting(
            name: "create_document",
            arguments: ["doc_id": .string("d"), "track_changes": .bool(true)]))
        XCTAssertTrue(out.contains("enabled"),
                      "an explicit request SHALL be acknowledged as enabled, got: \(out)")

        let path = tempDir.appendingPathComponent("tc.docx").path
        _ = await server.invokeToolForTesting(
            name: "save_document",
            arguments: ["doc_id": .string("d"), "path": .string(path)])

        let settings = try settingsXML(of: path)
        XCTAssertTrue(settings.contains("<w:trackChanges/>"),
                      "an explicitly requested mode SHALL reach settings.xml")
    }

    /// The two ways a session starts must agree. #13 flipped one and left the
    /// other, and nothing detected the split for two major versions.
    func testCreateAndOpenAgreeOnTheDefault() async throws {
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(name: "create_document",
                                              arguments: ["doc_id": .string("seed")])
        let seedPath = tempDir.appendingPathComponent("seed.docx").path
        _ = await server.invokeToolForTesting(
            name: "save_document",
            arguments: ["doc_id": .string("seed"), "path": .string(seedPath)])

        let openOut = text(await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["doc_id": .string("opened"), "path": .string(seedPath)]))
        let createOut = text(await server.invokeToolForTesting(
            name: "create_document", arguments: ["doc_id": .string("fresh")]))

        let openSaysDisabled = openOut.lowercased().contains("disabled")
        let createSaysDisabled = createOut.lowercased().contains("disabled")
        XCTAssertEqual(openSaysDisabled, createSaysDisabled,
                       "both entry points SHALL report the same default.\n"
                       + "open_document: \(openOut)\ncreate_document: \(createOut)")
    }
}
