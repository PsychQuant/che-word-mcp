import XCTest
import MCP
import DocxForm
@testable import CheWordMCP

/// #300 — `classify_form` and `apply_form`: the MCP face of the DocxForm
/// library (ooxml-swift 3.21.0) that `macdoc word form classify|apply` uses.
/// Every call goes through `handleToolCall`, so refusals are checked on the
/// wire (`isError: true`, `Error: ` prefix), not through a test seam.
final class FormToolsTests: XCTestCase {
    private static let namespaces = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml""#

    /// A two-column table (label, field) followed by a checkbox line.
    private static let form: [UInt8] = Array((
        #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        + "<w:document \(namespaces)><w:body>"
        + #"<w:tbl><w:tblPr/><w:tblGrid><w:gridCol w:w="2000"/><w:gridCol w:w="4000"/></w:tblGrid><w:tr>"#
        + #"<w:tc><w:p w14:paraId="0000A001"><w:r><w:t>Name</w:t></w:r></w:p></w:tc>"#
        + #"<w:tc><w:p w14:paraId="0000A002"><w:r><w:t>Applicant</w:t></w:r></w:p></w:tc>"#
        + "</w:tr></w:tbl>"
        + "<w:p w14:paraId=\"0000A003\"><w:r><w:t>\u{25A1} Agree</w:t></w:r></w:p>"
        + #"<w:sectPr><w:pgSz w:w="11906" w:h="16838"/></w:sectPr>"#
        + "</w:body></w:document>").utf8)

    private static let styles = Data("<w:styles/>".utf8)

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("FormToolsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - helpers

    private func makeDocx(_ document: [UInt8] = FormToolsTests.form, name: String = "in.docx") throws -> String {
        let url = dir.appendingPathComponent(name)
        try DocxPackage.write([DocxPackage.Entry(path: DocxPackage.documentPart, data: Data(document)),
                               DocxPackage.Entry(path: "word/styles.xml", data: Self.styles)], to: url)
        return url.path
    }

    private func call(_ name: String, _ args: [String: Value]) async throws -> CallTool.Result {
        let server = await WordMCPServer()
        return try await server.handleToolCall(CallTool.Parameters(name: name, arguments: args))
    }

    private func text(_ r: CallTool.Result) -> String {
        guard let first = r.content.first, case .text(let t, _, _) = first else { return "" }
        return t
    }

    private func json(_ r: CallTool.Result, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        XCTAssertNotEqual(r.isError, true, "unexpected refusal: \(text(r))", file: file, line: line)
        let object = try JSONSerialization.jsonObject(with: Data(text(r).utf8))
        return try XCTUnwrap(object as? [String: Any], file: file, line: line)
    }

    private func assertRefused(_ r: CallTool.Result, containing needle: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.isError, true, "expected isError: true, got \(text(r).prefix(200))", file: file, line: line)
        XCTAssertTrue(text(r).hasPrefix("Error: "), "missing 'Error: ' prefix: \(text(r).prefix(80))", file: file, line: line)
        XCTAssertTrue(text(r).contains(needle), "expected '\(needle)' in \(text(r).prefix(300))", file: file, line: line)
    }

    private func documentXML(at path: String) throws -> String {
        let parts = try DocxPackage.readParts(from: URL(fileURLWithPath: path), paths: [DocxPackage.documentPart])
        return String(decoding: try XCTUnwrap(parts.first).data, as: UTF8.self)
    }

    // MARK: - tool list

    func testBothToolsAreListedWithTheirRequiredParameters() async throws {
        let server = await WordMCPServer()
        let tools = Dictionary(uniqueKeysWithValues: await server.allTools.map { ($0.name, $0) })
        let classify = try XCTUnwrap(tools["classify_form"])
        let apply = try XCTUnwrap(tools["apply_form"])
        XCTAssertEqual(classify.inputSchema.objectValue?["required"]?.arrayValue?.compactMap(\.stringValue), ["source_path"])
        XCTAssertEqual(apply.inputSchema.objectValue?["required"]?.arrayValue?.compactMap(\.stringValue).sorted(),
                       ["output_path", "source_path"])
    }

    // MARK: - classify_form

