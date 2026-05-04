import XCTest
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#136 — `find_inline_math_gaps` caption detection
/// must use `Paragraph.style` as primary signal + handle expanded prefix set
/// (Tab. / Fig. / 圖 / U+3000 ideographic space / 表3-1 no-separator forms).
///
/// Verify finding from #112: text-only heuristic produced false negatives
/// (Figure 1 / Tab. 1 / 表3-1 / 表　1 / Caption-styled body text) AND
/// false positives ("Table reservations are required..." mistaken as caption).
///
/// Two-layer detection:
/// - Layer 1: `paragraph.properties.style?.lowercased().contains("caption")` (primary, ground truth)
/// - Layer 2: expanded text prefix fallback (when style absent)
final class Issue136CaptionDetectionTests: XCTestCase {

    // MARK: - Helpers

    private func paragraph(text: String, style: String? = nil) -> Paragraph {
        var para = Paragraph(runs: [Run(text: text)])
        if let style {
            para.properties.style = style
        }
        return para
    }

    // MARK: - Layer 1 (style-based) tests

    func testCaptionStyleSkippedRegardlessOfText() async throws {
        let server = await WordMCPServer()
        // Body text doesn't look like caption, but style says it is.
        let para = paragraph(text: "Some statistics here", style: "Caption")
        let isCaption = await server.isLikelyTableCaption(para)
        XCTAssertTrue(isCaption,
            "Paragraph with style='Caption' should be detected as caption regardless of body text content")
    }

    func testImageCaptionStyleSkipped() async throws {
        let server = await WordMCPServer()
        let para = paragraph(text: "本圖示意架構", style: "ImageCaption")
        let isCaption = await server.isLikelyTableCaption(para)
        XCTAssertTrue(isCaption,
            "Paragraph with style='ImageCaption' (substring 'caption') should be detected")
    }

    func testTableCaptionStyleCaseInsensitive() async throws {
        let server = await WordMCPServer()
        // Lower-case style name (some imports use lowercased ids)
        let para = paragraph(text: "Description without prefix", style: "tablecaption")
        let isCaption = await server.isLikelyTableCaption(para)
        XCTAssertTrue(isCaption,
            "Style match should be case-insensitive (lowercased contains 'caption')")
    }

    func testHeadingStyleNotSkippedDespiteTablePrefix() async throws {
        let server = await WordMCPServer()
        // Style says heading; text accidentally starts with "table" (e.g. "Table of contents")
        let para = paragraph(text: "Table of contents", style: "Heading 1")
        let isCaption = await server.isLikelyTableCaption(para)
        XCTAssertFalse(isCaption,
            "Heading-styled paragraph must NOT be skipped even if text starts with 'table'")
    }

    // MARK: - Layer 2 (prefix fallback) tests — no style set

    func testFigurePrefixSkipped() async throws {
        let server = await WordMCPServer()
        let para = paragraph(text: "Figure 1: model architecture")
        let isCaption = await server.isLikelyTableCaption(para)
        XCTAssertTrue(isCaption,
            "'Figure 1' prefix (no style) must be detected as caption")
    }

    func testTabAbbreviationPrefixSkipped() async throws {
        let server = await WordMCPServer()
        let para = paragraph(text: "Tab. 1 — Summary statistics")
        let isCaption = await server.isLikelyTableCaption(para)
        XCTAssertTrue(isCaption,
            "'Tab. ' (English journal abbreviation) prefix must be detected")
    }

    func testFigAbbreviationPrefixSkipped() async throws {
        let server = await WordMCPServer()
        let para = paragraph(text: "Fig. 2: experimental setup")
        let isCaption = await server.isLikelyTableCaption(para)
        XCTAssertTrue(isCaption, "'Fig. ' (English journal abbreviation) prefix must be detected")
    }

