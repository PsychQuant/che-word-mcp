import XCTest
import OOXMLSwift

/// PsychQuant/che-word-mcp#63 follow-up (verify F1) — pin the v0.20.5 lib-layer
/// fix at the MCP layer. `insert_image_from_path` / `insert_paragraph` /
/// `insert_caption` `before_text` / `after_text` resolution now reaches anchor
/// text wrapped in inline `<w:sdt>` (and other typed surfaces) — closes the
/// CHANGELOG over-claim from v3.14.4.
final class Issue63InsertAnchorInlineSDTSmokeTests: XCTestCase {

    private func injectInlineSDTAnchorDocx() throws -> URL {
        var base = WordDocument()
        base.body.children.append(.paragraph(Paragraph(runs: [Run(text: "x")])))
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("anchor63_smoke_base_\(UUID().uuidString).docx")
        try DocxWriter.write(base, to: baseURL)
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("anchor63_smoke_inj_\(UUID().uuidString).docx")
        try FileManager.default.copyItem(at: baseURL, to: outURL)

        let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("anchor63_smoke_work_\(UUID().uuidString)")
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

    func testInsertParagraphAfterTextInsideInlineSDT() throws {
        let url = try injectInlineSDTAnchorDocx()
        defer { try? FileManager.default.removeItem(at: url) }
        var doc = try DocxReader.read(from: url)

        XCTAssertNoThrow(try doc.insertParagraph(
            Paragraph(runs: [Run(text: "MARKER")]),
            at: .afterText("[tab:foo]", instance: 1)
        ), "afterText anchor inside inline <w:sdt> should resolve")
    }

    func testInsertImageAfterTextInsideInlineSDT() throws {
        let url = try injectInlineSDTAnchorDocx()
        defer { try? FileManager.default.removeItem(at: url) }
        var doc = try DocxReader.read(from: url)

        // Tiny 1x1 PNG.
        let pngData = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
            0x42, 0x60, 0x82
        ])
        let pngURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("anchor63_smoke_pixel_\(UUID().uuidString).png")
        try pngData.write(to: pngURL)
        defer { try? FileManager.default.removeItem(at: pngURL) }

        XCTAssertNoThrow(try doc.insertImage(
            path: pngURL.path, widthPx: 100, heightPx: 100,
            at: .afterText("[tab:foo]", instance: 1)
        ), "insertImage after_text anchor inside inline <w:sdt> should resolve")
    }
}
