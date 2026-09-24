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
// One exception (#227): the paragraphs-only reverse loop lives in the macdoc
// CLI rather than in ooxml-swift, so `paragraphsOnlyReverse` is a port. For
// that path the gated cross-check is the guard, not a backstop.
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
    /// Why this part stayed on the raw channel: ReverseExtractor.rawReasons
    /// passed through verbatim (#227). nil when no reason was computed, which
    /// is the case for every DSL part.
    let rawReason: String?
}

/// Summary of a paragraphs-only export (#227). Deliberately a different
/// shape from ScriptExportSummary: this path proves nothing byte-equal and
/// measures no form gaps, so it has no dslParts / formGapsEmpty to report.
struct ParagraphsOnlyExportSummary: Sendable {
    /// Body-level blocks the paragraphs-only reverse skipped, one entry per
    /// occurrence in document order ("table", "contentControl", …).
    let omittedBodyBlocks: [String]
    /// Number of slot designations baked into the exported script.
    let slotCount: Int
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
    case .rawSlotExecutionFailure(let name, let reason):
        return "raw slot「\(name)」執行失敗: \(reason)"
    }
}

/// paragraphs-only export refused because an oplog sidecar sits next to the
/// source (#227). `macdoc word reverse` exports the sidecar log whenever one
/// exists, ignoring --paragraphs-only; export_script does not read sidecars,
/// so for this input it cannot produce the script the CLI produces. Refusing
/// keeps the two faces from silently diverging.
struct ParagraphsOnlySidecarConflict: LocalizedError {
    let sidecarPath: String

    var errorDescription: String? {
        "來源檔旁有 oplog sidecar（\(sidecarPath)，或同目錄的 legacy <stem>.oplog.jsonl），未寫出任何檔案。"
            + "macdoc word reverse 在這種情況會改匯出 sidecar 的操作紀錄、忽略 --paragraphs-only；"
            + "export_script 不讀 sidecar，產不出同一份腳本，所以拒絕 paragraphs_only。"
            + "要段落腳本請先移開 sidecar；要 sidecar 的腳本請改用 macdoc word reverse。"
    }
}

/// A failing Stage-B verdict.
///
/// #180: this MUST be an error rather than a field on a successful response.
/// The old shape returned `verified: false` inside a normal result, so a
/// caller that branched only on call success read a failed rebuild as a pass.
///
/// The differing parts travel in the message rather than as a structured
/// list: `handleToolCall` renders a thrown error as plain text and returns a
/// JSON body only on success, so carrying both would mean changing the shape
/// every tool handler returns. That restructuring is tracked separately; the
/// information is destructured here, not lost.
struct ScriptVerificationFailure: LocalizedError {
    let brokenParts: [String]

    var errorDescription: String? {
        let parts = brokenParts.map { "  - \($0)" }.joined(separator: "\n")
        return "byte-equal 驗證失敗，未寫出任何檔案。以下 part 與參考檔不符：\n\(parts)"
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
                dslRatio: part.coverageRatio,
                rawReason: result.rawReasons[part.partPath])
        },
        aggregateRatio: report.aggregateRatio)
}

/// docx → paragraphs-only `.mdocx.swift` script, the MCP face of
/// `macdoc word reverse --paragraphs-only` (#227). Paragraph text + styleId
/// only; everything else is omitted and the rebuild is not guaranteed to be
/// byte-equal to the source. Strict slots and write-nothing-on-failure as on
/// the default path.
func scriptPipelineExportParagraphsOnly(
    sourcePath: String,
    outputPath: String,
    slots: [SlotDesignation] = []
) throws -> ParagraphsOnlyExportSummary {
    let sourceURL = URL(fileURLWithPath: sourcePath)
    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
        throw ScriptPipelineError.fileNotFound(sourcePath)
    }
    // Same lookup the CLI uses to decide it will export the sidecar instead.
    if try SidecarStore.loadLog(alongside: sourceURL) != nil {
        throw ParagraphsOnlySidecarConflict(
            sidecarPath: SidecarStore.oplogURL(for: sourceURL).path)
    }
    let reversed = try paragraphsOnlyReverse(from: sourceURL)
    let source = try ScriptExporter.exportSwift(log: reversed.log, slots: slots)
    try source.write(to: URL(fileURLWithPath: outputPath),
                     atomically: true, encoding: .utf8)
    return ParagraphsOnlyExportSummary(
        omittedBodyBlocks: reversed.omittedBodyBlocks,
        slotCount: slots.count)
}