    func testClassifyReportsKindsTextAndGrid() async throws {
        let source = try makeDocx()
        let result = try json(await call("classify_form", ["source_path": .string(source), "include_grid": .bool(true)]))
        let paragraphs = try XCTUnwrap(result["paragraphs"] as? [[String: Any]])
        XCTAssertEqual(paragraphs.compactMap { $0["para_id"] as? String }, ["0000A001", "0000A002", "0000A003"])
        XCTAssertEqual(paragraphs.compactMap { $0["kind"] as? String }, ["table-field", "table-field", "checkbox-line"])
        XCTAssertEqual(paragraphs.last?["text"] as? String, "\u{25A1} Agree")
        XCTAssertEqual(paragraphs.map { $0["position"] as? String }, ["t1:r1c1", "t1:r1c2", nil])
        let cell = try XCTUnwrap(paragraphs[1]["cell"] as? [String: Any])
        XCTAssertEqual(cell["table"] as? Int, 1)
        XCTAssertEqual(cell["rows"] as? [Int], [1, 1])
        XCTAssertEqual(cell["columns"] as? [Int], [2, 2])
        XCTAssertEqual(result["skipped_invalid_para_ids"] as? Int, 0)
    }

    func testClassifyWithoutGridOmitsPositions() async throws {
        let source = try makeDocx()
        let result = try json(await call("classify_form", ["source_path": .string(source)]))
        let paragraphs = try XCTUnwrap(result["paragraphs"] as? [[String: Any]])
        XCTAssertTrue(paragraphs.allSatisfy { $0["position"] == nil && $0["cell"] == nil })
    }

    func testClassifySkipsIdsThatAreNotEightHexDigitsLikeTheCLI() async throws {
        let document = String(decoding: Self.form, as: UTF8.self)
            .replacingOccurrences(of: "0000A003", with: "NOT-HEX!")
        let source = try makeDocx(Array(document.utf8))
        let result = try json(await call("classify_form", ["source_path": .string(source)]))
        let paragraphs = try XCTUnwrap(result["paragraphs"] as? [[String: Any]])
        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertEqual(result["skipped_invalid_para_ids"] as? Int, 1)
    }

    func testClassifyReportsAnUnreadableTable() async throws {
        let merged: [UInt8] = Array((
            "<w:document \(Self.namespaces)><w:body><w:tbl><w:tblPr/><w:tblGrid/><w:tr>"
            + #"<w:tc><w:tcPr><w:hMerge w:val="restart"/></w:tcPr><w:p w14:paraId="0000B001"/></w:tc>"#
            + "</w:tr></w:tbl></w:body></w:document>").utf8)
        let source = try makeDocx(merged)
        let result = try json(await call("classify_form", ["source_path": .string(source), "include_grid": .bool(true)]))
        XCTAssertEqual(result["unreadable_tables"] as? [Int], [1])
        let paragraphs = try XCTUnwrap(result["paragraphs"] as? [[String: Any]])
        XCTAssertEqual(paragraphs.first?["position"] as? String, "t1:?")
    }

    func testClassifyRefusesMalformedXMLWithTheCLIMessage() async throws {
        let source = try makeDocx(Array("<w:document><w:body>".utf8))
        let r = try await call("classify_form", ["source_path": .string(source)])
        var expected = ""
        do { _ = try FormClassifier.classify(documentXML: Array("<w:document><w:body>".utf8), numberingXML: nil) }
        catch let error as XMLScanError { expected = FormError.malformedPart(error.description).description }
        XCTAssertFalse(expected.isEmpty)
        assertRefused(r, containing: expected)
    }

    // MARK: - apply_form

    func testApplyFieldsWritesOnlyTheDocumentPart() async throws {
        let source = try makeDocx()
        let output = dir.appendingPathComponent("out.docx").path
        let result = try json(await call("apply_form", [
            "source_path": .string(source), "output_path": .string(output),
            "fields": .array([.string("0000A002")]), "field_size": .int(12),
        ]))
        XCTAssertEqual(result["written"] as? String, output)
        XCTAssertEqual(result["field_size"] as? String, "12 pt")
        XCTAssertEqual(result["field_size_derived"] as? Bool, false)
        XCTAssertTrue(try documentXML(at: output).contains(#"w:val="24""#))
        let styles = try DocxPackage.readParts(from: URL(fileURLWithPath: output), paths: ["word/styles.xml"])
        XCTAssertEqual(styles.first?.data, Self.styles)
    }

    func testApplyAcceptsANumericFieldSize() async throws {
        let source = try makeDocx()
        let output = dir.appendingPathComponent("out.docx").path
        let result = try json(await call("apply_form", [
            "source_path": .string(source), "output_path": .string(output),
            "fields": .array([.string("0000A002")]), "field_size": .double(10.5),
        ]))
        XCTAssertEqual(result["field_size"] as? String, "10.5 pt")
    }

    func testApplyTableDefaultsReportsTheFillCells() async throws {
        let source = try makeDocx()
        let output = dir.appendingPathComponent("out.docx").path
        let result = try json(await call("apply_form", [
            "source_path": .string(source), "output_path": .string(output), "field_size": .int(12),
            "table_defaults": .array([.object([
                "anchor": .string("0000A001"),
                "columns": .array([.object(["from": .int(2)])]),
            ])]),
        ]))
        let reports = try XCTUnwrap(result["table_defaults"] as? [[String: Any]])
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0]["anchor"] as? String, "0000A001")
        XCTAssertEqual(reports[0]["fill_cells"] as? Int, 1)
        XCTAssertEqual(reports[0]["partial_cells"] as? [String], [])
        XCTAssertEqual(reports[0]["skipped_cells"] as? [String], [])
    }

