import Foundation
import OOXMLSwift

/// #255 — wires the #189 `GlyphCoverageProbe` into `replace_text` /
/// `replace_text_batch` as a caller-side advisory.
///
/// #189 deliberately built only the three-valued primitive
/// (`hasGlyph`/`noGlyph`/`unknown`) and left "select the run's actually
/// effective font slot, resolving style/theme inheritance" to whichever
/// caller wires it in (see that file's doc comment: "Choosing the
/// applicable slot ... is the caller's job and is **not** done here").
/// This file is that caller.
///
/// Three residual risks were named against the probe in #189's prior review
/// (PR #193) and carried forward as #255's own acceptance criteria
/// (B1/B2/B3). None of them are fixed by touching `GlyphCoverage.swift` —
/// that file is already shipped and mutation-tested against a specific,
/// documented design; re-deriving its `resolve()` here risks exactly the
/// kind of confident-but-wrong verdict #189 was written to prevent. Instead:
///
/// - **B1** (localized-name resolution depends on the CURRENT process
///   locale, so a Chinese-named font can report `unknown` on a non-Chinese
///   locale machine): structurally contained, not patched — `glyphAdvisory`
///   below only ever fires for `.noGlyph`, never for `.unknown` or
///   `.hasGlyph`. A false `.unknown` from a locale mismatch can therefore
///   only under-warn (silence), never misreport an installed font as
///   lacking a glyph. This is also that satisfies the #255 body's own
///   instruction directly: "`unknown`...不應被說成「沒有字形」，要嘛不發".
///   We chose "不發".
/// - **B2** (family/full/PostScript/localized-name matching can, in
///   principle, accept a different family under a naming collision): NOT
///   fixed here. Disclosed in every advisory's text instead (see
///   `glyphAdvisoryMessage`).
/// - **B3** (the probe measures the regular/upright face, independent of a
///   run's bold/italic): NOT fixed here. Disclosed in every advisory's text
///   instead, rather than silently measuring the wrong face with unearned
///   confidence.
enum FontSlot: String {
    case ascii, hAnsi, eastAsia, cs
}

/// Classifies a scalar into the OOXML `<w:rFonts>` axis Word would use to
/// draw it.
///
/// This is a practical approximation of ECMA-376's Unicode-range-to-font
/// mapping (§17.3.2.26), not a transcription of it: it covers the ranges
/// this feature's own evidence needs to get right (#189's ballot-box /
/// checkbox symbols, CJK ideographs, and — for completeness — the
/// complex-script scripts most likely to appear in a declared `cs` font).
/// A scalar this function cannot confidently place in `eastAsia` or `cs`
/// falls through to `ascii`/`hAnsi`, split at the ASCII boundary (U+0080)
/// per that same section's Latin/High-ANSI split. Notably, `☑`/`☒`/`■`
/// (Miscellaneous Symbols, U+2600–26FF) are NOT East Asian by this
/// classification even though they are commonly used in CJK-locale forms —
/// matching what #189 measured empirically (their absence in Times New
/// Roman / Arial, both ascii/hAnsi-slot fonts, is what made them unsafe).
func effectiveFontSlot(for scalar: Unicode.Scalar) -> FontSlot {
    let v = scalar.value
    if isComplexScriptScalar(v) { return .cs }
    if isEastAsianScalar(v) { return .eastAsia }
    return v <= 0x7F ? .ascii : .hAnsi
}

private func isEastAsianScalar(_ v: UInt32) -> Bool {
    switch v {
    case 0x1100...0x11FF,     // Hangul Jamo
         0x2E80...0x2EFF,     // CJK Radicals Supplement
         0x3000...0x303F,     // CJK Symbols and Punctuation
         0x3040...0x309F,     // Hiragana
         0x30A0...0x30FF,     // Katakana
         0x3100...0x312F,     // Bopomofo
         0x3130...0x318F,     // Hangul Compatibility Jamo
         0x3400...0x4DBF,     // CJK Unified Ideographs Extension A
         0x4E00...0x9FFF,     // CJK Unified Ideographs
         0xAC00...0xD7A3,     // Hangul Syllables
         0xF900...0xFAFF,     // CJK Compatibility Ideographs
         0xFF00...0xFFEF,     // Halfwidth and Fullwidth Forms
         0x20000...0x2FA1F:   // CJK Unified Ideographs Extension B and beyond
        return true
    default:
        return false
    }
}

