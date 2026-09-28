import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// #255 — wires the #189 `GlyphCoverageProbe` into `replace_text` /
/// `replace_text_batch` as an advisory (riding the #192 advisory channel).
///
/// Three groups:
/// 1. `effectiveFontSlot` — pure Unicode-range classification, no CoreText.
/// 2. `resolveDeclaredFont` — pure style-cascade resolution, no CoreText,
///    no filesystem, deterministic on any machine.
/// 3. `glyphCoverageAdvisories` / end-to-end tool calls — uses the real
///    `GlyphCoverageProbe` (CoreText) against "Helvetica", the same
///    always-present / no-U+2611-or-2612-glyph fixture `GlyphCoverageTests`
///    already relies on.
final class Issue255GlyphCoverageAdvisoryTests: XCTestCase {

    // MARK: - Group 1: effectiveFontSlot

    func testBallotBoxCharactersAreNotClassifiedEastAsian() {
        // #189's whole finding was that ☑/☒ lack glyphs in Times New Roman /
        // Arial — both ascii/hAnsi-slot fonts. If this classifier routed them
        // to `.eastAsia` instead, the wiring would probe the WRONG axis's
        // declared font for any run that declares different fonts per axis.
        XCTAssertEqual(effectiveFontSlot(for: "\u{2611}"), .hAnsi)
        XCTAssertEqual(effectiveFontSlot(for: "\u{2612}"), .hAnsi)
        XCTAssertEqual(effectiveFontSlot(for: "\u{25A0}"), .hAnsi, "■ itself must resolve the same way")
    }

    func testBasicLatinIsAscii() {
        XCTAssertEqual(effectiveFontSlot(for: "A"), .ascii)
    }

    func testHighAnsiLatin1IsHAnsi() {
        XCTAssertEqual(effectiveFontSlot(for: "\u{00E9}"), .hAnsi) // é
    }

    func testCJKIdeographIsEastAsia() {
        XCTAssertEqual(effectiveFontSlot(for: "\u{4E2D}"), .eastAsia) // 中
    }

    func testHiraganaIsEastAsia() {
        XCTAssertEqual(effectiveFontSlot(for: "\u{3042}"), .eastAsia) // あ
    }

    func testArabicIsComplexScript() {
        XCTAssertEqual(effectiveFontSlot(for: "\u{0627}"), .cs) // ا
    }

    // MARK: - Group 2: resolveDeclaredFont cascade (pure, no CoreText)

    func testDirectRunRFontsWinsOverEverything() {
        let doc = WordDocument()
        var run = Run(text: "x")
        run.properties.rFonts = RFontsProperties(ascii: "DirectFont")
        XCTAssertEqual(
            resolveDeclaredFont(run: run, paragraphStyleId: nil, doc: doc, slot: .ascii),
            "DirectFont")
    }

    func testFallsBackToCharacterStyleWhenRunDeclaresNothing() {
        var doc = WordDocument()
        var charStyle = Style(id: "MyCharStyle", name: "MyCharStyle", type: .character)
        charStyle.runProperties = RunProperties(fontName: "CharStyleFont")
        doc.styles.append(charStyle)

        var run = Run(text: "x")
        run.properties.rStyle = "MyCharStyle"

        XCTAssertEqual(
            resolveDeclaredFont(run: run, paragraphStyleId: nil, doc: doc, slot: .ascii),
            "CharStyleFont")
    }

    func testFallsBackToParagraphStyleWhenNoCharacterStyle() {
        var doc = WordDocument()
        var paraStyle = Style(id: "MyParaStyle", name: "MyParaStyle", type: .paragraph)
        paraStyle.runProperties = RunProperties(fontName: "ParaStyleFont")
        doc.styles.append(paraStyle)

        let run = Run(text: "x") // no rStyle, no rFonts

        XCTAssertEqual(
            resolveDeclaredFont(run: run, paragraphStyleId: "MyParaStyle", doc: doc, slot: .ascii),
            "ParaStyleFont")
    }

    func testCharacterStyleTakesPrecedenceOverParagraphStyle() {
        var doc = WordDocument()
        var charStyle = Style(id: "CS", name: "CS", type: .character)
        charStyle.runProperties = RunProperties(fontName: "FromCharStyle")
        var paraStyle = Style(id: "PS", name: "PS", type: .paragraph)
        paraStyle.runProperties = RunProperties(fontName: "FromParaStyle")
        doc.styles.append(charStyle)
        doc.styles.append(paraStyle)

        var run = Run(text: "x")
        run.properties.rStyle = "CS"

        XCTAssertEqual(
            resolveDeclaredFont(run: run, paragraphStyleId: "PS", doc: doc, slot: .ascii),
            "FromCharStyle")
    }

