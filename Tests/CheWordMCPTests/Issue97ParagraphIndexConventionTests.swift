import XCTest
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#97 — pin the current paragraph-index convention
/// split without changing public API behavior.
final class Issue97ParagraphIndexConventionTests: XCTestCase {

    func testCrossFamilyFixturePinsCurrentIndexSemantics() throws {
        let doc = conventionFixture()

        XCTAssertEqual(doc.body.children.count, 4, "fixture must include paragraph + table + block-level SDT + paragraph")
        XCTAssertEqual(
            doc.getParagraphs().map { $0.getText() },
            ["top-0", "sdt-inner", "top-1"],
            "getParagraphs readback index descends into block-level SDTs but skips table-cell paragraphs"
        )

        var insertDoc = doc
        insertDoc.insertParagraph(Paragraph(runs: [Run(text: "inserted-before-table")]), at: 1)
        XCTAssertEqual(textOfBodyChild(insertDoc.body.children[1]), "inserted-before-table")
        XCTAssertTrue(isTable(insertDoc.body.children[2]), "body.children insertion index 1 must insert before the table body child")

        var mutateDoc = doc
        var bold = RunProperties()
        bold.bold = true
        try mutateDoc.formatParagraph(at: 1, with: bold)

        guard case .paragraph(let topOne) = mutateDoc.body.children[3] else {
            XCTFail("fixture body child 3 should remain the second top-level paragraph")
            return
        }
        XCTAssertTrue(topOne.runs.first?.properties.bold ?? false, "top-level paragraph ordinal 1 targets the second direct body paragraph")

        guard case .contentControl(_, let children) = mutateDoc.body.children[2],
              case .paragraph(let sdtPara) = children.first else {
            XCTFail("fixture body child 2 should be a block-level SDT containing one paragraph")
            return
        }
        XCTAssertFalse(
            sdtPara.runs.first?.properties.bold ?? false,
            "top-level paragraph ordinal must not target the block-level SDT child paragraph"
        )
    }

    func testParagraphIndexConventionDocsInventoryExists() throws {
        let docs = try String(contentsOf: repoRoot().appendingPathComponent("docs/paragraph-index-conventions.md"), encoding: .utf8)

        XCTAssertTrue(docs.contains("`body.children` insertion index"))
        XCTAssertTrue(docs.contains("Top-level paragraph ordinal"))
        XCTAssertTrue(docs.contains("`get_paragraphs` readback index"))
        XCTAssertTrue(docs.contains("`insert_paragraph.index`"))
        XCTAssertTrue(docs.contains("`insert_caption.paragraph_index`"))
        XCTAssertTrue(docs.contains("`format_text.paragraph_index`, `set_paragraph_format.paragraph_index`, `apply_style.paragraph_index`"))
        XCTAssertTrue(docs.contains("`set_paragraph_border.paragraph_index`, `set_paragraph_shading.paragraph_index`, `set_character_spacing.paragraph_index`, `set_text_effect.paragraph_index`"))
        XCTAssertTrue(docs.contains("`get_paragraph_runs.paragraph_index`, `get_text_with_formatting.paragraph_index`"))
        XCTAssertTrue(docs.contains("Public API renaming or typed wrapper indices would be a breaking change"))
    }

    func testRepresentativeSchemaDescriptionsNameIndexFamilies() throws {
        let source = try String(contentsOf: repoRoot().appendingPathComponent("Sources/CheWordMCP/Server.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("get_paragraphs readback index：top-level paragraphs + block-level SDT 內段落"))
        XCTAssertTrue(source.contains("index 是 body.children 插入索引"))
        XCTAssertTrue(source.contains("不是 get_paragraphs 的 paragraph readback index"))
        XCTAssertTrue(source.contains("top-level paragraph ordinal（從 0 開始；只計直接位於 body.children 的 `.paragraph`"))
        XCTAssertTrue(source.contains("body.children 插入索引（從 0 開始；計入 tables / block-level SDTs / bookmark markers / raw blocks）。五 anchor 擇一"))
    }

    func testReadmeLinksConventionGuide() throws {
        let readme = try String(contentsOf: repoRoot().appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertTrue(readme.contains("### Paragraph Index Conventions"))
        XCTAssertTrue(readme.contains("[docs/paragraph-index-conventions.md](docs/paragraph-index-conventions.md)"))
    }

    private func conventionFixture() -> WordDocument {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "top-0")])))
        doc.body.children.append(.table(Table(rows: [
            TableRow(cells: [TableCell(paragraphs: [Paragraph(runs: [Run(text: "table-cell")])])])
        ])))
        let sdt = StructuredDocumentTag(
            id: 9701,
            tag: "issue97_wrapper",
            alias: "Issue 97 Wrapper",
            type: .richText
        )
        let control = ContentControl(sdt: sdt, content: "")
        doc.body.children.append(.contentControl(control, children: [
            .paragraph(Paragraph(runs: [Run(text: "sdt-inner")]))
        ]))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "top-1")])))
        return doc
    }

    private func textOfBodyChild(_ child: BodyChild) -> String {
        if case .paragraph(let para) = child { return para.getText() }
        return ""
    }

    private func isTable(_ child: BodyChild) -> Bool {
        if case .table = child { return true }
        return false
    }

    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
        }
        return URL(fileURLWithPath: "/dev/null")
    }
}
