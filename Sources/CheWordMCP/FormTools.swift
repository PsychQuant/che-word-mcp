import Foundation
import MCP
import OOXMLSwift
import DocxForm

// MARK: - #300 form tools: classify_form / apply_form
//
// The MCP face of ooxml-swift's DocxForm product (3.21.0, ooxml-swift#238),
// the same library behind `macdoc word form classify|apply`. Both tools work
// on file paths, never on a session `doc_id`: DocxForm edits the named
// elements of word/document.xml as strings and copies every other part byte
// for byte, so a form never passes through the typed Document a session holds.
//
// Parameter names follow `FormPlan`'s fields, not the CLI's flags: names are
// how each consumer is reached, so they belong to that consumer (macdoc
// .claude/rules/format-library-vs-access-surface.md). Refusals carry the
// library's message verbatim, as the CLI does; some of those messages still
// name CLI flags, which #300 records as residue.

/// Deterministic JSON encoding for tool responses (sortedKeys → stable output).
private func formToolsJSON(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}

extension WordMCPServer {

    // MARK: - classify_form

    func classifyFormTool(args: [String: Value]) async throws -> String {
        guard let sourcePath = args["source_path"]?.stringValue else {
            throw WordError.missingParameter("source_path")
        }
        let includeGrid = try optionalBool(args, "include_grid") ?? false
        return try Self.mappingFormErrors {
            // Only the two parts classification reads are extracted (macdoc#252).
            let entries = try DocxPackage.readParts(from: URL(fileURLWithPath: sourcePath),
                                                    paths: [DocxPackage.documentPart, DocxPackage.numberingPart])
            guard let document = entries.first(where: { $0.path == DocxPackage.documentPart }) else {
                throw DocxPackageError.missingPart(DocxPackage.documentPart)
            }
            let numbering = entries.first { $0.path == DocxPackage.numberingPart }
            let paragraphs = try FormClassifier.classify(documentXML: Array(document.data),
                                                         numberingXML: numbering.map { Array($0.data) },
                                                         withCells: includeGrid)
            var rows: [[String: Any]] = []
            var skipped = 0
            var unreadableTables: Set<Int> = []
            for paragraph in paragraphs {
                // The table is unreadable whatever its paragraphs' ids are, so
                // it is recorded before the id check (verify R1; the CLI checks
                // the id first and misses a table whose ids are all skipped).
                if includeGrid, case .unreadableTable(let table)? = paragraph.cell {
                    unreadableTables.insert(table)
                }
                // Same rule as the CLI: a w14:paraId is eight hexadecimal
                // digits; any other value comes from a damaged or crafted file.
                guard Self.isFormParaId(paragraph.paraId) else { skipped += 1; continue }
                var row: [String: Any] = ["para_id": paragraph.paraId, "kind": paragraph.kind.rawValue,
                                          "text": paragraph.text]
                if includeGrid, let cell = paragraph.cell {
                    row["position"] = cell.description
                    switch cell {
                    case .cell(let table, let rowRange, let columnRange):
                        row["cell"] = ["table": table, "rows": [rowRange.lowerBound, rowRange.upperBound],
                                       "columns": [columnRange.lowerBound, columnRange.upperBound]]
                    case .unreadableTable(let table):
                        row["cell"] = ["table": table, "unreadable": true]
                    }
                }
                rows.append(row)
            }
            var payload: [String: Any] = [
                "paragraphs": rows,
                "skipped_invalid_para_ids": skipped,
                // An unreadable numbering part disables list-checkbox detection only.
                "numbering_readable": numbering.map { FormClassifier.isReadableNumbering(Array($0.data)) } ?? true,
            ]
            if includeGrid { payload["unreadable_tables"] = unreadableTables.sorted() }
            return try formToolsJSON(payload)
        }
    }

    // MARK: - apply_form

