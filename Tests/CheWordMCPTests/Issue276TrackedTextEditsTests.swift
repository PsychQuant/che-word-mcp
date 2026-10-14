import XCTest
import MCP
@testable import CheWordMCP
@testable import OOXMLSwift

/// Regression tests for [PsychQuant/che-word-mcp#276](https://github.com/PsychQuant/che-word-mcp/issues/276), Stage 1,
/// through the MCP tools: `insert_text_as_revision` lands in place and is
/// tracked (case 1); `replace_text` under session tracking writes `<w:del>` +
/// `<w:ins>` (case 2); an edit inside another author's insertion is refused
/// instead of rewriting their text (case 3); every returned revision id is in
/// the saved file (Expected 5).
final class Issue276TrackedTextEditsTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue276-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// The issue's paragraph, with and without Reviewer A's insertion.
    private static func body(withInsertion: Bool) -> String {
        let table = withInsertion
            ? "<w:ins w:id=\"1\" w:author=\"Reviewer A\" w:date=\"2026-10-01T00:00:00Z\"><w:r><w:t>Table 1, 2, 3, and 4 list the sample sizes</w:t></w:r></w:ins>"
            : "<w:r><w:t>Table 1, 2, 3, and 4 list the sample sizes</w:t></w:r>"
        return "<w:p><w:r><w:t xml:space=\"preserve\">Data came from Alphaland, Betaland, and Gammaland. </w:t></w:r>\(table)<w:r><w:t>.</w:t></w:r></w:p>"
    }

    private func makeFixture(withInsertion: Bool) throws -> String {
        let staging = tempDir.appendingPathComponent("staging-\(UUID().uuidString)")
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
                \(Self.body(withInsertion: withInsertion))<w:sectPr/></w:body></w:document>
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

    private func documentXML(at path: String) throws -> String {
        let process = Process()
        process.launchPath = "/usr/bin/unzip"
        process.arguments = ["-p", path, "word/document.xml"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { content -> String? in
            if case .text(let t, _, _) = content { return t }
            return nil
        }.joined(separator: " ")
    }

    /// Opens `path`; with `tracked`, opts the session into track changes as
    /// "CHE CHENG" (the issue's repro).
    private func session(_ path: String, tracked: Bool) async -> WordMCPServer {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: [
            "path": .string(path), "doc_id": .string("d"),
            "track_changes": .bool(tracked), "autosave_every": .int(0),
        ])
        if tracked {
            _ = await server.invokeToolForTesting(name: "enable_track_changes", arguments: [
                "doc_id": .string("d"), "author": .string("CHE CHENG"),
            ])
        }
        return server
    }

    private func call(_ server: WordMCPServer, _ name: String, _ args: [String: Value] = [:]) async -> CallTool.Result {
        var a = args
        a["doc_id"] = .string("d")
        return await server.invokeToolForTesting(name: name, arguments: a)
    }

    private func matches(_ xml: String, _ pattern: String) -> Bool {
        xml.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - Case 1

    func testInsertTextAsRevisionLandsInPlaceAndIsTracked() async throws {
        let path = try makeFixture(withInsertion: false)
        let server = await session(path, tracked: true)
        let r = await call(server, "insert_text_as_revision", [
            "paragraph_index": .int(0), "position": .int(15), "text": .string("INSERTED "),
        ])
        XCTAssertNotEqual(r.isError, true, text(r))
        _ = await call(server, "save_document")
        let xml = try documentXML(at: path)
        XCTAssertTrue(matches(xml, #"Data came from </w:t></w:r><w:ins w:id="\d+" w:author="CHE CHENG"[^>]*><w:r><w:t[^>]*>INSERTED </w:t></w:r></w:ins><w:r><w:t[^>]*>Alphaland"#),
                      "got: \(xml)")
    }

    // MARK: - Case 2

    func testReplaceTextUnderSessionTrackingWritesDeletionAndInsertion() async throws {
        let path = try makeFixture(withInsertion: false)
        let server = await session(path, tracked: true)
        let r = await call(server, "replace_text", ["find": .string("Alphaland"), "replace": .string("Alpha")])
        XCTAssertNotEqual(r.isError, true, text(r))
        XCTAssertTrue(text(r).contains("tracked"), "got: \(text(r))")
        _ = await call(server, "save_document")
        let xml = try documentXML(at: path)
        XCTAssertTrue(matches(xml, #"<w:del [^>]*w:author="CHE CHENG"[^>]*><w:r><w:delText[^>]*>Alphaland</w:delText></w:r></w:del><w:ins [^>]*w:author="CHE CHENG"[^>]*><w:r><w:t[^>]*>Alpha</w:t></w:r></w:ins>"#),
                      "got: \(xml)")
    }

    func testReplaceTextWithoutSessionOptInIsUnchanged() async throws {
        let path = try makeFixture(withInsertion: false)
        let server = await session(path, tracked: false)
        _ = await call(server, "replace_text", ["find": .string("Alphaland"), "replace": .string("Alpha")])
        _ = await call(server, "save_document")
        let xml = try documentXML(at: path)
        XCTAssertTrue(xml.contains("Data came from Alpha, Betaland"), "got: \(xml)")
        XCTAssertFalse(xml.contains("<w:del"), "got: \(xml)")
    }

    func testRegexUnderSessionTrackingIsRefused() async throws {
        let path = try makeFixture(withInsertion: false)
        let server = await session(path, tracked: true)
        let r = await call(server, "replace_text", [
            "find": .string("Alpha.*?,"), "replace": .string("X,"), "regex": .bool(true),
        ])
        XCTAssertEqual(r.isError, true, text(r))
    }

    func testReplaceTextBatchUnderSessionTrackingIsTracked() async throws {
        let path = try makeFixture(withInsertion: false)
        let server = await session(path, tracked: true)
        let r = await call(server, "replace_text_batch", ["replacements": .array([
            .object(["find": .string("Alphaland"), "replace": .string("Alpha")]),
            .object(["find": .string("Betaland"), "replace": .string("Beta")]),
        ])])
        XCTAssertNotEqual(r.isError, true, text(r))
        _ = await call(server, "save_document")
        let xml = try documentXML(at: path)
        for old in ["Alphaland", "Betaland"] {
            XCTAssertTrue(matches(xml, "<w:delText[^>]*>\(old)</w:delText>"), "\(old) must be a tracked deletion — got: \(xml)")
        }
    }

    // MARK: - Case 3 (Stage 1: refuse instead of rewriting another author's text)

    func testReplaceInsideAnotherAuthorsInsertionIsRefusedAndNothingChanges() async throws {
        let path = try makeFixture(withInsertion: true)
        let server = await session(path, tracked: true)
        let r = await call(server, "replace_text", [
            "find": .string("Table 1, 2, 3, and 4"), "replace": .string("Tables 1–4"),
        ])
        XCTAssertEqual(r.isError, true, "must refuse — got: \(text(r))")
        _ = await call(server, "save_document")
        let xml = try documentXML(at: path)
        XCTAssertTrue(xml.contains("Table 1, 2, 3, and 4 list the sample sizes"), "Reviewer A's text must be untouched — got: \(xml)")
        XCTAssertFalse(xml.contains("Tables 1–4"), "got: \(xml)")
    }

    // MARK: - Expected 5

    func testEveryReturnedRevisionIdIsInTheSavedFile() async throws {
        let path = try makeFixture(withInsertion: false)
        let first = await session(path, tracked: true)
        let ins = text(await call(first, "insert_text_as_revision", [
            "paragraph_index": .int(0), "position": .int(0), "text": .string("NEW "),
        ]))
        let rep = text(await call(first, "replace_text", ["find": .string("Gammaland"), "replace": .string("Gamma")]))
        XCTAssertTrue(rep.contains("revision ids"), "replace_text must report its revision ids — got: \(rep)")
        _ = await call(first, "save_document")
        _ = await call(first, "close_document")

        let numbers = { (s: String) -> [Int] in
            let re = try! NSRegularExpression(pattern: "\\d+")
            return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { Int(s[$0])! } }
        }
        let returned = Set([numbers(ins).last!] + numbers(rep).dropFirst())   // "Replaced 1 occurrence(s) … (revision ids a, b)"

        let second = await session(path, tracked: true)
        let listed = text(await call(second, "get_revisions"))
        for id in returned {
            XCTAssertTrue(listed.contains("[\(id)]"), "revision \(id) missing after reopen — got: \(listed)")
        }
    }
}