/// Builds the paragraphs-only authoring log from the docx typed views.
///
/// PORT, not a shared call: this is a line-for-line copy of
/// `MacDoc.Word.Reverse.reverseEngineer(from:)` (macdoc v0.10.0,
/// Sources/MacDocCLI/MacDoc+Word.swift). Unlike the full-fidelity path, that
/// logic lives in the CLI, not in ooxml-swift, so the two faces cannot share
/// it structurally until it is hoisted into the library. Until then the
/// gated cross-check in ScriptPipelineParityTests is what guards
/// byte-identical scripts — change both copies together.
///
/// The one deliberate difference is the skipped-block label: the CLI prints
/// `String(describing:).prefix(30)` to stderr; here the case name alone is
/// returned. It is informational only and never reaches the script.
func paragraphsOnlyReverse(from url: URL) throws
    -> (log: OperationLog, omittedBodyBlocks: [String])
{
    let document = try DocxReader.read(from: url, wireTreeBackedViews: true)
    var log = OperationLog()
    var omitted: [String] = []

    var paragraphIndex = 0
    for child in document.body.children {
        switch child {
        case .paragraph(let paragraph):
            paragraphIndex += 1
            var paraId: String?
            if let raw = paragraph.elementID?.raw,
               raw.hasPrefix("w14:paraId=") {
                paraId = String(raw.dropFirst("w14:paraId=".count))
            }
            // Paragraphs without a w14:paraId get a synthesized sequential
            // id (p<N>, N counts every top-level paragraph from 1) so the
            // script uses DSL Paragraph blocks and slots can target them.
            log.append(.appendParagraph(in: nil, paragraph: ParagraphPayload(
                text: paragraph.text,
                styleId: paragraph.properties.style,
                paraId: paraId ?? "p\(paragraphIndex)")), source: .swift)
        case .table:
            omitted.append("table")
        default:
            let described = String(describing: child)
            omitted.append(described.split(separator: "(", maxSplits: 1)
                .first.map(String.init) ?? described)
        }
    }
    return (log, omitted)
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
        // #227: same strict typing as the other optional parameters —
        // present-but-mistyped errors, explicit null counts as absent.
        var paragraphsOnly = false
        if let rawFlag = args["paragraphs_only"], rawFlag != .null {
            guard let flag = rawFlag.boolValue else {
                throw WordError.invalidParameter(
                    "paragraphs_only", "必須是布林值（收到非布林型別）")
            }
            paragraphsOnly = flag
        }

        if paragraphsOnly {
            let summary = try Self.mappingTranscodeErrors {
                try scriptPipelineExportParagraphsOnly(
                    sourcePath: sourcePath, outputPath: outputPath, slots: slots)
            }
            // A separate response shape on purpose: no dsl_parts (nothing is
            // byte-equal-proven) and no form_gaps_empty (not measured), plus
            // an explicit byte_equal:false so no caller can read this as the
            // full-fidelity result.
            return try scriptPipelineJSON([
                "paragraphs_only": true,
                "byte_equal": false,
                "omitted_body_blocks": summary.omittedBodyBlocks,
                "slot_count": summary.slotCount,
                "output_path": outputPath,
            ])
        }

        let summary = try Self.mappingTranscodeErrors {
            try scriptPipelineExport(
                sourcePath: sourcePath, outputPath: outputPath, slots: slots)
        }
        return try scriptPipelineJSON([
            "dsl_parts": summary.dslParts,
            "form_gaps_empty": summary.formGapsEmpty,
            "slot_count": summary.slotCount,
            "output_path": outputPath,
        ])
    }

    /// Strict mode: surface the transcoder's location/name-bearing reason
    /// (B2). Attribution split per verify R2 #1: only a designation failure
    /// is a `slots` problem — any other TranscodeError came from processing
    /// the SOURCE document. Shared by both export_script paths (#227).
    private static func mappingTranscodeErrors<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as TranscodeError {
            if case .slotDesignationFailure = error {
                throw WordError.invalidParameter("slots", describeTranscodeError(error))
            }
            throw WordError.invalidParameter("source_path", describeTranscodeError(error))
        }
    }

    func getScriptCoverageTool(args: [String: Value]) async throws -> String {
        guard let sourcePath = args["source_path"]?.stringValue else {
            throw WordError.missingParameter("source_path")
        }
        let report = try scriptPipelineCoverage(sourcePath: sourcePath)
        return try scriptPipelineJSON([
            "parts": report.parts.map { row in
                var entry: [String: Any] = [
                    "part_path": row.partPath,
                    "channel": row.channel,
                    "bytes": row.bytes,
                    "dsl_ratio": row.dslRatio,
                ]
                // #227: absent, never null, when no reason was computed —
                // DSL rows keep exactly their pre-#227 shape.
                if let reason = row.rawReason {
                    entry["raw_reason"] = reason
                }
                return entry
            },
            "aggregate_ratio": report.aggregateRatio,
        ])
    }

    func executeScriptTool(args: [String: Value]) async throws -> String {
        let profile = try resolveDocumentProfile(args: args, context: .existingDocument)
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
        // #181: the overwrite gate itself lives in the shared entry point, so
        // this only parses the argument and hands it over. Adding a
        // file-existence check here would rebuild the very defect being
        // fixed — a guard on one wrapper that the other face does not share.
        var overwrite = false
        if let rawOverwrite = args["overwrite"], rawOverwrite != .null {
            guard let flag = rawOverwrite.boolValue else {
                throw WordError.invalidParameter(
                    "overwrite", "必須是布林值（收到非布林型別）")
            }
            overwrite = flag
        }
        let result: ScriptExecuteResult
        do {
            result = try scriptPipelineExecute(
                scriptPath: scriptPath, outputPath: outputPath,
                verifyAgainst: verifyAgainst, overwrite: overwrite,
                formattingProfile: profile)
        } catch let error as TranscodeError {
            // B2: parse failures surface the transcoder's location-bearing
            // reason (task 3.4 contract).
            throw WordError.invalidParameter("script_path", describeTranscodeError(error))
        }
        // #180: a failing verdict is a FAILED call, not a successful one
        // carrying bad news. Nothing was published, so there is no result to
        // report either way.
        if result.verified == false {
            throw ScriptVerificationFailure(brokenParts: result.brokenParts)
        }
        var payload: [String: Any] = [:]
        if let written = result.written {
            // Absent, never null: assigning the Optional straight into the
            // payload emits `"written":null`, a shape no caller was told to
            // expect. Absence already means "did not happen" here, matching
            // the verdict fields below.
            payload["written"] = written
        }
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
