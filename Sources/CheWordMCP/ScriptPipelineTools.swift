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


// MARK: - Errors


/// TranscodeError is not LocalizedError — without this mapping a script
/// parse failure surfaces as a useless generic message. Task 3.4 contract:
/// parse failures map to MCP errors with the transcoder's location-bearing
/// reason (#134 verify R1, finding B2).
func describeTranscodeError(_ error: TranscodeError) -> String {
    switch error {
    case .unsupportedSyntax(let line, let column, let reason):
        return "腳本解析失敗（line \(line), column \(column)）: \(reason)"
    case .malformedRawOp(let line, let reason):
        return "raw op 解析失敗（line \(line)）: \(reason)"
    case .slotDesignationFailure(let name, let reason):
        return "slot「\(name)」無法建立: \(reason)"
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
        parts: report.parts.sorted { $0.partPath < $1.partPath }.map { part in
            ScriptCoverageRow(
                partPath: part.partPath,
                channel: part.dslBytes > 0 ? "dsl" : "raw",
                bytes: part.dslBytes + part.rawBytes,
                dslRatio: part.coverageRatio)
        },
        aggregateRatio: report.aggregateRatio)
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
        if let rawSlotsValue = args["slots"], rawSlotsValue != .null {
            // Strict typing (#134 verify R1, F1): a present-but-mistyped
            // `slots` must error, never silently degrade to "no slots".
            // Explicit JSON null counts as absent (verify R2 #11), not a
            // type error.
            guard let rawSlots = rawSlotsValue.arrayValue else {
                throw WordError.invalidParameter(
                    "slots", "必須是陣列（收到非陣列型別）")
            }
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
        } catch let error as TranscodeError {
            // Strict mode: surface the transcoder's location/name-bearing
            // reason (B2). Attribution split per verify R2 #1: only a
            // designation failure is a `slots` problem — any other
            // TranscodeError came from processing the SOURCE document.
            if case .slotDesignationFailure = error {
                throw WordError.invalidParameter("slots", describeTranscodeError(error))
            }
            throw WordError.invalidParameter("source_path", describeTranscodeError(error))
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
        // Strict typing (#134 verify R1, F1): present-but-mistyped
        // verification parameter must error, never silently skip verification.
        var verifyAgainst: String?
        if let rawVerify = args["verify_byte_equal_against"], rawVerify != .null {
            guard let path = rawVerify.stringValue else {
                throw WordError.invalidParameter(
                    "verify_byte_equal_against", "必須是字串路徑（收到非字串型別）")
            }
            verifyAgainst = path
        }
        let result: ScriptExecuteResult
        do {
            result = try scriptPipelineExecute(
                scriptPath: scriptPath, outputPath: outputPath, verifyAgainst: verifyAgainst)
        } catch let error as TranscodeError {
            // B2: parse failures surface the transcoder's location-bearing
            // reason (task 3.4 contract).
            throw WordError.invalidParameter("script_path", describeTranscodeError(error))
        }
        var payload: [String: Any] = ["written": result.written]
        if let verified = result.verified {
            // F2: verdict fields ride the response ONLY when verification
            // actually ran — an unconditional broken_parts: [] reads as a
            // false green light to clients that only check that field.
            payload["verified"] = verified
            payload["broken_parts"] = result.brokenParts
        }
        return try scriptPipelineJSON(payload)
    }
}
