// ScriptPipelineTools.swift
// Spectra change che-word-mcp-script-pipeline-parity, tasks 3.1–3.4
// (`che-word-mcp-script-pipeline-tools`).
//
// Thin wrappers over the ooxml-swift transcoder entry points — the SAME code
// path `macdoc word reverse` rides (design Decision 1): ReverseExtractor /
// ScriptExporter / ScriptImporter / RawPartChannel / PartFidelity. The MCP
// layer reimplements ZERO transcode logic; behavior parity with the CLI is
// structural, and the parity tests in ScriptPipelineParityTests only guard it.
//
// Registration (Tool entries + handleToolCall cases) lives in Server.swift,
// following the MarkdownExportTools satellite-file precedent.

import Foundation
import MCP
import OOXMLSwift

// MARK: - Result shapes (design Decision 2 response contracts)

struct ScriptExportSummary: Sendable {
    /// Part paths rebuilt through the typed DSL channel, sorted.
    let dslParts: [String]
    /// True when the reverse extraction reported zero form gaps.
    let formGapsEmpty: Bool
    /// Number of slot designations baked into the exported script.
    let slotCount: Int
}

struct ScriptCoverageRow: Sendable {
    let partPath: String
    /// "dsl" | "raw" (part-level granularity, matching the CLI report).
    let channel: String
    let bytes: Int
    /// DSL share of this part's bytes in [0, 1].
    let dslRatio: Double
}

struct ScriptCoverageReport: Sendable {
    let parts: [ScriptCoverageRow]
    let aggregateRatio: Double
}

struct ScriptExecuteResult: Sendable {
    /// Path the rebuilt docx was written to.
    let written: String
    /// Stage-B verdict when verification was requested; nil when it was not.
    let verified: Bool?
    /// Part paths that failed byte equality (empty unless verified == false).
    let brokenParts: [String]
}

// MARK: - Errors

enum ScriptPipelineError: LocalizedError {
    case fileNotFound(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "找不到輸入檔案: \(path)"
        }
    }
}

// MARK: - Handlers (pure functions; MCP plumbing stays in Server.swift)

/// docx → full-fidelity `.mdocx.swift` rebuild script. Strict mode: slot
/// designation failures throw (TranscodeError.slotDesignationFailure), and
/// the script file is NOT written on failure. The caller-supplied output
/// path is overwritten when it exists (explicit path = explicit intent).
func scriptPipelineExport(
    sourcePath: String,
    outputPath: String,
    slots: [SlotDesignation] = []
) throws -> ScriptExportSummary {
    let sourceURL = URL(fileURLWithPath: sourcePath)
    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
        throw ScriptPipelineError.fileNotFound(sourcePath)
    }
    // Same sequence as MacDoc+Word.swift's full-fidelity default branch.
    let parts = try RawPartChannel.readAllParts(from: sourceURL)
    let result = try ReverseExtractor.reverse(parts: parts)
    // exportSwift(log:slots:) delegates to the canonical exporter on empty
    // slots — single call site keeps the CLI-identical code path.
    let source = try ScriptExporter.exportSwift(log: result.log, slots: slots)
    try source.write(to: URL(fileURLWithPath: outputPath),
                     atomically: true, encoding: .utf8)
    return ScriptExportSummary(
        dslParts: result.dslParts.sorted(),
        formGapsEmpty: result.formGaps.isEmpty,
        slotCount: slots.count)
}

/// Dual-track coverage of a docx — the same numbers as the CLI --coverage
/// report (part-level granularity via RawPartChannel.partLevelCoverage).
func scriptPipelineCoverage(sourcePath: String) throws -> ScriptCoverageReport {
    let sourceURL = URL(fileURLWithPath: sourcePath)
    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
        throw ScriptPipelineError.fileNotFound(sourcePath)
    }
    let parts = try RawPartChannel.readAllParts(from: sourceURL)
    let result = try ReverseExtractor.reverse(parts: parts)
    let report = RawPartChannel.partLevelCoverage(parts: parts, dslParts: result.dslParts)
    return ScriptCoverageReport(
        parts: report.parts.map { part in
            ScriptCoverageRow(
                partPath: part.partPath,
                channel: part.dslBytes > 0 ? "dsl" : "raw",
                bytes: part.dslBytes + part.rawBytes,
                dslRatio: part.coverageRatio)
        },
        aggregateRatio: report.aggregateRatio)
}

