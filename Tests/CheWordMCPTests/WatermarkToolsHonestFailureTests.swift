import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// #201 → #208/#209 — the three write-side watermark tools used to report
/// success and write nothing (#201: honest `ToolNotImplemented` stubs). This
/// file now pins the REAL implementation (#208): `insert_watermark` /
/// `insert_image_watermark` / `remove_watermark` actually write/remove the
/// VML `<w:pict>` shape in every header part, and the round-trip through the
/// read side (`list_watermarks` / `get_watermark`, already real, plus #209's
/// image-watermark fingerprint fix) proves it.
///
/// File name kept from #201/#172 lineage for history; the class name follows.
final class WatermarkToolsHonestFailureTests: XCTestCase {

    // MARK: - Fixtures

    private static let watermarkHeaderXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
           xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office">
      <w:p>
        <w:r>
          <w:pict>
            <v:shape id="PowerPlusWaterMarkObject1" o:spt="136" type="#_x0000_t136" style="position:absolute">
              <v:textpath string="機密"/>
            </v:shape>
          </w:pict>
        </w:r>
      </w:p>
    </w:hdr>
    """

    /// A document with one existing (pre-seeded) text watermark header —
    /// used by tests that need something already there to replace/remove.
    private func makeWatermarkFixture() throws -> URL {
        var doc = WordDocument()
        doc.appendParagraph(Paragraph(text: "Body text"))
        doc.headers = [Header.withText("Header content", id: "rId10", type: .default)]
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm208-base-\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: base)
        defer { try? FileManager.default.removeItem(at: base) }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm208-staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { ZipHelper.cleanup(staging) }
        try FileManager.default.unzipItem(at: base, to: staging)
        try Self.watermarkHeaderXML.write(
            to: staging.appendingPathComponent("word/header1.xml"),
            atomically: true, encoding: .utf8)

        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm208-fixture-\(UUID().uuidString).docx")
        try ZipHelper.zip(staging, to: fixture)
        return fixture
    }

    /// A document with a plain header (no watermark, no prior VML namespace
    /// declarations) — exercises `ensureVMLNamespaces` and the "insert into a
    /// header that never had VML" path.
    private func makePlainHeaderFixture() throws -> URL {
        var doc = WordDocument()
        doc.appendParagraph(Paragraph(text: "Body text"))
        _ = doc.addHeader(text: "Plain header, no VML", type: .default)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm208-plain-\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    /// A document with NO headers at all — exercises the auto-create-header path.
    private func makeNoHeaderFixture() throws -> URL {
        var doc = WordDocument()
        doc.appendParagraph(Paragraph(text: "Body text, no header"))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm208-noheader-\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    /// PNG signature only (8 bytes) — enough to pass the magic-byte sniff;
    /// `ImageDimensions.detect` fails on it (no IHDR) and the handler falls
    /// back to a placeholder size, which is itself a path worth covering.
    private func makeThrowawayImage() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm208-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: url)
        return url
    }

    private func resultText(_ result: CallTool.Result) -> String {
        guard let first = result.content.first else { return "" }
        if case .text(let text, _, _) = first { return text }
        return ""
    }

    private func openFixture(_ server: WordMCPServer, _ fixture: URL, docId: String = "wm") async {
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string(docId)])
    }

    private func closeDiscarding(_ server: WordMCPServer, docId: String = "wm") async {
        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string(docId), "discard_changes": .bool(true)])
    }

    /// #208 verify note: `list_watermarks`/`get_watermark`/`list_headers`
    /// read `word/header*.xml` straight off `archiveTempDir` on disk
    /// (`readHeaderFooterXML`) rather than the in-memory typed model — a
    /// PRE-EXISTING trait of this codebase (see
    /// `HeadersFootersToolsTests.testEditingHeader2PreservesHeader1And3ByteEqual`,
    /// which also saves before re-reading), not something #208 introduced.
    /// A typed-model write this section makes is only guaranteed visible to
    /// those tools after a real save — `storeDocument` alone does not
    /// re-sync the archive; autosave does as an unrelated side effect, but
    /// on a counter-lagged schedule that must not be relied on. This helper
    /// saves to a throwaway path, opens it fresh under a new doc_id, runs
    /// `toolName`, closes the reopened session, and cleans up the file.
    private func saveReopenAndRun(
        _ server: WordMCPServer, docId: String = "wm",
        toolName: String, extraArgs: [String: Value] = [:]
    ) async -> String {
        let outPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm208-roundtrip-\(UUID().uuidString).docx").path
        let saveResult = await server.invokeToolForTesting(
            name: "save_document", arguments: ["doc_id": .string(docId), "path": .string(outPath)])
        XCTAssertNotEqual(saveResult.isError, true, "save_document failed: \(resultText(saveResult))")
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        let reopenServer = await WordMCPServer()
        _ = await reopenServer.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(outPath), "doc_id": .string("reopened")])
        var args: [String: Value] = ["doc_id": .string("reopened")]
        for (key, value) in extraArgs { args[key] = value }
        let result = await reopenServer.invokeToolForTesting(name: toolName, arguments: args)
        _ = await reopenServer.invokeToolForTesting(
            name: "close_document", arguments: ["doc_id": .string("reopened"), "discard_changes": .bool(true)])
        return resultText(result)
    }

    // MARK: - insert_watermark: real write

    func testInsertWatermarkWritesRealVMLShapeAndReadsBackViaListWatermarks() async throws {
        let fixture = try makePlainHeaderFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        await openFixture(server, fixture)

        let before = await server.isDocumentDirtyForTesting("wm")
        XCTAssertFalse(before, "opening a document must not start dirty")

        let insertResult = await server.invokeToolForTesting(
            name: "insert_watermark",
            arguments: ["doc_id": .string("wm"), "text": .string("DRAFT")])
        XCTAssertNotEqual(insertResult.isError, true, "insert_watermark must succeed. Got: \(resultText(insertResult))")
        XCTAssertTrue(resultText(insertResult).contains("DRAFT"))

        // #208 verify DA: a real write dirties the session (reverses the
        // #201-era "stubs leave it clean" assertion — see the test below).
        let afterInsert = await server.isDocumentDirtyForTesting("wm")
        XCTAssertTrue(afterInsert, "a real insert_watermark write must dirty the session")

        let list = await saveReopenAndRun(server, toolName: "list_watermarks")
        XCTAssertTrue(list.contains("DRAFT"), "list_watermarks must see the shape insert_watermark wrote: \(list)")
        XCTAssertTrue(list.contains("\"type\":\"text\""))

        // The original body text must not be disturbed — only the header changed.
        let bodyText = await server.invokeToolForTesting(
            name: "get_paragraphs", arguments: ["doc_id": .string("wm")])
        XCTAssertTrue(resultText(bodyText).contains("Body text"), "Got: \(resultText(bodyText))")

        await closeDiscarding(server)
    }

    func testInsertWatermarkAutoCreatesADefaultHeaderWhenNoneExists() async throws {
        let fixture = try makeNoHeaderFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        await openFixture(server, fixture)

        let listHeadersBefore = await server.invokeToolForTesting(
            name: "list_headers", arguments: ["doc_id": .string("wm")])
        XCTAssertEqual(resultText(listHeadersBefore), "[]", "fixture must start with zero headers")

        let insertResult = await server.invokeToolForTesting(
            name: "insert_watermark",
            arguments: ["doc_id": .string("wm"), "text": .string("CONFIDENTIAL")])
        XCTAssertNotEqual(insertResult.isError, true, "Got: \(resultText(insertResult))")

        let listHeadersAfter = await saveReopenAndRun(server, toolName: "list_headers")
        XCTAssertTrue(listHeadersAfter.contains("\"has_watermark\":true"), "Got: \(listHeadersAfter)")

        await closeDiscarding(server)
    }

    func testInsertWatermarkRejectsNonPositiveSize() async throws {
        let fixture = try makePlainHeaderFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        await openFixture(server, fixture)

        let result = await server.invokeToolForTesting(
            name: "insert_watermark",
            arguments: ["doc_id": .string("wm"), "text": .string("DRAFT"), "size": .int(0)])
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(resultText(result).contains("size"))

        await closeDiscarding(server)
    }

    /// Calling insert_watermark twice must REPLACE, not accumulate — two
    /// `PowerPlusWaterMarkObject1` shapes in one header would themselves be
    /// invalid (duplicate VML shape id).
    func testInsertWatermarkTwiceReplacesRatherThanAccumulates() async throws {
        let fixture = try makePlainHeaderFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        await openFixture(server, fixture)

        _ = await server.invokeToolForTesting(
            name: "insert_watermark", arguments: ["doc_id": .string("wm"), "text": .string("FIRST")])
        _ = await server.invokeToolForTesting(
            name: "insert_watermark", arguments: ["doc_id": .string("wm"), "text": .string("SECOND")])

        let text = await saveReopenAndRun(server, toolName: "list_watermarks")
        XCTAssertTrue(text.contains("SECOND"), "Got: \(text)")
        XCTAssertFalse(text.contains("FIRST"), "the first watermark must have been replaced, not kept alongside the second: \(text)")
        // Exactly one watermark entry in the JSON array (one header, one shape).
        XCTAssertEqual(text.components(separatedBy: "\"type\":\"text\"").count - 1, 1, "Got: \(text)")

        await closeDiscarding(server)
    }

    // MARK: - insert_image_watermark: real write

    func testInsertImageWatermarkWritesMediaRelationshipAndShapeThenReadsBackAsImage() async throws {
        let fixture = try makePlainHeaderFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let image = try makeThrowawayImage()
        defer { try? FileManager.default.removeItem(at: image) }
        let server = await WordMCPServer()
        await openFixture(server, fixture)

        let insertResult = await server.invokeToolForTesting(
            name: "insert_image_watermark",
            arguments: ["doc_id": .string("wm"), "image_path": .string(image.path)])
        XCTAssertNotEqual(insertResult.isError, true, "Got: \(resultText(insertResult))")

        // Critical regression: a header-scoped watermark image must NOT
        // create a document.xml.rels orphan (#175/#199 signature) — this is
        // the exact trap `document.images` would have set (see
        // insertImageWatermark's doc comment). `saveReopenAndRun` asserts the
        // DEFAULT (allow_orphan_images: false) save_document call succeeds.
        // #209: list_watermarks (on the reopened, genuinely-saved copy) must
        // recognise Word's real image-watermark shape (WordPictureWatermark),
        // not just the text fingerprint.
        let list = await saveReopenAndRun(server, toolName: "list_watermarks")
        XCTAssertTrue(list.contains("\"type\":\"image\""), "Got: \(list)")

        await closeDiscarding(server)
    }

    func testInsertImageWatermarkRejectsNonImageMagicBytes() async throws {
        let fixture = try makePlainHeaderFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        await openFixture(server, fixture)

        let fakeImage = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm208-notreally-\(UUID().uuidString).png")
        try Data("this is not a png".utf8).write(to: fakeImage)
        defer { try? FileManager.default.removeItem(at: fakeImage) }

        let result = await server.invokeToolForTesting(
            name: "insert_image_watermark",
            arguments: ["doc_id": .string("wm"), "image_path": .string(fakeImage.path)])
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(resultText(result).lowercased().contains("magic") || resultText(result).contains("魔數"), "Got: \(resultText(result))")

        await closeDiscarding(server)
    }

    func testInsertImageWatermarkRejectsDisallowedExtension() async throws {
        let fixture = try makePlainHeaderFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        await openFixture(server, fixture)

        let notAnImage = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm208-\(UUID().uuidString).exe")
        try Data([0x4D, 0x5A]).write(to: notAnImage)   // MZ header
        defer { try? FileManager.default.removeItem(at: notAnImage) }

        let result = await server.invokeToolForTesting(
            name: "insert_image_watermark",
            arguments: ["doc_id": .string("wm"), "image_path": .string(notAnImage.path)])
        XCTAssertEqual(result.isError, true)

        await closeDiscarding(server)
    }

    func testInsertImageWatermarkFailsTheSameWayForAMissingPath() async throws {
        let fixture = try makePlainHeaderFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        await openFixture(server, fixture)

        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm208-does-not-exist-\(UUID().uuidString).png").path
        let result = await server.invokeToolForTesting(
            name: "insert_image_watermark",
            arguments: ["doc_id": .string("wm"), "image_path": .string(missingPath)])
        XCTAssertEqual(result.isError, true)

        await closeDiscarding(server)
    }

    /// A `create_document` session (no source archive) cannot host a
    /// header-scoped media file — see `insertImageWatermark`'s doc comment.
    /// This is a named, honest refusal, not a silent no-op or a crash.
    func testInsertImageWatermarkRefusesOnADocumentWithNoPackageArchive() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "create_document", arguments: ["doc_id": .string("scratch")])
        let image = try makeThrowawayImage()
        defer { try? FileManager.default.removeItem(at: image) }

        let result = await server.invokeToolForTesting(
            name: "insert_image_watermark",
            arguments: ["doc_id": .string("scratch"), "image_path": .string(image.path)])
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(resultText(result).contains("package archive"), "Got: \(resultText(result))")

        // Text watermark has no such requirement.
        let textResult = await server.invokeToolForTesting(
            name: "insert_watermark", arguments: ["doc_id": .string("scratch"), "text": .string("DRAFT")])
        XCTAssertNotEqual(textResult.isError, true, "Got: \(resultText(textResult))")

        _ = await server.invokeToolForTesting(
            name: "close_document", arguments: ["doc_id": .string("scratch"), "discard_changes": .bool(true)])
    }

    // MARK: - remove_watermark: real removal

    func testRemoveWatermarkRemovesTheRealShapeReadBackAsGone() async throws {
        let fixture = try makeWatermarkFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        await openFixture(server, fixture)

        let before = resultText(await server.invokeToolForTesting(
            name: "list_watermarks", arguments: ["doc_id": .string("wm")]))
        XCTAssertTrue(before.contains("機密"), "fixture must start with the seeded watermark")

        let removeResult = await server.invokeToolForTesting(
            name: "remove_watermark", arguments: ["doc_id": .string("wm")])
        XCTAssertNotEqual(removeResult.isError, true, "Got: \(resultText(removeResult))")

        let after = await saveReopenAndRun(server, toolName: "list_watermarks")
        XCTAssertEqual(after, "[]", "the watermark must be gone after remove_watermark: \(after)")

        await closeDiscarding(server)
    }

    /// Removing an image watermark must also remove the header-local image
    /// relationship it referenced — leaving it behind would itself be an
    /// orphan (#175/#199 signature) on the next save.
    func testRemoveWatermarkAfterImageWatermarkLeavesNoOrphanRelationship() async throws {
        let fixture = try makePlainHeaderFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let image = try makeThrowawayImage()
        defer { try? FileManager.default.removeItem(at: image) }
        let server = await WordMCPServer()
        await openFixture(server, fixture)

        _ = await server.invokeToolForTesting(
            name: "insert_image_watermark",
            arguments: ["doc_id": .string("wm"), "image_path": .string(image.path)])
        _ = await server.invokeToolForTesting(
            name: "remove_watermark", arguments: ["doc_id": .string("wm")])

        // The default (allow_orphan_images: false) save inside
        // `saveReopenAndRun` must succeed — if the header-local relationship
        // were left behind as an orphan, it would refuse with
        // E_IMAGE_CONSISTENCY.
        let list = await saveReopenAndRun(server, toolName: "list_watermarks")
        XCTAssertEqual(list, "[]", "Got: \(list)")

        await closeDiscarding(server)
    }

    /// #208 issue body: "文件本來就沒有浮水印時回成功（無事可做）" — a no-op
    /// success, not the old stub's hard failure.
    func testRemoveWatermarkOnADocumentWithNoWatermarkSucceedsAsNoOp() async throws {
        let fixture = try makePlainHeaderFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        await openFixture(server, fixture)

        let before = await server.isDocumentDirtyForTesting("wm")
        let result = await server.invokeToolForTesting(
            name: "remove_watermark", arguments: ["doc_id": .string("wm")])
        XCTAssertNotEqual(result.isError, true, "Got: \(resultText(result))")
        XCTAssertTrue(resultText(result).contains("No watermark"), "Got: \(resultText(result))")

        let after = await server.isDocumentDirtyForTesting("wm")
        XCTAssertEqual(before, after, "a true no-op must not flip dirty state")

        await closeDiscarding(server)
    }

    // MARK: - Read side: unchanged behavior for the pre-existing text case

    func testReadSideStillReportsTheExistingWatermark() async throws {
        let fixture = try makeWatermarkFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        await openFixture(server, fixture)

        let list = await server.invokeToolForTesting(
            name: "list_watermarks", arguments: ["doc_id": .string("wm")])
        XCTAssertNotEqual(list.isError, true, "list_watermarks is real and must keep working. Got: \(resultText(list))")
        XCTAssertTrue(resultText(list).contains("機密"), "list_watermarks lost the watermark: \(resultText(list))")

        let one = await server.invokeToolForTesting(
            name: "get_watermark",
            arguments: ["doc_id": .string("wm"), "header_id": .string("rId10")])
        XCTAssertNotEqual(one.isError, true, "get_watermark is real and must keep working. Got: \(resultText(one))")
        XCTAssertTrue(resultText(one).contains("機密"), "get_watermark lost the watermark: \(resultText(one))")
        await closeDiscarding(server)
    }

    // MARK: - Transport contract (verify DA D4, #201 legacy — still true for a thrown error)

    /// `save_document` on a nonexistent doc_id still throws (not a returned
    /// "Error: …" string) and must surface as `isError` inside
    /// `handleToolCall`, not escape to the JSON-RPC error channel. Kept from
    /// #201 with a target that still throws now that the watermark tools
    /// themselves are real (they no longer throw `ToolNotImplemented`).
    func testThrownErrorBecomesIsErrorInsideHandleToolCall() async throws {
        let server = await WordMCPServer()
        let params = CallTool.Parameters(
            name: "insert_watermark",
            arguments: ["doc_id": .string("does-not-exist"), "text": .string("DRAFT")])
        let result: CallTool.Result
        do {
            result = try await server.handleToolCall(params)
        } catch {
            XCTFail("handleToolCall let the error escape to the JSON-RPC channel: \(error)")
            return
        }
        XCTAssertEqual(result.isError, true, "a thrown documentNotFound must surface as isError, not as a transport error")
    }
}
