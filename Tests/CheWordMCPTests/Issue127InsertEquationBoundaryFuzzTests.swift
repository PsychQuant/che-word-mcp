import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#127 — defense-in-depth test for the
/// `paragraphIndex!` force-unwrap removed in `insertEquation`'s inline-mode
/// branch. The source-grep pin lives in
/// `Issue98InsertEquationLibBypassTests.testInsertEquationSourceNoLongerForceUnwrapsParagraphIndex`;
/// this file is the runtime half the issue asked for: "加 fuzzing test：對
/// insert_equation 隨機餵 args（包括 nil paragraph_index + display_mode=false
/// 各種組合），確認永遠不會 crash".
///
/// A force-unwrap panic does NOT surface as a failed assertion — it aborts
/// the whole XCTest process. So this test's real signal is that it *runs to
/// completion* at all; the per-call assertions below just additionally
/// confirm each call returns a well-formed result (success or a structured
/// error), never silence.
final class Issue127InsertEquationBoundaryFuzzTests: XCTestCase {

    private func minimalDocxFiveParas() throws -> URL {
        var doc = WordDocument()
        for i in 0..<5 {
            doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "para\(i)")])))
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue127_eq_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    /// Every `display_mode` × `paragraph_index` combination near every
    /// boundary the handler checks: absent, negative, zero, in-range,
    /// exactly at the top-level paragraph count / body.children.count (the
    /// asymmetric append-at-end boundary — #123), and past it.
    func testInsertEquationBoundaryArgSweepNeverCrashes() async throws {
        let paragraphIndices: [Value?] = [nil, .int(-1), .int(0), .int(4), .int(5), .int(6), .int(9999)]

        for displayMode in [true, false] {
            for pIdx in paragraphIndices {
                // Fresh document per call so earlier successful inserts in
                // this sweep don't change later calls' bounds.
                let url = try minimalDocxFiveParas()
                defer { try? FileManager.default.removeItem(at: url) }
                let server = await WordMCPServer()
                let docId = "e127-\(UUID().uuidString)"

                _ = await server.invokeToolForTesting(
                    name: "open_document",
                    arguments: ["path": .string(url.path), "doc_id": .string(docId)]
                )

                var args: [String: Value] = [
                    "doc_id": .string(docId),
                    "latex": .string("x"),
                    "display_mode": .bool(displayMode)
                ]
                if let pIdx { args["paragraph_index"] = pIdx }

                // If this call force-unwraps a nil and traps, the process
                // aborts here and the whole test suite fails loudly — that
                // IS the test. Reaching the assertion below is already part
                // of the signal.
                let r = await server.invokeToolForTesting(name: "insert_equation", arguments: args)
                XCTAssertFalse(
                    r.content.isEmpty,
                    "insert_equation must always return content (success or structured error), never empty — display_mode=\(displayMode), paragraph_index=\(String(describing: pIdx))"
                )
            }
        }
    }
}
