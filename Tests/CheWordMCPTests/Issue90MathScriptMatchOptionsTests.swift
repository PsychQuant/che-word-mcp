import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

final class Issue90MathScriptMatchOptionsTests: XCTestCase {

    func testScopedInsertionToolSchemasExposeMathScriptMatchOption() async {
        let server = await WordMCPServer()
        for tool in ["insert_paragraph", "insert_equation", "insert_image_from_path", "insert_caption"] {
            let schema = await server.toolInputSchemaForTesting(name: tool)
            let properties = schema?.objectValue?["properties"]?.objectValue
            let matchOptions = properties?["match_options"]?.objectValue
            let matchProperties = matchOptions?["properties"]?.objectValue
            let mathScript = matchProperties?["math_script_insensitive"]?.objectValue

            XCTAssertNotNil(matchOptions, "\(tool) schema should expose match_options")
            XCTAssertEqual(mathScript?["type"]?.stringValue, "boolean")
            XCTAssertTrue(
                mathScript?["description"]?.stringValue?.contains("H₀/H0") == true,
                "\(tool) schema should document H₀/H0 matching"
            )
        }
    }

    func testOmittedMatchOptionsKeepsExactMatching() async throws {
        let url = try writeDocx(paragraphs: ["H0 anchor", "tail"])
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("issue90-exact")]
        )

        let result = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("issue90-exact"),
                "text": .string("INSERTED"),
                "after_text": .string("H₀")
            ]
        )

        XCTAssertTrue(
            textOf(result).contains("Error: insert_paragraph: text 'H₀' not found"),
            "omitted match_options must keep exact matching; got \(textOf(result))"
        )
    }

    func testInsertParagraphMatchesUnicodeSubscriptAnchorToASCIITextWhenEnabled() async throws {
        let url = try writeDocx(paragraphs: ["H0 anchor", "tail"])
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("issue90-after")]
        )

        let result = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("issue90-after"),
                "text": .string("INSERTED_AFTER_H0"),
                "after_text": .string("H₀"),
                "match_options": .object([
                    "math_script_insensitive": .bool(true)
                ])
            ]
        )
        XCTAssertFalse(result.isError == true, "insert_paragraph should succeed; got \(textOf(result))")

        let paragraphs = await server.invokeToolForTesting(
            name: "get_paragraphs",
            arguments: ["doc_id": .string("issue90-after")]
        )
        let text = textOf(paragraphs)
        guard let anchorPos = text.range(of: "H0 anchor")?.lowerBound,
              let insertPos = text.range(of: "INSERTED_AFTER_H0")?.lowerBound,
              let tailPos = text.range(of: "tail")?.lowerBound else {
            return XCTFail("expected anchor, inserted text, and tail in get_paragraphs: \(text)")
        }
        XCTAssertLessThan(anchorPos, insertPos)
        XCTAssertLessThan(insertPos, tailPos)
    }

    func testInsertCaptionMatchesASCIIAnchorToUnicodeSubscriptTextWhenEnabled() async throws {
        let url = try writeDocx(paragraphs: ["H₀ anchor", "tail"])
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("issue90-caption")]
        )

        let result = await server.invokeToolForTesting(
            name: "insert_caption",
            arguments: [
                "doc_id": .string("issue90-caption"),
                "label": .string("Equation"),
                "caption_text": .string("Null hypothesis"),
                "after_text": .string("H0"),
                "match_options": .object([
                    "math_script_insensitive": .bool(true)
                ])
            ]
        )
        XCTAssertFalse(result.isError == true, "insert_caption should succeed; got \(textOf(result))")

        let paragraphs = await server.invokeToolForTesting(
            name: "get_paragraphs",
            arguments: ["doc_id": .string("issue90-caption")]
        )
        let text = textOf(paragraphs)
        guard let anchorPos = text.range(of: "H₀ anchor")?.lowerBound,
              let captionPos = text.range(of: "Null hypothesis")?.lowerBound else {
            return XCTFail("expected anchor and caption in get_paragraphs: \(text)")
        }
        XCTAssertLessThan(anchorPos, captionPos)
    }

    func testInvalidMatchOptionsTypeIsRejected() async throws {
        let url = try writeDocx(paragraphs: ["H0 anchor"])
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("issue90-invalid")]
        )

        let result = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("issue90-invalid"),
                "text": .string("INSERTED"),
                "after_text": .string("H0"),
                "match_options": .string("bad")
            ]
        )

        XCTAssertTrue(textOf(result).contains("Error: insert_paragraph: match_options must be an object"))
    }

    private func writeDocx(paragraphs: [String]) throws -> URL {
        var doc = WordDocument()
        doc.body.children = paragraphs.map { .paragraph(Paragraph(text: $0)) }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue90_match_options_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    private func textOf(_ result: CallTool.Result) -> String {
        result.content.compactMap { item -> String? in
            if case let .text(text, _, _) = item { return text }
            return nil
        }.joined(separator: "\n")
    }
}
