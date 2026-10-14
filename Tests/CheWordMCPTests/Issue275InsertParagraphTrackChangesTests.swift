import XCTest
import MCP
@testable import CheWordMCP
@testable import OOXMLSwift

/// Regression tests for [PsychQuant/che-word-mcp#275](https://github.com/PsychQuant/che-word-mcp/issues/275).
///
/// Before this fix `insert_paragraph` wrote a plain, untracked paragraph even
/// with track changes on (no `<w:ins>`, no author), and built it from scratch
/// so it did not match the surrounding body text (no first-line indent).
/// After this fix, with track changes on it writes a tracked insertion
/// (`<w:ins>` around the runs + `<w:ins/>` on the paragraph mark, session
/// author); with an `after_text` / `before_text` anchor and no `style` it
/// copies the anchor paragraph's formatting; `inherit_format: false` opts out.
final class Issue275InsertParagraphTrackChangesTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue275-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// "Alpha paragraph." carries a first-line indent and a coloured
    /// paragraph mark; "Beta paragraph." is plain.
    private func makeFixture() throws -> String {
        let staging = tempDir.appendingPathComponent("staging")
        let files: [(String, String)] = [
            ("[Content_Types].xml", """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
                <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
                <Default Extension="xml" ContentType="application/xml"/>\
                <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
                </Types>
                """),
            ("_rels/.rels", """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
                </Relationships>
                """),
            ("word/document.xml", """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\
                <w:p><w:pPr><w:ind w:firstLine="720"/><w:rPr><w:color w:val="1F3864"/></w:rPr></w:pPr><w:r><w:t>Alpha paragraph.</w:t></w:r></w:p>\
                <w:p><w:r><w:t>Beta paragraph.</w:t></w:r></w:p>\
                <w:sectPr/></w:body></w:document>
                """),
        ]
        for (relPath, content) in files {
            let url = staging.appendingPathComponent(relPath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        let docx = tempDir.appendingPathComponent("fixture-\(UUID().uuidString).docx")
        try ZipHelper.zip(staging, to: docx)
        return docx.path
    }

    private func unzipDocumentXML(at docxPath: String) throws -> String {
        let process = Process()
        process.launchPath = "/usr/bin/unzip"
        process.arguments = ["-p", docxPath, "word/document.xml"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func paragraph(containing marker: String, in xml: String) -> String? {
        let pattern = try! NSRegularExpression(pattern: "<w:p[ >].*?</w:p>", options: [.dotMatchesLineSeparators])
        let ns = xml as NSString
        for match in pattern.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            let p = ns.substring(with: match.range)
            if p.contains(marker) { return p }
        }
        return nil
    }

    private func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { content -> String? in
            if case .text(let t, _, _) = content { return t }
            return nil
        }.joined(separator: " ")
    }

    /// Opens the fixture, runs `insert_paragraph` with `extra` arguments,
    /// saves, and returns the new paragraph's XML.
    private func insertAndSave(trackChanges: Bool, extra: [String: Value] = [:]) async throws -> String {
        let path = try makeFixture()
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: [
            "path": .string(path), "doc_id": .string("d"),
            "track_changes": .bool(trackChanges), "autosave_every": .int(0),
        ])
        if trackChanges {
            _ = await server.invokeToolForTesting(name: "enable_track_changes", arguments: [
                "doc_id": .string("d"), "author": .string("Editor B"),
            ])
        }
        var args: [String: Value] = [
            "doc_id": .string("d"), "after_text": .string("Alpha paragraph."), "text": .string("New paragraph."),
        ]
        for (k, v) in extra { args[k] = v }
        let r = await server.invokeToolForTesting(name: "insert_paragraph", arguments: args)
        XCTAssertNotEqual(r.isError, true, text(r))
        _ = await server.invokeToolForTesting(name: "save_document", arguments: ["doc_id": .string("d")])
        return try XCTUnwrap(paragraph(containing: "New paragraph.", in: try unzipDocumentXML(at: path)))
    }

    func testTrackedInsertionWrapsTheRunsAndTheParagraphMarkWithTheSessionAuthor() async throws {
        let p = try await insertAndSave(trackChanges: true)
        XCTAssertTrue(p.range(of: "<w:ins w:id=\"\\d+\" w:author=\"Editor B\" w:date=\"[^\"]+\"><w:r>",
                              options: .regularExpression) != nil, "runs must be wrapped in <w:ins> — got: \(p)")
        XCTAssertTrue(p.range(of: "<w:pPr>.*<w:rPr><w:ins w:id=\"\\d+\" w:author=\"Editor B\"",
                              options: .regularExpression) != nil, "paragraph mark must be marked inserted — got: \(p)")
    }

    func testUntrackedInsertionCarriesNoRevisionMarkup() async throws {
        let p = try await insertAndSave(trackChanges: false)
        XCTAssertFalse(p.contains("<w:ins"), "got: \(p)")
    }

    func testAnchorFormattingIsInherited() async throws {
        let p = try await insertAndSave(trackChanges: true)
        XCTAssertTrue(p.contains("w:firstLine=\"720\""), "anchor first-line indent must be inherited — got: \(p)")
        XCTAssertTrue(p.contains("w:val=\"1F3864\""), "anchor paragraph-mark colour must carry to the new run — got: \(p)")
    }

    func testInheritFormatFalseKeepsThePlainParagraph() async throws {
        let p = try await insertAndSave(trackChanges: false, extra: ["inherit_format": .bool(false)])
        XCTAssertFalse(p.contains("w:firstLine"), "got: \(p)")
        XCTAssertFalse(p.contains("1F3864"), "got: \(p)")
    }

    func testExplicitStyleIsAppliedInsteadOfInheritance() async throws {
        let p = try await insertAndSave(trackChanges: false, extra: ["style": .string("Heading1")])
        XCTAssertTrue(p.contains("<w:pStyle w:val=\"Heading1\"/>"), "got: \(p)")
        XCTAssertFalse(p.contains("w:firstLine"), "an explicit style must not pick up the anchor's direct formatting — got: \(p)")
    }
}
