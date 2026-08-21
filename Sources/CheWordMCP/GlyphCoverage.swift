import CoreGraphics
import CoreText
import Foundation

/// Why a coverage question could not be answered.
///
/// Separate cases because they call for different things to be said. A run
/// that declared nothing needs style/theme resolution, which this probe does
/// not do; a font that is not installed needs a different machine to answer;
/// a name that landed on some other family needs the caller to know *which*,
/// or the substitution is unauditable.
enum GlyphCoverageUnknownReason: Equatable, Sendable {
    /// No font name was declared. In OOXML the run inherits from its style or
    /// the theme — neither of which this probe follows.
    case noDeclaredFont
    /// The declared family is not present on this machine.
    case notInstalled
    /// A font matched, but it belongs to a different family than the one
    /// declared. Carries the family actually matched.
    case resolvedToDifferentFamily(String)
}

/// Whether a character can be drawn in a run's *declared* font.
///
/// Three values rather than a `Bool`, because "the font has no glyph for this"
/// and "nothing was measured" are different claims and only one of them
/// justifies warning a caller. Collapsing them is not a cosmetic loss — it
/// inverts the advice. `CTFontCreateWithName` answers an uninstalled family
/// with Helvetica instead of failing, and Helvetica carries no `□`/`■`, so a
/// two-valued probe asked about `■` in an absent CJK family reports "no glyph"
/// for the very character callers are told to use.
///
/// The two decided cases carry the family that was actually measured. Without
/// it a caller cannot tell a verdict about the declared font from a verdict
/// about whatever CoreText decided was close enough — and that difference is
/// the whole point of the `unknown` case existing.
///
/// Absence of a measurement must not be readable as a negative measurement —
/// the same reason `ScriptExecuteResult.verified` is `nil` rather than `false`
/// when verification did not run (ooxml-swift, `ScriptPipelineExecute`).
enum GlyphCoverage: Equatable, Sendable {
    /// The declared family resolved and covers the character.
    case hasGlyph(resolvedFont: String)
    /// The declared family resolved and does **not** cover the character. A
    /// renderer will substitute some other font — for `☑` on macOS, typically
    /// a colour emoji face, which is how #189 was noticed.
    case noGlyph(resolvedFont: String)
    /// Coverage was never measured against the declared font.
    case unknown(declaredFont: String, reason: GlyphCoverageUnknownReason)
}

/// Answers **nominal cmap coverage** questions about a *declared* font name —
/// the string that appears in `w:rFonts`, which may name a font this machine
/// does not have.
///
/// Deliberately narrow, and the name of the thing is the honest one: this asks
/// whether a font's character map contains a scalar. It is **not** a prediction
/// of what a renderer will draw. Shaping, normalization, GSUB substitution and
/// variation-selector sequences (`☑︎` / `☑️` are a scalar *pair*) all live above
/// this layer, and a `hasGlyph` verdict does not rule out a renderer choosing a
/// different face for emoji presentation.
///
/// Scope, stated plainly: it measures the local font set. The document is
/// rendered on the reader's machine with the reader's fonts, so every answer is
/// advisory. `unknown` is expected to be common rather than exceptional; on the
/// machine where #189 was diagnosed, all three PMingLiU-family spellings were
/// unresolvable.
///
/// It also takes **one** font name. An OOXML run declares up to four
/// (`w:rFonts` `ascii` / `hAnsi` / `eastAsia` / `cs`) and which one draws a
/// given character depends on that character's script — for the CJK forms in
/// #189, `eastAsia`. Choosing the applicable slot, and resolving style/theme
/// inheritance, is the caller's job and is **not** done here.
enum GlyphCoverageProbe {

    /// Whether `declaredFont` names a family present on this machine *and*
    /// CoreText resolves it to that same family.
    static func fontResolvesLocally(_ declaredFont: String) -> Bool {
        if case .resolved = resolve(declaredFont) { return true }
        return false
    }

    /// Coverage of `scalar` in `declaredFont`, or `.unknown` with a reason.
    static func coverage(of scalar: Unicode.Scalar, declaredFont: String) -> GlyphCoverage {
        let font: CTFont
        let family: String
        switch resolve(declaredFont) {
        case .unresolvable(let reason):
            return .unknown(declaredFont: declaredFont, reason: reason)
        case .resolved(let f, let name):
            font = f
            family = name
        }

        var utf16 = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        // One scalar, so this is one character to CoreText even when it spans a
        // surrogate pair: the pair maps to a single glyph at index 0, index 1
        // stays zero, and the call still returns true. Measured against Apple
        // Color Emoji with U+1F600 — glyphs came back [2096, 0], result true.
        // Reading those zeros as "partially unmapped" would report every
        // non-BMP character as missing.
        let covered = CTFontGetGlyphsForCharacters(font, &utf16, &glyphs, utf16.count)
        return covered ? .hasGlyph(resolvedFont: family) : .noGlyph(resolvedFont: family)
    }

    // MARK: - Resolution

    private enum Resolution {
        case resolved(CTFont, family: String)
        case unresolvable(GlyphCoverageUnknownReason)
    }

    /// Resolves a declared family name, refusing anything CoreText merely
    /// considered a good substitute.
    ///
    /// `CTFontDescriptorCreateMatchingFontDescriptor` with no mandatory
    /// attributes is a *best match*, not a lookup — asking for `System Font`
    /// hands back the `.SF NS` family. Treating that as success would produce
    /// a confident `hasGlyph` / `noGlyph` about a font the document never
    /// named, which is exactly the silent wrong answer the `unknown` case
    /// exists to prevent.
    ///
    /// Acceptance is by identity rather than by family name alone, because
    /// `CTFontCopyFamilyName` answers in English: `標楷體` comes back as
    /// `DFKai-SB`, and a family-name comparison would call an installed font
    /// missing. Comparing against the resolved font's own name set — family,
    /// full, PostScript, and localized family — accepts the localized spelling
    /// and the differently-cased one while still rejecting `.SF NS`.
    private static func resolve(_ declaredFont: String) -> Resolution {
        let trimmed = declaredFont.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unresolvable(.noDeclaredFont) }

        let query = CTFontDescriptorCreateWithAttributes(
            [kCTFontFamilyNameAttribute: trimmed] as CFDictionary)
        guard let matched = CTFontDescriptorCreateMatchingFontDescriptor(query, nil) else {
            return .unresolvable(.notInstalled)
        }

        let font = CTFontCreateWithFontDescriptor(matched, 0, nil)
        let family = CTFontCopyFamilyName(font) as String
        guard identities(of: font).contains(where: {
            $0.compare(trimmed, options: [.caseInsensitive]) == .orderedSame
        }) else {
            return .unresolvable(.resolvedToDifferentFamily(family))
        }
        return .resolved(font, family: family)
    }

    /// Every name the resolved font answers to, so a localized or differently
    /// cased spelling of the declared family is recognised as that family.
    private static func identities(of font: CTFont) -> [String] {
        var names: [String] = []
        for key in [kCTFontFamilyNameKey, kCTFontFullNameKey, kCTFontPostScriptNameKey] {
            if let name = CTFontCopyName(font, key) { names.append(name as String) }
        }
        var language: Unmanaged<CFString>?
        if let localized = CTFontCopyLocalizedName(font, kCTFontFamilyNameKey, &language) {
            names.append(localized as String)
        }
        return names
    }
}
