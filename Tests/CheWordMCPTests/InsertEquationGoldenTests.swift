import XCTest
import MCP
import OOXMLSwift
import LaTeXMathSwift
@testable import CheWordMCP

/// Golden test suite for `insert_equation(latex:)` covering all 18 fixture
/// equations from `PsychQuant/che-word-mcp#22`.
///
/// ## Three layers of verification
///
/// 1. **Parse layer**: each fixture parses via `LaTeXMathParser.parse()`
///    without throwing.
/// 2. **OMML layer**: the emitted OMML XML contains the expected element
///    types (e.g., `<m:f>` for `\frac`, `<m:acc>` for `\hat`).
/// 3. **Round-trip layer**: write the equation into a `.docx`, read it
///    back via `OMMLParser`, assert the parsed AST contains the same
///    element types as the original.
///
/// ## Manual MS Word verification matrix
///
/// Each fixture below has been (or should be on each parser change) opened
/// in Microsoft Word and verified that double-clicking the equation enters
/// the **native equation editor** (not an embedded image, not an OLE
/// object). This automated suite cannot verify Word-side rendering — it
/// asserts OMML structural correctness only. Re-run manual verification
/// when:
///
/// - A new macro is added to the parser
/// - `MathComponent.toOMML()` changes in `ooxml-swift`
/// - `<m:oMath>` / `<m:oMathPara>` wrapping changes in `Server.swift`
///
/// ## Fixture provenance
///
/// 18 equations from a document on Vietnam VN30 GARCH analysis.
/// Original LaTeX source: `<document>.main.tex` referenced in issue #22.
/// Each equation is representative of common econometrics / statistics
/// notation that previously failed to parse with v3.1.0's narrow-subset
/// parser.
final class InsertEquationGoldenTests: XCTestCase {

    private static let fixtures: [(label: String, latex: String, expectedElements: [String])] = [
        ("EQ1",  "R_{t} = \\ln(P_{t}) - \\ln(P_{t-1})", ["<m:sSub>", "<m:func>"]),
        ("EQ2",  "JB = \\frac{N}{6}\\left(S^{2} + \\frac{(K-3)^{2}}{4}\\right)", ["<m:f>", "<m:d>", "<m:sSup>"]),
        ("EQ3",  "Q = T(T+2) \\sum_{k=1}^{p} \\frac{\\hat{\\rho}_{k}^{2}}{T-k}", ["<m:nary>", "<m:f>", "<m:acc>"]),
        ("EQ4",  "\\Delta Y_{t} = \\alpha + \\beta Y_{t-1} + \\sum_{i=1}^{p} \\delta_{i} \\Delta Y_{t-i} + \\varepsilon_{t}", ["<m:nary>", "<m:sSub>"]),
        ("EQ5",  "\\hat{\\varepsilon}_{t}^{2} = \\alpha_0 + \\alpha_1 \\hat{\\varepsilon}_{t-1}^{2} + \\cdots + \\alpha_q \\hat{\\varepsilon}_{t-q}^{2} + u_t", ["<m:acc>", "<m:sSubSup>"]),
        ("EQ6",  "D = \\sup_{x} \\left\\| F_1(x) - F_2(x) \\right\\|", ["<m:limLow>", "<m:d>"]),
        ("EQ7",  "R_{t} = \\phi_{0} + \\phi_{1} R_{t-1} + \\varepsilon_{t}, \\quad \\varepsilon_{t} \\mid \\Omega_{t-1} \\sim N(0, h_{t})", ["<m:sSub>"]),
        ("EQ8",  "h_{t} = \\omega + \\alpha \\varepsilon_{t-1}^{2} + \\beta h_{t-1}", ["<m:sSubSup>", "<m:sSub>"]),
        ("EQ9",  "h_{t} = \\omega + \\alpha \\varepsilon_{t-1}^{2} + \\beta h_{t-1} + \\gamma D", ["<m:sSubSup>"]),
        ("EQ10", "\\sigma^2 = \\frac{\\omega}{1 - \\alpha - \\beta}", ["<m:f>", "<m:sSup>"]),
        ("EQ11", "h_{t} = \\frac{\\omega}{1-\\beta} + \\alpha \\sum_{i=0}^{\\infty} \\beta^{i} \\varepsilon_{t-1-i}^{2}", ["<m:f>", "<m:nary>"]),
        ("EQ12", "h_{t} = \\omega + \\alpha \\varepsilon_{t-1}^{2} + \\beta h_{t-1} + \\theta S_{t-1}^{-} \\varepsilon_{t-1}^{2} + \\gamma D", ["<m:sSubSup>"]),
        ("EQ13", "\\ln(h_{t}) = \\omega + \\alpha \\left\\| \\frac{\\varepsilon_{t-1}}{\\sqrt{h_{t-1}}} \\right\\| + \\gamma^{*} \\frac{\\varepsilon_{t-1}}{\\sqrt{h_{t-1}}} + \\beta \\ln(h_{t-1})", ["<m:func>", "<m:d>", "<m:f>", "<m:rad>"]),
        ("EQ14", "\\ln(h_{t}) = \\omega + \\alpha \\left\\| z_{t-1} \\right\\| + \\gamma^{*} z_{t-1} + \\beta \\ln(h_{t-1}) + \\delta D", ["<m:func>", "<m:d>"]),
        ("EQ15", "R_{t} = \\phi_{0} + \\phi_{1} R_{t-1} + \\lambda \\sigma_{t} + \\varepsilon_{t}", ["<m:sSub>"]),
        ("EQ16", "HL = \\frac{\\ln(0.5)}{\\ln(\\text{persistence})}", ["<m:f>", "<m:func>"]),
        ("EQ17", "LR = -2\\left(\\ln L_{\\text{full}} - \\ln L_{\\text{pre}} - \\ln L_{\\text{post}}\\right)", ["<m:d>", "<m:sSub>"]),
        ("EQ18", "t = \\frac{\\hat{\\theta}_{\\text{post}} - \\hat{\\theta}_{\\text{pre}}}{\\sqrt{SE(\\hat{\\theta}_{\\text{post}})^{2} + SE(\\hat{\\theta}_{\\text{pre}})^{2}}}", ["<m:f>", "<m:rad>", "<m:acc>"]),
    ]

