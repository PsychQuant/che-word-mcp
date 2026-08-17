import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// `get_tables` truncation-policy compliance (#177).
///
/// Spec `word-mcp-markdown-export` — Requirement: Truncation policy via
/// summarize parameter:
///
/// > The `che-word-mcp` server SHALL accept a `summarize: Bool` argument
/// > (default `false`) on **every** tool that returns potentially long text.
/// > When `summarize` is `false` or omitted, the server SHALL return
/// > **complete text with no upper bound**.
///
/// **Pre-fix bug**: `getTables` accepted no `summarize` argument and truncated
/// unconditionally with four hardcoded constants — first-row column count for
/// the header, 3 rows, 3 columns, 15 characters per cell. Of the three
/// truncations only the row one disclosed itself (`... (N more rows)`); column
/// and cell-text truncation were entirely silent, so the tool's own output
/// contradicted its own header (`[0] 2x5 table` followed by three columns).
///
/// Downstream consequence: PsychQuant/ntu-claude-plugins#16 built an
/// exhaustive cell-by-cell fidelity gate on the premise that `get_tables`
/// returns the whole table. It compared the first 3 rows × 3 columns × 15
/// characters and reported PASS.
///
/// Refs PsychQuant/macdoc#157, PsychQuant/ntu-claude-plugins#16. Sibling
/// truncations in four other tools: #178.
final class Issue177GetTablesCompleteOutputTests: XCTestCase {

    // MARK: - Helpers

    private func resultText(_ result: CallTool.Result) -> String {
        guard let first = result.content.first else { return "" }
        switch first {
        case .text(let text, _, _):
            return text
        default:
            return ""
        }
    }

    private func makeServer() async -> WordMCPServer { await WordMCPServer() }

    private func createDoc(_ server: WordMCPServer, _ id: String) async {
        _ = await server.invokeToolForTesting(
            name: "create_document",
            arguments: ["doc_id": .string(id)]
        )
    }