private func isComplexScriptScalar(_ v: UInt32) -> Bool {
    switch v {
    case 0x0590...0x05FF,     // Hebrew
         0x0600...0x06FF,     // Arabic
         0x0700...0x074F,     // Syriac
         0x0750...0x077F,     // Arabic Supplement
         0x0780...0x07BF,     // Thaana
         0x0900...0x097F,     // Devanagari
         0x0980...0x09FF,     // Bengali
         0x0A00...0x0A7F,     // Gurmukhi
         0x0E00...0x0E7F,     // Thai
         0x0E80...0x0EFF,     // Lao
         0x0F00...0x0FFF:     // Tibetan
        return true
    default:
        return false
    }
}

/// Resolves the font name declared for `slot` on `run`, walking the same
/// cascade Word itself resolves formatting through: direct run formatting,
/// then the run's character style (`rStyle`) chain, then the enclosing
/// paragraph's style chain, then the document's default paragraph style
/// (conventionally "Normal", identified here by `Style.isDefault`).
///
/// Theme font references (`w:asciiTheme` / `w:hAnsiTheme` / …) are out of
/// scope: `OOXMLSwift.RFontsProperties` has no field for them at all, so a
/// run naming a font only via a theme reference resolves to `nil` here —
/// which this file treats as "nothing declared" (§ `glyphCoverageAdvisories`
/// skips it), never as a false claim about a font that was never measured.
///
/// Returns `nil` when no font is declared anywhere in the cascade.
func resolveDeclaredFont(
    run: Run, paragraphStyleId: String?, doc: WordDocument, slot: FontSlot
) -> String? {
    if let v = declaredFont(in: run.properties, slot: slot) { return v }

    if let rStyleId = run.properties.rStyle {
        for style in doc.getStyleInheritanceChain(styleId: rStyleId) {
            if let v = declaredFont(in: style.runProperties, slot: slot) { return v }
        }
    }

    if let pStyleId = paragraphStyleId {
        for style in doc.getStyleInheritanceChain(styleId: pStyleId) {
            if let v = declaredFont(in: style.runProperties, slot: slot) { return v }
        }
    }

    if let defaultId = defaultParagraphStyleId(doc: doc), defaultId != paragraphStyleId {
        for style in doc.getStyleInheritanceChain(styleId: defaultId) {
            if let v = declaredFont(in: style.runProperties, slot: slot) { return v }
        }
    }

    return nil
}

private func declaredFont(in props: RunProperties?, slot: FontSlot) -> String? {
    guard let props else { return nil }
    if let rFonts = props.rFonts {
        let axisValue: String?
        switch slot {
        case .ascii: axisValue = rFonts.ascii
        case .hAnsi: axisValue = rFonts.hAnsi
        case .eastAsia: axisValue = rFonts.eastAsia
        case .cs: axisValue = rFonts.cs
        }
        if let axisValue { return axisValue }
    }
    // Legacy single-axis field mirrors to all four axes when written
    // (`RunProperties.toXML()`), so it answers for any slot equally.
    return props.fontName
}

private func defaultParagraphStyleId(doc: WordDocument) -> String? {
    doc.styles.first(where: { $0.type == .paragraph && $0.isDefault })?.id
}

