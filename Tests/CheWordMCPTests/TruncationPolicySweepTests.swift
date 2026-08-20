import XCTest
import MCP
@testable import CheWordMCP

/// #178 — the same-shape sweep after #177 fixed `get_tables`.
///
/// Spec `word-mcp-markdown-export`, Requirement "Truncation policy via
/// summarize parameter": every tool returning potentially long text SHALL take
/// `summarize: Bool` (default `false`), and SHALL return complete text with no
/// upper bound when it is false or omitted.
///
/// Four tools broke it, and three broke it in *both* directions at once: they
/// cut at 50 characters nobody asked for, and then appended "..."
/// unconditionally — so a paragraph reading "Hi" printed as "Hi...", and the
/// reader had no way to tell a short entry from a truncated one. A silent cut
/// is a missing disclosure; an unconditional ellipsis is a *false* one. Both
/// make the output untrustworthy, in opposite directions.
final class TruncationPolicySweepTests: XCTestCase {

    /// Longer than the 50/57-character caps that were hardcoded, shorter than
    /// the 5000-character shared threshold — so it must come back whole under
    /// the default AND under `summarize: true`.
    private let longText = String(repeating: "L", count: 400)

    /// Past the shared 5000-char threshold, so `summarize: true` must elide it.
    private let veryLongText = String(repeating: "V", count: 6000)

    private func text(_ result: CallTool.Result?) -> String {
        guard let c = result?.content.first, case .text(let t) = c else { return "" }
        return t.text
    }

    // MARK: - get_paragraphs