    func applyFormTool(args: [String: Value]) async throws -> String {
        guard let sourcePath = args["source_path"]?.stringValue else {
            throw WordError.missingParameter("source_path")
        }
        guard let outputPath = args["output_path"]?.stringValue else {
            throw WordError.missingParameter("output_path")
        }
        let overwrite = try optionalBool(args, "overwrite") ?? false
        let fields = try Self.formStrings(args, "fields")
        let tickList = try Self.formStrings(args, "tick_list")
        let removals = try Self.formStrings(args, "removals")
        let removedTables = try Self.formStrings(args, "removed_tables")
        let checkboxFont = try Self.formString(args, "checkbox_font")
        let truncateFrom = try Self.formString(args, "truncate_from")
        let insertions = try Self.formInsertions(args)
        // A JSON number (12, 10.5). It reaches the library as text so the
        // library's parser stays the only place the value is checked; a
        // fraction or a value past Int's range is spelled by String(_:) and
        // refused there when it is not a 0.5 pt step within range.
        let rawFieldSize = try optionalDouble(args, "field_size")
            .map { Int(exactly: $0).map(String.init) ?? String($0) }
        let (plan, fieldSizeGiven): (FormPlan, Bool) = try Self.mappingFormErrors {
            let tableDefaults = try Self.formTableDefaults(args)
            let size = try rawFieldSize.map { try FieldSize.parse(points: $0) }
            return (FormPlan(fields: fields, fieldSize: size, checkboxFont: checkboxFont, tickList: tickList,
                             insertions: insertions, removals: removals, removedTables: removedTables,
                             truncateFrom: truncateFrom, tableDefaults: tableDefaults), size != nil)
        }
        guard plan.hasOperations else {
            throw ToolRefusal("至少要指定一個操作：fields、table_defaults、checkbox_font、tick_list、insertions、removals、removed_tables 或 truncate_from")
        }
        if fieldSizeGiven, plan.fields.isEmpty, plan.tableDefaults.isEmpty {
            throw ToolRefusal("field_size 需要搭配 fields 或 table_defaults")
        }

        var outcome: FormResult?
        try Self.mappingFormErrors {
            try DocxPackage.rewriteDocument(input: URL(fileURLWithPath: sourcePath),
                                            output: URL(fileURLWithPath: outputPath),
                                            force: overwrite) { document, _ in
                let result = try plan.apply(toDocumentXML: Array(document))
                outcome = result
                return Data(result.documentXML)
            }
        }
        guard let outcome else {
            throw ToolRefusal("表單整理沒有產生結果，未寫出檔案")
        }
        var payload: [String: Any] = [
            "written": outputPath,
            "field_size_derived": outcome.fieldSizeWasDerived,
            "skipped_checkbox_runs": outcome.skippedCheckboxRuns,
            "added_final_paragraph": outcome.addedFinalParagraph,
            "table_defaults": outcome.tableDefaultsReports.map { report -> [String: Any] in
                ["anchor": report.anchor, "fill_cells": report.fillCells,
                 "partial_cells": report.partialCells, "skipped_cells": report.skippedCells]
            },
            "skipped_cleanups": outcome.skippedCleanups.map { skip -> [String: Any] in
                ["para_id": skip.paragraphId, "reasons": skip.reasons.map(\.elementName)]
            },
        ]
        if let size = outcome.fieldSize { payload["field_size"] = size.pointsDescription }
        return try formToolsJSON(payload)
    }

    // MARK: - Errors

