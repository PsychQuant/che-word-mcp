import CoreText
import XCTest
@testable import CheWordMCP

/// Tests for the glyph-coverage probe behind issue #189.
///
/// The defect these guard against is directional. A checkbox tick written as
/// `☑` (U+2611) had no glyph in any font measured for #189 — including Times
/// New Roman and Arial — so the renderer falls back to another face and the
/// tick stops matching the form. A probe that reports that is useful.
///
/// A probe that reports it for the WRONG reason is worse than none, and there
/// are two ways to get there. CoreText answers `CTFontCreateWithName` with
/// Helvetica when a family is not installed, and Helvetica itself has no
/// `□`/`■` — so a two-valued probe says "`■` has no glyph in PMingLiU",
/// fingering the one character that is actually safe. And descriptor matching
/// is a *best match*, not a lookup: asking for `System Font` yields `.SF NS`,
/// a different family, about which a confident verdict would be equally wrong.
/// Hence three values, hence `unknown` carries a reason, and hence the verdicts
/// carry the family that was actually measured.
final class GlyphCoverageTests: XCTestCase {

    /// Always present on macOS, and — measured, not assumed — carries no glyph
    /// for any of the geometric-shape or ballot-box characters.
    private let alwaysPresentFont = "Helvetica"

    /// Deliberately absent. Doubles as a control: an unresolvable name must
    /// travel the same path as a real-but-uninstalled family.
    private let absentFont = "ThisFontIsDeliberatelyAbsent-189"

    private let latinA: Unicode.Scalar = "A"
    private let blackSquare: Unicode.Scalar = "\u{25A0}"          // ■ the safe tick
    private let ballotBoxWithCheck: Unicode.Scalar = "\u{2611}"   // ☑ unsafe
    private let ballotBoxWithX: Unicode.Scalar = "\u{2612}"       // ☒ unsafe
    private let grinningFace: Unicode.Scalar = "\u{1F600}"        // non-BMP: 2 UTF-16 units

    /// Resolves a family name WITHOUT going through the code under test, so a
    /// regression in the production resolver cannot silently disable a test by
    /// turning its precondition false.
    private func familyIsInstalledIndependently(_ family: String) -> Bool {
        let names = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        return names.contains { $0.compare(family, options: [.caseInsensitive]) == .orderedSame }
    }

    // MARK: - Resolvable fonts answer about glyphs, and name what they measured

    func testResolvableFontWithGlyphReportsHasGlyphAndNamesTheFont() {
        XCTAssertEqual(
            GlyphCoverageProbe.coverage(of: latinA, declaredFont: alwaysPresentFont),
            .hasGlyph(resolvedFont: alwaysPresentFont))
    }

    func testResolvableFontMissingGlyphReportsNoGlyph() {
        XCTAssertEqual(
            GlyphCoverageProbe.coverage(of: ballotBoxWithCheck, declaredFont: alwaysPresentFont),
            .noGlyph(resolvedFont: alwaysPresentFont),
            "Helvetica has no U+2611; a resolvable font must yield a real verdict")
    }

    // MARK: - The core regression line (#189)

    func testUnresolvableFontReportsUnknownNotNoGlyph() {
        let verdict = GlyphCoverageProbe.coverage(of: latinA, declaredFont: absentFont)

        XCTAssertEqual(verdict, .unknown(declaredFont: absentFont, reason: .notInstalled))
        XCTAssertNotEqual(
            verdict, .noGlyph(resolvedFont: absentFont),
            "An absent font means we could not look. That is not the same claim as "
            + "'this font lacks the glyph', and must never be reported as one.")
    }

    /// The specific reversal that motivated the three-valued design. Asserts
    /// full equality rather than `!= .noGlyph`: a substituted font containing
    /// U+25A0 would satisfy the weaker assertion while still being a verdict
    /// about a font nobody asked about.
    func testUnresolvableFontDoesNotIncriminateTheSafeCharacter() {
        XCTAssertEqual(
            GlyphCoverageProbe.coverage(of: blackSquare, declaredFont: absentFont),
            .unknown(declaredFont: absentFont, reason: .notInstalled),
            "U+25A0 is the recommended tick. Reporting anything but 'not installed' here "
            + "either inverts the advice or answers about the wrong font.")
    }