    func testGetParagraphsDoesNotClaimAnElisionThatDidNotHappen() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document",
                                              arguments: ["doc_id": .string("d")])
        _ = await server.invokeToolForTesting(name: "insert_paragraph",
                                              arguments: ["doc_id": .string("d"), "text": .string("Hi")])

        let out = text(await server.invokeToolForTesting(name: "get_paragraphs",
                                                         arguments: ["doc_id": .string("d")]))
        XCTAssertTrue(out.contains("Hi"), "the paragraph SHALL appear, got: \(out)")
        XCTAssertFalse(out.contains("Hi..."),
                       "a two-character paragraph SHALL NOT be printed as elided, got: \(out)")
    }

    func testGetParagraphsReturnsCompleteTextByDefault() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document",
                                              arguments: ["doc_id": .string("d")])
        _ = await server.invokeToolForTesting(name: "insert_paragraph",
                                              arguments: ["doc_id": .string("d"), "text": .string(longText)])

        let out = text(await server.invokeToolForTesting(name: "get_paragraphs",
                                                         arguments: ["doc_id": .string("d")]))
        XCTAssertTrue(out.contains(longText),
                      "400 characters SHALL survive the default path in full (the old cap was 50)")
    }

    func testGetParagraphsElidesOnlyWhenAskedAndOnlyPastThreshold() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document",
                                              arguments: ["doc_id": .string("d")])
        _ = await server.invokeToolForTesting(name: "insert_paragraph",
                                              arguments: ["doc_id": .string("d"), "text": .string(veryLongText)])

        let summarized = text(await server.invokeToolForTesting(
            name: "get_paragraphs",
            arguments: ["doc_id": .string("d"), "summarize": .bool(true)]))
        XCTAssertTrue(summarized.contains(" [...] "),
                      "past the 5000-char threshold, summarize:true SHALL elide")

        let notSummarized = text(await server.invokeToolForTesting(
            name: "get_paragraphs", arguments: ["doc_id": .string("d")]))
        XCTAssertFalse(notSummarized.contains(" [...] "),
                       "the same entry SHALL be complete when summarize is omitted")
    }

    // MARK: - list_footnotes / list_endnotes

    func testListFootnotesDoesNotClaimAnElisionThatDidNotHappen() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document",
                                              arguments: ["doc_id": .string("d")])
        _ = await server.invokeToolForTesting(name: "insert_paragraph",
                                              arguments: ["doc_id": .string("d"), "text": .string("body")])
        _ = await server.invokeToolForTesting(
            name: "insert_footnote",
            arguments: ["doc_id": .string("d"), "paragraph_index": .int(0), "text": .string("Hi")])

        let out = text(await server.invokeToolForTesting(name: "list_footnotes",
                                                         arguments: ["doc_id": .string("d")]))
        XCTAssertFalse(out.contains("Hi..."),
                       "a two-character footnote SHALL NOT be printed as elided, got: \(out)")
    }

    func testListFootnotesReturnsCompleteTextByDefault() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document",
                                              arguments: ["doc_id": .string("d")])
        _ = await server.invokeToolForTesting(name: "insert_paragraph",
                                              arguments: ["doc_id": .string("d"), "text": .string("body")])
        _ = await server.invokeToolForTesting(
            name: "insert_footnote",
            arguments: ["doc_id": .string("d"), "paragraph_index": .int(0), "text": .string(longText)])

        let out = text(await server.invokeToolForTesting(name: "list_footnotes",
                                                         arguments: ["doc_id": .string("d")]))
        XCTAssertTrue(out.contains(longText), "400 characters SHALL survive in full (old cap was 50)")
    }

    func testListEndnotesDoesNotClaimAnElisionThatDidNotHappen() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document",
                                              arguments: ["doc_id": .string("d")])
        _ = await server.invokeToolForTesting(name: "insert_paragraph",
                                              arguments: ["doc_id": .string("d"), "text": .string("body")])
        _ = await server.invokeToolForTesting(
            name: "insert_endnote",
            arguments: ["doc_id": .string("d"), "paragraph_index": .int(0), "text": .string("Hi")])

        let out = text(await server.invokeToolForTesting(name: "list_endnotes",
                                                         arguments: ["doc_id": .string("d")]))
        XCTAssertFalse(out.contains("Hi..."),
                       "a two-character endnote SHALL NOT be printed as elided, got: \(out)")
    }

    func testListEndnotesReturnsCompleteTextByDefault() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document",
                                              arguments: ["doc_id": .string("d")])
        _ = await server.invokeToolForTesting(name: "insert_paragraph",
                                              arguments: ["doc_id": .string("d"), "text": .string("body")])
        _ = await server.invokeToolForTesting(
            name: "insert_endnote",
            arguments: ["doc_id": .string("d"), "paragraph_index": .int(0), "text": .string(longText)])

        let out = text(await server.invokeToolForTesting(name: "list_endnotes",
                                                         arguments: ["doc_id": .string("d")]))
        XCTAssertTrue(out.contains(longText), "400 characters SHALL survive in full (old cap was 50)")
    }

    // MARK: - list_all_formatted_text

    /// This one always gated its ellipsis on length, so it never lied about an
    /// elision. What it violated is the other half of the SHALL: a 60-character
    /// ceiling applied whether or not the caller wanted one.
    func testListAllFormattedTextReturnsCompleteTextByDefault() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document",
                                              arguments: ["doc_id": .string("d")])
        _ = await server.invokeToolForTesting(name: "insert_paragraph",
                                              arguments: ["doc_id": .string("d"), "text": .string(longText)])
        _ = await server.invokeToolForTesting(
            name: "format_text",
            arguments: ["doc_id": .string("d"), "paragraph_index": .int(0), "bold": .bool(true)])

        let out = text(await server.invokeToolForTesting(
            name: "list_all_formatted_text",
            arguments: ["doc_id": .string("d"), "format_type": .string("bold")]))
        XCTAssertTrue(out.contains(longText),
                      "400 characters SHALL survive the default path in full (the old cap was 57+…), got: \(out.prefix(200))")
    }

    // MARK: - Sweep regression

    /// #178's own acceptance criterion: after the sweep, the only hardcoded
    /// numeric `prefix(` calls left in the server source are the three UUID
    /// slices. This is what stops the next 50-character cap from being added
    /// back by hand somewhere else.
    func testNoHardcodedTextPrefixRemainsOutsideUUIDs() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CheWordMCPTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/CheWordMCP/Server.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        var offenders: [String] = []
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            guard line.range(of: #"\.prefix\([0-9]+\)"#, options: .regularExpression) != nil else { continue }
            if line.contains("uuidString") { continue }
            offenders.append("line \(i + 1): \(line.trimmingCharacters(in: .whitespaces))")
        }
        XCTAssertTrue(offenders.isEmpty,
                      "hardcoded text truncation SHALL route through truncateText instead:\n"
                      + offenders.joined(separator: "\n"))
    }
}
