import XCTest
import MCP
@testable import CheWordMCP

/// #172 — the document-protection tools reported success and wrote nothing.
///
/// Five of them, not the two the issue named: `protect_document`,
/// `unprotect_document`, `set_document_password`, `remove_document_password`,
/// `restrict_editing_region`. Each validated its arguments, returned a
/// confident string, and left the document exactly as it was. Each also
/// carried a comment naming the OOXML it was not writing — the code documented
/// its own dishonesty and nobody acted on it.
///
/// `set_document_password` was the worst by consequence: it echoed the password
/// *length* back, which reads as confirmation the password was received and
/// applied.
///
/// These now fail. Failing is worse than working and better than lying: an
/// error costs the caller a workaround, a false success costs them the thing
/// they were protecting against — and they learn about it from someone else.
///
/// The assertions check `isError`, not message wording, so the text can be
/// improved without the tests rotting.
final class ProtectionToolsHonestFailureTests: XCTestCase {

    private func openDoc(_ server: WordMCPServer) async {
        _ = await server.invokeToolForTesting(
            name: "create_document", arguments: ["doc_id": .string("d")])
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("d"), "text": .string("body")])
    }

    private func assertErrors(_ result: CallTool.Result, _ tool: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        var text = ""
        if let c = result.content.first, case .text(let t) = c { text = t.text }
        XCTAssertEqual(result.isError, true,
                       "\(tool) SHALL report failure rather than a success string. Got: \(text)",
                       file: file, line: line)
    }

    func testProtectDocumentFailsInsteadOfClaimingSuccess() async {
        let server = await WordMCPServer()
        await openDoc(server)
        assertErrors(await server.invokeToolForTesting(
            name: "protect_document",
            arguments: ["doc_id": .string("d"), "protection_type": .string("readOnly")]),
                     "protect_document")
    }

    func testUnprotectDocumentFailsInsteadOfClaimingSuccess() async {
        let server = await WordMCPServer()
        await openDoc(server)
        assertErrors(await server.invokeToolForTesting(
            name: "unprotect_document", arguments: ["doc_id": .string("d")]),
                     "unprotect_document")
    }

    func testSetDocumentPasswordFailsInsteadOfEchoingTheLengthBack() async {
        let server = await WordMCPServer()
        await openDoc(server)
        assertErrors(await server.invokeToolForTesting(
            name: "set_document_password",
            arguments: ["doc_id": .string("d"), "password": .string("hunter2")]),
                     "set_document_password")
    }

    func testRemoveDocumentPasswordFailsInsteadOfClaimingSuccess() async {
        let server = await WordMCPServer()
        await openDoc(server)
        assertErrors(await server.invokeToolForTesting(
            name: "remove_document_password",
            arguments: ["doc_id": .string("d"), "current_password": .string("hunter2")]),
                     "remove_document_password")
    }

    func testRestrictEditingRegionFailsInsteadOfClaimingSuccess() async {
        let server = await WordMCPServer()
        await openDoc(server)
        assertErrors(await server.invokeToolForTesting(
            name: "restrict_editing_region",
            arguments: ["doc_id": .string("d"),
                        "start_paragraph": .int(0), "end_paragraph": .int(0)]),
                     "restrict_editing_region")
    }

    /// Argument validation must still come first: a caller passing a bad
    /// protection type deserves to hear about the argument, not about the
    /// feature being absent. Pins the ordering so a later refactor cannot
    /// collapse every failure into one message.
    func testArgumentValidationStillPrecedesTheNotImplementedError() async {
        let server = await WordMCPServer()
        await openDoc(server)
        let r = await server.invokeToolForTesting(
            name: "protect_document",
            arguments: ["doc_id": .string("d"), "protection_type": .string("nonsense")])
        var text = ""
        if let c = r.content.first, case .text(let t) = c { text = t.text }
        XCTAssertTrue(text.contains("Invalid protection type"),
                      "an invalid argument SHALL be reported as such, got: \(text)")
    }

    /// A missing document is still a missing document — the not-implemented
    /// error must not mask session errors either.
    func testUnknownDocumentStillReportsTheDocumentError() async {
        let server = await WordMCPServer()
        let r = await server.invokeToolForTesting(
            name: "protect_document",
            arguments: ["doc_id": .string("nope"), "protection_type": .string("readOnly")])
        var text = ""
        if let c = r.content.first, case .text(let t) = c { text = t.text }
        XCTAssertTrue(text.lowercased().contains("nope") || text.lowercased().contains("not found"),
                      "an unopened document SHALL be reported as such, got: \(text)")
    }
}
