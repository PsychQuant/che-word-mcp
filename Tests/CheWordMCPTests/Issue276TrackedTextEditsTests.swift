import XCTest
import MCP
@testable import CheWordMCP
@testable import OOXMLSwift

/// Regression tests for [PsychQuant/che-word-mcp#276](https://github.com/PsychQuant/che-word-mcp/issues/276), Stage 1,
/// through the MCP tools: `insert_text_as_revision` lands in place and is
/// tracked (case 1); `replace_text` under session tracking refuses (case 2 —
/// tracked replacement was withdrawn from stage 1, #292); an edit inside
/// another author's insertion is refused instead of rewriting their text
/// (case 3); every returned revision id is in the saved file (Expected 5).
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

    /// Tracked replacement was taken out of stage 1 (#292): under session
    /// tracking replace_text refuses and points to the revision tools —
    /// never an untracked edit.
    func testReplaceTextUnderSessionTrackingIsRefused() async throws {
        let path = try makeFixture(withInsertion: false)
        let server = await session(path, tracked: true)
        let r = await call(server, "replace_text", ["find": .string("Alphaland"), "replace": .string("Alpha")])
        XCTAssertEqual(r.isError, true, text(r))
        XCTAssertTrue(text(r).contains("delete_text_as_revision") && text(r).contains("#292"), "got: \(text(r))")
        _ = await call(server, "save_document")
        XCTAssertTrue(try documentXML(at: path).contains("Data came from Alphaland, Betaland"))
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

    func testReplaceTextBatchUnderSessionTrackingIsRefused() async throws {
        let path = try makeFixture(withInsertion: false)
        let server = await session(path, tracked: true)
        let r = await call(server, "replace_text_batch", ["replacements": .array([
            .object(["find": .string("Alphaland"), "replace": .string("Alpha")]),
            .object(["find": .string("Betaland"), "replace": .string("Beta")]),
        ])])
        XCTAssertEqual(r.isError, true, text(r))
        _ = await call(server, "save_document")
        XCTAssertTrue(try documentXML(at: path).contains("Data came from Alphaland, Betaland"))
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
        let del = text(await call(first, "delete_text_as_revision", [
            "paragraph_index": .int(0), "start": .int(4), "end": .int(9),
        ]))
        _ = await call(first, "save_document")
        _ = await call(first, "close_document")

        let numbers = { (s: String) -> [Int] in
            let re = try! NSRegularExpression(pattern: "\\d+")
            return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { Int(s[$0])! } }
        }
        let returned = Set([numbers(ins).last!, numbers(del).last!])

        let second = await session(path, tracked: true)
        let listed = text(await call(second, "get_revisions"))
        for id in returned {
            XCTAssertTrue(listed.contains("[\(id)]"), "revision \(id) missing after reopen — got: \(listed)")
        }
    }

    // MARK: - Stage 1 round 2 (verify findings)

    /// The pre-check names the paragraph length callers read: text deleted
    /// in the session no longer counts.
    func testDeletePreCheckUsesTheVisibleLength() async throws {
        let path = try makeFixture(withInsertion: false)
        let server = await session(path, tracked: true)
        _ = await call(server, "delete_text_as_revision", ["paragraph_index": .int(0), "start": .int(0), "end": .int(5)])
        let visible = "Data came from Alphaland, Betaland, and Gammaland. Table 1, 2, 3, and 4 list the sample sizes.".count - 5
        let r = await call(server, "delete_text_as_revision", [
            "paragraph_index": .int(0), "start": .int(0), "end": .int(visible + 1),
        ])
        XCTAssertEqual(r.isError, true, text(r))
        XCTAssertTrue(text(r).contains("paragraph length \(visible)"), "got: \(text(r))")
    }

    func testInsertTextRefusesCharactersXMLCannotStore() async throws {
        let path = try makeFixture(withInsertion: false)
        let server = await session(path, tracked: true)
        let r = await call(server, "insert_text_as_revision", [
            "paragraph_index": .int(0), "position": .int(0), "text": .string("Bad\u{01}"),
        ])
        XCTAssertEqual(r.isError, true, text(r))
        let a = await call(server, "delete_text_as_revision", [
            "paragraph_index": .int(0), "start": .int(0), "end": .int(4), "author": .string("Bad\u{FFFF}"),
        ])
        XCTAssertEqual(a.isError, true, text(a))
    }

    /// Refusal paths reach the caller as errors and change nothing.
    func testInsertInsideAnotherAuthorsInsertionIsRefusedThroughMCP() async throws {
        let path = try makeFixture(withInsertion: true)
        let server = await session(path, tracked: true)
        let r = await call(server, "insert_text_as_revision", [
            "paragraph_index": .int(0), "position": .int(60), "text": .string("X"),
        ])
        XCTAssertEqual(r.isError, true, text(r))
        XCTAssertTrue(text(r).contains("#293"), "got: \(text(r))")
        let d = await call(server, "delete_text_as_revision", [
            "paragraph_index": .int(0), "start": .int(51), "end": .int(71),
        ])
        XCTAssertEqual(d.isError, true, text(d))
        _ = await call(server, "save_document")
        XCTAssertFalse(try documentXML(at: path).contains("CHE CHENG"))
    }
}
