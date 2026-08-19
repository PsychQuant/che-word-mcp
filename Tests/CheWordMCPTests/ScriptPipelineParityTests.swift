// ScriptPipelineParityTests.swift
// Spectra change che-word-mcp-script-pipeline-parity, tasks 3.1–3.5
// (`che-word-mcp-script-pipeline-tools`, «Two-layer parity guard»).
//
// Layer 1 (this file, ungated — always runs in CI): the MCP handler
// functions ride the exact ooxml-swift transcoder code path the macdoc CLI
// uses (design Decision 1 — thin wrappers, zero reimplemented logic), so an
// in-process export → execute round trip must reproduce the reference docx
// Stage-B byte-equal. Layer 2 (gated cross-check vs the real CLI binary)
// lives in testCLICrossCheck below, behind MACDOC_TEMPLATE_DIR +
// MACDOC_CLI_PATH.

import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

final class ScriptPipelineParityTests: XCTestCase {

    // MARK: - Fixtures

    /// Synthetic five-layer authoring-built docx (text+style, run formatting,
    /// paragraph formatting, tables, sections) — the DSL-channel upgrade set,
    /// public-API spelling of ooxml-swift's UpgradeClassGuardTests classes.
    private func makeFiveLayerDocx(at url: URL) throws {
        var doc = WordDocument.emptyAuthoringDocument()
        try doc.apply(operations: [
            .appendParagraph(in: nil, paragraph: ParagraphPayload(
                text: "見出しと本文", styleId: "Heading1", paraId: "P1")),
            .appendParagraph(in: nil, paragraph: ParagraphPayload(text: "", paraId: "P2")),
            .setRuns(target: ElementID(rawString: "w14:paraId=P2"), runs: [
                RunPayload(text: "ゴシック", bold: true, italic: true, color: "336699",
                           fontAscii: "Times New Roman", fontEastAsia: "ＭＳ ゴシック",
                           sizeHalfPoints: 21, underline: "single", vertAlign: "superscript"),
            ]),
            .appendParagraph(in: nil, paragraph: ParagraphPayload(
                text: "整形段落", paraId: "P3", alignment: "center",
                spacingBefore: 100, spacingAfter: 200, spacingLine: 240,
                spacingLineRule: "auto", indentLeft: 720, indentHanging: 360)),
            .appendTable(in: nil, table: TablePayload(rows: 2, columns: 2, cells: [
                ["a", "b"], ["c", "d"],
            ])),
            .setSectionProperties(at: nil, section: SectionPayload(
                pageWidth: 11906, pageHeight: 16838, columnSpace: 708)),
        ])
        try doc.writeAuthoringPackage(to: url)
    }

