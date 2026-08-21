import XCTest
@testable import CheWordMCP

/// Tests for the glyph-coverage probe behind issue #189.
///
/// The defect these guard against is directional. A checkbox tick written as
/// `☑` (U+2611) has no glyph in any font measured for #189 — including Times
/// New Roman and Arial — so the renderer falls back to an emoji font and the
/// tick stops matching the form. A probe that reports that is useful.
///
/// A probe that reports it for the WRONG reason is worse than none. CoreText
/// answers `CTFontCreateWithName("PMingLiU")` with Helvetica when the family
/// is not installed, and Helvetica itself has no `□`/`■`. So a two-valued
/// probe says "`■` has no glyph in PMingLiU" — fingering the one character
/// that is actually safe, while the real finding (the font is not present, so
/// nothing can be concluded) is thrown away. Hence three values, and hence
/// the assertions below that `unknown` is not merely != hasGlyph.
final class GlyphCoverageTests: XCTestCase {

    /// Always present on macOS, and — measured, not assumed — carries no
    /// glyph for any of the geometric-shape or ballot-box characters. That
    /// combination is what makes it usable as a fixture without a skip.
    private let alwaysPresentFont = "Helvetica"

    /// Deliberately absent. Doubles as the control group: an unresolvable
    /// name must travel the same path as a real-but-uninstalled family.
    private let absentFont = "ThisFontIsDeliberatelyAbsent-189"

    private let latinA: Unicode.Scalar = "A"
    private let blackSquare: Unicode.Scalar = "\u{25A0}"      // ■ the safe tick
    private let ballotBoxWithCheck: Unicode.Scalar = "\u{2611}" // ☑ the unsafe one

    // MARK: - Resolvable fonts answer about glyphs

    func testResolvableFontWithGlyphReportsHasGlyph() {
        XCTAssertEqual(
            GlyphCoverageProbe.coverage(of: latinA, declaredFont: alwaysPresentFont),
            .hasGlyph)
    }

    func testResolvableFontMissingGlyphReportsNoGlyph() {
        XCTAssertEqual(
            GlyphCoverageProbe.coverage(of: ballotBoxWithCheck, declaredFont: alwaysPresentFont),
            .noGlyph,
            "Helvetica has no U+2611; a resolvable font must yield a real verdict")
    }

    // MARK: - The core regression line (#189)

    func testUnresolvableFontReportsUnknownNotNoGlyph() {
        let verdict = GlyphCoverageProbe.coverage(of: latinA, declaredFont: absentFont)

        XCTAssertEqual(verdict, .unknown(declaredFont: absentFont))
        XCTAssertNotEqual(
            verdict, .noGlyph,
            "An absent font means we could not look. That is not the same claim as "
            + "'this font lacks the glyph', and must never be reported as one.")
        XCTAssertNotEqual(verdict, .hasGlyph)
    }

    /// The specific reversal that motivated the three-valued design: `■` is
    /// the character the guidance tells callers to use, so a probe that
    /// reports `noGlyph` for it when the font merely is not installed would
    /// steer callers away from the correct answer.
    func testUnresolvableFontDoesNotIncriminateTheSafeCharacter() {
        XCTAssertNotEqual(
            GlyphCoverageProbe.coverage(of: blackSquare, declaredFont: absentFont),
            .noGlyph,
            "U+25A0 is the recommended tick. Reporting it as glyphless because the "
            + "declared font is absent inverts the advice this probe exists to give.")
    }

    // MARK: - Localized family names

    /// `標楷體` is the same family as `DFKai-SB`. Matching the requested name
    /// against `CTFontCopyFamilyName` — which answers in English — would call
    /// an installed font unresolvable.
    func testLocalizedFamilyNameIsNotReportedUnknown() throws {
        let localized = "標楷體"
        try XCTSkipUnless(
            GlyphCoverageProbe.fontResolvesLocally(localized),
            "DFKai-SB not installed on this host; nothing to assert about localized names")

        let verdict = GlyphCoverageProbe.coverage(of: blackSquare, declaredFont: localized)
        XCTAssertNotEqual(verdict, .unknown(declaredFont: localized),
                          "An installed family referred to by its localized name must resolve")
        XCTAssertEqual(verdict, .hasGlyph)
    }

    // MARK: - The reported scenario end to end

    func testReportedScenarioTickCharacters() throws {
        let font = "Times New Roman"
        try XCTSkipUnless(GlyphCoverageProbe.fontResolvesLocally(font),
                          "\(font) not installed on this host")

        XCTAssertEqual(GlyphCoverageProbe.coverage(of: blackSquare, declaredFont: font),
                       .hasGlyph, "■ is the tick the guidance recommends")
        XCTAssertEqual(GlyphCoverageProbe.coverage(of: ballotBoxWithCheck, declaredFont: font),
                       .noGlyph,
                       "☑ is absent even from Times New Roman — the finding is not CJK-specific")
    }

    /// A run with no `rFonts` declaration inherits from the style or theme,
    /// which this probe does not resolve. "I was told nothing" is a reason to
    /// conclude nothing — not a reason to conclude the glyph is missing.
    func testEmptyDeclaredFontIsUnknownNotNoGlyph() {
        let verdict = GlyphCoverageProbe.coverage(of: blackSquare, declaredFont: "")
        XCTAssertEqual(verdict, .unknown(declaredFont: ""))
        XCTAssertNotEqual(verdict, .noGlyph)
    }

    // MARK: - Resolution predicate

    func testAbsentFontDoesNotResolve() {
        XCTAssertFalse(GlyphCoverageProbe.fontResolvesLocally(absentFont))
    }

    func testPresentFontResolves() {
        XCTAssertTrue(GlyphCoverageProbe.fontResolvesLocally(alwaysPresentFont))
    }
}