    private func discardDoc(_ server: WordMCPServer, _ id: String) async {
        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string(id), "discard_changes": .bool(true)]
        )
    }

    private func insertTable(
        _ server: WordMCPServer, _ id: String,
        rows: Int, cols: Int, data: [[String]]
    ) async {
        _ = await server.invokeToolForTesting(
            name: "insert_table",
            arguments: [
                "doc_id": .string(id),
                "rows": .int(rows),
                "cols": .int(cols),
                "data": .array(data.map { row in .array(row.map { .string($0) }) })
            ]
        )
    }

    private func getTables(
        _ server: WordMCPServer, _ id: String, summarize: Bool? = nil
    ) async -> String {
        var args: [String: Value] = ["doc_id": .string(id)]
        if let summarize { args["summarize"] = .bool(summarize) }
        return resultText(await server.invokeToolForTesting(name: "get_tables", arguments: args))
    }

    // MARK: - Default (summarize omitted) returns complete output

    /// Columns 4 and 5 of a uniform 2×5 table vanished silently pre-fix.
    func testDefaultShowsAllColumns() async {
        let server = await makeServer()
        let id = "gt-cols"
        await createDoc(server, id)
        await insertTable(server, id, rows: 2, cols: 5, data: [
            ["A1", "B1", "C1", "D1-visible", "E1-visible"],
            ["A2", "B2", "C2", "D2-visible", "E2-visible"]
        ])

        let out = await getTables(server, id)
        await discardDoc(server, id)

        XCTAssertTrue(out.contains("D1-visible"), "4th column dropped:\n\(out)")
        XCTAssertTrue(out.contains("E1-visible"), "5th column dropped:\n\(out)")
        XCTAssertTrue(out.contains("E2-visible"), "5th column of row 2 dropped:\n\(out)")
    }

    /// Rows beyond the third vanished pre-fix (with a `... N more rows` note,
    /// so this one at least announced itself — but the spec says the default
    /// must be complete, announced or not).
    func testDefaultShowsAllRows() async {
        let server = await makeServer()
        let id = "gt-rows"
        await createDoc(server, id)
        await insertTable(server, id, rows: 5, cols: 2, data: [
            ["r0", "x"], ["r1", "x"], ["r2", "x"], ["r3-visible", "x"], ["r4-visible", "x"]
        ])

        let out = await getTables(server, id)
        await discardDoc(server, id)

        XCTAssertTrue(out.contains("r3-visible"), "4th row dropped:\n\(out)")
        XCTAssertTrue(out.contains("r4-visible"), "5th row dropped:\n\(out)")
        XCTAssertFalse(out.contains("more rows"), "default must not elide rows:\n\(out)")
    }

    /// Cell text was cut at 15 characters with no ellipsis, so the truncated
    /// value read as the cell's complete content.
    func testDefaultShowsFullCellText() async {
        let server = await makeServer()
        let id = "gt-text"
        let long = "this-cell-text-is-definitely-longer-than-fifteen-characters"
        await createDoc(server, id)
        await insertTable(server, id, rows: 1, cols: 2, data: [[long, "b"]])

        let out = await getTables(server, id)
        await discardDoc(server, id)

        XCTAssertTrue(out.contains(long), "cell text truncated:\n\(out)")
    }

    // MARK: - Ragged tables: header must not report the first row's width

    /// A horizontal merge across row 0 leaves that row with one `<w:tc>` while
    /// the others keep four — the shape of the real form in macdoc#157, where
    /// the header claimed `20x1` but addressable columns went up to index 4.
    /// The header must not present the first row's width as the table's width.
    func testHeaderDoesNotReportOnlyFirstRowWidthForRaggedTable() async {
        let server = await makeServer()
        let id = "gt-ragged"
        await createDoc(server, id)
        await insertTable(server, id, rows: 3, cols: 4, data: [
            ["h", "", "", ""],
            ["a", "b", "c", "d-visible"],
            ["e", "f", "g", "h-visible"]
        ])
        _ = await server.invokeToolForTesting(
            name: "merge_cells",
            arguments: [
                "doc_id": .string(id),
                "table_index": .int(0),
                "direction": .string("horizontal"),
                "row": .int(0),
                "col": .int(0),
                "end_col": .int(3)
            ]
        )

        let out = await getTables(server, id)
        await discardDoc(server, id)

        guard let header = out.split(separator: "\n").first(where: { $0.contains("table") }) else {
            return XCTFail("no header line in:\n\(out)")
        }
        XCTAssertFalse(
            header.contains("3x1"),
            "header must not claim 1 column when other rows have 4: \(header)"
        )
        XCTAssertTrue(
            header.contains("4"),
            "header must surface the true maximum column count: \(header)"
        )
        // Body must still reach the 4th column of the unmerged rows.
        XCTAssertTrue(out.contains("d-visible"), "4th column dropped:\n\(out)")
    }

    // MARK: - summarize: true may elide, but must disclose every elision

    func testSummarizeDisclosesRowElision() async {
        let server = await makeServer()
        let id = "gt-s-rows"
        await createDoc(server, id)
        await insertTable(server, id, rows: 5, cols: 2, data: [
            ["r0", "x"], ["r1", "x"], ["r2", "x"], ["r3", "x"], ["r4", "x"]
        ])

        let out = await getTables(server, id, summarize: true)
        await discardDoc(server, id)

        XCTAssertTrue(out.contains("more rows"), "row elision undisclosed:\n\(out)")
    }

    /// The silent half of the pre-fix bug: columns past the third disappeared
    /// with no note at all.
    func testSummarizeDisclosesColumnElision() async {
        let server = await makeServer()
        let id = "gt-s-cols"
        await createDoc(server, id)
        await insertTable(server, id, rows: 1, cols: 5, data: [
            ["A", "B", "C", "D", "E"]
        ])

        let out = await getTables(server, id, summarize: true)
        await discardDoc(server, id)

        XCTAssertTrue(out.contains("more column"), "column elision undisclosed:\n\(out)")
    }

    /// Long cell text under `summarize: true` must go through the shared
    /// head+tail elision (5000-char threshold, ` [...] ` marker) rather than a
    /// bespoke character cap.
    func testSummarizeElidesLongCellTextWithMarker() async {
        let server = await makeServer()
        let id = "gt-s-text"
        let huge = String(repeating: "z", count: 6_000)
        await createDoc(server, id)
        await insertTable(server, id, rows: 1, cols: 1, data: [[huge]])

        let out = await getTables(server, id, summarize: true)
        await discardDoc(server, id)

        XCTAssertTrue(out.contains("[...]"), "long cell text not elided with marker:\n\(out.prefix(200))")
        XCTAssertFalse(out.contains(huge), "elision did not happen")
    }

    /// Below the threshold, `summarize: true` must leave text alone — the
    /// mirror-image failure of #178, where an unconditional `...` claimed an
    /// elision that never happened.
    func testSummarizeLeavesShortCellTextIntact() async {
        let server = await makeServer()
        let id = "gt-s-short"
        await createDoc(server, id)
        await insertTable(server, id, rows: 1, cols: 1, data: [["Hi"]])

        let out = await getTables(server, id, summarize: true)
        await discardDoc(server, id)

        XCTAssertTrue(out.contains("Hi"), "short text lost:\n\(out)")
        XCTAssertFalse(out.contains("Hi..."), "fabricated ellipsis on untruncated text:\n\(out)")
        XCTAssertFalse(out.contains("[...]"), "elision marker on text below threshold:\n\(out)")
    }
}
