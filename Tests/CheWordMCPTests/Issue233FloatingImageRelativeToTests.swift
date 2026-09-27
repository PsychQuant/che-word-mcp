import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#233 — `insert_floating_image`'s `relative_to_h` /
/// `relative_to_v` were declared in the schema but never read: the handler
/// read the undocumented `horizontal_relative` instead of `relative_to_h`,
/// and had no code path at all for `relative_to_v` (the vertical reference
/// point was always the `AnchorPosition` default, `.paragraph`, no matter
/// what the caller sent). A supplementary comment on the issue also found
/// the schema declared `base64`/`file_name` as required while the handler
/// only ever read `path` — a caller following the schema exactly always got
/// "Missing required parameter: path".
final class Issue233FloatingImageRelativeToTests: XCTestCase {

    private func textOf(_ r: CallTool.Result) -> String {
        guard let first = r.content.first else { return "" }
        if case .text(let text, _, _) = first { return text }
        return ""
    }

    private func docxWithText(_ text: String) throws -> URL {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: text)])))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("i233-\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    private func onePixelPNGPath() throws -> String {
        // Minimal-but-valid 1x1 PNG: signature + IHDR(1x1) + IDAT + IEND.
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        guard let data = Data(base64Encoded: base64) else { throw XCTSkip("bad base64 fixture") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("i233-\(UUID().uuidString).png")
        try data.write(to: url)
        return url.path
    }

    /// Save, unzip, and return `word/document.xml` as a string — the only
    /// reliable way to see what `<wp:positionH>`/`<wp:positionV>` actually
    /// carry (no readback tool surfaces AnchorPosition fields directly).
    private func savedDocumentXML(_ server: WordMCPServer, docId: String) async throws -> String {
        let outPath = FileManager.default.temporaryDirectory.appendingPathComponent("i233-saved-\(UUID().uuidString).docx")
        let save = await server.invokeToolForTesting(name: "save_document", arguments: ["doc_id": .string(docId), "path": .string(outPath.path)])
        XCTAssertNotEqual(save.isError, true, textOf(save))
        defer { try? FileManager.default.removeItem(at: outPath) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("i233-unzip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { ZipHelper.cleanup(dir) }
        try FileManager.default.unzipItem(at: outPath, to: dir)
        return try String(contentsOf: dir.appendingPathComponent("word/document.xml"), encoding: .utf8)
    }

    // MARK: - Schema/handler mismatch (the supplementary comment)

    /// Calling the tool exactly the way the (pre-fix) schema demanded —
    /// `base64` + `file_name`, no `path` — used to succeed at the schema
    /// level but fail at the handler with "Missing required parameter:
    /// path". The schema now declares `path`; this pins that a `path`-based
    /// call (what the handler has always actually done) succeeds end to end.
    func testInsertFloatingImageWithPathSucceeds() async throws {
        let url = try docxWithText("seed"); defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: ["path": .string(url.path), "doc_id": .string("f233a")])
        let png = try onePixelPNGPath(); defer { try? FileManager.default.removeItem(atPath: png) }

        let result = await server.invokeToolForTesting(name: "insert_floating_image", arguments: [
            "doc_id": .string("f233a"), "path": .string(png), "width": .int(500_000), "height": .int(300_000),
        ])
        XCTAssertNotEqual(result.isError, true, "Got: \(textOf(result))")

        _ = await server.invokeToolForTesting(name: "close_document", arguments: ["doc_id": .string("f233a"), "discard_changes": .bool(true)])
    }

    // MARK: - relative_to_h / relative_to_v are actually read

    func testRelativeToHAndRelativeToVAreWrittenIntoTheDrawing() async throws {
        let url = try docxWithText("seed"); defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: ["path": .string(url.path), "doc_id": .string("f233b")])
        let png = try onePixelPNGPath(); defer { try? FileManager.default.removeItem(atPath: png) }

        let result = await server.invokeToolForTesting(name: "insert_floating_image", arguments: [
            "doc_id": .string("f233b"), "path": .string(png), "width": .int(500_000), "height": .int(300_000),
            "relative_to_h": .string("page"), "relative_to_v": .string("line"),
        ])
        XCTAssertNotEqual(result.isError, true, "Got: \(textOf(result))")

        let xml = try await savedDocumentXML(server, docId: "f233b")
        XCTAssertTrue(xml.contains("<wp:positionH relativeFrom=\"page\">"), "relative_to_h='page' must reach positionH. Got: \(xml)")
        XCTAssertTrue(xml.contains("<wp:positionV relativeFrom=\"line\">"), "relative_to_v='line' must reach positionV — pre-#233 there was no read path for this parameter at all. Got: \(xml)")

        _ = await server.invokeToolForTesting(name: "close_document", arguments: ["doc_id": .string("f233b"), "discard_changes": .bool(true)])
    }

    /// Omitting both parameters must keep the pre-#233 default behavior
    /// byte-for-byte (`column` / `paragraph`) — a caller who never used
    /// these parameters sees no change.
    func testOmittingRelativeToKeepsTheDefaults() async throws {
        let url = try docxWithText("seed"); defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: ["path": .string(url.path), "doc_id": .string("f233c")])
        let png = try onePixelPNGPath(); defer { try? FileManager.default.removeItem(atPath: png) }

        let result = await server.invokeToolForTesting(name: "insert_floating_image", arguments: [
            "doc_id": .string("f233c"), "path": .string(png), "width": .int(500_000), "height": .int(300_000),
        ])
        XCTAssertNotEqual(result.isError, true, "Got: \(textOf(result))")

        let xml = try await savedDocumentXML(server, docId: "f233c")
        XCTAssertTrue(xml.contains("<wp:positionH relativeFrom=\"column\">"), "Got: \(xml)")
        XCTAssertTrue(xml.contains("<wp:positionV relativeFrom=\"paragraph\">"), "Got: \(xml)")

        _ = await server.invokeToolForTesting(name: "close_document", arguments: ["doc_id": .string("f233c"), "discard_changes": .bool(true)])
    }

    /// The undocumented `horizontal_relative` (never in the schema — the only
    /// name that ever worked pre-#233) still works as a compat fallback when
    /// `relative_to_h` is absent.
    func testHorizontalRelativeCompatFallbackStillWorks() async throws {
        let url = try docxWithText("seed"); defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: ["path": .string(url.path), "doc_id": .string("f233d")])
        let png = try onePixelPNGPath(); defer { try? FileManager.default.removeItem(atPath: png) }

        let result = await server.invokeToolForTesting(name: "insert_floating_image", arguments: [
            "doc_id": .string("f233d"), "path": .string(png), "width": .int(500_000), "height": .int(300_000),
            "horizontal_relative": .string("margin"),
        ])
        XCTAssertNotEqual(result.isError, true, "Got: \(textOf(result))")
        let xml = try await savedDocumentXML(server, docId: "f233d")
        XCTAssertTrue(xml.contains("<wp:positionH relativeFrom=\"margin\">"), "Got: \(xml)")

        _ = await server.invokeToolForTesting(name: "close_document", arguments: ["doc_id": .string("f233d"), "discard_changes": .bool(true)])
    }

    // MARK: - Invalid values fail loudly, naming the parameter

    func testInvalidRelativeToHFailsNamingTheParameter() async throws {
        let url = try docxWithText("seed"); defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: ["path": .string(url.path), "doc_id": .string("f233e")])
        let png = try onePixelPNGPath(); defer { try? FileManager.default.removeItem(atPath: png) }

        let result = await server.invokeToolForTesting(name: "insert_floating_image", arguments: [
            "doc_id": .string("f233e"), "path": .string(png), "width": .int(500_000), "height": .int(300_000),
            "relative_to_h": .string("not-a-real-value"),
        ])
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(textOf(result).contains("relative_to_h"), "Got: \(textOf(result))")

        _ = await server.invokeToolForTesting(name: "close_document", arguments: ["doc_id": .string("f233e"), "discard_changes": .bool(true)])
    }

    func testInvalidRelativeToVFailsNamingTheParameter() async throws {
        let url = try docxWithText("seed"); defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: ["path": .string(url.path), "doc_id": .string("f233f")])
        let png = try onePixelPNGPath(); defer { try? FileManager.default.removeItem(atPath: png) }

        let result = await server.invokeToolForTesting(name: "insert_floating_image", arguments: [
            "doc_id": .string("f233f"), "path": .string(png), "width": .int(500_000), "height": .int(300_000),
            "relative_to_v": .string("not-a-real-value"),
        ])
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(textOf(result).contains("relative_to_v"), "Got: \(textOf(result))")

        _ = await server.invokeToolForTesting(name: "close_document", arguments: ["doc_id": .string("f233f"), "discard_changes": .bool(true)])
    }
}