    func testListingPrefixSkipped() async throws {
        let server = await WordMCPServer()
        let para = paragraph(text: "Listing 1: example code")
        let isCaption = await server.isLikelyTableCaption(para)
        XCTAssertTrue(isCaption, "'Listing 1' (code-listing convention) must be detected")
    }

    func testIdeographicSpacePrefixSkipped() async throws {
        let server = await WordMCPServer()
        // U+3000 ideographic space (CJK common)
        let para = paragraph(text: "表\u{3000}1：實驗結果")
        let isCaption = await server.isLikelyTableCaption(para)
        XCTAssertTrue(isCaption,
            "'表' + U+3000 ideographic space prefix must be detected (CJK common usage)")
    }

    func testCJKDirectDigitPrefixTable() async throws {
        let server = await WordMCPServer()
        // No separator: 表3-1 (academic CJK common)
        let para = paragraph(text: "表3-1：模型參數")
        let isCaption = await server.isLikelyTableCaption(para)
        XCTAssertTrue(isCaption, "'表3-1' (no-separator CJK form) must be detected")
    }

    func testCJKDirectDigitPrefixFigure() async throws {
        let server = await WordMCPServer()
        let para = paragraph(text: "圖1.2 系統架構")
        let isCaption = await server.isLikelyTableCaption(para)
        XCTAssertTrue(isCaption, "'圖1.2' (no-separator CJK form) must be detected")
    }

    func testSimplifiedChineseFigurePrefix() async throws {
        let server = await WordMCPServer()
        // Simplified Chinese 图 (U+56FE)
        let para = paragraph(text: "图 1：算法流程")
        let isCaption = await server.isLikelyTableCaption(para)
        XCTAssertTrue(isCaption, "Simplified Chinese '图 1' must be detected")
    }

    // MARK: - Negative cases (false-positive guard)

    func testTableBodyTextNotSkipped() async throws {
        let server = await WordMCPServer()
        // Body sentence starting with "Table " but NOT followed by a digit.
        // Pre-#136-fix: was incorrectly skipped (false positive).
        // Post-fix: digit-after-prefix guard rejects this (Layer 2 returns false).
        let para = paragraph(text: "Table reservations are required for groups of 6 or more.")
        let isCaption = await server.isLikelyTableCaption(para)
        XCTAssertFalse(isCaption,
            "'Table ' prefix without digit follow-up (e.g. 'Table reservations...') " +
            "must NOT be detected as caption. Real captions are 'Table 1', 'Table 2-1', etc.")
    }

    func testFigureShowsThatNotSkipped() async throws {
        let server = await WordMCPServer()
        // Body sentence starting with "Figure " but no digit
        let para = paragraph(text: "Figure shows that the trend is increasing.")
        let isCaption = await server.isLikelyTableCaption(para)
        XCTAssertFalse(isCaption,
            "'Figure ' followed by non-digit text must NOT be detected (Layer 2 digit guard)")
    }

    func testNonCaptionTextWithoutPrefixNotSkipped() async throws {
        let server = await WordMCPServer()
        let para = paragraph(text: "This is a regular paragraph with no caption hints.")
        let isCaption = await server.isLikelyTableCaption(para)
        XCTAssertFalse(isCaption,
            "Plain body text without caption prefix and without style must NOT be skipped")
    }

    func testCJKBodyTextWithoutDigit() async throws {
        let server = await WordMCPServer()
        // 表面 = "surface" — body word, not a caption
        let para = paragraph(text: "表面溫度需要保持穩定")
        let isCaption = await server.isLikelyTableCaption(para)
        XCTAssertFalse(isCaption,
            "'表面' (surface) starts with 表 but second char is not digit → not a caption. " +
            "Same guard for 圖案/图案 etc.")
    }

    func testEmptyParagraph() async throws {
        let server = await WordMCPServer()
        let para = paragraph(text: "")
        let isCaption = await server.isLikelyTableCaption(para)
        XCTAssertFalse(isCaption, "Empty paragraph must NOT be detected as caption")
    }
}