    /// `CTFontDescriptorCreateMatchingFontDescriptor` is a best-match, not a
    /// lookup: `System Font` resolves to the `.SF NS` family. A verdict about
    /// `.SF NS` is not a verdict about what the document declared, so it must
    /// come back as `unknown` — and say which family it landed on.
    func testSubstitutedFamilyIsUnknownRatherThanAConfidentVerdict() throws {
        let aliasThatSubstitutes = "System Font"
        let verdict = GlyphCoverageProbe.coverage(of: latinA, declaredFont: aliasThatSubstitutes)

        guard case .unknown(let declared, let reason) = verdict else {
            return XCTFail("expected unknown for a substituted family, got \(verdict)")
        }
        XCTAssertEqual(declared, aliasThatSubstitutes)
        guard case .resolvedToDifferentFamily(let landedOn) = reason else {
            return XCTFail("expected a substitution reason, got \(reason)")
        }
        XCTAssertNotEqual(landedOn, aliasThatSubstitutes,
                          "the reason must name the family actually matched, for auditability")
    }

    func testEmptyDeclaredFontIsUnknownWithItsOwnReason() {
        XCTAssertEqual(
            GlyphCoverageProbe.coverage(of: blackSquare, declaredFont: ""),
            .unknown(declaredFont: "", reason: .noDeclaredFont),
            "A run with no rFonts inherits from style or theme, which this probe does "
            + "not follow. 'I was told nothing' is its own reason, not 'not installed'.")
    }

    // MARK: - Localized family names

    /// `標楷體` is the same family as `DFKai-SB`. Matching the requested name
    /// against `CTFontCopyFamilyName` — which answers in English — would call
    /// an installed font unresolvable.
    ///
    /// The precondition is checked through CoreText directly. Gating on the
    /// function under test would mean a regression that breaks localized-name
    /// resolution silently SKIPS this test instead of failing it.
    func testLocalizedFamilyNameIsNotReportedUnknown() throws {
        try XCTSkipUnless(familyIsInstalledIndependently("DFKai-SB"),
                          "DFKai-SB absent on this host; nothing to assert about localized names")

        XCTAssertEqual(
            GlyphCoverageProbe.coverage(of: blackSquare, declaredFont: "標楷體"),
            .hasGlyph(resolvedFont: "DFKai-SB"),
            "an installed family referred to by its localized name must resolve, and the "
            + "verdict must name the family that was measured")
    }

    // MARK: - Characters the guidance makes claims about

    func testBothBallotBoxCharactersLackGlyphsInTheCitedLatinFonts() throws {
        for family in ["Times New Roman", "Arial"] {
            try XCTSkipUnless(familyIsInstalledIndependently(family), "\(family) absent on this host")
            XCTAssertEqual(GlyphCoverageProbe.coverage(of: blackSquare, declaredFont: family),
                           .hasGlyph(resolvedFont: family), "■ is the recommended tick")
            for unsafe in [ballotBoxWithCheck, ballotBoxWithX] {
                XCTAssertEqual(
                    GlyphCoverageProbe.coverage(of: unsafe, declaredFont: family),
                    .noGlyph(resolvedFont: family),
                    "the tool description names U+2611 AND U+2612 as unsafe in \(family); "
                    + "both halves of that claim need evidence")
            }
        }
    }

    // MARK: - Non-BMP scalars

    /// A scalar outside the BMP is two UTF-16 units. CoreText maps the pair to
    /// one glyph and leaves index 1 at zero while still returning true, so a
    /// probe that reasoned "any zero means unmapped" would report every
    /// non-BMP character as missing.
    func testNonBMPScalarIsNotReportedMissingWhenTheFontHasIt() throws {
        try XCTSkipUnless(familyIsInstalledIndependently("Apple Color Emoji"),
                          "Apple Color Emoji absent on this host")
        XCTAssertEqual(
            GlyphCoverageProbe.coverage(of: grinningFace, declaredFont: "Apple Color Emoji"),
            .hasGlyph(resolvedFont: "Apple Color Emoji"))
    }

    func testNonBMPScalarIsReportedMissingWhenTheFontLacksIt() {
        XCTAssertEqual(
            GlyphCoverageProbe.coverage(of: grinningFace, declaredFont: alwaysPresentFont),
            .noGlyph(resolvedFont: alwaysPresentFont))
    }

    // MARK: - Resolution predicate

    func testAbsentFontDoesNotResolve() {
        XCTAssertFalse(GlyphCoverageProbe.fontResolvesLocally(absentFont))
    }

    func testPresentFontResolves() {
        XCTAssertTrue(GlyphCoverageProbe.fontResolvesLocally(alwaysPresentFont))
    }

    func testSubstitutedFamilyDoesNotCountAsResolved() {
        XCTAssertFalse(GlyphCoverageProbe.fontResolvesLocally("System Font"),
                       "landing on a different family is not the declared font resolving")
    }
}
