// ScriptPipelineFixtures.swift
// #227 — fixtures shared by the script-pipeline tests (ungated tool tests in
// Issue227ScriptCoverageReasonsTests and the gated CLI cross-check in
// ScriptPipelineParityTests).

import Foundation
import OOXMLSwift

enum ScriptPipelineFixtures {

    /// Body paragraphs of `writeParagraphsWithoutParaId`, in document order
    /// (text, pStyle). The table between the second and third paragraph is
    /// not listed: paragraphs-only export omits it.
    static let paragraphsWithoutParaId: [(text: String, style: String?)] = [
        ("Assignment 02", "Heading1"),
        ("第一段「引號」與 \"quotes\" 與反斜線 \\ 結尾", nil),
        ("表格之後的段落", nil),
        ("", nil),
    ]

    /// Text inside the table cell — must NOT survive a paragraphs-only export.
    static let tableCellText = "表格裡的文字"

    /// A docx whose paragraphs carry no `w14:paraId` — the shape Word 2010 and
    /// many converters produce (PsychQuant/macdoc#181). Direct body mutation
    /// bypasses the authoring chokepoints, so nothing is stamped and
    /// ReverseExtractor keeps document.xml on the raw channel with the
    /// `paragraph-no-paraId` reason. A table and an empty paragraph are
    /// included so paragraphs-only omission and synthesized ids get exercised.
    static func writeParagraphsWithoutParaId(to url: URL) throws {
        var doc = WordDocument()
        func paragraph(_ entry: (text: String, style: String?)) -> BodyChild {
            var p = entry.text.isEmpty ? Paragraph() : Paragraph(runs: [Run(text: entry.text)])
            p.properties.style = entry.style
            return .paragraph(p)
        }
        doc.body.children.append(paragraph(paragraphsWithoutParaId[0]))
        doc.body.children.append(paragraph(paragraphsWithoutParaId[1]))
        var cell = TableCell()
        cell.paragraphs = [Paragraph(runs: [Run(text: tableCellText)])]
        doc.body.children.append(.table(Table(rows: [TableRow(cells: [cell])])))
        doc.body.children.append(paragraph(paragraphsWithoutParaId[2]))
        doc.body.children.append(paragraph(paragraphsWithoutParaId[3]))
        try DocxWriter.write(doc, to: url)
    }

    /// A pure-paragraph authoring docx (every paragraph stamped with a
    /// paraId), so document.xml rides the DSL channel.
    static func writeAuthoredParagraphs(to url: URL) throws {
        var doc = WordDocument.emptyAuthoringDocument()
        try doc.apply(operations: [
            .appendParagraph(in: nil, paragraph: ParagraphPayload(
                text: "標題", styleId: "Heading1", paraId: "A1")),
            .appendParagraph(in: nil, paragraph: ParagraphPayload(
                text: "本文", paraId: "A2")),
        ])
        try doc.writeAuthoringPackage(to: url)
    }

    /// Top-level body paragraphs of a docx as (text, pStyle), in order.
    static func bodyParagraphs(of url: URL) throws -> [(text: String, style: String?)] {
        let document = try DocxReader.read(from: url)
        return document.body.children.compactMap { child in
            if case .paragraph(let p) = child { return (p.text, p.properties.style) }
            return nil
        }
    }