    /// DocxForm's errors become refusals carrying the library's message; an
    /// XML scan error is wrapped the way the CLI wraps it. The messages quote
    /// caller- and file-supplied text (paraIds, entry names), so control and
    /// bidirectional formatting characters are replaced, as the CLI does.
    private static func mappingFormErrors<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as FormError {
            throw ToolRefusal(sanitizedFormMessage(error.description))
        } catch let error as DocxPackageError {
            throw ToolRefusal(sanitizedFormMessage(error.description))
        } catch let error as XMLScanError {
            throw ToolRefusal(sanitizedFormMessage(FormError.malformedPart(error.description).description))
        }
    }

    /// The same set macdoc's `TerminalText` replaces (macdoc#249): every
    /// control character, the line and paragraph separators and the
    /// bidirectional formatting characters become a space.
    static func sanitizedFormMessage(_ text: String) -> String {
        let bidi: Set<Unicode.Scalar> = ["\u{061C}", "\u{200E}", "\u{200F}", "\u{202A}", "\u{202B}", "\u{202C}",
                                         "\u{202D}", "\u{202E}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}"]
        let scalars = text.unicodeScalars.map { scalar -> Unicode.Scalar in
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: return " "
            default: return bidi.contains(scalar) ? " " : scalar
            }
        }
        return String(String.UnicodeScalarView(scalars))
    }

    // MARK: - Argument parsing (strict: present but mistyped is an error, #134)

    /// True for exactly eight ASCII hexadecimal digits.
    static func isFormParaId(_ id: String) -> Bool {
        id.utf8.count == 8 && id.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0)
        }
    }

    private static func present(_ args: [String: Value], _ key: String) -> Value? {
        guard let value = args[key], value != .null else { return nil }
        return value
    }

    private static func formString(_ args: [String: Value], _ key: String) throws -> String? {
        guard let value = present(args, key) else { return nil }
        guard let string = value.stringValue else { throw WordError.invalidParameter(key, "必須是字串") }
        return string
    }

    private static func formStrings(_ args: [String: Value], _ key: String) throws -> [String] {
        guard let value = present(args, key) else { return [] }
        guard let items = value.arrayValue else { throw WordError.invalidParameter(key, "必須是字串陣列") }
        return try items.map { item in
            guard let string = item.stringValue else { throw WordError.invalidParameter(key, "必須是字串陣列（有元素不是字串）") }
            return string
        }
    }

    private static func formInsertions(_ args: [String: Value]) throws -> [FormInsertion] {
        guard let value = present(args, "insertions") else { return [] }
        guard let items = value.arrayValue else { throw WordError.invalidParameter("insertions", "必須是物件陣列") }
        return try items.map { item in
            guard let object = item.objectValue,
                  let anchor = object["anchor"]?.stringValue, !anchor.isEmpty,
                  let text = object["text"]?.stringValue else {
                throw WordError.invalidParameter("insertions", "每個元素必須是 {anchor: 非空字串, text: 字串}")
            }
            return FormInsertion(anchor: anchor, text: text)
        }
    }

    /// `{anchor, columns, rows}`; `columns` and `rows` are lists of grid
    /// ranges `{from, to}` (1-based, `to` omitted = to the last). At least one
    /// of the two lists, as with the CLI's `col:` / `row:` (macdoc#250).
    private static func formTableDefaults(_ args: [String: Value]) throws -> [TableDefaults] {
        guard let value = present(args, "table_defaults") else { return [] }
        guard let items = value.arrayValue else { throw WordError.invalidParameter("table_defaults", "必須是物件陣列") }
        return try items.map { item in
            guard let object = item.objectValue, let anchor = object["anchor"]?.stringValue, !anchor.isEmpty else {
                throw WordError.invalidParameter("table_defaults", "每個元素必須有 anchor（非空字串）")
            }
            let columns = try gridSelection(object["columns"], key: "columns")
            let rows = try gridSelection(object["rows"], key: "rows")
            guard columns != nil || rows != nil else {
                throw WordError.invalidParameter("table_defaults", "每個元素至少要有 columns 或 rows")
            }
            return TableDefaults(anchor: anchor, columns: columns, rows: rows)
        }
    }

    private static func gridSelection(_ value: Value?, key: String) throws -> GridSelection? {
        guard let value, value != .null else { return nil }
        guard let ranges = value.arrayValue else {
            throw WordError.invalidParameter("table_defaults", "\(key) 必須是範圍物件陣列")
        }
        let items: [GridSelection.Item] = try ranges.map { range in
            guard let object = range.objectValue, let from = gridNumber(object["from"]) else {
                throw WordError.invalidParameter("table_defaults", "\(key) 的每個範圍必須有整數 from")
            }
            guard let rawTo = object["to"], rawTo != .null else { return .from(from) }
            guard let to = gridNumber(rawTo) else {
                throw WordError.invalidParameter("table_defaults", "\(key) 的 to 必須是整數")
            }
            return to == from ? .single(from) : .range(from, to)
        }
        // GridSelection checks the values (non-empty, n ≥ 1, from ≤ to); its
        // message is kept and prefixed with the parameter and axis it came from.
        do {
            return try GridSelection(items: items)
        } catch let error as FormError {
            throw WordError.invalidParameter("table_defaults", "\(key)：\(error.description)")
        }
    }

    private static func gridNumber(_ value: Value?) -> Int? {
        guard let value else { return nil }
        if let int = value.intValue { return int }
        if let double = value.doubleValue { return Int(exactly: double) }
        return nil
    }
}
