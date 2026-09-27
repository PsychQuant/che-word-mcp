import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// che-word-mcp#168 — the ungated Layer-1 fixture used everywhere else in
/// `ScriptPipelineParityTests` (`makeFiveLayerDocx`) is authoring-built:
/// produced and read back through the SAME ooxml-swift writer/reader pair,
/// so it can only ever exercise parts that pair already agrees on. Real
/// Word documents carry raw-channel content nothing in this repo's own
/// writer ever produces on its own (`DocxWriter`'s own doc comment names
/// theme/webSettings/people/glossary as its overlay mode's reason for
/// existing) — until now, verifying THAT was exclusively the job of the
/// env-gated `testCLICrossCheckAgainstMacdocBinary` /
/// `testGetScriptCoverageJPATemplateParity` tests, both of which need a
/// private JPA template that never runs in CI.
///
/// `ScriptPipelineFixtures.writeWordStyleFixture` builds a diverse
/// typed-model document (heading, numbered list, bookmark, comment, table)
/// through `WordDocument`'s own authoring API, then injects two genuinely
/// foreign parts (`word/theme/theme1.xml`, `word/webSettings.xml`) from
/// committed, plain-text, standard-boilerplate XML — see that function's
/// doc comment for why this is the "自己手寫最小 XML" substitute for an
/// actual Word-produced document rather than a real one.
///
/// These tests are UNGATED — no environment variable, no private template,
/// no macdoc CLI binary — so they run in every `swift test` invocation,
/// including CI.
final class Issue168CommittableWordStyleFixtureTests: XCTestCase {