/// Computes advisories for one completed `replace_text` / `replace_text_batch`
/// replacement. `doc` must already reflect the finished mutation — this
/// walks the current (post-replace) state looking for runs whose text now
/// contains `replacement` verbatim.
///
/// **Scope**: body paragraphs and table cells always; headers and footers
/// are also scanned when `scope == .all` — matching the reach
/// `WordDocument.replaceText` itself has under that same scope value.
/// Footnotes and endnotes are NOT scanned in this round. That is a
/// documented residual (see the #255 closing report), not a silent gap.
///
/// **Run identification is a heuristic, not a trace.** `WordDocument
/// .replaceText` returns only a match count, no run identity, so "which
/// run(s) just received the new text" is approximated as "any run whose
/// current text contains `replacement` as a substring". This can
/// occasionally flag a run that already contained matching text before
/// this call — but that direction of error is harmless: it can only
/// produce an extra, still-true advisory about a real font/character
/// pairing in the document, never suppress a real one.
func glyphCoverageAdvisories(doc: WordDocument, replacement: String, scope: ReplaceScope) -> [String] {
    guard !replacement.isEmpty else { return [] }
    let scalars = Array(Set(replacement.unicodeScalars))
    guard !scalars.isEmpty else { return [] }

    var seenKeys = Set<String>()
    var advisories: [String] = []

    func consider(run: Run, paragraphStyleId: String?) {
        // Field runs / drawings carry no comparable "text" in the sense a
        // replacement could have landed in — same exclusion
        // `TextReplacementEngine.isTextRun` uses.
        guard run.rawXML == nil, run.drawing == nil else { return }
        guard run.text.contains(replacement) else { return }
        for scalar in scalars {
            let slot = effectiveFontSlot(for: scalar)
            guard let declared = resolveDeclaredFont(
                run: run, paragraphStyleId: paragraphStyleId, doc: doc, slot: slot
            ), !declared.isEmpty else { continue }

            let key = "\(scalar.value)|\(slot.rawValue)|\(declared)"
            guard !seenKeys.contains(key) else { continue }

            guard case .noGlyph(let resolvedFont) = GlyphCoverageProbe.coverage(of: scalar, declaredFont: declared) else {
                // .hasGlyph -> nothing to warn about.
                // .unknown  -> B1: never reported as "no glyph".
                continue
            }
            seenKeys.insert(key)
            advisories.append(glyphAdvisoryMessage(scalar: scalar, declaredFont: declared, resolvedFont: resolvedFont))
        }
    }

    func walkParagraphs(_ paragraphs: [Paragraph]) {
        for para in paragraphs {
            for run in para.runs { consider(run: run, paragraphStyleId: para.properties.style) }
        }
    }

    func walk(_ children: [BodyChild]) {
        for child in children {
            switch child {
            case .paragraph(let para):
                walkParagraphs([para])
            case .table(let table):
                for row in table.rows {
                    for cell in row.cells {
                        walkParagraphs(cell.paragraphs)
                    }
                }
            case .contentControl(_, let inner):
                walk(inner)
            case .bookmarkMarker, .rawBlockElement:
                continue
            }
        }
    }

    walk(doc.body.children)
    if scope == .all {
        for header in doc.headers { walk(header.bodyChildren) }
        for footer in doc.footers { walk(footer.bodyChildren) }
    }

    return advisories
}

private func glyphAdvisoryMessage(scalar: Unicode.Scalar, declaredFont: String, resolvedFont: String) -> String {
    let codepoint = String(format: "U+%04X", scalar.value)
    let sameFont = resolvedFont.compare(declaredFont, options: [.caseInsensitive]) == .orderedSame
    let fontDescription = sameFont
        ? "declared font '\(declaredFont)'"
        : "declared font '\(declaredFont)' (resolved locally to '\(resolvedFont)')"
    return "replacement text contains \(codepoint) (\(String(scalar))), which has no glyph in the "
        + "\(fontDescription) — a renderer will substitute a different font/face for it, which is how "
        + "checkbox ticks silently break (#189). If a checkbox mark was intended, U+25A0 (■) is confirmed "
        + "to have a glyph in Times New Roman, Arial, and common CJK fonts. This measured only the font's "
        + "regular/upright face, not this run's bold/italic, and only this machine's installed fonts, not "
        + "the reader's; font-name resolution also accepts a match by family, full, PostScript, or "
        + "localized name, so a rare cross-name collision could name a different font than the one intended."
}
