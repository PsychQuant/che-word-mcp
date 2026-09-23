import Foundation
import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

final class Issue197FormatTextFalseTests: XCTestCase {
    func testFormatTextFalsePersistsAndOmittedFieldsRemainUnchanged() async throws {
        let server = await WordMCPServer()
        let docId = "format-false-\(UUID().uuidString)"
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("format-false-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: output) }

        try await requireSuccess(server, "create_document", ["doc_id": .string(docId)])
        try await requireSuccess(server, "insert_paragraph", [
            "doc_id": .string(docId),
            "text": .string("formatted text"),
        ])
        try await requireSuccess(server, "format_text", [
            "doc_id": .string(docId),
            "paragraph_index": .int(0),
            "bold": .bool(true),
            "italic": .bool(true),
            "underline": .bool(true),
        ])

        // Explicit false clears bold. Omitted italic/underline remain on.
        try await requireSuccess(server, "format_text", [
            "doc_id": .string(docId),
            "paragraph_index": .int(0),
            "bold": .bool(false),
        ])

        // A later patch omits bold and clears the remaining two properties.
        try await requireSuccess(server, "format_text", [
            "doc_id": .string(docId),
            "paragraph_index": .int(0),
            "italic": .bool(false),
            "underline": .bool(false),
        ])
        try await requireSuccess(server, "save_document", [
            "doc_id": .string(docId),
            "path": .string(output.path),
        ])

        var reopened = try DocxReader.read(from: output)
        defer { reopened.close() }
        let properties = try XCTUnwrap(reopened.getParagraphs().first?.runs.first?.properties)
        XCTAssertFalse(properties.bold)
        XCTAssertFalse(properties.italic)
        XCTAssertNil(properties.underline)
    }

    func testFormatTextFalseAsRevisionPreservesOmittedProperties() async throws {
        let server = await WordMCPServer()
        let docId = "format-false-revision-\(UUID().uuidString)"
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("format-false-revision-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: output) }

        try await requireSuccess(server, "create_document", ["doc_id": .string(docId)])
        try await requireSuccess(server, "insert_paragraph", [
            "doc_id": .string(docId),
            "text": .string("revision text"),
        ])
        try await requireSuccess(server, "format_text", [
            "doc_id": .string(docId),
            "paragraph_index": .int(0),
            "bold": .bool(true),
            "italic": .bool(true),
        ])
        try await requireSuccess(server, "enable_track_changes", [
            "doc_id": .string(docId),
            "author": .string("Reviewer"),
        ])

        try await requireSuccess(server, "format_text", [
            "doc_id": .string(docId),
            "paragraph_index": .int(0),
            "run_index": .int(0),
            "bold": .bool(false),
            "as_revision": .bool(true),
        ])
        try await requireSuccess(server, "save_document", [
            "doc_id": .string(docId),
            "path": .string(output.path),
        ])

        var reopened = try DocxReader.read(from: output)
        defer { reopened.close() }
        let run = try XCTUnwrap(reopened.getParagraphs().first?.runs.first)
        XCTAssertFalse(run.properties.bold)
        XCTAssertTrue(run.properties.italic, "omitted italic must remain unchanged")
        let previous = try XCTUnwrap(
            reopened.revisions.revisions.first(where: { $0.previousFormat != nil })?.previousFormat
        )
        XCTAssertTrue(previous.bold)
        XCTAssertTrue(previous.italic)
    }

    /// paragraph_index counts direct body paragraphs only (the tool's contract,
    /// and what applyRunPropertiesAsRevision uses). A block-level SDT paragraph
    /// before the target must not become the seed for the target's patch.
    func testFormatTextAsRevisionSeedsFromIndexedParagraphAfterBlockSDT() async throws {
        var sdtProperties = RunProperties()
        sdtProperties.bold = true
        var targetProperties = RunProperties()
        targetProperties.bold = true
        targetProperties.italic = true

        var document = WordDocument()
        let control = ContentControl(
            sdt: StructuredDocumentTag(id: 197001, tag: "wrap", type: .richText),
            content: ""
        )
        document.body.children = [
            .contentControl(control, children: [
                .paragraph(Paragraph(runs: [Run(text: "inside sdt", properties: sdtProperties)])),
            ]),
            .paragraph(Paragraph(runs: [Run(text: "target", properties: targetProperties)])),
        ]
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("format-false-sdt-src-\(UUID().uuidString).docx")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("format-false-sdt-out-\(UUID().uuidString).docx")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }
        try DocxWriter.write(document, to: source)

        let server = await WordMCPServer()
        let docId = "format-false-sdt-\(UUID().uuidString)"
        try await requireSuccess(server, "open_document", [
            "path": .string(source.path),
            "doc_id": .string(docId),
        ])
        try await requireSuccess(server, "enable_track_changes", [
            "doc_id": .string(docId),
            "author": .string("Reviewer"),
        ])
        try await requireSuccess(server, "format_text", [
            "doc_id": .string(docId),
            "paragraph_index": .int(0),
            "run_index": .int(0),
            "bold": .bool(false),
            "as_revision": .bool(true),
        ])
        try await requireSuccess(server, "save_document", [
            "doc_id": .string(docId),
            "path": .string(output.path),
        ])

        var reopened = try DocxReader.read(from: output)
        defer { reopened.close() }
        let direct = reopened.body.children.compactMap { child -> Paragraph? in
            if case .paragraph(let paragraph) = child { return paragraph }
            return nil
        }
        let target = try XCTUnwrap(direct.first?.runs.first)
        XCTAssertEqual(target.text, "target")
        XCTAssertFalse(target.properties.bold)
        XCTAssertTrue(target.properties.italic, "the SDT paragraph's properties must not seed the target")
    }

    private func requireSuccess(
        _ server: WordMCPServer,
        _ name: String,
        _ arguments: [String: Value]
    ) async throws {
        let result = await server.invokeToolForTesting(name: name, arguments: arguments)
        if result.isError == true {
            XCTFail("\(name) failed: \(result)")
        }
    }
}
