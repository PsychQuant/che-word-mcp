import XCTest
import MCP
import OOXMLSwift
import ZIPFoundation
@testable import CheWordMCP

/// #187 — `search_text` / `replace_text`'s text model can silently drop a
/// whitespace-only run's content, so a query copied verbatim out of the
/// source XML (the caller's normal workflow: raw XML / pandoc / python-docx
/// extraction) finds nothing even though the text is right there in the
/// file.
///
/// **Confirmed root cause** (empirically, against both the public NTU
/// REC-P-011 form and a minimal reproducer): Foundation's `XMLDocument`
/// collapses a whitespace-only `<w:t>` text node's `stringValue` to `""`.
/// ooxml-swift has a recovery mechanism (`WhitespaceOverlay`) for this, but
/// by its OWN documented scope it only covers `<w:t xml:space="preserve">
/// [whitespace]</w:t>` — a **bare** `<w:t>   </w:t>` with no `xml:space`
/// attribute is explicitly out of scope ("Word always emits the attribute
/// when text starts/ends with whitespace" — an assumption that does not
/// hold for every real-world document; not every `.docx` in the wild was
/// produced by Word itself). This is the reliable, minimal reproducer used
/// below. The exact-`xml:space="preserve"` case from the original report
/// (inside a table nested two levels deep in the ~480KB real form) was ALSO
/// empirically confirmed to lose its whitespace, but no minimal synthetic
/// XML reproduced that specific path — it appears to depend on document-wide
/// state this repo cannot economically isolate without shipping the real
/// 480KB file as a fixture (`.docx` files are gitignored in this repo). The
/// fix below is agnostic to *why* the model's text lost the whitespace; it
/// only needs the empirically-confirmed *symptom* (`Paragraph.getText()`
/// returns text shorter than the source XML), which the bare-`<w:t>` case
/// reproduces deterministically.
///
/// ooxml-swift is not modified: the fix is a fallback layer in che-word-mcp.
/// When a literal search finds nothing AND the query contains whitespace,
/// it retries with whitespace stripped from both the query and each
/// paragraph's (already-lossy) parsed text, and labels any hit as a
/// "normalized match". The literal pass is untouched code, so an already-
/// working search (the common case) is provably unaffected.
final class Issue187WhitespaceRunSearchTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue187-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - search_text

    /// The literal query (with the space that really exists in the source
    /// XML bytes) finds nothing by itself — the parsed model has already
    /// lost it — but the normalized fallback still finds and reports it.
    func testSearchTextFindsNormalizedMatchWhenLiteralQueryHasNoHit() async throws {
        let output = try await search(query: "否   □是", documentXML: bareWhitespaceRunDocumentXML)
        XCTAssertTrue(output.contains("Found 1 match"), output)
        XCTAssertTrue(output.contains("normalized match"), "result must disclose it used normalization: \(output)")
        XCTAssertTrue(output.contains("Table 0, row 0, col 0"), output)
    }

    /// A query that already matches the (lossy) parsed text directly is
    /// completely unaffected by the fallback — no normalization note, and
    /// the fallback pass never even runs (the literal pass already found
    /// something).
    func testSearchTextLiteralMatchIsUnaffectedByFallback() async throws {
        let output = try await search(query: "否□是", documentXML: bareWhitespaceRunDocumentXML)
        XCTAssertTrue(output.contains("Found 1 match"), output)
        XCTAssertFalse(output.contains("normalized"), "a literal hit must not carry the normalization disclosure: \(output)")
    }

    /// A query that matches nothing even after normalization is still
    /// reported as no matches — the fallback doesn't manufacture false
    /// positives.
    func testSearchTextReportsNoMatchesWhenNormalizedQueryAlsoMisses() async throws {
        let output = try await search(query: "完全不存在的字串", documentXML: bareWhitespaceRunDocumentXML)
        XCTAssertEqual(output, "No matches found for '完全不存在的字串'")
    }

    /// A query with no whitespace at all never triggers the fallback pass
    /// (stripping it would be a no-op) — this is mostly a performance/
    /// no-surprise guarantee, verified via the plain "No matches" wording
    /// (the fallback path would still say "No matches", but this pins that
    /// a whitespace-free miss doesn't accidentally match something else).
    func testSearchTextWithNoWhitespaceInQueryIsUnaffected() async throws {
        let output = try await search(query: "全部找不到的字串123", documentXML: bareWhitespaceRunDocumentXML)
        XCTAssertEqual(output, "No matches found for '全部找不到的字串123'")
    }

    // MARK: - replace_text

    /// `find` copied verbatim from the source XML (with the space the
    /// parser lost) fails literally, same as search — but the same
    /// normalized fallback lets the replace actually succeed, and the
    /// caller's intended `replace` text (WITH its own spacing) lands in the
    /// saved file exactly as written, because it's written fresh into the
    /// typed model rather than re-parsed through the same lossy path.
    func testReplaceTextSucceedsViaNormalizedFallbackAndKeepsIntendedSpacing() async throws {
        let (saved, message) = try await replaceAndSave(
            find: "否   □是", replace: "否   ■是", documentXML: bareWhitespaceRunDocumentXML)

        XCTAssertTrue(message.contains("Replaced 1"), message)
        XCTAssertTrue(message.contains("normalized"), "message must disclose the fallback was used: \(message)")
        XCTAssertTrue(saved.contains("■"), "the replacement text is missing:\n\(saved)")
        // The caller's own spacing in `replace` must survive into the saved
        // file — written fresh into the typed model, not re-parsed through
        // the same lossy Foundation XMLDocument path that lost the
        // ORIGINAL document's whitespace run.
        XCTAssertTrue(saved.contains("否   ■是"),
                     "expected the caller's intended spacing to land literally in the saved run text:\n\(saved)")
    }

    /// A literal `find`/`replace` pair that already matches directly is
    /// completely unaffected — no normalization note.
    func testReplaceTextLiteralMatchIsUnaffectedByFallback() async throws {
        let (_, message) = try await replaceAndSave(
            find: "否□是", replace: "否■是", documentXML: bareWhitespaceRunDocumentXML)
        XCTAssertTrue(message.contains("Replaced 1"), message)
        XCTAssertFalse(message.contains("normalized"), message)
    }

    private func replaceAndSave(find: String, replace: String, documentXML: String) async throws -> (saved: String, message: String) {
        let source = scratch.appendingPathComponent("source-\(UUID().uuidString).docx")
        let output = scratch.appendingPathComponent("saved-\(UUID().uuidString).docx")
        try Self.writePackage(documentXML: documentXML, to: source)

        let server = await WordMCPServer()
        let docId = "t187-replace-\(UUID().uuidString)"
        let opened = await server.invokeToolForTesting(name: "open_document", arguments: [
            "doc_id": .string(docId), "path": .string(source.path),
        ])
        XCTAssertNotEqual(opened.isError, true, "open_document failed: \(text(of: opened))")

        let replaced = await server.invokeToolForTesting(name: "replace_text", arguments: [
            "doc_id": .string(docId), "find": .string(find), "replace": .string(replace),
        ])
        XCTAssertNotEqual(replaced.isError, true, "replace_text failed: \(text(of: replaced))")
        let message = text(of: replaced)

        let savedResult = await server.invokeToolForTesting(name: "save_document", arguments: [
            "doc_id": .string(docId), "path": .string(output.path),
        ])
        XCTAssertNotEqual(savedResult.isError, true, "save_document failed: \(text(of: savedResult))")
        _ = await server.invokeToolForTesting(name: "close_document", arguments: ["doc_id": .string(docId)])

        let archive = try Archive(url: output, accessMode: .read)
        let entry = try XCTUnwrap(archive["word/document.xml"])
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return (String(decoding: data, as: UTF8.self), message)
    }

    // MARK: - Helpers

    private func search(query: String, documentXML: String) async throws -> String {
        let source = scratch.appendingPathComponent("source-\(UUID().uuidString).docx")
        try Self.writePackage(documentXML: documentXML, to: source)

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(name: "search_text", arguments: [
            "source_path": .string(source.path), "query": .string(query),
        ])
        XCTAssertNotEqual(result.isError, true, "search_text failed: \(text(of: result))")
        return text(of: result)
    }

    private func text(of result: CallTool.Result) -> String {
        guard case .text(let value, _, _)? = result.content.first else { return "" }
        return value
    }

    private static func writePackage(documentXML: String, to destination: URL) throws {
        let archive = try Archive(url: destination, accessMode: .create)
        let parts: [(String, String)] = [
            ("[Content_Types].xml", contentTypesXML),
            ("_rels/.rels", packageRelsXML),
            ("word/_rels/document.xml.rels", documentRelsXML),
            ("word/document.xml", documentXML),
        ]
        for (path, content) in parts {
            let data = Data(content.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                                 compressionMethod: .deflate) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
    }
}

// MARK: - Fixture

/// One table cell, four runs: "否", a bare (no `xml:space="preserve"`)
/// whitespace-only run "   ", "□", "是" — matches the exact pattern
/// (`□否 □是 □不適用`-shaped checklist text) reported in #187, minimized to
/// a single reliable reproducer.
private let bareWhitespaceRunDocumentXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<w:body>
<w:tbl>
<w:tblPr><w:tblW w:w="0" w:type="auto"/></w:tblPr>
<w:tblGrid><w:gridCol w:w="4000"/></w:tblGrid>
<w:tr>
<w:tc><w:tcPr><w:tcW w:w="4000" w:type="dxa"/></w:tcPr><w:p><w:r><w:t>否</w:t></w:r><w:r><w:t>   </w:t></w:r><w:r><w:t>□</w:t></w:r><w:r><w:t>是</w:t></w:r></w:p></w:tc>
</w:tr>
</w:tbl>
<w:p/>
<w:sectPr></w:sectPr>
</w:body>
</w:document>
"""

private let contentTypesXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>
"""

private let packageRelsXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>
"""

private let documentRelsXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
</Relationships>
"""
