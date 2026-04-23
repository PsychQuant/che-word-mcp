import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// Session state management tests (contributed by @ildunari)
final class WordMCPServerTests: XCTestCase {
    private func tempURL(_ suffix: String = UUID().uuidString) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cheword-\(suffix).docx")
    }

    private func writeDocument(text: String, to url: URL) throws {
        var document = WordDocument()
        document.appendParagraph(Paragraph(text: text))
        try DocxWriter.write(document, to: url)
    }

    private func readDocumentText(from url: URL) throws -> String {
        try DocxReader.read(from: url).getText()
    }

    private func resultText(_ result: CallTool.Result) -> String {
        guard let first = result.content.first else { return "" }
        switch first {
        case .text(let text, _, _):
            return text
        default:
            return ""
        }
    }

    func testCreateDocumentEnablesTrackChangesByDefault() async {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "create_document",
            arguments: ["doc_id": .string("doc")]
        )

        do {
            let trackChanges_ = await server.isTrackChangesEnabledForTesting("doc")
            XCTAssertEqual(trackChanges_, true)
        }
    }

    func testDirtyDocumentCannotCloseWithoutSave() async {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "create_document",
            arguments: ["doc_id": .string("doc")]
        )
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("doc"),
                "text": .string("Hello from test")
            ]
        )

        let closeResult = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc")]
        )

        // v3.0.0: dirty close returns an Error: E_DIRTY_DOC text response (not an MCP-level error)
        // listing 3 recovery paths. Doc remains dirty and in openDocuments.
        let text = resultText(closeResult)
        XCTAssertTrue(text.contains("E_DIRTY_DOC"))
        XCTAssertTrue(text.contains("discard_changes"))
        XCTAssertTrue(text.contains("finalize_document"))
        do {
            let isDirty_ = await server.isDocumentDirtyForTesting("doc")
            XCTAssertTrue(isDirty_)
        }
    }

    func testDuplicateDocIdIsRejectedBeforeOverwrite() async {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "create_document",
            arguments: ["doc_id": .string("doc")]
        )
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("doc"),
                "text": .string("Unsaved draft")
            ]
        )

        let duplicateCreate = await server.invokeToolForTesting(
            name: "create_document",
            arguments: ["doc_id": .string("doc")]
        )

        XCTAssertEqual(duplicateCreate.isError, true)
        XCTAssertTrue(resultText(duplicateCreate).contains("Document already open"))
        do {
            let isDirty_ = await server.isDocumentDirtyForTesting("doc")
            XCTAssertTrue(isDirty_)
        }
    }

    func testNewDocumentRequiresExplicitPathForFirstSave() async {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "create_document",
            arguments: ["doc_id": .string("doc")]
        )
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("doc"),
                "text": .string("Hello")
            ]
        )

        let saveResult = await server.invokeToolForTesting(
            name: "save_document",
            arguments: ["doc_id": .string("doc")]
        )

        XCTAssertEqual(saveResult.isError, true)
        XCTAssertTrue(resultText(saveResult).contains("No path was provided"))
        do {
            let isDirty_ = await server.isDocumentDirtyForTesting("doc")
            XCTAssertTrue(isDirty_)
        }
    }

    func testSaveDocumentWithoutPathUsesOriginalOpenedPath() async throws {
        let url = tempURL("save-fallback")
        try writeDocument(text: "Before", to: url)

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: [
                "path": .string(url.path),
                "doc_id": .string("doc")
            ]
        )
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("doc"),
                "text": .string("After")
            ]
        )

        let saveResult = await server.invokeToolForTesting(
            name: "save_document",
            arguments: ["doc_id": .string("doc")]
        )

        XCTAssertEqual(saveResult.isError, nil)
        XCTAssertTrue(resultText(saveResult).contains("original path"))
        XCTAssertTrue(try readDocumentText(from: url).contains("After"))
        do {
            let isDirty_ = await server.isDocumentDirtyForTesting("doc")
            XCTAssertFalse(isDirty_)
        }
    }

    func testAutosavePersistsMutationsImmediatelyWhenEnabled() async throws {
        let url = tempURL("autosave")
        try writeDocument(text: "Start", to: url)

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: [
                "path": .string(url.path),
                "doc_id": .string("doc"),
                "autosave": .bool(true)
            ]
        )

        let insertResult = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("doc"),
                "text": .string("Autosaved line")
            ]
        )

        XCTAssertEqual(insertResult.isError, nil)
        XCTAssertTrue(try readDocumentText(from: url).contains("Autosaved line"))
        do {
            let isDirty_ = await server.isDocumentDirtyForTesting("doc")
            XCTAssertFalse(isDirty_)
        }
    }

    func testGetDocumentSessionStateReportsDirtyAndFinalizeReadiness() async throws {
        let url = tempURL("session-state")
        try writeDocument(text: "State doc", to: url)

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: [
                "path": .string(url.path),
                "doc_id": .string("doc"),
                // v3.0.0: track_changes default flipped to false; opt-in for this legacy test
                "track_changes": .bool(true)
            ]
        )
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("doc"),
                "text": .string("Dirty edit")
            ]
        )

        let stateResult = await server.invokeToolForTesting(
            name: "get_document_session_state",
            arguments: ["doc_id": .string("doc")]
        )

        let text = resultText(stateResult)
        XCTAssertEqual(stateResult.isError, nil)
        XCTAssertTrue(text.contains("Dirty: true"))
        XCTAssertTrue(text.contains("Track changes enabled: true"))
        XCTAssertTrue(text.contains("Save without explicit path available: true"))
        XCTAssertTrue(text.contains("Close without save allowed: false"))
        XCTAssertTrue(text.contains("Finalize without explicit path available: true"))
    }

    func testGetDocumentSessionStateForNewDocumentRequiresExplicitSavePath() async {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "create_document",
            arguments: ["doc_id": .string("doc")]
        )

        let stateResult = await server.invokeToolForTesting(
            name: "get_document_session_state",
            arguments: ["doc_id": .string("doc")]
        )

        let text = resultText(stateResult)
        XCTAssertEqual(stateResult.isError, nil)
        XCTAssertTrue(text.contains("Original path: (none)"))
        XCTAssertTrue(text.contains("Save without explicit path available: false"))
        XCTAssertTrue(text.contains("Finalize without explicit path available: false"))
    }

    func testShutdownFlushPersistsDirtyOpenedDocuments() async throws {
        let url = tempURL("flush")
        try writeDocument(text: "Original", to: url)

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: [
                "path": .string(url.path),
                "doc_id": .string("doc")
            ]
        )
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("doc"),
                "text": .string("Needs flush")
            ]
        )

        do {
            let isDirty_ = await server.isDocumentDirtyForTesting("doc")
            XCTAssertTrue(isDirty_)
        }

        await server.flushDirtyDocumentsForTesting()

        do {
            let isDirty_ = await server.isDocumentDirtyForTesting("doc")
            XCTAssertFalse(isDirty_)
        }
        XCTAssertTrue(try readDocumentText(from: url).contains("Needs flush"))
    }

    func testShutdownFlushSkipsDirtyNewDocumentWithoutKnownPath() async {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "create_document",
            arguments: ["doc_id": .string("doc")]
        )
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("doc"),
                "text": .string("Unsaved new doc")
            ]
        )

        await server.flushDirtyDocumentsForTesting()

        do {
            let isDirty_ = await server.isDocumentDirtyForTesting("doc")
            XCTAssertTrue(isDirty_)
        }
    }

    func testFinalizeDocumentSavesAndClosesUsingOriginalPath() async throws {
        let url = tempURL("finalize-opened")
        try writeDocument(text: "Before finalize", to: url)

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: [
                "path": .string(url.path),
                "doc_id": .string("doc")
            ]
        )
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("doc"),
                "text": .string("Finalize me")
            ]
        )

        let finalizeResult = await server.invokeToolForTesting(
            name: "finalize_document",
            arguments: ["doc_id": .string("doc")]
        )

        XCTAssertEqual(finalizeResult.isError, nil)
        XCTAssertTrue(resultText(finalizeResult).contains("Finalized document"))
        do {
            let trackChanges_ = await server.isTrackChangesEnabledForTesting("doc")
            XCTAssertNil(trackChanges_)
        }
        XCTAssertTrue(try readDocumentText(from: url).contains("Finalize me"))
    }

    func testFinalizeDocumentRequiresExplicitPathForNewDocument() async {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "create_document",
            arguments: ["doc_id": .string("doc")]
        )
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("doc"),
                "text": .string("Needs first path")
            ]
        )

        let finalizeResult = await server.invokeToolForTesting(
            name: "finalize_document",
            arguments: ["doc_id": .string("doc")]
        )

        XCTAssertEqual(finalizeResult.isError, true)
        XCTAssertTrue(resultText(finalizeResult).contains("No path was provided"))
        do {
            let isDirty_ = await server.isDocumentDirtyForTesting("doc")
            XCTAssertTrue(isDirty_)
        }
    }
}
