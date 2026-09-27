import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// che-word-mcp#169 — `export_script` had no equivalent of the CLI's
/// `macdoc word reverse --from-oplog`: `export_script` always called
/// `ReverseExtractor.reverse(parts:)` to re-derive a log from the current
/// docx bytes, with no way to instead export the sidecar's ACTUAL recorded
/// edit history (`SidecarStore.loadLog(alongside:)`).
///
/// `from_oplog: true` closes that secondary-path gap. It is a strict,
/// explicit opt-in (matching the CLI's `--from-oplog`, not the CLI's
/// no-flag default that silently prefers a sidecar when one exists): no
/// sidecar present → a loud, named failure, never a silent fallback to the
/// reverse-extracted script.
final class Issue169ExportScriptFromOplogTests: XCTestCase {

    private func textOf(_ r: CallTool.Result) -> String {
        guard let content = r.content.first else { return "" }
        if case .text(let t) = content { return t.text }
        return ""
    }

    private func makeScratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("i169-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// A docx + a genuine oplog sidecar recording the operations that built
    /// it — the same `apply(operations:)` pattern `ScriptPipelineParityTests`
    /// uses, but the log is ALSO persisted to `<docx>.oplog.jsonl` via
    /// `SidecarStore.saveLog`, which is exactly what `SidecarStore.loadLog`
    /// (the function under test, transitively) reads back.
    private func makeDocxWithOplogSidecar(in dir: URL, name: String = "with-sidecar") throws -> URL {
        var doc = WordDocument.emptyAuthoringDocument()
        try doc.apply(operations: [
            .appendParagraph(in: nil, paragraph: ParagraphPayload(
                text: "見出し", styleId: "Heading1", paraId: "P1")),
        ])
        let url = dir.appendingPathComponent("\(name).docx")
        try doc.writeAuthoringPackage(to: url)
        try SidecarStore.saveLog(doc.operationLog, alongside: url)
        return url
    }

    // MARK: - Success path

    func testExportsFromOplogWhenSidecarPresent() async throws {
        let dir = try makeScratch()
        let source = try makeDocxWithOplogSidecar(in: dir)
        let script = dir.appendingPathComponent("out.mdocx.swift")

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(name: "export_script", arguments: [
            "source_path": .string(source.path),
            "output_path": .string(script.path),
            "from_oplog": .bool(true),
        ])
        XCTAssertNotEqual(result.isError, true, textOf(result))
        let text = textOf(result)
        XCTAssertTrue(text.contains("\"from_oplog\":true"), text)
        XCTAssertTrue(text.contains("\"op_count\":1"), "one appendParagraph op was recorded; got: \(text)")
        XCTAssertTrue(text.contains("\"slot_count\":0"), text)
        XCTAssertFalse(text.contains("dsl_parts"), "the oplog shape must not carry the reverse-extraction fields: \(text)")
        XCTAssertFalse(text.contains("form_gaps_empty"), text)

        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path), "script must be written")
        let scriptText = try String(contentsOfFile: script.path, encoding: .utf8)
        XCTAssertTrue(scriptText.contains("見出し"), "exported script must carry the paragraph text: \(scriptText)")
    }

    /// Slot designation must reach the oplog path exactly as it reaches the
    /// reverse-extraction path (same `ScriptExporter.exportSwift(log:slots:)`
    /// call underneath).
    func testFromOplogHonorsSlots() async throws {
        let dir = try makeScratch()
        let source = try makeDocxWithOplogSidecar(in: dir, name: "slotted")
        let script = dir.appendingPathComponent("slotted.mdocx.swift")

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(name: "export_script", arguments: [
            "source_path": .string(source.path),
            "output_path": .string(script.path),
            "from_oplog": .bool(true),
            "slots": .array([.object([
                "name": .string("heading"), "para_id": .string("P1"),
            ])]),
        ])
        XCTAssertNotEqual(result.isError, true, textOf(result))
        XCTAssertTrue(textOf(result).contains("\"slot_count\":1"), textOf(result))
        let scriptText = try String(contentsOfFile: script.path, encoding: .utf8)
        XCTAssertTrue(scriptText.contains("heading: \"見出し\""),
                      "the slot's call-site default must carry the extracted text: \(scriptText)")
    }

    // MARK: - Strict failure: no silent fallback

    func testFailsLoudlyWhenNoSidecarPresent() async throws {
        let dir = try makeScratch()
        var doc = WordDocument.emptyAuthoringDocument()
        try doc.apply(operations: [
            .appendParagraph(in: nil, paragraph: ParagraphPayload(text: "no sidecar here", paraId: "Q1")),
        ])
        let source = dir.appendingPathComponent("no-sidecar.docx")
        try doc.writeAuthoringPackage(to: source)
        // Deliberately NOT calling SidecarStore.saveLog.
        let script = dir.appendingPathComponent("out.mdocx.swift")

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(name: "export_script", arguments: [
            "source_path": .string(source.path),
            "output_path": .string(script.path),
            "from_oplog": .bool(true),
        ])
        XCTAssertEqual(result.isError, true, "from_oplog with no sidecar must fail, not silently reverse-extract")
        XCTAssertTrue(textOf(result).contains("oplog") || textOf(result).contains("sidecar"),
                      "error must name what was missing: \(textOf(result))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: script.path),
                       "no script may be written on this failure")
    }

    // MARK: - Mutual exclusion with paragraphs_only

    func testRejectsFromOplogTogetherWithParagraphsOnly() async throws {
        let dir = try makeScratch()
        let source = try makeDocxWithOplogSidecar(in: dir, name: "both-flags")
        let script = dir.appendingPathComponent("out.mdocx.swift")

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(name: "export_script", arguments: [
            "source_path": .string(source.path),
            "output_path": .string(script.path),
            "from_oplog": .bool(true),
            "paragraphs_only": .bool(true),
        ])
        XCTAssertEqual(result.isError, true, "from_oplog + paragraphs_only together must be refused")
        XCTAssertFalse(FileManager.default.fileExists(atPath: script.path))
    }

    // MARK: - Strict typing (matches the other optional params' discipline)

    func testFromOplogMistypedValueErrorsLoudly() async throws {
        let dir = try makeScratch()
        let source = try makeDocxWithOplogSidecar(in: dir, name: "mistyped")
        let script = dir.appendingPathComponent("out.mdocx.swift")

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(name: "export_script", arguments: [
            "source_path": .string(source.path),
            "output_path": .string(script.path),
            "from_oplog": .int(1),  // not a boolean
        ])
        XCTAssertEqual(result.isError, true, "non-boolean from_oplog must error")
    }
}