    private func makeScratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("i168-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Premise check: the fixture actually carries the two typed-model-
    /// unmanaged parts the rest of this file is testing preservation of. If
    /// this fails, the fixture construction changed shape and every other
    /// test in this file is testing nothing.
    func testFixturePremiseCarriesTheInjectedRawChannelParts() throws {
        let dir = try makeScratch()
        let source = dir.appendingPathComponent("fixture.docx")
        try ScriptPipelineFixtures.writeWordStyleFixture(to: source)

        let parts = try RawPartChannel.readAllParts(from: source)
        XCTAssertNotNil(parts["word/theme/theme1.xml"], "premise: injected theme part must be present")
        XCTAssertNotNil(parts["word/webSettings.xml"], "premise: injected webSettings part must be present")
        let themeXML = String(decoding: parts["word/theme/theme1.xml"] ?? Data(), as: UTF8.self)
        XCTAssertTrue(themeXML.contains("<a:theme"), "premise: theme part must be real theme XML: \(themeXML.prefix(80))")

        // And the typed-model diversity this fixture adds over the other
        // ungated fixture (numbering / bookmark / comment / table).
        let doc = try DocxReader.read(from: source)
        XCTAssertFalse(doc.numbering.abstractNums.isEmpty, "premise: fixture must carry a numbering definition")
        XCTAssertFalse(doc.comments.comments.isEmpty, "premise: fixture must carry a comment")
        let hasBookmark = doc.body.children.contains { child in
            if case .paragraph(let p) = child { return !p.bookmarks.isEmpty }
            return false
        }
        XCTAssertTrue(hasBookmark, "premise: fixture must carry a bookmark")
    }

    /// The reverse → execute → Stage-B round trip
    /// (`ScriptPipelineParityTests.testExportExecuteRoundTripIsByteEqual`'s
    /// exact shape) against THIS fixture, run ungated. The typed-model
    /// content (document.xml) must survive; separately, the genuinely
    /// foreign raw-channel parts must survive byte-for-byte through
    /// overlay-mode preservation — the thing an authoring-built-only
    /// fixture structurally cannot test.
    func testReverseExecuteRoundTripIsByteEqualIncludingRawChannelParts() throws {
        let dir = try makeScratch()
        let source = dir.appendingPathComponent("fixture.docx")
        try ScriptPipelineFixtures.writeWordStyleFixture(to: source)
        let script = dir.appendingPathComponent("fixture.mdocx.swift")
        let rebuilt = dir.appendingPathComponent("rebuilt.docx")

        _ = try scriptPipelineExport(sourcePath: source.path, outputPath: script.path)
        let result = try scriptPipelineExecute(
            scriptPath: script.path, outputPath: rebuilt.path, verifyAgainst: source.path)
        XCTAssertEqual(result.verified, true, "Stage B must verify byte-equal")
        XCTAssertTrue(result.brokenParts.isEmpty, "broken: \(result.brokenParts)")

        // Independent check, never trusting only the handler's own verdict
        // (same discipline as ScriptPipelineParityTests) — and specifically
        // naming the two raw-channel parts so a future writer regression
        // that silently drops unmanaged parts fails HERE, not just on the
        // aggregate PartFidelity.stageB check below.
        let ref = try RawPartChannel.readAllParts(from: source)
        let reb = try RawPartChannel.readAllParts(from: rebuilt)
        // XCTUnwrap, not XCTAssertEqual on the Optionals directly: two absent
        // parts on both sides would otherwise compare nil == nil and pass
        // vacuously, hiding a regression where NEITHER side carries the
        // part at all (verified empirically: mutating the fixture builder
        // to skip injection left this exact assertion pair silently green).
        let refTheme = try XCTUnwrap(ref["word/theme/theme1.xml"], "reference fixture must carry the injected theme part")
        let refWebSettings = try XCTUnwrap(ref["word/webSettings.xml"], "reference fixture must carry the injected webSettings part")
        XCTAssertEqual(try XCTUnwrap(reb["word/theme/theme1.xml"], "rebuilt package lost the theme part"), refTheme,
                       "the injected theme part (typed-model-unmanaged) must survive byte-equal")
        XCTAssertEqual(try XCTUnwrap(reb["word/webSettings.xml"], "rebuilt package lost the webSettings part"), refWebSettings,
                       "the injected webSettings part (typed-model-unmanaged) must survive byte-equal")
        XCTAssertTrue(PartFidelity.stageB(reference: ref, rebuilt: reb))
    }

    /// Same round trip through the MCP tool surface
    /// (`export_script` / `execute_script`), matching
    /// `ScriptPipelineParityTests.testExportScriptToolWritesScriptAndReportsSummary`
    /// + `testExecuteScriptToolVerifiesByteEqual`'s shape, but against a
    /// fixture with genuinely foreign raw-channel content.
    func testMCPToolSurfaceRoundTripIsByteEqual() async throws {
        let dir = try makeScratch()
        let source = dir.appendingPathComponent("fixture.docx")
        try ScriptPipelineFixtures.writeWordStyleFixture(to: source)
        let script = dir.appendingPathComponent("out.mdocx.swift")
        let rebuilt = dir.appendingPathComponent("rebuilt.docx")

        let server = await WordMCPServer()
        let export = await server.invokeToolForTesting(name: "export_script", arguments: [
            "source_path": .string(source.path),
            "output_path": .string(script.path),
        ])
        func resultText(_ result: CallTool.Result) -> String {
            guard let first = result.content.first else { return "" }
            if case .text(let text, _, _) = first { return text }
            return ""
        }
        XCTAssertNotEqual(export.isError, true, resultText(export))

        let exec = await server.invokeToolForTesting(name: "execute_script", arguments: [
            "script_path": .string(script.path),
            "output_path": .string(rebuilt.path),
            "verify_byte_equal_against": .string(source.path),
        ])
        XCTAssertNotEqual(exec.isError, true, resultText(exec))
        XCTAssertTrue(resultText(exec).contains("\"verified\":true"), resultText(exec))
        XCTAssertTrue(resultText(exec).contains("\"broken_parts\":[]"), resultText(exec))
    }
}
