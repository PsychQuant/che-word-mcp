// Issue227ScriptCoverageReasonsTests.swift
// PsychQuant/che-word-mcp#227 (Refs PsychQuant/macdoc#193, #181):
//
// 1. get_script_coverage carries each raw part's root cause as an optional
//    `raw_reason`, passed through from ReverseExtractor.rawReasons. Parts
//    without a reason (DSL parts) carry no such key — the pre-#227 shape.
// 2. export_script takes `paragraphs_only` (default false), the MCP face of
//    `macdoc word reverse --paragraphs-only`: paragraph text + styleId only,
//    non-paragraph content omitted, NO byte-equal guarantee. The default path
//    stays byte-for-byte what it was.
//
// The CLI↔MCP byte-identical cross-check for paragraphs-only is gated on the
// real macdoc binary and lives in ScriptPipelineParityTests.

import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

final class Issue227ScriptCoverageReasonsTests: XCTestCase {

    private func makeScratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue227-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func resultText(_ result: CallTool.Result) -> String {
        guard let first = result.content.first else { return "" }
        if case .text(let text, _, _) = first { return text }
        return ""
    }

    private func jsonObject(_ result: CallTool.Result) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(resultText(result).utf8)) as? [String: Any],
            "not a JSON object: \(resultText(result))")
    }

    private func coverageRows(for source: URL) async throws -> [[String: Any]] {
        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(name: "get_script_coverage", arguments: [
            "source_path": .string(source.path),
        ])
        XCTAssertNotEqual(result.isError, true, resultText(result))
        return try XCTUnwrap(try jsonObject(result)["parts"] as? [[String: Any]])
    }

    // MARK: - get_script_coverage raw_reason

    /// The #181 document shape: document.xml raw because a paragraph lacks
    /// w14:paraId — the one reason with an alternative path — must be named.
    func testCoverageNamesParagraphNoParaIdOnDocumentXML() async throws {
        let dir = try makeScratch()
        let source = dir.appendingPathComponent("no-paraid.docx")
        try ScriptPipelineFixtures.writeParagraphsWithoutParaId(to: source)

        let rows = try await coverageRows(for: source)
        let docRow = try XCTUnwrap(rows.first { $0["part_path"] as? String == "word/document.xml" })
        XCTAssertEqual(docRow["channel"] as? String, "raw")
        XCTAssertEqual(docRow["raw_reason"] as? String, "paragraph-no-paraId",
                       "document.xml must name its raw root cause; got: \(docRow)")
    }

    /// Pass-through, not reinterpretation: every row's raw_reason equals what
    /// ReverseExtractor computed for that part, and a part without a computed
    /// reason carries no raw_reason key at all.
    func testCoverageRawReasonIsVerbatimPassThrough() async throws {
        let dir = try makeScratch()
        let noParaId = dir.appendingPathComponent("no-paraid.docx")
        try ScriptPipelineFixtures.writeParagraphsWithoutParaId(to: noParaId)
        let authored = dir.appendingPathComponent("authored.docx")
        try ScriptPipelineFixtures.writeAuthoredParagraphs(to: authored)

        for source in [noParaId, authored] {
            let expected = try ReverseExtractor.reverse(
                parts: RawPartChannel.readAllParts(from: source)).rawReasons
            let rows = try await coverageRows(for: source)
            XCTAssertFalse(rows.isEmpty)
            for row in rows {
                let path = try XCTUnwrap(row["part_path"] as? String)
                XCTAssertEqual(row["raw_reason"] as? String, expected[path],
                               "\(source.lastPathComponent) \(path): raw_reason must be passed through")
                if expected[path] == nil {
                    XCTAssertNil(row["raw_reason"], "no computed reason → no key (\(path))")
                }
            }
        }
    }

    /// Backward compatibility: a DSL row keeps exactly the pre-#227 key set,
    /// and a raw row only gains `raw_reason`.
    func testCoverageRowShapeIsAdditiveOnly() async throws {
        let dir = try makeScratch()
        let authored = dir.appendingPathComponent("authored.docx")
        try ScriptPipelineFixtures.writeAuthoredParagraphs(to: authored)

        let rows = try await coverageRows(for: authored)
        let legacyKeys: Set<String> = ["part_path", "channel", "bytes", "dsl_ratio"]
        let docRow = try XCTUnwrap(rows.first { $0["part_path"] as? String == "word/document.xml" })
        XCTAssertEqual(docRow["channel"] as? String, "dsl")
        XCTAssertEqual(Set(docRow.keys), legacyKeys, "a DSL row must not change shape")
        let rawRow = try XCTUnwrap(rows.first { $0["channel"] as? String == "raw" })
        XCTAssertEqual(Set(rawRow.keys), legacyKeys.union(["raw_reason"]))
    }

    /// Backward compatibility, values: the pre-#227 fields and the aggregate
    /// still equal the shared part-level report the CLI --coverage prints.
    func testCoverageLegacyFieldsStillMatchSharedReport() async throws {
        let dir = try makeScratch()
        let noParaId = dir.appendingPathComponent("no-paraid.docx")
        try ScriptPipelineFixtures.writeParagraphsWithoutParaId(to: noParaId)
        let authored = dir.appendingPathComponent("authored.docx")
        try ScriptPipelineFixtures.writeAuthoredParagraphs(to: authored)

        let server = await WordMCPServer()
        for source in [noParaId, authored] {
            let parts = try RawPartChannel.readAllParts(from: source)
            let reversed = try ReverseExtractor.reverse(parts: parts)
            let report = RawPartChannel.partLevelCoverage(parts: parts, dslParts: reversed.dslParts)

            let result = await server.invokeToolForTesting(name: "get_script_coverage", arguments: [
                "source_path": .string(source.path),
            ])
            let json = try jsonObject(result)
            let rows = try XCTUnwrap(json["parts"] as? [[String: Any]])
            XCTAssertEqual(rows.compactMap { $0["part_path"] as? String },
                           report.parts.map(\.partPath).sorted(),
                           "\(source.lastPathComponent): same parts, same order")
            for expected in report.parts {
                let row = try XCTUnwrap(rows.first { $0["part_path"] as? String == expected.partPath })
                XCTAssertEqual(row["channel"] as? String, expected.dslBytes > 0 ? "dsl" : "raw")
                XCTAssertEqual(row["bytes"] as? Int, expected.dslBytes + expected.rawBytes)
                XCTAssertEqual(row["dsl_ratio"] as? Double, expected.coverageRatio)
            }
            XCTAssertEqual(json["aggregate_ratio"] as? Double, report.aggregateRatio)
        }
    }

    // MARK: - Tool definitions carry the boundary

    /// The issue's hard requirement: the not-byte-equal boundary is written
    /// into the tool description, and the new fields are documented where a
    /// caller reads them.
    func testToolDefinitionsDocumentParagraphsOnlyAndRawReason() async throws {
        let server = await WordMCPServer()
        let tools = await server.toolsForTesting()

        let export = try XCTUnwrap(tools.first { $0.name == "export_script" })
        let exportDescription = export.description ?? ""
        XCTAssertTrue(exportDescription.contains("paragraphs_only"), exportDescription)
        XCTAssertTrue(exportDescription.contains("不保證 byte-equal"),
                      "the not-byte-equal boundary must be in the description: \(exportDescription)")
        let flag = try XCTUnwrap(export.inputSchema.objectValue?["properties"]?
            .objectValue?["paragraphs_only"]?.objectValue)
        XCTAssertEqual(flag["type"]?.stringValue, "boolean")
        XCTAssertTrue(flag["description"]?.stringValue?.contains("不保證 byte-equal") ?? false,
                      "the parameter's own description must state the boundary too")
        let required = export.inputSchema.objectValue?["required"]?.arrayValue?
            .compactMap(\.stringValue) ?? []
        XCTAssertFalse(required.contains("paragraphs_only"), "the flag is optional")

        let coverage = try XCTUnwrap(tools.first { $0.name == "get_script_coverage" })
        let coverageDescription = coverage.description ?? ""
        XCTAssertTrue(coverageDescription.contains("raw_reason"), coverageDescription)
        XCTAssertTrue(coverageDescription.contains("paragraph-no-paraId")
                      && coverageDescription.contains("paragraphs_only"),
                      "coverage must point the one actionable reason at its alternative path")
    }

    // MARK: - export_script paragraphs_only

    /// paragraphs_only produces the readable paragraph DSL (synthesized ids
    /// for paraId-less paragraphs), omits the table, and says so — including
    /// that the result is not byte-equal.
    func testParagraphsOnlyExportsParagraphDSLAndStatesBoundary() async throws {
        let dir = try makeScratch()
        let source = dir.appendingPathComponent("no-paraid.docx")
        try ScriptPipelineFixtures.writeParagraphsWithoutParaId(to: source)
        let script = dir.appendingPathComponent("out.mdocx.swift")

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(name: "export_script", arguments: [
            "source_path": .string(source.path),
            "output_path": .string(script.path),
            "paragraphs_only": .bool(true),
        ])
        XCTAssertNotEqual(result.isError, true, resultText(result))
        let json = try jsonObject(result)
        XCTAssertEqual(json["paragraphs_only"] as? Bool, true)
        XCTAssertEqual(json["byte_equal"] as? Bool, false,
                       "paragraphs-only must never read as byte-equal: \(json)")
        XCTAssertEqual(json["omitted_body_blocks"] as? [String], ["table"])
        XCTAssertEqual(json["slot_count"] as? Int, 0)
        XCTAssertEqual(json["output_path"] as? String, script.path)
        XCTAssertNil(json["dsl_parts"],
                     "no part is byte-equal-proven here; dsl_parts must be absent: \(json)")
        XCTAssertNil(json["form_gaps_empty"],
                     "form gaps were not measured on this path; the field must be absent: \(json)")

        let text = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(text.contains("Paragraph(id: \"p1\", style: .heading1)"),
                      "paraId-less paragraphs get synthesized DSL ids, styleId kept:\n\(text)")
        XCTAssertTrue(text.contains("Paragraph(id: \"p3\")"),
                      "the table does not consume a synthesized id:\n\(text)")
        XCTAssertTrue(text.contains("Assignment 02"))
        XCTAssertFalse(text.contains(ScriptPipelineFixtures.tableCellText),
                       "table content is omitted on this path")
        XCTAssertFalse(text.contains("carryPart"),
                       "no raw-channel part may ride a paragraphs-only script:\n\(text)")
    }

    /// Executing a paragraphs-only script reproduces the paragraphs (text +
    /// styleId, in order) and nothing else. For this fixture — which has a
    /// table and paraId-less paragraphs — the rebuild is not byte-equal to
    /// the source, and execute_script's verification says so. (The path makes
    /// no byte-equal promise either way; this pins one case where it fails.)
    func testParagraphsOnlyRebuildIsParagraphEquivalentButNotByteEqual() async throws {
        let dir = try makeScratch()
        let source = dir.appendingPathComponent("no-paraid.docx")
        try ScriptPipelineFixtures.writeParagraphsWithoutParaId(to: source)
        let script = dir.appendingPathComponent("out.mdocx.swift")

        let server = await WordMCPServer()
        let export = await server.invokeToolForTesting(name: "export_script", arguments: [
            "source_path": .string(source.path),
            "output_path": .string(script.path),
            "paragraphs_only": .bool(true),
        ])
        XCTAssertNotEqual(export.isError, true, resultText(export))

        let rebuilt = dir.appendingPathComponent("rebuilt.docx")
        let exec = await server.invokeToolForTesting(name: "execute_script", arguments: [
            "script_path": .string(script.path),
            "output_path": .string(rebuilt.path),
        ])
        XCTAssertNotEqual(exec.isError, true, resultText(exec))
        let got = try ScriptPipelineFixtures.bodyParagraphs(of: rebuilt)
        let want = ScriptPipelineFixtures.paragraphsWithoutParaId
        XCTAssertEqual(got.map(\.text), want.map(\.text))
        XCTAssertEqual(got.map(\.style), want.map(\.style))

        let verified = await server.invokeToolForTesting(name: "execute_script", arguments: [
            "script_path": .string(script.path),
            "output_path": .string(dir.appendingPathComponent("verified.docx").path),
            "verify_byte_equal_against": .string(source.path),
        ])
        XCTAssertEqual(verified.isError, true,
                       "a paragraphs-only rebuild must fail byte-equal verification: \(resultText(verified))")
    }

    /// Slots work on this path as they do on the CLI: a synthesized id is a
    /// valid target, and a substituted value lands in the rebuild.
    func testParagraphsOnlySlotOnSynthesizedId() async throws {
        let dir = try makeScratch()
        let source = dir.appendingPathComponent("no-paraid.docx")
        try ScriptPipelineFixtures.writeParagraphsWithoutParaId(to: source)
        let script = dir.appendingPathComponent("slotted.mdocx.swift")

        let server = await WordMCPServer()
        let export = await server.invokeToolForTesting(name: "export_script", arguments: [
            "source_path": .string(source.path),
            "output_path": .string(script.path),
            "paragraphs_only": .bool(true),
            "slots": .array([.object(["name": .string("title"), "para_id": .string("p1")])]),
        ])
        XCTAssertNotEqual(export.isError, true, resultText(export))
        XCTAssertEqual(try jsonObject(export)["slot_count"] as? Int, 1)

        var text = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(text.contains("title: \"Assignment 02\""), text)
        text = text.replacingOccurrences(of: "title: \"Assignment 02\"", with: "title: \"Assignment 03\"")
        try text.write(to: script, atomically: true, encoding: .utf8)

        let rebuilt = dir.appendingPathComponent("rebuilt.docx")
        let exec = await server.invokeToolForTesting(name: "execute_script", arguments: [
            "script_path": .string(script.path),
            "output_path": .string(rebuilt.path),
        ])
        XCTAssertNotEqual(exec.isError, true, resultText(exec))
        let texts = try ScriptPipelineFixtures.bodyParagraphs(of: rebuilt).map(\.text)
        XCTAssertEqual(texts.first, "Assignment 03")
        XCTAssertEqual(Array(texts.dropFirst()),
                       Array(ScriptPipelineFixtures.paragraphsWithoutParaId.dropFirst().map(\.text)))
    }

    /// Strict slots stay strict on this path: an unknown id is a tool error
    /// naming the slot, and no script is written.
    func testParagraphsOnlyStrictSlotFailureWritesNothing() async throws {
        let dir = try makeScratch()
        let source = dir.appendingPathComponent("no-paraid.docx")
        try ScriptPipelineFixtures.writeParagraphsWithoutParaId(to: source)
        let script = dir.appendingPathComponent("out.mdocx.swift")

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(name: "export_script", arguments: [
            "source_path": .string(source.path),
            "output_path": .string(script.path),
            "paragraphs_only": .bool(true),
            "slots": .array([.object(["name": .string("title"), "para_id": .string("NOPE")])]),
        ])
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(resultText(result).contains("title"), resultText(result))
        XCTAssertFalse(FileManager.default.fileExists(atPath: script.path))
    }

    /// The CLI exports an oplog sidecar instead whenever one sits next to the
    /// docx, ignoring --paragraphs-only. export_script does not read sidecars,
    /// so it cannot produce the CLI's script for that input: it must refuse
    /// rather than silently diverge. The default path is untouched by this.
    func testParagraphsOnlyRefusesWhenOplogSidecarIsPresent() async throws {
        let dir = try makeScratch()
        let source = dir.appendingPathComponent("with-sidecar.docx")
        try ScriptPipelineFixtures.writeParagraphsWithoutParaId(to: source)
        var log = OperationLog()
        log.append(.appendParagraph(in: nil, paragraph: ParagraphPayload(
            text: "sidecar", paraId: "S1")), source: .swift)
        try SidecarStore.saveLog(log, alongside: source)
        let script = dir.appendingPathComponent("out.mdocx.swift")

        let server = await WordMCPServer()
        let refused = await server.invokeToolForTesting(name: "export_script", arguments: [
            "source_path": .string(source.path),
            "output_path": .string(script.path),
            "paragraphs_only": .bool(true),
        ])
        XCTAssertEqual(refused.isError, true,
                       "sidecar + paragraphs_only must be refused: \(resultText(refused))")
        XCTAssertTrue(resultText(refused).contains("sidecar"), resultText(refused))
        XCTAssertFalse(FileManager.default.fileExists(atPath: script.path),
                       "a refused export must write nothing")

        let defaultPath = await server.invokeToolForTesting(name: "export_script", arguments: [
            "source_path": .string(source.path),
            "output_path": .string(script.path),
        ])
        XCTAssertNotEqual(defaultPath.isError, true,
                          "the default path's behavior must not change: \(resultText(defaultPath))")
    }

    /// Strict typing like the other optional parameters: a present-but-
    /// mistyped flag errors (nothing written); explicit null means absent.
    func testParagraphsOnlyMistypedErrorsAndNullIsAbsent() async throws {
        let dir = try makeScratch()
        let source = dir.appendingPathComponent("no-paraid.docx")
        try ScriptPipelineFixtures.writeParagraphsWithoutParaId(to: source)
        let script = dir.appendingPathComponent("out.mdocx.swift")

        let server = await WordMCPServer()
        let mistyped = await server.invokeToolForTesting(name: "export_script", arguments: [
            "source_path": .string(source.path),
            "output_path": .string(script.path),
            "paragraphs_only": .string("yes"),
        ])
        XCTAssertEqual(mistyped.isError, true, "non-boolean paragraphs_only must error")
        XCTAssertTrue(resultText(mistyped).contains("paragraphs_only"), resultText(mistyped))
        XCTAssertFalse(FileManager.default.fileExists(atPath: script.path))

        let null = await server.invokeToolForTesting(name: "export_script", arguments: [
            "source_path": .string(source.path),
            "output_path": .string(script.path),
            "paragraphs_only": .null,
        ])
        XCTAssertNotEqual(null.isError, true, resultText(null))
        XCTAssertNil(try jsonObject(null)["paragraphs_only"], "null must take the default path")
    }

    /// The default path — parameter omitted or explicitly false — produces
    /// the same script bytes and the same response as before #227.
    func testDefaultPathIsUnchangedWhetherFlagOmittedOrFalse() async throws {
        let dir = try makeScratch()
        let server = await WordMCPServer()
        for (name, write) in [
            ("no-paraid", ScriptPipelineFixtures.writeParagraphsWithoutParaId(to:)),
            ("authored", ScriptPipelineFixtures.writeAuthoredParagraphs(to:)),
        ] {
            let source = dir.appendingPathComponent("\(name).docx")
            try write(source)
            let omitted = dir.appendingPathComponent("\(name)-omitted.mdocx.swift")
            let explicitFalse = dir.appendingPathComponent("\(name)-false.mdocx.swift")

            let a = await server.invokeToolForTesting(name: "export_script", arguments: [
                "source_path": .string(source.path),
                "output_path": .string(omitted.path),
            ])
            let b = await server.invokeToolForTesting(name: "export_script", arguments: [
                "source_path": .string(source.path),
                "output_path": .string(explicitFalse.path),
                "paragraphs_only": .bool(false),
            ])
            XCTAssertNotEqual(a.isError, true, resultText(a))
            XCTAssertNotEqual(b.isError, true, resultText(b))
            XCTAssertEqual(try Data(contentsOf: omitted), try Data(contentsOf: explicitFalse),
                           "\(name): explicit false must equal the default script")
            // Responses: identical once the (necessarily different) output
            // path is set aside, with exactly the pre-#227 keys and values.
            var jsonA = try jsonObject(a)
            var jsonB = try jsonObject(b)
            XCTAssertEqual(jsonA.removeValue(forKey: "output_path") as? String, omitted.path)
            XCTAssertEqual(jsonB.removeValue(forKey: "output_path") as? String, explicitFalse.path)
            XCTAssertEqual(NSDictionary(dictionary: jsonA), NSDictionary(dictionary: jsonB),
                           "\(name): explicit false must return what the default returns")
            XCTAssertEqual(Set(jsonB.keys), ["dsl_parts", "form_gaps_empty", "slot_count"],
                           "\(name): the default response keeps its pre-#227 shape")

            // And the values are what the shared entry points compute — the
            // same thing export_script always wrote and reported.
            let reversed = try ReverseExtractor.reverse(
                parts: RawPartChannel.readAllParts(from: source))
            XCTAssertEqual(jsonB["dsl_parts"] as? [String], reversed.dslParts.sorted())
            XCTAssertEqual(jsonB["form_gaps_empty"] as? Bool, reversed.formGaps.isEmpty)
            XCTAssertEqual(jsonB["slot_count"] as? Int, 0)
            XCTAssertEqual(try String(contentsOf: omitted, encoding: .utf8),
                           try ScriptExporter.exportSwift(log: reversed.log, slots: []))
        }
    }
}
