import XCTest
import OOXMLSwift

/// PsychQuant/che-word-mcp#63 — smoke test pinning the lib-layer fix at the
/// MCP layer. Builds a minimal docx whose document.xml wraps `[tab:foo]` in an
/// inline `<w:sdt>` (same convention pandoc / Quarto / LaTeX→docx use for
/// cross-ref placeholders), then runs `WordDocument.replaceText` and asserts:
///
/// 1. Replacement count is 1 (pre-fix: 0).
/// 2. Round-trip preserves the SDT wrapper (sdt.tag == "ref", structural
///    survival).
///
/// Mirrors `OOXMLSwiftTests.Issue63InlineSDTReplaceTests` — duplicating the
/// gate here ensures che-word-mcp dep-bump regressions surface in CI even if
/// the lib version is held back.
final class Issue63ReplaceTextInlineSDTSmokeTests: XCTestCase {

    private func injectInlineSDTDocx() throws -> URL {
        var base = WordDocument()
        base.body.children.append(.paragraph(Paragraph(runs: [Run(text: "x")])))
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue63_smoke_base_\(UUID().uuidString).docx")
        try DocxWriter.write(base, to: baseURL)
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue63_smoke_inj_\(UUID().uuidString).docx")
        try FileManager.default.copyItem(at: baseURL, to: outURL)

        let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue63_smoke_work_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let docXMLDir = workDir.appendingPathComponent("word")
        try FileManager.default.createDirectory(at: docXMLDir, withIntermediateDirectories: true)

        let docXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p>
              <w:r><w:t xml:space="preserve">prefix </w:t></w:r>
              <w:sdt>
                <w:sdtPr><w:tag w:val="ref"/><w:alias w:val="cross-ref"/></w:sdtPr>
                <w:sdtContent>
                  <w:r><w:t>[tab:foo]</w:t></w:r>
                </w:sdtContent>
              </w:sdt>
              <w:r><w:t xml:space="preserve"> further description follows</w:t></w:r>
            </w:p>
          </w:body>
        </w:document>
        """
        try docXML.write(to: docXMLDir.appendingPathComponent("document.xml"),
                         atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.currentDirectoryURL = workDir
        proc.arguments = [outURL.path, "word/document.xml"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()

        return outURL
    }

    func testReplaceTextMatchesInsideInlineSDT() throws {
        let url = try injectInlineSDTDocx()
        defer { try? FileManager.default.removeItem(at: url) }

        var doc = try DocxReader.read(from: url)
        let n = try doc.replaceText(find: "[tab:foo]", with: "REPLACED")
        XCTAssertEqual(n, 1, "replace_text should reach text inside inline <w:sdt>")
    }

    func testReplaceTextRoundTripPreservesInlineSDTWrapper() throws {
        let url = try injectInlineSDTDocx()
        defer { try? FileManager.default.removeItem(at: url) }

        var doc = try DocxReader.read(from: url)
        _ = try doc.replaceText(find: "[tab:foo]", with: "REPLACED")

        let savedURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue63_smoke_rt_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: savedURL)
        defer { try? FileManager.default.removeItem(at: savedURL) }

        let reread = try DocxReader.read(from: savedURL)
        guard case .paragraph(let p) = reread.body.children[0] else {
            XCTFail("expected paragraph"); return
        }
        XCTAssertEqual(p.contentControls.count, 1,
                       "SDT wrapper survives save→reload after replace")
        XCTAssertEqual(p.contentControls.first?.sdt.tag, "ref",
                       "SDT tag preserved")
        XCTAssertTrue(p.contentControls.first?.content.contains("REPLACED") == true,
                      "Replaced text written into SDT inner content")
    }
}