/// `.mdocx.swift` script → rebuilt docx. When `verifyAgainst` names a
/// reference docx, the rebuilt XML part set is compared for Stage-B byte
/// equality and the verdict (with broken part paths) rides the result.
func scriptPipelineExecute(
    scriptPath: String,
    outputPath: String,
    verifyAgainst: String? = nil
) throws -> ScriptExecuteResult {
    let scriptURL = URL(fileURLWithPath: scriptPath)
    guard FileManager.default.fileExists(atPath: scriptURL.path) else {
        throw ScriptPipelineError.fileNotFound(scriptPath)
    }
    let source = try String(contentsOf: scriptURL, encoding: .utf8)
    let log = try ScriptImporter.parse(source: source)

    var document = WordDocument.emptyAuthoringDocument()
    try document.apply(operations: log.entries.map(\.op))
    let outputURL = URL(fileURLWithPath: outputPath)
    try document.writeAuthoringPackage(to: outputURL)

    guard let referencePath = verifyAgainst else {
        return ScriptExecuteResult(written: outputPath, verified: nil, brokenParts: [])
    }
    let referenceURL = URL(fileURLWithPath: referencePath)
    guard FileManager.default.fileExists(atPath: referenceURL.path) else {
        throw ScriptPipelineError.fileNotFound(referencePath)
    }
    let reference = try RawPartChannel.readAllParts(from: referenceURL)
    let rebuilt = try RawPartChannel.readAllParts(from: outputURL)
    let broken = PartFidelity.compareParts(reference: reference, rebuilt: rebuilt)
        .filter { !$0.isEqual }
        .map(\.partPath)
    return ScriptExecuteResult(
        written: outputPath, verified: broken.isEmpty, brokenParts: broken)
}

// MARK: - MCP arg-parsing wrappers (dispatch cases live in Server.swift)

/// Deterministic JSON encoding for tool responses (sortedKeys → stable output).
private func scriptPipelineJSON(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(
        withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}

extension WordMCPServer {

    func exportScriptTool(args: [String: Value]) async throws -> String {
        guard let sourcePath = args["source_path"]?.stringValue else {
            throw WordError.missingParameter("source_path")
        }
        guard let outputPath = args["output_path"]?.stringValue else {
            throw WordError.missingParameter("output_path")
        }
        var slots: [SlotDesignation] = []
        if let rawSlots = args["slots"]?.arrayValue {
            for (index, raw) in rawSlots.enumerated() {
                guard let object = raw.objectValue,
                      let name = object["name"]?.stringValue,
                      let paraId = object["para_id"]?.stringValue else {
                    throw WordError.invalidParameter(
                        "slots", "slots[\(index)] 需要 {name, para_id} 物件")
                }
                slots.append(SlotDesignation(name: name, paraId: paraId))
            }
        }
        let summary: ScriptExportSummary
        do {
            summary = try scriptPipelineExport(
                sourcePath: sourcePath, outputPath: outputPath, slots: slots)
        } catch let TranscodeError.slotDesignationFailure(name, reason) {
            // Strict mode: surface the transcoder's reason verbatim, naming
            // the failing slot (spec scenario "Strict slot failure surfaces
            // as a tool error").
            throw WordError.invalidParameter("slots", "slot「\(name)」無法建立: \(reason)")
        }
        return try scriptPipelineJSON([
            "dsl_parts": summary.dslParts,
            "form_gaps_empty": summary.formGapsEmpty,
            "slot_count": summary.slotCount,
            "output_path": outputPath,
        ])
    }

    func getScriptCoverageTool(args: [String: Value]) async throws -> String {
        guard let sourcePath = args["source_path"]?.stringValue else {
            throw WordError.missingParameter("source_path")
        }
        let report = try scriptPipelineCoverage(sourcePath: sourcePath)
        return try scriptPipelineJSON([
            "parts": report.parts.map { row in
                [
                    "part_path": row.partPath,
                    "channel": row.channel,
                    "bytes": row.bytes,
                    "dsl_ratio": row.dslRatio,
                ] as [String: Any]
            },
            "aggregate_ratio": report.aggregateRatio,
        ])
    }

    func executeScriptTool(args: [String: Value]) async throws -> String {
        guard let scriptPath = args["script_path"]?.stringValue else {
            throw WordError.missingParameter("script_path")
        }
        guard let outputPath = args["output_path"]?.stringValue else {
            throw WordError.missingParameter("output_path")
        }
        let verifyAgainst = args["verify_byte_equal_against"]?.stringValue
        let result = try scriptPipelineExecute(
            scriptPath: scriptPath, outputPath: outputPath, verifyAgainst: verifyAgainst)
        var payload: [String: Any] = [
            "written": result.written,
            "broken_parts": result.brokenParts,
        ]
        if let verified = result.verified {
            payload["verified"] = verified
        }
        return try scriptPipelineJSON(payload)
    }
}
