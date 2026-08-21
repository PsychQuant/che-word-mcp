import CoreGraphics
import CoreText
import Foundation

/// Whether a character can be drawn in a run's *declared* font.
///
/// Three values rather than a `Bool`, because "the font has no glyph for this"
/// and "the font is not here, so nothing was measured" are different claims and
/// only one of them justifies warning a caller. Collapsing them is not a
/// cosmetic loss — it inverts the advice. `CTFontCreateWithName` answers an
/// uninstalled family with Helvetica instead of failing, and Helvetica carries
/// no `□`/`■`, so a two-valued probe asked about `■` in an absent CJK family
/// reports "no glyph" for the very character callers are told to use.
///
/// `unknown` is therefore load-bearing and deliberately carries the name it
/// could not resolve, so a caller can say *which* declaration it could not act
/// on. Absence of a measurement must not be readable as a negative measurement
/// — the same reason `ScriptExecuteResult.verified` is `nil` rather than
/// `false` when verification did not run (ooxml-swift, `ScriptPipelineExecute`).
enum GlyphCoverage: Equatable, Sendable {
    /// The declared font resolved locally and covers the character.
    case hasGlyph
    /// The declared font resolved locally and does **not** cover the character.
    /// A renderer will substitute some other font — for `☑` on macOS, typically
    /// a colour emoji face, which is how #189 was noticed.
    case noGlyph
    /// The declared font could not be resolved on this machine, so coverage was
    /// never measured. Not a verdict about the character.
    case unknown(declaredFont: String)
}

/// Answers glyph-coverage questions about a *declared* font name — the string
/// that appears in `w:rFonts`, which may name a font this machine does not have.
///
/// Scope, stated plainly: this measures the local font set. The document is
/// rendered on the reader's machine with the reader's fonts, so every answer is
/// advisory. `unknown` is expected to be common rather than exceptional; on the
/// machine where #189 was diagnosed, all three PMingLiU-family spellings were
/// unresolvable.
enum GlyphCoverageProbe {

    /// Whether `declaredFont` names a family present on this machine.
    ///
    /// Matching goes through a font *descriptor* rather than comparing against
    /// `CTFontCopyFamilyName`, because that call answers in English: `標楷體`
    /// comes back as `DFKai-SB`, so a literal comparison would call an installed
    /// family missing. Descriptor matching accepts the localized spelling.
    static func fontResolvesLocally(_ declaredFont: String) -> Bool {
        resolvedDescriptor(for: declaredFont) != nil
    }

    /// Coverage of `scalar` in `declaredFont`, or `.unknown` when that font is
    /// not resolvable here.
    static func coverage(of scalar: Unicode.Scalar, declaredFont: String) -> GlyphCoverage {
        guard let descriptor = resolvedDescriptor(for: declaredFont) else {
            return .unknown(declaredFont: declaredFont)
        }
        let font = CTFontCreateWithFontDescriptor(descriptor, 0, nil)
        var utf16 = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        // Returns false if ANY unit went unmapped, which is the answer we want
        // for surrogate pairs too: a partially mapped character is not covered.
        let covered = CTFontGetGlyphsForCharacters(font, &utf16, &glyphs, utf16.count)
        return covered ? .hasGlyph : .noGlyph
    }

    /// An empty or whitespace-only name is treated as unresolvable rather than
    /// handed to CoreText. A run without `w:rFonts` inherits from its style or
    /// the theme, neither of which this probe follows — so there is nothing it
    /// can honestly conclude, and it says so instead of guessing.
    private static func resolvedDescriptor(for declaredFont: String) -> CTFontDescriptor? {
        let trimmed = declaredFont.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let query = CTFontDescriptorCreateWithAttributes(
            [kCTFontFamilyNameAttribute: trimmed] as CFDictionary)
        return CTFontDescriptorCreateMatchingFontDescriptor(query, nil)
    }
}
