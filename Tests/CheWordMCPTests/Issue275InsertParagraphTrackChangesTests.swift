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

    private static let defaultBody = """
        <w:p><w:pPr><w:ind w:firstLine="720"/><w:rPr><w:color w:val="1F3864"/></w:rPr></w:pPr><w:r><w:t>Alpha paragraph.</w:t></w:r></w:p>\
        <w:p><w:r><w:t>Beta paragraph.</w:t></w:r></w:p>
        """

    /// Heading 1 is followed by Normal (`w:next`), as in Word's defaults.
    private static let headingStyles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>\
        <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/>\
        <w:next w:val="Normal"/><w:pPr><w:keepNext/><w:outlineLvl w:val="0"/></w:pPr></w:style>\
        </w:styles>
        """

    /// Default body: "Alpha paragraph." carries a first-line indent and a
    /// coloured paragraph mark; "Beta paragraph." is plain. `settingsTrackChanges`
    /// puts the document itself in review mode (the setting ooxml-swift reads).
    private func makeFixture(body: String = defaultBody, styles: String? = nil,
                             settingsTrackChanges: Bool = false) throws -> String {
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
                \(body)\
                <w:sectPr/></w:body></w:document>
                """),
        ]
        var parts = files
        if let styles { parts.append(("word/styles.xml", styles)) }
        if settingsTrackChanges {
            parts.append(("word/settings.xml", """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:trackRevisions/><w:trackChanges/></w:settings>
                """))
        }
        for (relPath, content) in parts {
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
    private func insertAndSave(trackChanges: Bool, extra: [String: Value] = [:],
                               body: String = defaultBody, styles: String? = nil,
                               anchor: String = "Alpha paragraph.") async throws -> String {
        let path = try makeFixture(body: body, styles: styles)
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
            "doc_id": .string("d"), "after_text": .string(anchor), "text": .string("New paragraph."),
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
        XCTAssertTrue(p.range(of: "<w:r><w:rPr>[^<]*(<[^>]+>)*?<w:color w:val=\"1F3864\"", options: .regularExpression) != nil,
                      "anchor paragraph-mark colour must carry to the new RUN, not only the mark — got: \(p)")
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

    // MARK: - Verify round 1 (round 2 of #275)

    private func session(_ path: String, trackChanges: Bool, enableAuthor: String? = nil) async -> WordMCPServer {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: [
            "path": .string(path), "doc_id": .string("d"),
            "track_changes": .bool(trackChanges), "autosave_every": .int(0),
        ])
        if let enableAuthor {
            _ = await server.invokeToolForTesting(name: "enable_track_changes", arguments: [
                "doc_id": .string("d"), "author": .string(enableAuthor),
            ])
        }
        return server
    }

    private func call(_ server: WordMCPServer, _ name: String, _ args: [String: Value]) async -> CallTool.Result {
        var a = args; a["doc_id"] = .string("d")
        return await server.invokeToolForTesting(name: name, arguments: a)
    }

    /// Tracking follows the session opt-in, like every other tracked tool —
    /// not the file's own review-mode setting (which produced "Unknown"
    /// revisions while the session reported track changes off).
    func testDocumentInReviewModeButSessionNotOptedInStaysUntracked() async throws {
        let path = try makeFixture(settingsTrackChanges: true)
        let server = await session(path, trackChanges: false)
        _ = await call(server, "insert_paragraph", ["after_text": .string("Alpha paragraph."), "text": .string("New paragraph.")])
        _ = await call(server, "save_document", [:])
        let p = try XCTUnwrap(paragraph(containing: "New paragraph.", in: try unzipDocumentXML(at: path)))
        XCTAssertFalse(p.contains("<w:ins"), "got: \(p)")
    }

    /// Opting in with track_changes: true on a document already in review
    /// mode must not leave the author as "Unknown".
    func testOptInOnADocumentAlreadyInReviewModeUsesTheDefaultAuthor() async throws {
        let path = try makeFixture(settingsTrackChanges: true)
        let server = await session(path, trackChanges: true)
        _ = await call(server, "insert_paragraph", ["after_text": .string("Alpha paragraph."), "text": .string("New paragraph.")])
        _ = await call(server, "save_document", [:])
        let p = try XCTUnwrap(paragraph(containing: "New paragraph.", in: try unzipDocumentXML(at: path)))
        XCTAssertTrue(p.contains("<w:ins"), "got: \(p)")
        XCTAssertFalse(p.contains("w:author=\"Unknown\""), "got: \(p)")
    }

    func testEnableTrackChangesInTheSessionTracksAndTheResultNamesTheRevision() async throws {
        let path = try makeFixture()
        let server = await session(path, trackChanges: false, enableAuthor: "Editor B")
        let r = await call(server, "insert_paragraph", ["after_text": .string("Alpha paragraph."), "text": .string("New paragraph.")])
        XCTAssertTrue(text(r).contains("revision id"), "result must name the revision — got: \(text(r))")
        _ = await call(server, "save_document", [:])
        let p = try XCTUnwrap(paragraph(containing: "New paragraph.", in: try unzipDocumentXML(at: path)))
        XCTAssertTrue(p.contains("w:author=\"Editor B\""), "got: \(p)")
    }

    func testAuthorAndDateArgumentsOverrideTheSessionAuthor() async throws {
        let p = try await insertAndSave(trackChanges: true, extra: [
            "author": .string("Reviewer X"), "date": .string("2026-10-01T00:00:00Z"),
        ])
        XCTAssertTrue(p.contains("w:author=\"Reviewer X\" w:date=\"2026-10-01T00:00:00Z\""), "got: \(p)")
    }

    /// Word's Enter at the end of a heading starts a paragraph in the style's
    /// `w:next` (Heading 1 → Normal), without the heading's direct formatting.
    func testAfterTextUnderAHeadingUsesTheNextStyle() async throws {
        let body = """
            <w:p><w:pPr><w:pStyle w:val="Heading1"/><w:ind w:left="360"/></w:pPr><w:r><w:t>Methods</w:t></w:r></w:p>\
            <w:p><w:r><w:t>Body.</w:t></w:r></w:p>
            """
        let p = try await insertAndSave(trackChanges: false, body: body, styles: Self.headingStyles, anchor: "Methods")
        XCTAssertFalse(p.contains("Heading1"), "a paragraph after a heading is body text — got: \(p)")
        XCTAssertFalse(p.contains("w:left=\"360\""), "the heading's direct formatting does not carry — got: \(p)")
    }

    /// Enter at the start of a paragraph keeps its style for the new one.
    func testBeforeTextKeepsTheAnchorStyle() async throws {
        let body = """
            <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Methods</w:t></w:r></w:p>
            """
        let path = try makeFixture(body: body, styles: Self.headingStyles)
        let server = await session(path, trackChanges: false)
        _ = await call(server, "insert_paragraph", ["before_text": .string("Methods"), "text": .string("New paragraph.")])
        _ = await call(server, "save_document", [:])
        let p = try XCTUnwrap(paragraph(containing: "New paragraph.", in: try unzipDocumentXML(at: path)))
        XCTAssertTrue(p.contains("<w:pStyle w:val=\"Heading1\"/>"), "got: \(p)")
    }

    func testHiddenTextAndPageBreakBeforeAreNotInherited() async throws {
        let body = """
            <w:p><w:pPr><w:pageBreakBefore/><w:ind w:firstLine="720"/><w:rPr><w:vanish/></w:rPr></w:pPr><w:r><w:t>Alpha paragraph.</w:t></w:r></w:p>
            """
        let p = try await insertAndSave(trackChanges: false, body: body)
        XCTAssertTrue(p.contains("w:firstLine=\"720\""), "ordinary formatting still carries — got: \(p)")
        XCTAssertFalse(p.contains("pageBreakBefore"), "got: \(p)")
        XCTAssertFalse(p.contains("vanish"), "inserted text must not be hidden — got: \(p)")
    }

    /// Without paragraph-mark formatting, the new text takes the formatting
    /// at the insertion point: the anchor's last run (after) / first run (before).
    func testRunFormattingFallsBackToTheAdjacentRun() async throws {
        let body = """
            <w:p><w:r><w:rPr><w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman"/><w:sz w:val="24"/></w:rPr><w:t>Alpha paragraph.</w:t></w:r></w:p>
            """
        let p = try await insertAndSave(trackChanges: false, body: body)
        XCTAssertTrue(p.range(of: "<w:r><w:rPr>.*w:ascii=\"Times New Roman\".*<w:sz w:val=\"24\"/>.*</w:rPr><w:t>New paragraph.",
                              options: .regularExpression) != nil, "got: \(p)")
    }

    func testEveryAnchorKindIsTracked() async throws {
        for args: [String: Value] in [
            ["before_text": .string("Beta paragraph.")],
            ["index": .int(1)],
            [:],   // append
        ] {
            let path = try makeFixture()
            let server = await session(path, trackChanges: true, enableAuthor: "Editor B")
            var a = args; a["text"] = .string("New paragraph.")
            _ = await call(server, "insert_paragraph", a)
            _ = await call(server, "save_document", [:])
            let p = try XCTUnwrap(paragraph(containing: "New paragraph.", in: try unzipDocumentXML(at: path)), "\(args)")
            XCTAssertTrue(p.contains("<w:ins") && p.contains("w:author=\"Editor B\""), "\(args) — got: \(p)")
        }
    }

    /// The round trip the issue is about: insert tracked, save, reopen in a
    /// later session, reject — the paragraph is gone; two inserts, reject the
    /// first — the second stays and nothing else changes.
    func testRejectThroughMCPAfterReopenAndAfterASecondInsert() async throws {
        let path = try makeFixture()
        let first = await session(path, trackChanges: true, enableAuthor: "Editor B")
        _ = await call(first, "insert_paragraph", ["after_text": .string("Beta paragraph."), "text": .string("One.")])
        _ = await call(first, "insert_paragraph", ["after_text": .string("Alpha paragraph."), "text": .string("Two.")])
        _ = await call(first, "save_document", [:])
        _ = await call(first, "close_document", [:])

        let second = await session(path, trackChanges: true, enableAuthor: "Editor B")
        let revs = text(await call(second, "get_revisions", [:]))
        let ids = try NSRegularExpression(pattern: "\\[(\\d+)\\]").matches(in: revs, range: NSRange(revs.startIndex..., in: revs))
            .compactMap { Range($0.range(at: 1), in: revs).map { Int(revs[$0])! } }
        XCTAssertEqual(ids.count, 2, "both insertions must be read back — got: \(revs)")
        let rejected = ids.min()!
        _ = await call(second, "reject_revision", ["revision_id": .int(rejected)])
        _ = await call(second, "save_document", [:])
        let xml = try unzipDocumentXML(at: path)
        XCTAssertNil(paragraph(containing: "One.", in: xml), "got: \(xml)")
        // The paragraph itself is gone, not left empty with a stale mark.
        let paragraphs = try NSRegularExpression(pattern: "<w:p[ >]").numberOfMatches(in: xml, range: NSRange(xml.startIndex..., in: xml))
        XCTAssertEqual(paragraphs, 3, "Alpha, Two, Beta — got: \(xml)")
        XCTAssertFalse(xml.contains("w:id=\"\(rejected)\""), "no markup of the rejected revision may remain — got: \(xml)")
        XCTAssertNotNil(paragraph(containing: "Two.", in: xml))
        XCTAssertNotNil(paragraph(containing: "Alpha paragraph.", in: xml))
        XCTAssertNotNil(paragraph(containing: "Beta paragraph.", in: xml))
    }

    // MARK: - Verify round 2 (round 3 of #275)

    /// revert_to_disk / reload_from_disk swap in a fresh read; the session's
    /// opt-in must carry over, or the next insert is silently untracked.
    func testSessionOptInSurvivesRevertToDisk() async throws {
        let path = try makeFixture()
        let server = await session(path, trackChanges: false, enableAuthor: "Editor B")
        _ = await call(server, "revert_to_disk", [:])
        let r = await call(server, "insert_paragraph", ["after_text": .string("Alpha paragraph."), "text": .string("After revert.")])
        XCTAssertTrue(text(r).contains("revision id"), "got: \(text(r))")
        _ = await call(server, "save_document", [:])
        let p = try XCTUnwrap(paragraph(containing: "After revert.", in: try unzipDocumentXML(at: path)))
        XCTAssertTrue(p.contains("w:author=\"Editor B\""), "got: \(p)")
    }

    /// An anchor whose paragraph-mark rPr holds only a revision marker (any
    /// tracked paragraph) has no mark formatting: fall back to the run.
    func testMarkerOnlyMarkRPrFallsBackToTheAdjacentRun() async throws {
        let body = """
            <w:p><w:pPr><w:rPr><w:ins w:id="5" w:author="A" w:date="2026-10-01T00:00:00Z"/></w:rPr></w:pPr>\
            <w:ins w:id="5" w:author="A" w:date="2026-10-01T00:00:00Z"><w:r><w:rPr><w:sz w:val="28"/></w:rPr><w:t>Alpha paragraph.</w:t></w:r></w:ins></w:p>
            """
        let p = try await insertAndSave(trackChanges: false, body: body)
        XCTAssertTrue(p.range(of: "<w:r><w:rPr>.*<w:sz w:val=\"28\"/>.*</w:rPr><w:t>New paragraph.", options: .regularExpression) != nil,
                      "got: \(p)")
    }

    func testAuthorWithControlCharactersIsRefused() async throws {
        let path = try makeFixture()
        let server = await session(path, trackChanges: true, enableAuthor: "Editor B")
        let r = await call(server, "insert_paragraph", [
            "after_text": .string("Alpha paragraph."), "text": .string("X."), "author": .string("Bad\u{01}Name"),
        ])
        XCTAssertEqual(r.isError, true, text(r))
    }

    func testNonStringDateIsRefusedAndDateIsIgnoredWhenUntracked() async throws {
        let path = try makeFixture()
        let tracked = await session(path, trackChanges: true, enableAuthor: "Editor B")
        let bad = await call(tracked, "insert_paragraph", [
            "after_text": .string("Alpha paragraph."), "text": .string("X."), "date": .int(5),
        ])
        XCTAssertEqual(bad.isError, true, text(bad))

        let path2 = try makeFixture()
        let untracked = await session(path2, trackChanges: false)
        let ok = await call(untracked, "insert_paragraph", [
            "after_text": .string("Alpha paragraph."), "text": .string("X."), "date": .string("not a date"),
        ])
        XCTAssertNotEqual(ok.isError, true, "date is ignored when not tracking — got: \(text(ok))")
    }

    func testIntoTableCellIsTracked() async throws {
        let body = "<w:tbl><w:tr><w:tc><w:p><w:r><w:t>cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>"
        let path = try makeFixture(body: body)
        let server = await session(path, trackChanges: true, enableAuthor: "Editor B")
        _ = await call(server, "insert_paragraph", [
            "into_table_cell": .object(["table_index": .int(0), "row": .int(0), "col": .int(0)]), "text": .string("New paragraph."),
        ])
        _ = await call(server, "save_document", [:])
        let p = try XCTUnwrap(paragraph(containing: "New paragraph.", in: try unzipDocumentXML(at: path)))
        XCTAssertTrue(p.contains("<w:ins") && p.contains("w:author=\"Editor B\""), "got: \(p)")
    }
}