    /// che-word-mcp#168: a committable, self-produced fixture exercising the
    /// raw-channel long tail an authoring-built-then-rebuilt document never
    /// touches. The ungated `makeFiveLayerDocx` fixture in
    /// `ScriptPipelineParityTests` is built and read back through the SAME
    /// ooxml-swift writer/reader pair, so it can only ever exercise parts
    /// that writer already knows how to round-trip — the real-document
    /// verification for genuinely foreign content lived exclusively in the
    /// env-gated cross-check against a private JPA template, unreachable in
    /// CI (#168, #183).
    ///
    /// This fixture is NOT a real Word document — nothing in this sandbox
    /// can run actual Microsoft Word, and even if it could, checking in a
    /// document Word produced would risk the git-privacy boundary this repo
    /// enforces for third-party artifacts. Instead: the typed-model layer
    /// (numbering, comments, an image, a table, a bookmark) is built through
    /// `WordDocument`'s own authoring API — deliberately DIVERSE, unlike
    /// `makeFiveLayerDocx`'s five-construct minimum — and two parts real
    /// Word ALWAYS emits but ooxml-swift's typed model explicitly does NOT
    /// manage (`DocxWriter`'s own doc comment names them as the overlay
    /// mode's reason for existing: "theme/, webSettings.xml, people.xml,
    /// glossary/, etc.") are injected as extra ZIP entries from committed,
    /// plain-text, boilerplate XML — standard OOXML theme/webSettings
    /// skeletons, zero original or confidential content, reviewable in a
    /// diff. This is the "自己手寫最小 XML" alternative the task's own
    /// instructions name when a real-Word-style fixture is needed but a
    /// third-party document cannot be committed.
    static func writeWordStyleFixture(to url: URL) throws {
        var doc = WordDocument()

        var heading = Paragraph(runs: [Run(text: "Issue168 標題", properties: RunProperties(bold: true))])
        heading.properties.style = "Heading1"
        doc.body.children.append(.paragraph(heading))

        let numId = doc.numbering.createNumberedList()
        var numbered = Paragraph(runs: [Run(text: "第一項清單內容")])
        numbered.properties.numbering = NumberingInfo(numId: numId, level: 0)
        doc.body.children.append(.paragraph(numbered))

        var bookmarked = Paragraph(runs: [Run(text: "含書籤與註解的段落")])
        bookmarked.bookmarks = [Bookmark(id: 0, name: "Issue168Bookmark")]
        doc.body.children.append(.paragraph(bookmarked))
        doc.comments.comments.append(Comment(
            id: 0, author: "Fixture Author", text: "固定測試用註解", paragraphIndex: 2,
            date: Date(timeIntervalSince1970: 0), initials: "FA"))

        var cell = TableCell()
        cell.paragraphs = [Paragraph(runs: [Run(text: "表格儲存格")])]
        doc.body.children.append(.table(Table(rows: [TableRow(cells: [cell])])))

        try DocxWriter.write(doc, to: url)

        // Inject the two typed-model-unmanaged parts from committed fixture
        // XML (see the doc comment above). `/usr/bin/zip` appends entries to
        // the archive DocxWriter just wrote — the same technique
        // `ScriptPipelineParityTests.testExecuteMissingPartBreaksVerification`
        // uses to grow a package beyond what the typed model can write.
        let fixtureDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Issue168WordStyleFixture")
        let stagingDir = url.deletingLastPathComponent()
            .appendingPathComponent("issue168-staging-\(UUID().uuidString)")
        let themeDir = stagingDir.appendingPathComponent("word/theme", isDirectory: true)
        try FileManager.default.createDirectory(at: themeDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixtureDir.appendingPathComponent("theme1.xml"),
            to: themeDir.appendingPathComponent("theme1.xml"))
        try FileManager.default.copyItem(
            at: fixtureDir.appendingPathComponent("webSettings.xml"),
            to: stagingDir.appendingPathComponent("webSettings-inject-me.xml"))
        // word/webSettings.xml must land directly under word/, not staged
        // twice — move the copy into place with the real target name.
        let wordDir = stagingDir.appendingPathComponent("word", isDirectory: true)
        try FileManager.default.moveItem(
            at: stagingDir.appendingPathComponent("webSettings-inject-me.xml"),
            to: wordDir.appendingPathComponent("webSettings.xml"))
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = stagingDir
        zip.arguments = ["-q", url.path, "word/theme/theme1.xml", "word/webSettings.xml"]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else {
            throw NSError(domain: "Issue168Fixture", code: Int(zip.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "zip injection failed"])
        }
    }
}
