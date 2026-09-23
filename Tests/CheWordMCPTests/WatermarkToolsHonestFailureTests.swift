import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// #201 — the three write-side watermark tools reported success and wrote nothing.
///
/// `insert_watermark`, `insert_image_watermark` and `remove_watermark` validated
/// their arguments, returned a confident sentence ("Watermark inserted: …",
/// "Watermark removed from document") and left every header part exactly as it
/// was. The read side (`list_watermarks`, `get_watermark`) parses the VML
/// `PowerPlusWaterMarkObject` shape Word writes for *text* watermarks — so a
/// caller who inserted and then listed saw the contradiction only if they
/// thought to check. (Word's *image* watermarks use a different shape the read
/// side does not yet recognise: #209.)
///
/// Same treatment as #172: the stubs now throw `ToolNotImplemented`, naming the
/// OOXML they would have to write. The read side is untouched, and this file
/// pins that too, so the fix cannot quietly widen.
///
/// The assertions check `isError`, the phrase "not implemented" and the names of
/// the missing OOXML pieces — not the full wording — so the message can improve
/// without the tests rotting.
final class WatermarkToolsHonestFailureTests: XCTestCase {

    // MARK: - Fixture: one header carrying a real VML text watermark

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

    private func makeWatermarkFixture() throws -> URL {
        var doc = WordDocument()
        doc.appendParagraph(Paragraph(text: "Body text"))
        doc.headers = [Header.withText("Header content", id: "rId10", type: .default)]
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm201-base-\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: base)
        defer { try? FileManager.default.removeItem(at: base) }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm201-staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { ZipHelper.cleanup(staging) }
        try FileManager.default.unzipItem(at: base, to: staging)
        try Self.watermarkHeaderXML.write(
            to: staging.appendingPathComponent("word/header1.xml"),
            atomically: true, encoding: .utf8)

        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm201-fixture-\(UUID().uuidString).docx")
        try ZipHelper.zip(staging, to: fixture)
        return fixture
    }

    /// `insert_image_watermark` never reads the file; any path will do. A real
    /// file is used so the test does not depend on the (removed) existence check.
    private func makeThrowawayImage() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm201-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: url)
        return url
    }

    private func resultText(_ result: CallTool.Result) -> String {
        guard let first = result.content.first else { return "" }
        if case .text(let text, _, _) = first { return text }
        return ""
    }

    private func openFixture(_ server: WordMCPServer, _ fixture: URL) async {
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("wm")])
    }

    private func closeDiscarding(_ server: WordMCPServer) async {
        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("wm"), "discard_changes": .bool(true)])
    }

    private func assertNotImplemented(_ result: CallTool.Result, _ tool: String,
                                      naming keywords: [String],
                                      file: StaticString = #filePath, line: UInt = #line) {
        let text = resultText(result)
        XCTAssertEqual(result.isError, true,
                       "\(tool) SHALL fail rather than return a success string. Got: \(text)",
                       file: file, line: line)
        XCTAssertTrue(text.lowercased().contains("not implemented"),
                      "\(tool) SHALL say it is not implemented. Got: \(text)",
                      file: file, line: line)
        for keyword in keywords {
            XCTAssertTrue(text.contains(keyword),
                          "\(tool) SHALL name the OOXML it does not write (\(keyword)). Got: \(text)",
                          file: file, line: line)
        }
        XCTAssertTrue(text.contains("#201"),
                      "\(tool) SHALL point the caller at its own issue, not #172. Got: \(text)",
                      file: file, line: line)
    }

    // MARK: - Write side: fail, and say what is missing

    func testInsertWatermarkFailsAndNamesTheHeaderShape() async throws {
        let fixture = try makeWatermarkFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        await openFixture(server, fixture)

        assertNotImplemented(await server.invokeToolForTesting(
            name: "insert_watermark",
            arguments: ["doc_id": .string("wm"), "text": .string("DRAFT")]),
                             "insert_watermark",
                             naming: ["PowerPlusWaterMarkObject", "v:textpath", "header"])
        await closeDiscarding(server)
    }

    func testInsertImageWatermarkFailsAndNamesTheImageDataShape() async throws {
        let fixture = try makeWatermarkFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let image = try makeThrowawayImage()
        defer { try? FileManager.default.removeItem(at: image) }
        let server = await WordMCPServer()
        await openFixture(server, fixture)

        assertNotImplemented(await server.invokeToolForTesting(
            name: "insert_image_watermark",
            arguments: ["doc_id": .string("wm"), "image_path": .string(image.path)]),
                             "insert_image_watermark",
                             naming: ["WordPictureWatermark", "v:imagedata", "relationship", "media part"])
        await closeDiscarding(server)
    }

    /// Verify S1: the old file-existence check answered "not found" with a plain
    /// string and "found" with a thrown error — an existence oracle with reversed
    /// polarity. A path that does not exist must fail exactly like one that does.
    func testInsertImageWatermarkFailsTheSameWayForAMissingPath() async throws {
        let fixture = try makeWatermarkFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        await openFixture(server, fixture)

        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm201-does-not-exist-\(UUID().uuidString).png").path
        assertNotImplemented(await server.invokeToolForTesting(
            name: "insert_image_watermark",
            arguments: ["doc_id": .string("wm"), "image_path": .string(missingPath)]),
                             "insert_image_watermark",
                             naming: ["WordPictureWatermark", "v:imagedata"])
        await closeDiscarding(server)
    }

    func testRemoveWatermarkFailsAndNamesTheShapesItWouldRemove() async throws {
        let fixture = try makeWatermarkFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        await openFixture(server, fixture)

        assertNotImplemented(await server.invokeToolForTesting(
            name: "remove_watermark",
            arguments: ["doc_id": .string("wm")]),
                             "remove_watermark",
                             naming: ["PowerPlusWaterMarkObject", "w:pict", "header"])
        await closeDiscarding(server)
    }

    // MARK: - Transport contract (verify DA D4)

    /// `invokeToolForTesting` carries its own catch, so it cannot tell whether a
    /// thrown handler error became `isError: true` inside `handleToolCall` or
    /// escaped to the SDK's JSON-RPC error channel. The descriptions and the
    /// CHANGELOG promise the former; pin it by calling `handleToolCall` directly.
    func testThrownNotImplementedBecomesIsErrorInsideHandleToolCall() async throws {
        let fixture = try makeWatermarkFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        await openFixture(server, fixture)

        let params = CallTool.Parameters(
            name: "insert_watermark",
            arguments: ["doc_id": .string("wm"), "text": .string("DRAFT")])
        let result: CallTool.Result
        do {
            result = try await server.handleToolCall(params)
        } catch {
            XCTFail("handleToolCall let the error escape to the JSON-RPC channel: \(error)")
            await closeDiscarding(server)
            return
        }
        XCTAssertEqual(result.isError, true, "the thrown ToolNotImplemented must surface as isError, not as a transport error")
        XCTAssertTrue(resultText(result).lowercased().contains("not implemented"))
        await closeDiscarding(server)
    }

    // MARK: - Read side: unchanged

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

    // MARK: - The stubs touch nothing

    /// The listing comparison does the real work here. The dirty-flag check is
    /// belt-and-braces only: the flag is false from registration, so it would
    /// pass even if the stubs were never called; it guards a half-implementation
    /// that mutates before failing, and must be reversed when #208 lands.
    func testStubsLeaveTheSessionCleanAndTheWatermarkAsItWas() async throws {
        let fixture = try makeWatermarkFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let image = try makeThrowawayImage()
        defer { try? FileManager.default.removeItem(at: image) }
        let server = await WordMCPServer()
        await openFixture(server, fixture)

        let before = resultText(await server.invokeToolForTesting(
            name: "list_watermarks", arguments: ["doc_id": .string("wm")]))

        _ = await server.invokeToolForTesting(
            name: "insert_watermark",
            arguments: ["doc_id": .string("wm"), "text": .string("DRAFT")])
        _ = await server.invokeToolForTesting(
            name: "insert_image_watermark",
            arguments: ["doc_id": .string("wm"), "image_path": .string(image.path)])
        _ = await server.invokeToolForTesting(
            name: "remove_watermark", arguments: ["doc_id": .string("wm")])

        let dirty = await server.isDocumentDirtyForTesting("wm")
        XCTAssertFalse(dirty, "Three tools that write nothing must not dirty the session")

        let after = resultText(await server.invokeToolForTesting(
            name: "list_watermarks", arguments: ["doc_id": .string("wm")]))
        XCTAssertEqual(before, after, "The existing watermark must survive the stubs untouched")
        XCTAssertTrue(after.contains("機密"))
        await closeDiscarding(server)
    }
}
