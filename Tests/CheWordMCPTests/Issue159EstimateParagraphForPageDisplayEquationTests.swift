import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#159 — verification of #142 (PR #158) found that
/// `testEstimateParagraphForPageMixedThesisLayout` never actually
/// synthesized `<m:oMathPara>` markup; it only asserted `display_equations
/// >= 0`, which passes whether or not the display-equation branch of
/// `classifyParagraph()` ever fires. The heuristic logic itself (empty runs
/// + `<m:oMathPara` substring in `unrecognizedChildren`) was already
/// correct — this test locks it down end-to-end with a hand-crafted
/// `UnrecognizedChild` carrying real `<m:oMathPara>` rawXML, round-tripped
/// through an actual `.docx` write/read (not just constructed in memory),
/// so it also verifies the writer/reader round-trip preserves this
/// direct-child markup.
final class Issue159EstimateParagraphForPageDisplayEquationTests: XCTestCase {

    func testEstimateParagraphForPageDetectsDisplayEquationParagraph() async throws {
        var doc = WordDocument()

        // 5 ordinary text paragraphs.
        for _ in 0..<5 {
            doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "some text")])))
        }

        // 1 display-equation paragraph: empty run text + `<m:oMathPara>`
        // carried as a direct-child `unrecognizedChildren` entry (the
        // Pandoc display-math pattern, see #99). The namespace is declared
        // inline on the element itself so the fragment is self-contained
        // and parses correctly regardless of what the document root
        // declares.
        var displayEqPara = Paragraph(runs: [Run(text: "")])
        let mathChild = UnrecognizedChild(
            name: "oMathPara",
            rawXML: "<m:oMathPara xmlns:m=\"http://schemas.openxmlformats.org/officeDocument/2006/math\">"
                + "<m:oMath><m:r><m:t>x=1</m:t></m:r></m:oMath></m:oMathPara>",
            position: 0
        )
        displayEqPara.unrecognizedChildren.append(mathChild)
        doc.body.children.append(.paragraph(displayEqPara))

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue159_display_equation_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(
            name: "estimate_paragraph_for_page",
            arguments: [
                "source_path": .string(url.path),
                "page": .int(1),
                "chars_per_page": .int(1000),
                "context_paragraphs": .int(0),
            ]
        )

        let json = try jsonObject(from: textOf(result))
        // 5 text + 1 display-equation = 6 body-stream paragraphs.
        XCTAssertEqual(json["paragraph_count"] as? Int, 6, textOf(result))

        let breakdown = try XCTUnwrap(json["structural_breakdown"] as? [String: Any], textOf(result))
        XCTAssertEqual(breakdown["display_equations"] as? Int, 1, textOf(result))
        XCTAssertEqual(breakdown["equation_chars_added"] as? Int, 120, textOf(result))
        XCTAssertEqual(breakdown["paragraphs_with_text"] as? Int, 5, textOf(result))
    }

    private func textOf(_ r: CallTool.Result) -> String {
        r.content.compactMap { item -> String? in
            if case let .text(t, _, _) = item { return t } else { return nil }
        }.joined(separator: "\n")
    }

    private func jsonObject(from text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