    private func makeScratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("script-pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: - Layer 1: ungated in-process parity (task 3.1)

    /// Spec scenario "Ungated parity always runs": export → execute through
    /// the handler functions reproduces the reference byte-equal.
    func testExportExecuteRoundTripIsByteEqual() throws {
        let dir = try makeScratch()
        let source = dir.appendingPathComponent("reference.docx")
        try makeFiveLayerDocx(at: source)
        let script = dir.appendingPathComponent("reference.mdocx.swift")
        let rebuilt = dir.appendingPathComponent("rebuilt.docx")

        let summary = try scriptPipelineExport(
            sourcePath: source.path, outputPath: script.path)
        XCTAssertTrue(summary.dslParts.contains("word/document.xml"),
                      "authoring-built document.xml must ride the DSL channel")
        XCTAssertTrue(summary.formGapsEmpty, "no form gaps expected on the synthetic fixture")
        XCTAssertEqual(summary.slotCount, 0)

        let result = try scriptPipelineExecute(
            scriptPath: script.path, outputPath: rebuilt.path,
            verifyAgainst: source.path)
        XCTAssertEqual(result.verified, true, "Stage B must verify byte-equal")
        XCTAssertTrue(result.brokenParts.isEmpty,
                      "broken: \(result.brokenParts)")

        // Independent check — never trust only the handler's own verdict.
        let ref = try RawPartChannel.readAllParts(from: source)
        let reb = try RawPartChannel.readAllParts(from: rebuilt)
        XCTAssertTrue(PartFidelity.stageB(reference: ref, rebuilt: reb))
    }

    // MARK: - MCP tool layer (task 3.2 — export_script)

    private func resultText(_ result: CallTool.Result) -> String {
        guard let first = result.content.first else { return "" }
        if case .text(let text, _, _) = first { return text }
        return ""
    }

    /// export_script registers and reports the Decision 2 summary shape.
    func testExportScriptToolWritesScriptAndReportsSummary() async throws {
        let dir = try makeScratch()
        let source = dir.appendingPathComponent("reference.docx")
        try makeFiveLayerDocx(at: source)
        let script = dir.appendingPathComponent("out.mdocx.swift")

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(name: "export_script", arguments: [
            "source_path": .string(source.path),
            "output_path": .string(script.path),
        ])
        XCTAssertNotEqual(result.isError, true, resultText(result))
        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path),
                      "script must be written")
        let text = resultText(result)
        XCTAssertTrue(text.contains("word/document.xml"),
                      "summary must list DSL parts; got: \(text)")
        XCTAssertTrue(text.contains("\"slot_count\":0"),
                      "summary must carry slot_count; got: \(text)")
        XCTAssertTrue(text.contains("\"form_gaps_empty\":true"),
                      "summary must carry form-gap emptiness; got: \(text)")
    }

    /// Spec scenario "Strict slot failure surfaces as a tool error": unknown
    /// paragraph id → MCP error naming the slot, and NO script file written.
    func testExportScriptToolStrictSlotFailureWritesNothing() async throws {
        let dir = try makeScratch()
        let source = dir.appendingPathComponent("reference.docx")
        try makeFiveLayerDocx(at: source)
        let script = dir.appendingPathComponent("out.mdocx.swift")

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(name: "export_script", arguments: [
            "source_path": .string(source.path),
            "output_path": .string(script.path),
            "slots": .array([.object([
                "name": .string("title"), "para_id": .string("NOPE"),
            ])]),
        ])
        XCTAssertEqual(result.isError, true, "strict designation failure must be a tool error")
        XCTAssertTrue(resultText(result).contains("title"),
                      "error must name the failing slot; got: \(resultText(result))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: script.path),
                       "no script may be written on strict failure")
    }

    // MARK: - MCP tool layer (task 3.3 — get_script_coverage)

    /// Ungated shape test: dual-track rows + aggregate on the synthetic
    /// fixture (document.xml rides dsl at ratio 1.0; sibling parts raw).
    func testGetScriptCoverageToolReportsDualTrack() async throws {
        let dir = try makeScratch()
        let source = dir.appendingPathComponent("reference.docx")
        try makeFiveLayerDocx(at: source)

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(name: "get_script_coverage", arguments: [
            "source_path": .string(source.path),
        ])
        XCTAssertNotEqual(result.isError, true, resultText(result))

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(resultText(result).utf8)) as? [String: Any])
        let parts = try XCTUnwrap(json["parts"] as? [[String: Any]])
        let docRow = try XCTUnwrap(parts.first { $0["part_path"] as? String == "word/document.xml" })
        XCTAssertEqual(docRow["channel"] as? String, "dsl")
        XCTAssertEqual(docRow["dsl_ratio"] as? Double, 1.0)
        XCTAssertTrue(parts.contains { $0["channel"] as? String == "raw" },
                      "sibling parts must report raw")
        let aggregate = try XCTUnwrap(json["aggregate_ratio"] as? Double)
        XCTAssertGreaterThan(aggregate, 0.0)
        XCTAssertLessThan(aggregate, 1.0)
    }

    /// Spec scenario "JPA template coverage parity" (env-gated): document.xml
    /// channel dsl at ratio 1.0; aggregate matches the recorded CLI baseline
    /// (53.5%, docs/format-alignment-baselines.md).
    func testGetScriptCoverageJPATemplateParity() async throws {
        guard let templateDir = ProcessInfo.processInfo.environment["MACDOC_TEMPLATE_DIR"] else {
            throw XCTSkip("set MACDOC_TEMPLATE_DIR to run real-template coverage parity")
        }
        let template = URL(fileURLWithPath: templateDir)
            .appendingPathComponent("90_template_ja.docx")
        guard FileManager.default.fileExists(atPath: template.path) else {
            throw XCTSkip("90_template_ja.docx not present under MACDOC_TEMPLATE_DIR")
        }

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(name: "get_script_coverage", arguments: [
            "source_path": .string(template.path),
        ])
        XCTAssertNotEqual(result.isError, true, resultText(result))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(resultText(result).utf8)) as? [String: Any])
        let parts = try XCTUnwrap(json["parts"] as? [[String: Any]])
        let docRow = try XCTUnwrap(parts.first { $0["part_path"] as? String == "word/document.xml" })
        XCTAssertEqual(docRow["channel"] as? String, "dsl",
                       "JPA document.xml must ride the DSL channel")
        XCTAssertEqual(docRow["dsl_ratio"] as? Double, 1.0)
        let aggregate = try XCTUnwrap(json["aggregate_ratio"] as? Double)
        XCTAssertEqual(aggregate, 0.535, accuracy: 0.01,
                       "aggregate must match the recorded CLI baseline (53.5%)")
    }

    // MARK: - MCP tool layer (task 3.4 — execute_script)

    /// Spec scenario "Rebuild verifies byte-equal against the reference"
    /// through the MCP surface.
    func testExecuteScriptToolVerifiesByteEqual() async throws {
        let dir = try makeScratch()
        let source = dir.appendingPathComponent("reference.docx")
        try makeFiveLayerDocx(at: source)
        let script = dir.appendingPathComponent("out.mdocx.swift")
        let rebuilt = dir.appendingPathComponent("rebuilt.docx")

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "export_script", arguments: [
            "source_path": .string(source.path),
            "output_path": .string(script.path),
        ])
        let result = await server.invokeToolForTesting(name: "execute_script", arguments: [
            "script_path": .string(script.path),
            "output_path": .string(rebuilt.path),
            "verify_byte_equal_against": .string(source.path),
        ])
        XCTAssertNotEqual(result.isError, true, resultText(result))
        let text = resultText(result)
        XCTAssertTrue(text.contains("\"verified\":true"), text)
        XCTAssertTrue(text.contains("\"broken_parts\":[]"), text)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rebuilt.path))
    }

    /// Spec scenario "Slot substitution through the MCP surface": new text
    /// lands at the designated position; every non-slot XML part stays
    /// byte-equal to the reference.
    func testExecuteScriptToolSlotSubstitution() async throws {
        let dir = try makeScratch()
        let source = dir.appendingPathComponent("reference.docx")
        try makeFiveLayerDocx(at: source)
        let script = dir.appendingPathComponent("slotted.mdocx.swift")
        let rebuilt = dir.appendingPathComponent("substituted.docx")

        let server = await WordMCPServer()
        let export = await server.invokeToolForTesting(name: "export_script", arguments: [
            "source_path": .string(source.path),
            "output_path": .string(script.path),
            "slots": .array([.object([
                "name": .string("heading"), "para_id": .string("P1"),
            ])]),
        ])
        XCTAssertNotEqual(export.isError, true, resultText(export))
        XCTAssertTrue(resultText(export).contains("\"slot_count\":1"))

        // Caller substitutes new content at the call site (Swift argument form).
        var scriptText = try String(contentsOfFile: script.path, encoding: .utf8)
        XCTAssertTrue(scriptText.contains("heading: \"見出しと本文\""),
                      "call-site default must carry the extracted text")
        scriptText = scriptText.replacingOccurrences(
            of: "heading: \"見出しと本文\"", with: "heading: \"差し込み新標題\"")
        try scriptText.write(toFile: script.path, atomically: true, encoding: .utf8)

        let result = await server.invokeToolForTesting(name: "execute_script", arguments: [
            "script_path": .string(script.path),
            "output_path": .string(rebuilt.path),
        ])
        XCTAssertNotEqual(result.isError, true, resultText(result))

        let reference = try RawPartChannel.readAllParts(from: source)
        let substituted = try RawPartChannel.readAllParts(from: URL(fileURLWithPath: rebuilt.path))
        let docXML = String(decoding: substituted["word/document.xml"] ?? Data(), as: UTF8.self)
        XCTAssertTrue(docXML.contains("差し込み新標題"), "new slot text must land")
        XCTAssertFalse(docXML.contains("見出しと本文"), "old slot text must be gone")
        for (path, bytes) in reference where path != "word/document.xml" {
            XCTAssertEqual(substituted[path], bytes,
                           "non-slot part \(path) must stay byte-equal")
        }
    }

    // MARK: - Verify R1 fixes (#134 findings B1/B2/F1/F5)

    /// B1: `output_path == verify_byte_equal_against` must compare against
    /// the PRE-write reference bytes — a script that does NOT rebuild the
    /// reference byte-equal must yield verified:false, never the
    /// output-vs-output false positive.
    func testExecuteSamePathVerificationIsNotFalsePositive() throws {
        let dir = try makeScratch()
        let reference = dir.appendingPathComponent("target.docx")
        try makeFiveLayerDocx(at: reference)
        // A DIFFERENT document's script.
        var other = WordDocument.emptyAuthoringDocument()
        try other.apply(operations: [
            .appendParagraph(in: nil, paragraph: ParagraphPayload(text: "別的內容", paraId: "Q1")),
        ])
        let otherDocx = dir.appendingPathComponent("other.docx")
        try other.writeAuthoringPackage(to: otherDocx)
        let script = dir.appendingPathComponent("other.mdocx.swift")
        _ = try scriptPipelineExport(sourcePath: otherDocx.path, outputPath: script.path)

        // Execute the OTHER script with output overwriting the reference,
        // verifying against that same path.
        // `overwrite` is explicit: this pattern necessarily targets a file
        // that already exists, so the gate applies on the same terms as any
        // other pre-existing output.
        let result = try scriptPipelineExecute(
            scriptPath: script.path, outputPath: reference.path,
            verifyAgainst: reference.path, overwrite: true)
        XCTAssertEqual(result.verified, false,
                       "same-path verification must compare against pre-write bytes")
        XCTAssertFalse(result.brokenParts.isEmpty)
    }

    /// B1(b): a mistyped reference path errors BEFORE any output is written.
    func testExecuteMissingReferenceLeavesNoSideEffect() throws {
        let dir = try makeScratch()
        let source = dir.appendingPathComponent("reference.docx")
        try makeFiveLayerDocx(at: source)
        let script = dir.appendingPathComponent("ref.mdocx.swift")
        _ = try scriptPipelineExport(sourcePath: source.path, outputPath: script.path)
        let output = dir.appendingPathComponent("out.docx")

        XCTAssertThrowsError(try scriptPipelineExecute(
            scriptPath: script.path, outputPath: output.path,
            verifyAgainst: dir.appendingPathComponent("typo.docx").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                       "no output may be written when the reference path is invalid")
    }

    /// B2: script parse failures surface the transcoder's location-bearing
    /// reason through the MCP error (task 3.4 contract).
    func testExecuteScriptToolParseFailureCarriesLocation() async throws {
        let dir = try makeScratch()
        let script = dir.appendingPathComponent("broken.mdocx.swift")
        try "let document = WordDocument {\n    Nonsense(!!)\n}\n"
            .write(to: script, atomically: true, encoding: .utf8)

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(name: "execute_script", arguments: [
            "script_path": .string(script.path),
            "output_path": .string(dir.appendingPathComponent("out.docx").path),
        ])
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(resultText(result).contains("line"),
                      "parse error must carry a line; got: \(resultText(result))")
        XCTAssertTrue(resultText(result).contains("column"),
                      "parse error must carry a column (verify R2 #7); got: \(resultText(result))")
    }

    /// F1: present-but-mistyped optional params must error, never silently
    /// degrade (slots as object; verify_byte_equal_against as number).
    func testMistypedOptionalParamsErrorLoudly() async throws {
        let dir = try makeScratch()
        let source = dir.appendingPathComponent("reference.docx")
        try makeFiveLayerDocx(at: source)
        let script = dir.appendingPathComponent("out.mdocx.swift")

        let server = await WordMCPServer()
        let export = await server.invokeToolForTesting(name: "export_script", arguments: [
            "source_path": .string(source.path),
            "output_path": .string(script.path),
            "slots": .object(["name": .string("t"), "para_id": .string("P1")]),  // not an array
        ])
        XCTAssertEqual(export.isError, true, "non-array slots must error")

        _ = await server.invokeToolForTesting(name: "export_script", arguments: [
            "source_path": .string(source.path),
            "output_path": .string(script.path),
        ])
        let exec = await server.invokeToolForTesting(name: "execute_script", arguments: [
            "script_path": .string(script.path),
            "output_path": .string(dir.appendingPathComponent("o.docx").path),
            "verify_byte_equal_against": .int(123),  // not a string
        ])
        XCTAssertEqual(exec.isError, true, "non-string verify path must error")
    }

    /// F5: raw-form op-level slot substitution through the MCP surface —
    /// the OTHER half of the slot requirement (issue Expected #2). A
    /// formatted paragraph (rich pPr forces the raw `// @op` escape, text in
    /// a single-run setRuns) is slotted, substituted, and executed; the new
    /// text lands while every other part stays byte-equal.
    func testExecuteScriptToolOpLevelSlotSubstitution() async throws {
        let dir = try makeScratch()
        var doc = WordDocument.emptyAuthoringDocument()
        try doc.apply(operations: [
            .appendParagraph(in: nil, paragraph: ParagraphPayload(
                text: "", paraId: "R1",
                indentFirstLine: 180, indentFirstLineChars: 100,
                paragraphMarkRun: RunPayload(
                    text: "", fontAscii: "Times New Roman", sizeHalfPoints: 36))),
            .setRuns(target: ElementID(rawString: "w14:paraId=R1"), runs: [RunPayload(
                text: "原文の見出し", bold: true, fontEastAsia: "ＭＳ ゴシック",
                sizeHalfPoints: 36)]),
        ])
        let source = dir.appendingPathComponent("formatted.docx")
        try doc.writeAuthoringPackage(to: source)
        let script = dir.appendingPathComponent("slotted.mdocx.swift")

        let server = await WordMCPServer()
        let export = await server.invokeToolForTesting(name: "export_script", arguments: [
            "source_path": .string(source.path),
            "output_path": .string(script.path),
            "slots": .array([.object([
                "name": .string("heading"), "para_id": .string("R1"),
            ])]),
        ])
        XCTAssertNotEqual(export.isError, true, resultText(export))
        var scriptText = try String(contentsOfFile: script.path, encoding: .utf8)
        XCTAssertTrue(scriptText.contains("// @slot heading R1"),
                      "raw-form paragraph must take the op-level slot directive")

        scriptText = scriptText.replacingOccurrences(
            of: "heading: \"原文の見出し\"", with: "heading: \"置換後の見出し\"")
        try scriptText.write(toFile: script.path, atomically: true, encoding: .utf8)

        let rebuilt = dir.appendingPathComponent("substituted.docx")
        let exec = await server.invokeToolForTesting(name: "execute_script", arguments: [
            "script_path": .string(script.path),
            "output_path": .string(rebuilt.path),
        ])
        XCTAssertNotEqual(exec.isError, true, resultText(exec))

        let reference = try RawPartChannel.readAllParts(from: source)
        let substituted = try RawPartChannel.readAllParts(from: rebuilt)
        let docXML = String(decoding: substituted["word/document.xml"] ?? Data(), as: UTF8.self)
        XCTAssertTrue(docXML.contains("置換後の見出し"), "op-level slot text must land")
        XCTAssertFalse(docXML.contains("原文の見出し"))
        XCTAssertTrue(docXML.contains("w:firstLineChars=\"100\""),
                      "raw-form formatting must survive substitution")
        for (path, bytes) in reference where path != "word/document.xml" {
            XCTAssertEqual(substituted[path], bytes)
        }
    }

    /// R2 #4: part-set asymmetry must break verification — a reference
    /// carrying a part the rebuilt package lacks yields verified:false
    /// (pins compareParts' union semantics in THIS repo's suite, independent
    /// of content differences on shared parts). Construction: export the
    /// script FIRST, then append an extra entry into the reference zip.
    func testExecuteMissingPartBreaksVerification() throws {
        let dir = try makeScratch()
        let source = dir.appendingPathComponent("reference.docx")
        try makeFiveLayerDocx(at: source)
        let script = dir.appendingPathComponent("ref.mdocx.swift")
        _ = try scriptPipelineExport(sourcePath: source.path, outputPath: script.path)

        // Append an extra XML part to the reference AFTER export — the
        // rebuilt package cannot contain it.
        let extraDir = dir.appendingPathComponent("customXml", isDirectory: true)
        try FileManager.default.createDirectory(at: extraDir, withIntermediateDirectories: true)
        try "<extra/>".write(to: extraDir.appendingPathComponent("extra.xml"),
                             atomically: true, encoding: .utf8)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = dir
        zip.arguments = ["-q", source.lastPathComponent, "customXml/extra.xml"]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)

        let result = try scriptPipelineExecute(
            scriptPath: script.path,
            outputPath: dir.appendingPathComponent("out.docx").path,
            verifyAgainst: source.path)
        XCTAssertEqual(result.verified, false,
                       "a reference part missing from the rebuild must break Stage-B verification")
        XCTAssertTrue(result.brokenParts.contains("customXml/extra.xml"),
                      "broken parts must name the asymmetric part; got \(result.brokenParts)")
    }

    // MARK: - Failure signalling and the overwrite gate
    //
    // Spectra change `script-pipeline-failure-contract`, task 3.2.
    // che-word-mcp#180: a failing verdict rode a SUCCESSFUL response, so a
    // caller checking only call success read failure as pass.
    // che-word-mcp#181: the overwrite gate existed only on the CLI face.

    /// Build a reference that the exported script provably cannot rebuild,
    /// by appending an XML part to the reference AFTER the export.
    private func makeDivergentPair(in dir: URL) throws -> (script: URL, reference: URL) {
        let reference = dir.appendingPathComponent("reference.docx")
        try makeFiveLayerDocx(at: reference)
        let script = dir.appendingPathComponent("ref.mdocx.swift")
        _ = try scriptPipelineExport(sourcePath: reference.path, outputPath: script.path)

        let extraDir = dir.appendingPathComponent("customXml", isDirectory: true)
        try FileManager.default.createDirectory(at: extraDir, withIntermediateDirectories: true)
        try "<extra/>".write(to: extraDir.appendingPathComponent("extra.xml"),
                             atomically: true, encoding: .utf8)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = dir
        zip.arguments = ["-q", reference.lastPathComponent, "customXml/extra.xml"]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        return (script, reference)
    }

    /// A failing verdict must be an ERROR, not a successful response carrying
    /// `verified: false`. A caller that branches only on call success is the
    /// whole point: under the old shape it read a failed rebuild as a pass.
    func testExecuteScriptToolFailedVerificationIsAToolError() async throws {
        let dir = try makeScratch()
        let pair = try makeDivergentPair(in: dir)
        let output = dir.appendingPathComponent("out.docx")

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(name: "execute_script", arguments: [
            "script_path": .string(pair.script.path),
            "output_path": .string(output.path),
            "verify_byte_equal_against": .string(pair.reference.path),
        ])

        XCTAssertEqual(result.isError, true,
                       "a failing verdict must surface as a tool error: \(resultText(result))")
        XCTAssertTrue(resultText(result).contains("customXml/extra.xml"),
                      "the error must name the differing part; got: \(resultText(result))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                       "a failed verification must publish nothing")
    }

    /// The overwrite gate reaches the MCP face. Default is refuse.
    func testExecuteScriptToolRefusesExistingOutputWithoutOverwrite() async throws {
        let dir = try makeScratch()
        let source = dir.appendingPathComponent("reference.docx")
        try makeFiveLayerDocx(at: source)
        let script = dir.appendingPathComponent("ref.mdocx.swift")
        _ = try scriptPipelineExport(sourcePath: source.path, outputPath: script.path)
        let output = dir.appendingPathComponent("out.docx")
        try Data("這份檔案先前就在輸出路徑上".utf8).write(to: output)
        let before = try Data(contentsOf: output)

        let server = await WordMCPServer()
        let refused = await server.invokeToolForTesting(name: "execute_script", arguments: [
            "script_path": .string(script.path),
            "output_path": .string(output.path),
        ])
        XCTAssertEqual(refused.isError, true,
                       "an existing output must be refused by default: \(resultText(refused))")
        XCTAssertEqual(try Data(contentsOf: output), before,
                       "the refused run must leave the existing file untouched")

        // ... and the parameter actually reaches the shared entry point.
        let permitted = await server.invokeToolForTesting(name: "execute_script", arguments: [
            "script_path": .string(script.path),
            "output_path": .string(output.path),
            "overwrite": .bool(true),
        ])
        XCTAssertNotEqual(permitted.isError, true, resultText(permitted))
        XCTAssertNotEqual(try Data(contentsOf: output), before,
                          "with overwrite requested the rebuild must replace the file")
    }

    /// Pins the exact shape of a successful response.
    ///
    /// HONEST LIMIT — this does NOT guard the `if let written` unwrap in the
    /// handler, and no MCP-level test can. Verified by measurement: a non-nil
    /// `Optional<String>` assigned straight into the payload bridges to
    /// NSString and serialises as an ordinary string, so the naive form and
    /// the guarded form produce byte-identical output here. The two only
    /// diverge when `written` is nil — and nil is coupled exclusively to a
    /// failing verdict, which throws before any payload is built. The unwrap
    /// is therefore defensive, not load-bearing, and this test was originally
    /// written claiming to guard it. It does not. What it does guard is the
    /// success shape: `written` present as a string, no JSON null anywhere.
    func testExecuteScriptToolSuccessCarriesStringWrittenPath() async throws {
        let dir = try makeScratch()
        let source = dir.appendingPathComponent("reference.docx")
        try makeFiveLayerDocx(at: source)
        let script = dir.appendingPathComponent("ref.mdocx.swift")
        _ = try scriptPipelineExport(sourcePath: source.path, outputPath: script.path)
        let output = dir.appendingPathComponent("out.docx")

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(name: "execute_script", arguments: [
            "script_path": .string(script.path),
            "output_path": .string(output.path),
        ])
        XCTAssertNotEqual(result.isError, true, resultText(result))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(resultText(result).utf8)) as? [String: Any])
        XCTAssertTrue(json["written"] is String,
                      "written must be a string on success; got: \(resultText(result))")
        XCTAssertFalse(json.values.contains { $0 is NSNull },
                       "no successful response field may be JSON null: \(resultText(result))")
        XCTAssertNil(json["verified"],
                     "no reference was supplied, so the verdict fields must be absent")
        XCTAssertNil(json["broken_parts"],
                     "broken_parts must not appear when no verification ran")
    }

    // MARK: - Layer 2: gated MCP-vs-CLI cross-check (task 3.5)

    /// Spec scenario "Gated cross-check skips loudly" + the cross-check
    /// proper: MCP export_script and macdoc word-reverse produce
    /// byte-identical scripts for the real JPA template; executing both
    /// scripts yields byte-identical part sets, Stage-B equal to the
    /// reference. Needs BOTH MACDOC_TEMPLATE_DIR and MACDOC_CLI_PATH.
    func testCLICrossCheckAgainstMacdocBinary() async throws {
        guard let templateDir = ProcessInfo.processInfo.environment["MACDOC_TEMPLATE_DIR"] else {
            throw XCTSkip("set MACDOC_TEMPLATE_DIR — cross-check needs the real template")
        }
        guard let cliPath = ProcessInfo.processInfo.environment["MACDOC_CLI_PATH"] else {
            throw XCTSkip("set MACDOC_CLI_PATH — cross-check needs the macdoc binary")
        }
        let template = URL(fileURLWithPath: templateDir)
            .appendingPathComponent("90_template_ja.docx")
        guard FileManager.default.fileExists(atPath: template.path) else {
            throw XCTSkip("90_template_ja.docx not present under MACDOC_TEMPLATE_DIR")
        }
        let dir = try makeScratch()

        // CLI surface: macdoc word reverse.
        let cliScript = dir.appendingPathComponent("cli.mdocx.swift")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = ["word", "reverse", template.path, "--to-mdocx", cliScript.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        // Drain the pipe BEFORE waitUntilExit (verify R2 #6): if the CLI's
        // combined stdout+stderr exceeds the pipe buffer (~64KB), the child
        // blocks on write while we block on waitUntilExit → deadlock.
        // readDataToEndOfFile drains to EOF (child death), then wait reaps.
        let cliOutput = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "CLI export failed: \(cliOutput)")

        // MCP surface: export_script.
        let mcpScript = dir.appendingPathComponent("mcp.mdocx.swift")
        let server = await WordMCPServer()
        let export = await server.invokeToolForTesting(name: "export_script", arguments: [
            "source_path": .string(template.path),
            "output_path": .string(mcpScript.path),
        ])
        XCTAssertNotEqual(export.isError, true, resultText(export))

        // (1) Exported scripts byte-identical.
        let cliBytes = try Data(contentsOf: cliScript)
        let mcpBytes = try Data(contentsOf: mcpScript)
        XCTAssertEqual(cliBytes, mcpBytes,
                       "MCP and CLI must export byte-identical scripts (shared code path)")

        // (2) Executing both scripts yields byte-identical part sets,
        //     Stage-B equal to the reference.
        let rebuiltFromMCP = dir.appendingPathComponent("rebuilt-mcp.docx")
        let rebuiltFromCLI = dir.appendingPathComponent("rebuilt-cli.docx")
        let execMCP = await server.invokeToolForTesting(name: "execute_script", arguments: [
            "script_path": .string(mcpScript.path),
            "output_path": .string(rebuiltFromMCP.path),
            "verify_byte_equal_against": .string(template.path),
        ])
        XCTAssertNotEqual(execMCP.isError, true, resultText(execMCP))
        XCTAssertTrue(resultText(execMCP).contains("\"verified\":true"), resultText(execMCP))
        let execCLI = await server.invokeToolForTesting(name: "execute_script", arguments: [
            "script_path": .string(cliScript.path),
            "output_path": .string(rebuiltFromCLI.path),
        ])
        XCTAssertNotEqual(execCLI.isError, true, resultText(execCLI))

        let partsMCP = try RawPartChannel.readAllParts(from: rebuiltFromMCP)
        let partsCLI = try RawPartChannel.readAllParts(from: rebuiltFromCLI)
        XCTAssertTrue(PartFidelity.stageB(reference: partsMCP, rebuilt: partsCLI),
                      "rebuilds from the two surfaces' scripts must be byte-identical")

        // (3) Slotted exports byte-identical too (#134 verify R1, F6 —
        //     Expected #3 names reverse → SLOT → rebuild). Pick the first
        //     op-level-substitutable paragraph (single-run setRuns with
        //     non-empty text) from the template's log via public APIs.
        let templateParts = try RawPartChannel.readAllParts(from: template)
        let log = try ReverseExtractor.reverse(parts: templateParts).log
        var slotParaId: String?
        for entry in log.entries {
            if case .setRuns(let target, let runs) = entry.op,
               runs.count == 1, !runs[0].text.isEmpty,
               target.raw.hasPrefix("w14:paraId=") {
                slotParaId = String(target.raw.dropFirst("w14:paraId=".count))
                break
            }
        }
        let paraId = try XCTUnwrap(slotParaId, "template must have a slottable paragraph")

        let cliSlotted = dir.appendingPathComponent("cli-slotted.mdocx.swift")
        let slotProcess = Process()
        slotProcess.executableURL = URL(fileURLWithPath: cliPath)
        slotProcess.arguments = ["word", "reverse", template.path,
                                 "--to-mdocx", cliSlotted.path,
                                 "--slot", "slot0=\(paraId)"]
        let slotPipe = Pipe()
        slotProcess.standardError = slotPipe
        slotProcess.standardOutput = slotPipe
        try slotProcess.run()
        let slotOutput = String(  // drain before wait (verify R2 #6, deadlock-safe)
            decoding: slotPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        slotProcess.waitUntilExit()
        XCTAssertEqual(slotProcess.terminationStatus, 0, slotOutput)

        let mcpSlotted = dir.appendingPathComponent("mcp-slotted.mdocx.swift")
        let slottedExport = await server.invokeToolForTesting(name: "export_script", arguments: [
            "source_path": .string(template.path),
            "output_path": .string(mcpSlotted.path),
            "slots": .array([.object([
                "name": .string("slot0"), "para_id": .string(paraId),
            ])]),
        ])
        XCTAssertNotEqual(slottedExport.isError, true, resultText(slottedExport))
        XCTAssertEqual(try Data(contentsOf: cliSlotted), try Data(contentsOf: mcpSlotted),
                       "slotted exports from the two surfaces must be byte-identical")

        // (4) Coverage aggregate vs the LIVE CLI --coverage report (verify
        //     R2 #2 — no more reliance on the documented 0.535 literal).
        let covScript = dir.appendingPathComponent("cov.mdocx.swift")
        let covProcess = Process()
        covProcess.executableURL = URL(fileURLWithPath: cliPath)
        covProcess.arguments = ["word", "reverse", template.path,
                                "--to-mdocx", covScript.path, "--coverage"]
        let covPipe = Pipe()
        covProcess.standardOutput = covPipe
        covProcess.standardError = Pipe()
        try covProcess.run()
        let covData = covPipe.fileHandleForReading.readDataToEndOfFile()
        covProcess.waitUntilExit()
        XCTAssertEqual(covProcess.terminationStatus, 0)
        let covOut = String(decoding: covData, as: UTF8.self)
        // "--- Aggregate: 53.5% DSL (71771 / 134050 XML bytes across 13 parts) ---"
        let fraction = try XCTUnwrap(
            covOut.components(separatedBy: "(").last?
                .components(separatedBy: " XML bytes").first,
            "CLI coverage output must carry the byte fraction; got: \(covOut)")
        let numbers = fraction.components(separatedBy: " / ").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        XCTAssertEqual(numbers.count, 2, "unexpected fraction shape: \(fraction)")
        let cliAggregate = Double(numbers[0]) / Double(numbers[1])

        let coverage = await server.invokeToolForTesting(name: "get_script_coverage", arguments: [
            "source_path": .string(template.path),
        ])
        let covJSON = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(resultText(coverage).utf8)) as? [String: Any])
        let mcpAggregate = try XCTUnwrap(covJSON["aggregate_ratio"] as? Double)
        XCTAssertEqual(mcpAggregate, cliAggregate, accuracy: 1e-9,
                       "MCP aggregate must equal the live CLI aggregate")
    }

    /// Without verify_byte_equal_against the verdict is absent (nil), not a
    /// silent false/true.
    func testExecuteWithoutVerificationReportsNoVerdict() throws {
        let dir = try makeScratch()
        let source = dir.appendingPathComponent("reference.docx")
        try makeFiveLayerDocx(at: source)
        let script = dir.appendingPathComponent("reference.mdocx.swift")
        let rebuilt = dir.appendingPathComponent("rebuilt.docx")
        _ = try scriptPipelineExport(sourcePath: source.path, outputPath: script.path)

        let result = try scriptPipelineExecute(
            scriptPath: script.path, outputPath: rebuilt.path, verifyAgainst: nil)
        XCTAssertNil(result.verified)
        XCTAssertTrue(result.brokenParts.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rebuilt.path))
    }
}