    func testFallsBackToDocumentDefaultStyleWhenNothingElseDeclares() {
        // WordDocument() seeds Style.defaultStyles, whose "Normal" style
        // (isDefault == true) declares fontName "Calibri" — a real,
        // deterministic fact about the shipped default style table, not
        // dependent on any font being installed on this machine.
        let doc = WordDocument()
        let run = Run(text: "x")

        XCTAssertEqual(
            resolveDeclaredFont(run: run, paragraphStyleId: nil, doc: doc, slot: .ascii),
            "Calibri")
    }

    func testReturnsNilWhenNothingDeclaresAnywhere() {
        var doc = WordDocument()
        doc.styles = [] // no default style, no chain to fall back to
        let run = Run(text: "x")

        XCTAssertNil(resolveDeclaredFont(run: run, paragraphStyleId: nil, doc: doc, slot: .ascii))
    }

    // MARK: - Group 3: glyphCoverageAdvisories (real CoreText, "Helvetica" fixture)

    /// Same fixture fact `GlyphCoverageTests` already establishes and relies
    /// on: Helvetica is always present on macOS and has no glyph for either
    /// ballot-box character.
    private let alwaysPresentFont = "Helvetica"
    private let absentFont = "ThisFontIsDeliberatelyAbsent-189"

    private func docWithSingleBodyRun(text: String, fontName: String?) -> WordDocument {
        var doc = WordDocument()
        var props = RunProperties()
        if let fontName { props.fontName = fontName }
        doc.appendParagraph(Paragraph(runs: [Run(text: text, properties: props)]))
        return doc
    }

    func testNoGlyphProducesExactlyOneAdvisoryNamingCharacterAndFont() {
        let doc = docWithSingleBodyRun(text: "\u{2611}", fontName: alwaysPresentFont)
        let advisories = glyphCoverageAdvisories(doc: doc, replacement: "\u{2611}", scope: .bodyAndTables)

        XCTAssertEqual(advisories.count, 1)
        let message = advisories[0]
        XCTAssertTrue(message.contains("U+2611"), "must name the character: \(message)")
        XCTAssertTrue(message.contains("Helvetica"), "must name the declared font: \(message)")
        XCTAssertTrue(message.contains("U+25A0"), "must suggest the safe alternative: \(message)")
        XCTAssertTrue(message.lowercased().contains("regular"),
                      "B3 disclosure: must say the measurement is against the regular/upright face: \(message)")
        XCTAssertTrue(message.contains("this machine") || message.lowercased().contains("machine"),
                      "must disclose the local-fontset-only boundary: \(message)")
        XCTAssertFalse(message.lowercased().contains("unknown"),
                       "an actual noGlyph verdict must never be phrased with the unknown vocabulary")
    }

    func testHasGlyphProducesNoAdvisory() {
        let doc = docWithSingleBodyRun(text: "A", fontName: alwaysPresentFont)
        let advisories = glyphCoverageAdvisories(doc: doc, replacement: "A", scope: .bodyAndTables)
        XCTAssertEqual(advisories, [])
    }

    /// The B1-containment assertion, end to end: an unresolvable declared
    /// font must produce NO advisory (not a "noGlyph" advisory) even though
    /// the character itself is the same unsafe one from the previous test.
    /// This is the concrete regression #189's `unknown` case exists to
    /// prevent, exercised through the wiring rather than the probe directly.
    func testUnresolvableDeclaredFontProducesNoAdvisory() {
        let doc = docWithSingleBodyRun(text: "\u{2611}", fontName: absentFont)
        let advisories = glyphCoverageAdvisories(doc: doc, replacement: "\u{2611}", scope: .bodyAndTables)
        XCTAssertEqual(advisories, [], "unknown must never be reported as noGlyph, including through this wiring")
    }

    func testRunNotContainingTheReplacementIsNotFlagged() {
        var doc = WordDocument()
        var props = RunProperties()
        props.fontName = alwaysPresentFont
        doc.appendParagraph(Paragraph(runs: [Run(text: "totally unrelated text", properties: props)]))

        let advisories = glyphCoverageAdvisories(doc: doc, replacement: "\u{2611}", scope: .bodyAndTables)
        XCTAssertEqual(advisories, [])
    }

