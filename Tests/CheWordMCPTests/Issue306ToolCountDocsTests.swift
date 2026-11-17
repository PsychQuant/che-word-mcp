import XCTest
@testable import CheWordMCP

/// che-word-mcp#306 — the tool count and the tool tables were written by hand in several
/// documents, and nothing compared them with the tools the server registers. When the
/// server registered 248 tools, `README.md` listed 192 and claimed 234, `README_zh-TW.md`
/// listed 131 and claimed 233, and the instructions sent at MCP `initialize` said 148.
/// These tests read the documents and compare them with `allTools`, so the next drift
/// fails `swift test` instead of reaching users.
///
/// Spec: capability `che-word-mcp-tool-count-docs` (docs/spectra/specs).
final class Issue306ToolCountDocsTests: XCTestCase {

    // MARK: - Fixtures

    /// Walk up from this file to the directory holding `Package.swift` (the same
    /// technique `Issue211VersionConsistencyTests` uses).
    private static var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
        }
        return URL(fileURLWithPath: #filePath)
    }

    private func read(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func registeredToolNames() async -> [String] {
        await WordMCPServer().toolsForTesting().map(\.name)
    }

    /// One category of a README tool section: its level-3 heading, the count the heading
    /// states (if any), and the tool names in the first column of the tables under it.
    private struct Category {
        let heading: String
        let statedCount: Int?
        var tools: [String]
    }

    private struct ToolSection {
        let heading: String
        let categories: [Category]
        var allTools: [String] { categories.flatMap(\.tools) }
    }

    /// The tool section starts at the line beginning with `sectionPrefix` and ends at the
    /// next level-2 heading. A tool is a backticked identifier in the first cell of a table
    /// row; the stated count of a category heading is the number after `countOpener`.
    private func toolSection(
        of markdown: String, sectionPrefix: String, countOpener: String
    ) throws -> ToolSection {
        let lines = markdown.components(separatedBy: "\n")
        let start = try XCTUnwrap(
            lines.firstIndex { $0.hasPrefix(sectionPrefix) },
            "no line starts with \(sectionPrefix)")
        let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("## ") } ?? lines.endIndex

        var categories: [Category] = []
        var current = Category(heading: lines[start], statedCount: nil, tools: [])
        for line in lines[(start + 1)..<end] {
            if line.hasPrefix("### ") {
                categories.append(current)
                current = Category(
                    heading: line, statedCount: Self.number(after: countOpener, in: line), tools: [])
            } else if line.hasPrefix("|") {
                let cells = line.components(separatedBy: "|")
                guard cells.count > 2 else { continue }
                current.tools += Self.backticked(in: cells[1])
            }
        }
        categories.append(current)
        return ToolSection(heading: lines[start], categories: categories)
    }

    private static func backticked(in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "`([a-z][a-z0-9_]*)`")
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }

    /// The first integer that directly follows `opener` in `line`, or nil.
    private static func number(after opener: String, in line: String) -> Int? {
        guard let range = line.range(of: opener) else { return nil }
        let digits = line[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    /// Every number written directly before one of `nouns` (e.g. `148 tools`).
    private static func statedTotals(in text: String, nouns: [String]) -> [Int] {
        let alternatives = nouns.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let regex = try! NSRegularExpression(pattern: "(\\d+)\\s?(?:\(alternatives))")
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { Int(ns.substring(with: $0.range(at: 1))) }
    }

    private func assertListsEachToolOnce(_ section: ToolSection, registered: [String], file: String) {
        var seen: [String: Int] = [:]
        for tool in section.allTools { seen[tool, default: 0] += 1 }
        let missing = registered.filter { seen[$0] == nil }
        let duplicated = seen.filter { $0.value > 1 }.map(\.key).sorted()
        let unregistered = Set(seen.keys).subtracting(registered).sorted()
        XCTAssertEqual(missing, [], "\(file) does not list these registered tools")
        XCTAssertEqual(duplicated, [], "\(file) lists these tools more than once")
        XCTAssertEqual(unregistered, [], "\(file) lists tools the server does not register")
    }

    private func assertCountsAgree(
        _ section: ToolSection, totalOpener: String, registered: [String], file: String
    ) {
        XCTAssertEqual(
            Self.number(after: totalOpener, in: section.heading), registered.count,
            "\(file): the section heading \(section.heading) does not state \(registered.count)")
        for category in section.categories {
            guard let stated = category.statedCount else { continue }
            XCTAssertEqual(
                stated, category.tools.count,
                "\(file): \(category.heading) states \(stated) but lists \(category.tools.count)")
        }
    }

    // MARK: - Requirement: README tool tables list every registered tool once

    // spec-example: che-word-mcp-tool-count-docs / README.md lists each registered tool once
    func testReadmeListsEachRegisteredToolOnce() async throws {
        let registered = await registeredToolNames()
        let section = try toolSection(
            of: read("README.md"), sectionPrefix: "## Available Tools", countOpener: "(")
        assertListsEachToolOnce(section, registered: registered, file: "README.md")
    }

    // spec-example: che-word-mcp-tool-count-docs / README_zh-TW.md lists each registered tool once
    func testZhTWReadmeListsEachRegisteredToolOnce() async throws {
        let registered = await registeredToolNames()
        let section = try toolSection(
            of: read("README_zh-TW.md"), sectionPrefix: "## 可用工具", countOpener: "(")
        assertListsEachToolOnce(section, registered: registered, file: "README_zh-TW.md")
    }

    // MARK: - Requirement: README tool counts agree with the tables and the server

    // spec-example: che-word-mcp-tool-count-docs / README.md headings agree with their tables
    func testReadmeHeadingsAgreeWithTheirTables() async throws {
        let registered = await registeredToolNames()
        let section = try toolSection(
            of: read("README.md"), sectionPrefix: "## Available Tools", countOpener: "(")
        assertCountsAgree(section, totalOpener: "(", registered: registered, file: "README.md")
    }

    // spec-example: che-word-mcp-tool-count-docs / README_zh-TW.md headings agree with their tables
    func testZhTWReadmeHeadingsAgreeWithTheirTables() async throws {
        let registered = await registeredToolNames()
        let section = try toolSection(
            of: read("README_zh-TW.md"), sectionPrefix: "## 可用工具", countOpener: "(")
        assertCountsAgree(section, totalOpener: "（共 ", registered: registered, file: "README_zh-TW.md")
    }

    // MARK: - Requirement: Version history is kept only in the changelog

    // spec-example: che-word-mcp-tool-count-docs / Version history points to CHANGELOG
    func testVersionHistoryPointsToChangelog() throws {
        let versionRow = try NSRegularExpression(pattern: "^\\|\\s*(\\*\\*)?v\\d+\\.\\d+", options: .anchorsMatchLines)
        for file in ["README.md", "README_zh-TW.md"] {
            let text = try read(file)
            let rows = versionRow.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            XCTAssertEqual(rows, 0, "\(file) still keeps \(rows) version history row(s)")
            XCTAssertTrue(text.contains("(CHANGELOG.md)"), "\(file) does not link to CHANGELOG.md")
        }
    }

    // MARK: - Requirement: Manifest description names no version or tool count

    // spec-example: che-word-mcp-tool-count-docs / Manifest description names no version or count
    func testManifestDescriptionNamesNoVersionOrCount() throws {
        let data = try Data(contentsOf: Self.repoRoot.appendingPathComponent("mcpb/manifest.json"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let description = try XCTUnwrap(json["description"] as? String)
        let version = try NSRegularExpression(pattern: "\\bv?\\d+\\.\\d+(\\.\\d+)?\\b")
        let ns = description as NSString
        XCTAssertEqual(
            version.numberOfMatches(in: description, range: NSRange(location: 0, length: ns.length)), 0,
            "mcpb/manifest.json description names a version: \(description)")
        XCTAssertEqual(
            Self.statedTotals(in: description, nouns: ["tools"]), [],
            "mcpb/manifest.json description names a tool count: \(description)")
    }

    // MARK: - Requirement: No stale tool total in instructions, skill or developer notes

    // spec-example: che-word-mcp-tool-count-docs / Server instructions state no stale tool total
    func testServerInstructionsStateNoStaleToolTotal() async throws {
        let count = await registeredToolNames().count
        let stale = Self.statedTotals(in: WordMCPServer.serverInstructions, nouns: ["tools"])
            .filter { $0 != count }
        XCTAssertEqual(stale, [], "the server instructions state tool totals other than \(count)")
    }

    // spec-example: che-word-mcp-tool-count-docs / Skill description and CLAUDE.md state no stale tool total
    func testSkillDescriptionAndClaudeMdStateNoStaleToolTotal() async throws {
        let count = await registeredToolNames().count
        for file in ["skills/che-word-mcp/SKILL.md", "CLAUDE.md"] {
            let stale = Self.statedTotals(in: try read(file), nouns: ["tools", "個工具"])
                .filter { $0 != count }
            XCTAssertEqual(stale, [], "\(file) states tool totals other than \(count)")
        }
    }
}
