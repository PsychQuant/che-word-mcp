// Issue173SelfProducedDSLUpgradeTests.swift
// PsychQuant/che-word-mcp#173 — self-produced docx must upgrade to the typed
// DSL channel. Root cause was upstream (ooxml-swift#85, fixed in v1.5.0:
// authoring path emits transcoder-canonical document.xml with stamped
// w14:paraId); this consumer regression pins the contract at the MCP tool
// layer, mirroring the issue's reproduction path (create_document →
// disable_track_changes → insert_paragraph → save_document → export_script).

import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

final class Issue173SelfProducedDSLUpgradeTests: XCTestCase {

    private func resultText(_ result: CallTool.Result) -> String {
        guard let first = result.content.first else { return "" }
        if case .text(let text, _, _) = first { return text }
        return ""
    }

    private func makeScratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue173-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Builds a pure-paragraph docx exactly the way an MCP consumer does —
    /// through the tool layer, with track changes disabled (the issue's
    /// reproduction shape).
    private func makeSelfProducedDocx(at path: String) async throws {
        let server = await WordMCPServer()
        let docId = "issue173"
        let create = await server.invokeToolForTesting(name: "create_document", arguments: [
            "doc_id": .string(docId),
        ])
        XCTAssertNotEqual(create.isError, true, resultText(create))
        // Track changes is orthogonal to the DSL upgrade (insert_paragraph
        // never emits <w:ins>; verify #173 DA probe), but the issue's repro
        // disables it — assert the step so a silent tool failure can't drift
        // this fixture away from the documented reproduction shape.
        let disable = await server.invokeToolForTesting(name: "disable_track_changes", arguments: [
            "doc_id": .string(docId),
        ])
        XCTAssertNotEqual(disable.isError, true, resultText(disable))
        for text in ["自產文件第一段", "第二段：純段落內容", "第三段"] {
            let r = await server.invokeToolForTesting(name: "insert_paragraph", arguments: [
                "doc_id": .string(docId),
                "text": .string(text),
            ])
            XCTAssertNotEqual(r.isError, true, resultText(r))
        }
        let save = await server.invokeToolForTesting(name: "save_document", arguments: [
            "doc_id": .string(docId),
            "path": .string(path),
        ])
        XCTAssertNotEqual(save.isError, true, resultText(save))
        _ = await server.invokeToolForTesting(name: "close_document", arguments: [
            "doc_id": .string(docId),
        ])
    }

    /// #173 symptom 1: export_script on a self-produced pure-paragraph docx
    /// reported dsl_parts=[] / aggregate_ratio 0 (all parts raw carryPart).
    /// With ooxml-swift >= 1.5.0 the document part must ride the DSL channel.
    func testSelfProducedPureParagraphDocxUpgradesToDSL() async throws {
        let dir = try makeScratch()
        let docPath = dir.appendingPathComponent("self-produced.docx").path
        try await makeSelfProducedDocx(at: docPath)

        let script = dir.appendingPathComponent("self-produced.mdocx.swift").path
        let summary = try scriptPipelineExport(sourcePath: docPath, outputPath: script)
        XCTAssertTrue(summary.dslParts.contains("word/document.xml"),
                      "self-produced document.xml must upgrade to the DSL channel")

        let coverage = try scriptPipelineCoverage(sourcePath: docPath)
        let docRow = try XCTUnwrap(coverage.parts.first { $0.partPath == "word/document.xml" })
        XCTAssertEqual(docRow.channel, "dsl")
        XCTAssertEqual(docRow.dslRatio, 1.0, accuracy: 1e-12,
                       "pure-paragraph document.xml per-part DSL ratio must be 100%")
        XCTAssertGreaterThan(coverage.aggregateRatio, 0,
                             "aggregate ratio must leave the all-raw floor")
    }

    /// #173 symptom 2: slots were unusable on self-produced docs because no
    /// paragraph carried w14:paraId. Stamped paraIds must now anchor slots.
    func testSelfProducedDocxSupportsSlotDesignation() async throws {
        let dir = try makeScratch()
        let docPath = dir.appendingPathComponent("slot-source.docx").path
        try await makeSelfProducedDocx(at: docPath)

        let documentXML = try XCTUnwrap(
            RawPartChannel.readAllParts(from: URL(fileURLWithPath: docPath))["word/document.xml"])
        let xml = String(decoding: documentXML, as: UTF8.self)
        let match = try XCTUnwrap(
            xml.range(of: #"w14:paraId="([0-9A-F]{8})""#, options: .regularExpression),
            "self-produced paragraphs must carry stamped w14:paraId slot anchors")
        let paraId = String(xml[match].dropFirst("w14:paraId=\"".count).dropLast())

        let script = dir.appendingPathComponent("slotted.mdocx.swift").path
        let summary = try scriptPipelineExport(
            sourcePath: docPath, outputPath: script,
            slots: [SlotDesignation(name: "body_slot", paraId: paraId)])
        XCTAssertEqual(summary.slotCount, 1,
                       "a stamped paraId must be designatable as a named content slot")
    }
}