    func testApplyRefusesAnInvalidGridRangeWithTheLibraryMessage() async throws {
        let source = try makeDocx()
        let output = dir.appendingPathComponent("out.docx").path
        let r = try await call("apply_form", [
            "source_path": .string(source), "output_path": .string(output),
            "table_defaults": .array([.object([
                "anchor": .string("0000A001"),
                "columns": .array([.object(["from": .int(3), "to": .int(2)])]),
            ])]),
        ])
        XCTAssertEqual(r.isError, true, text(r))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output))
    }

    func testApplyInsertsAndReturnsTheNotes() async throws {
        let source = try makeDocx()
        let output = dir.appendingPathComponent("out.docx").path
        let result = try json(await call("apply_form", [
            "source_path": .string(source), "output_path": .string(output),
            "insertions": .array([.object(["anchor": .string("0000A003"), "text": .string("Note")])]),
        ]))
        XCTAssertTrue(try documentXML(at: output).contains(">Note<"))
        XCTAssertEqual(result["skipped_checkbox_runs"] as? Int, 0)
        XCTAssertEqual(result["added_final_paragraph"] as? Bool, false)
        XCTAssertEqual((result["skipped_cleanups"] as? [Any])?.count, 0)
    }

    func testApplyRefusesAnUnknownParagraphWithTheLibraryMessageAndWritesNothing() async throws {
        let source = try makeDocx()
        let output = dir.appendingPathComponent("out.docx").path
        let r = try await call("apply_form", [
            "source_path": .string(source), "output_path": .string(output),
            "fields": .array([.string("FFFFFFFF")]),
        ])
        var expected = ""
        do { _ = try FormPlan(fields: ["FFFFFFFF"]).apply(toDocumentXML: Self.form) }
        catch let error as FormError { expected = error.description }
        XCTAssertFalse(expected.isEmpty)
        assertRefused(r, containing: expected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output))
    }

    func testApplyRefusesAnExistingOutputUnlessOverwrite() async throws {
        let source = try makeDocx()
        let output = try makeDocx(name: "existing.docx")
        let before = try Data(contentsOf: URL(fileURLWithPath: output))
        // field_size given so the second call measures only the overwrite
        // switch: this fixture's field has no explicit size to derive from.
        let args: [String: Value] = ["source_path": .string(source), "output_path": .string(output),
                                     "fields": .array([.string("0000A002")]), "field_size": .int(12)]
        let refused = try await call("apply_form", args)
        assertRefused(refused, containing: DocxPackageError.outputExists(output).description)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: output)), before)

        var overwrite = args
        overwrite["overwrite"] = .bool(true)
        _ = try json(await call("apply_form", overwrite))
        XCTAssertNotEqual(try Data(contentsOf: URL(fileURLWithPath: output)), before)
    }

    func testApplyNeedsAtLeastOneOperation() async throws {
        let source = try makeDocx()
        let output = dir.appendingPathComponent("out.docx").path
        let r = try await call("apply_form", ["source_path": .string(source), "output_path": .string(output)])
        XCTAssertEqual(r.isError, true)
        XCTAssertTrue(text(r).contains("fields"), text(r))
    }

    func testFieldSizeNeedsFieldsOrTableDefaults() async throws {
        let source = try makeDocx()
        let output = dir.appendingPathComponent("out.docx").path
        let r = try await call("apply_form", [
            "source_path": .string(source), "output_path": .string(output),
            "field_size": .int(12), "checkbox_font": .string("MS Gothic"),
        ])
        XCTAssertEqual(r.isError, true)
        XCTAssertTrue(text(r).contains("field_size"), text(r))
    }

    func testMistypedParametersAreRefusedNotIgnored() async throws {
        let source = try makeDocx()
        let output = dir.appendingPathComponent("out.docx").path
        for (key, value) in [("fields", Value.string("0000A002")), ("overwrite", .string("yes")),
                             ("removals", .array([.int(1)])), ("insertions", .array([.string("0000A003=x")])),
                             ("field_size", .string("12"))] {
            let r = try await call("apply_form", [
                "source_path": .string(source), "output_path": .string(output),
                "checkbox_font": .string("MS Gothic"), key: value,
            ])
            XCTAssertEqual(r.isError, true, "\(key): \(text(r))")
            XCTAssertTrue(text(r).contains(key), "\(key): \(text(r))")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output))
    }
}