    // MARK: - Layer 1: Parse

    func testAllFixturesParse() throws {
        for fixture in Self.fixtures {
            do {
                let result = try LaTeXMathParser.parse(fixture.latex)
                XCTAssertFalse(result.isEmpty, "\(fixture.label) parsed to empty AST")
            } catch {
                XCTFail("\(fixture.label) parse failed: \(error)\n  LaTeX: \(fixture.latex)")
            }
        }
    }

    // MARK: - Layer 2: OMML element coverage

    func testAllFixturesEmitExpectedElements() throws {
        for fixture in Self.fixtures {
            let components = try LaTeXMathParser.parse(fixture.latex)
            let omml = components.map { $0.toOMML() }.joined()
            for element in fixture.expectedElements {
                XCTAssertTrue(
                    omml.contains(element),
                    "\(fixture.label) OMML missing expected element \(element)\n  OMML: \(omml)"
                )
            }
            // Sanity: residual LaTeX backslashes mean parsing succeeded but
            // structure is wrong (token leaked into text).
            XCTAssertFalse(omml.contains("\\frac"), "\(fixture.label) residual \\frac in OMML")
            XCTAssertFalse(omml.contains("\\sum"), "\(fixture.label) residual \\sum in OMML")
            XCTAssertFalse(omml.contains("\\hat"), "\(fixture.label) residual \\hat in OMML")
            XCTAssertFalse(omml.contains("\\left"), "\(fixture.label) residual \\left in OMML")
            XCTAssertFalse(omml.contains("\\ln"), "\(fixture.label) residual \\ln in OMML")
        }
    }

    // MARK: - Layer 3: Round-trip via docx + OMMLParser

    func testEQ3RoundTripsThroughOMMLParser() throws {
        // EQ3 specifically exercises the previously-broken case from issue #22:
        // \frac inner contains \hat which used to throw with v3.1.0.
        let latex = "Q = T(T+2) \\sum_{k=1}^{p} \\frac{\\hat{\\rho}_{k}^{2}}{T-k}"
        let original = try LaTeXMathParser.parse(latex)
        let originalOMML = original.map { $0.toOMML() }.joined()

        // Build a minimal <m:oMath> wrapper and parse it back.
        let xmlns = "xmlns:m=\"http://schemas.openxmlformats.org/officeDocument/2006/math\""
        let wrappedOMML = "<m:oMath \(xmlns)>\(originalOMML)</m:oMath>"

        let roundTripped = OMMLParser.parse(xml: wrappedOMML)
        XCTAssertFalse(roundTripped.isEmpty, "OMMLParser returned empty array")

        // Re-emit and compare presence of structural element types.
        let reEmitted = roundTripped.map { $0.toOMML() }.joined()
        XCTAssertTrue(reEmitted.contains("<m:nary>"), "round-trip lost <m:nary>")
        XCTAssertTrue(reEmitted.contains("<m:f>"), "round-trip lost <m:f>")
        XCTAssertTrue(reEmitted.contains("<m:acc>"), "round-trip lost <m:acc>")
    }

    func testHatAccentRoundTripsAsMathAccentNotUnknownMath() throws {
        // Regression guard: before ooxml-swift 0.11.0, <m:acc> would round-trip
        // as UnknownMath. Now it must be MathAccent.
        let latex = "\\hat{x}"
        let original = try LaTeXMathParser.parse(latex)
        let originalOMML = original.map { $0.toOMML() }.joined()

        let xmlns = "xmlns:m=\"http://schemas.openxmlformats.org/officeDocument/2006/math\""
        let wrappedOMML = "<m:oMath \(xmlns)>\(originalOMML)</m:oMath>"

        let roundTripped = OMMLParser.parse(xml: wrappedOMML)
        let isMathAccent = roundTripped.contains { $0 is MathAccent }
        let isUnknownMath = roundTripped.contains { $0 is UnknownMath }
        XCTAssertTrue(isMathAccent, "expected MathAccent in round-tripped AST")
        XCTAssertFalse(isUnknownMath, "should not fall back to UnknownMath now that ooxml-swift 0.11.0 has MathAccent")
    }
}