    func testDuplicateOccurrencesAreDeduplicated() {
        var doc = WordDocument()
        var props = RunProperties()
        props.fontName = alwaysPresentFont
        doc.appendParagraph(Paragraph(runs: [Run(text: "\u{2611}", properties: props)]))
        doc.appendParagraph(Paragraph(runs: [Run(text: "\u{2611}", properties: props)]))

        let advisories = glyphCoverageAdvisories(doc: doc, replacement: "\u{2611}", scope: .bodyAndTables)
        XCTAssertEqual(advisories.count, 1, "same (font, character) pair must only be reported once")
    }

    func testHeaderIsScannedOnlyUnderAllScope() {
        var doc = WordDocument()
        var props = RunProperties()
        props.fontName = alwaysPresentFont
        var header = Header(id: "rIdHeader1")
        header.bodyChildren = [.paragraph(Paragraph(runs: [Run(text: "\u{2611}", properties: props)]))]
        doc.headers = [header]

        let bodyOnly = glyphCoverageAdvisories(doc: doc, replacement: "\u{2611}", scope: .bodyAndTables)
        XCTAssertEqual(bodyOnly, [], "headers must not be scanned under .bodyAndTables")

        let withAll = glyphCoverageAdvisories(doc: doc, replacement: "\u{2611}", scope: .all)
        XCTAssertEqual(withAll.count, 1, "headers must be scanned under .all")
    }

    func testEmptyReplacementProducesNoAdvisory() {
        let doc = docWithSingleBodyRun(text: "", fontName: alwaysPresentFont)
        XCTAssertEqual(glyphCoverageAdvisories(doc: doc, replacement: "", scope: .bodyAndTables), [])
    }

    // MARK: - Group 4: end-to-end through the MCP tools

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Issue255-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func text(_ content: Tool.Content) -> String {
        if case .text(let t, _, _) = content { return t }
        return ""
    }

    private func tempDocxWithPlaceholder(fontName: String) throws -> String {
        var doc = WordDocument()
        var props = RunProperties()
        props.fontName = fontName
        doc.appendParagraph(Paragraph(runs: [Run(text: "PLACEHOLDER", properties: props)]))
        let url = tempDir.appendingPathComponent("test.docx")
        try DocxWriter.write(doc, to: url)
        return url.path
    }

    func testReplaceTextEmitsAdvisoryOnTheTriggeringCall() async throws {
        let path = try tempDocxWithPlaceholder(fontName: alwaysPresentFont)
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: [
            "path": .string(path), "doc_id": .string("g255"),
        ])
        let r = await server.invokeToolForTesting(name: "replace_text", arguments: [
            "doc_id": .string("g255"), "find": .string("PLACEHOLDER"), "replace": .string("\u{2611}"),
        ])
        XCTAssertNotEqual(r.isError, true)
        XCTAssertEqual(r.content.count, 2, "main result + exactly one advisory: \(r.content)")
        let advisory = text(r.content[1])
        XCTAssertTrue(advisory.hasPrefix("Advisory: "), advisory)
        XCTAssertTrue(advisory.contains("U+2611"), advisory)
        XCTAssertTrue(advisory.contains("Helvetica"), advisory)
    }

    func testReplaceTextWithSafeCharacterEmitsNoAdvisory() async throws {
        let path = try tempDocxWithPlaceholder(fontName: alwaysPresentFont)
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: [
            "path": .string(path), "doc_id": .string("g255b"),
        ])
        let r = await server.invokeToolForTesting(name: "replace_text", arguments: [
            "doc_id": .string("g255b"), "find": .string("PLACEHOLDER"), "replace": .string("ordinary text"),
        ])
        XCTAssertEqual(r.content.count, 1, "no advisory expected: \(r.content)")
    }

    func testReplaceTextBatchEmitsAdvisory() async throws {
        let path = try tempDocxWithPlaceholder(fontName: alwaysPresentFont)
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: [
            "path": .string(path), "doc_id": .string("g255c"),
        ])
        let r = await server.invokeToolForTesting(name: "replace_text_batch", arguments: [
            "doc_id": .string("g255c"),
            "replacements": .array([
                .object(["find": .string("PLACEHOLDER"), "replace": .string("\u{2611}")]),
            ]),
        ])
        XCTAssertNotEqual(r.isError, true)
        XCTAssertEqual(r.content.count, 2, "main result + exactly one advisory: \(r.content)")
        let advisory = text(r.content[1])
        XCTAssertTrue(advisory.hasPrefix("Advisory: "), advisory)
        XCTAssertTrue(advisory.contains("U+2611"), advisory)
    }
}
