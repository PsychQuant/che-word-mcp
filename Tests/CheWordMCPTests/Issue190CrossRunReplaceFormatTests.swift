import XCTest
import MCP
import OOXMLSwift
import ZIPFoundation
@testable import CheWordMCP

/// #190 — `replace_text` matching text that spans more than one run merges
/// the matched text into the *first* run and silently discards every other
/// matched run's `rPr` (ooxml-swift's `TextReplacementEngine`, a dependency
/// this repo does not modify). The reported case: a checkbox glyph run
/// (`□`, `rFonts ascii="新細明體, PMingLiU"`) directly followed by a label run
/// (`免除審查`, `rFonts eastAsia="標楷體"`) — replacing `"□免除審查"` with
/// `"■免除審查"` silently turned the label from 標楷體 into whatever the glyph
/// run declared (or docDefaults, if the glyph run declared nothing for
/// `eastAsia`).
///
/// che-word-mcp adds a repair layer on top of `doc.replaceText` (the
/// dependency call is unchanged): when the match/replacement have equal
/// length (the checkbox-toggle shape — one glyph swapped for another,
/// label text unchanged) and the span is a single, cleanly-removable
/// cross-run merge, the replacement text is split back onto the *original*
/// run boundaries so each surviving character keeps the `rPr` its original
/// character had. When repair isn't possible (different lengths, regex,
/// multiple cross-run matches in one paragraph, or a non-removable run
/// sitting in the middle of the span), the tool falls back to the old
/// collapsing behaviour but says so in its return string.
final class Issue190CrossRunReplaceFormatTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue190-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Same-length cross-run match: fully repaired

    /// The exact reproducer from #190: `run0 = "□"` (ascii font declared, no
    /// eastAsia), `run1 = "免除審查"` (eastAsia="標楷體"). Replacing
    /// `"□免除審查"` → `"■免除審查"` must keep "免除審查" in 標楷體.
    func testReplaceTextPreservesLabelFontAcrossCheckboxToggle() async throws {
        let (saved, message) = try await replaceAndSave(
            find: "□免除審查", replace: "■免除審查",
            documentXML: checkboxLabelDocumentXML)

        // Precise: the RUN that actually carries the visible label text must
        // declare 標楷體 — not merely "the paragraph contains that string
        // somewhere" (the pre-fix bug leaves an ORPHANED empty run still
        // declaring 標楷體 while the visible text sits in the glyph run's
        // font, which would pass a paragraph-level substring check).
        let labelRun = try XCTUnwrap(runXML(containing: "免除審查", in: saved),
                                     "no <w:r> carries the label text:\n\(saved)")
        XCTAssertTrue(labelRun.contains(#"w:eastAsia="標楷體""#),
                      "the run holding the visible label text lost its own font: \(labelRun)")
        XCTAssertFalse(saved.contains("□"), "the old glyph is still present:\n\(saved)")
        let glyphRun = try XCTUnwrap(runXML(containing: "■", in: saved),
                                     "no <w:r> carries the replaced glyph:\n\(saved)")
        XCTAssertFalse(glyphRun.contains("免除審查"),
                       "glyph and label text were merged into the same run: \(glyphRun)")
        XCTAssertFalse(message.lowercased().contains("warning"),
                       "a successfully-repaired replace should not warn: \(message)")
    }

    /// The glyph run's OWN font must also survive — repair must not merge
    /// everything onto the label's font either.
    func testReplaceTextPreservesGlyphRunFontAcrossCheckboxToggle() async throws {
        let (saved, _) = try await replaceAndSave(
            find: "□免除審查", replace: "■免除審查",
            documentXML: checkboxLabelDocumentXML)

        let glyphRun = try XCTUnwrap(runXML(containing: "■", in: saved),
                                     "the replaced glyph is missing:\n\(saved)")
        XCTAssertTrue(glyphRun.contains("新細明體"),
                      "glyph run lost its own declared font: \(glyphRun)")
    }

    // MARK: - Different-length cross-run match: warns, does not corrupt

    /// When `find`/`replace` differ in length, per-character repair is not
    /// well-defined — the tool must fall back to the (documented) collapsing
    /// behaviour and say so, rather than silently losing the label's font
    /// with zero disclosure.
    func testReplaceTextWarnsWhenLengthsDifferAcrossCrossRunMatch() async throws {
        let (saved, message) = try await replaceAndSave(
            find: "□免除審查", replace: "■已核可（免除審查）",
            documentXML: checkboxLabelDocumentXML)

        XCTAssertTrue(saved.contains("已核可"), "replacement text is missing:\n\(saved)")
        XCTAssertTrue(message.lowercased().contains("warning"),
                     "a collapsed, un-repairable cross-run replace must warn: \(message)")
    }

    // MARK: - Same-run match: untouched, no warning

    /// A match entirely within one run never loses formatting — no warning,
    /// no repair machinery involved.
    func testReplaceTextSingleRunMatchIsUnaffected() async throws {
        let (saved, message) = try await replaceAndSave(
            find: "免除審查", replace: "全委員會審查",
            documentXML: checkboxLabelDocumentXML)

        let run = try XCTUnwrap(runXML(containing: "全委員會審查", in: saved))
        XCTAssertTrue(run.contains(#"w:eastAsia="標楷體""#), run)
        XCTAssertFalse(message.lowercased().contains("warning"), message)
    }

    // MARK: - replace_text_batch carries the same repair + warning

    func testReplaceTextBatchPreservesFormatAndReportsRepair() async throws {
        let source = scratch.appendingPathComponent("source.docx")
        try Self.writePackage(documentXML: checkboxLabelDocumentXML, to: source)
        let output = scratch.appendingPathComponent("saved.docx")

        let server = await WordMCPServer()
        let docId = "t190-batch-\(UUID().uuidString)"
        let opened = await server.invokeToolForTesting(name: "open_document", arguments: [
            "doc_id": .string(docId), "path": .string(source.path),
        ])
        XCTAssertNotEqual(opened.isError, true, text(of: opened))

        let batchResult = await server.invokeToolForTesting(name: "replace_text_batch", arguments: [
            "doc_id": .string(docId),
            "replacements": .array([
                .object(["find": .string("□免除審查"), "replace": .string("■免除審查")])
            ]),
        ])
        XCTAssertNotEqual(batchResult.isError, true, text(of: batchResult))
        XCTAssertTrue(text(of: batchResult).lowercased().contains("preserved") ||
                     text(of: batchResult).contains("1 replaced"),
                     text(of: batchResult))

        let savedResult = await server.invokeToolForTesting(name: "save_document", arguments: [
            "doc_id": .string(docId), "path": .string(output.path),
        ])
        XCTAssertNotEqual(savedResult.isError, true, text(of: savedResult))

        let archive = try Archive(url: output, accessMode: .read)
        let entry = try XCTUnwrap(archive["word/document.xml"])
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        let saved = String(decoding: data, as: UTF8.self)

        let labelRun = try XCTUnwrap(runXML(containing: "免除審查", in: saved))
        XCTAssertTrue(labelRun.contains(#"w:eastAsia="標楷體""#),
                      "batch path lost the label's font: \(labelRun)")
    }

    // MARK: - Helpers

    private func replaceAndSave(find: String, replace: String, documentXML: String) async throws -> (saved: String, message: String) {
        let source = scratch.appendingPathComponent("source-\(UUID().uuidString).docx")
        let output = scratch.appendingPathComponent("saved-\(UUID().uuidString).docx")
        try Self.writePackage(documentXML: documentXML, to: source)

        let server = await WordMCPServer()
        let docId = "t190-\(UUID().uuidString)"
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

    private func text(of result: CallTool.Result) -> String {
        guard case .text(let value, _, _)? = result.content.first else { return "" }
        return value
    }

    private func paragraphXML(containing needle: String, in xml: String) -> String? {
        guard let hit = xml.range(of: needle) else { return nil }
        let before = xml[xml.startIndex..<hit.lowerBound]
        let starts = [before.range(of: "<w:p>", options: .backwards),
                      before.range(of: "<w:p ", options: .backwards)].compactMap { $0 }
        guard let open = starts.max(by: { $0.lowerBound < $1.lowerBound }),
              let close = xml.range(of: "</w:p>", range: hit.upperBound..<xml.endIndex)
        else { return nil }
        return String(xml[open.lowerBound..<close.upperBound])
    }

    /// The single `<w:r>…</w:r>` element whose `<w:t>` text contains
    /// `needle` — precise enough to tell "this run carries this text with
    /// this rPr" apart from "this rPr exists somewhere in the paragraph".
    private func runXML(containing needle: String, in xml: String) -> String? {
        guard let hit = xml.range(of: needle) else { return nil }
        let before = xml[xml.startIndex..<hit.lowerBound]
        let starts = [before.range(of: "<w:r>", options: .backwards),
                      before.range(of: "<w:r ", options: .backwards)].compactMap { $0 }
        guard let open = starts.max(by: { $0.lowerBound < $1.lowerBound }),
              let close = xml.range(of: "</w:r>", range: hit.upperBound..<xml.endIndex)
        else { return nil }
        return String(xml[open.lowerBound..<close.upperBound])
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

/// One paragraph, two runs: `run0 = "□"` (declares ascii/hAnsi/cs but no
/// eastAsia — matches the real-world REC-P-011 shape), `run1 = "免除審查"`
/// (declares eastAsia="標楷體").
private let checkboxLabelDocumentXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<w:body>
<w:p><w:r><w:rPr><w:rFonts w:ascii="新細明體, PMingLiU" w:hAnsi="新細明體, PMingLiU" w:cs="新細明體, PMingLiU"/></w:rPr><w:t>□</w:t></w:r><w:r><w:rPr><w:rFonts w:eastAsia="標楷體"/></w:rPr><w:t>免除審查</w:t></w:r></w:p>
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
