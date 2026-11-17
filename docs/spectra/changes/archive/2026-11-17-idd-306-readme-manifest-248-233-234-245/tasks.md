## 1. Tests first

- [x] 1.1 Add `Tests/CheWordMCPTests/Issue306ToolCountDocsTests.swift` with one test per Example below, each marked with its `spec-example:` comment, reading the documents from the repository root and the tools from `WordMCPServer.toolsForTesting()`. Verified when `swift test --filter Issue306ToolCountDocsTests` fails on the current documents for the README tool tables list every registered tool once, README tool counts agree with the tables and the server, version history is kept only in the changelog, manifest description names no version or tool count, and no stale tool total in instructions, skill or developer notes.
- [x] 1.2 Test for Example "README.md lists each registered tool once" (`spec-example: che-word-mcp-tool-count-docs / README.md lists each registered tool once`): fails while `README.md` misses any of the 248 tools; passes once every tool is listed exactly once.
- [x] 1.3 Test for Example "README_zh-TW.md lists each registered tool once" (`spec-example: che-word-mcp-tool-count-docs / README_zh-TW.md lists each registered tool once`): same check on `README_zh-TW.md`.
- [x] 1.4 Test for Example "README.md headings agree with their tables" (`spec-example: che-word-mcp-tool-count-docs / README.md headings agree with their tables`): every `(N tools` heading equals its row count and `(N Total)` equals `allTools.count`.
- [x] 1.5 Test for Example "README_zh-TW.md headings agree with their tables" (`spec-example: che-word-mcp-tool-count-docs / README_zh-TW.md headings agree with their tables`): every `(N 個` heading equals its row count and `（共 N 個）` equals `allTools.count`.
- [x] 1.6 Test for Example "Version history points to CHANGELOG" (`spec-example: che-word-mcp-tool-count-docs / Version history points to CHANGELOG`): no README row starts with a version number and both READMEs link to `CHANGELOG.md`.
- [x] 1.7 Test for Example "Manifest description names no version or count" (`spec-example: che-word-mcp-tool-count-docs / Manifest description names no version or count`): the `description` of `mcpb/manifest.json` contains no version number and no number followed by `tools`.
- [x] 1.8 Test for Example "Server instructions state no stale tool total" (`spec-example: che-word-mcp-tool-count-docs / Server instructions state no stale tool total`): every number followed by `tools` in `WordMCPServer.serverInstructions` equals `allTools.count`; `serverInstructions` becomes `static let` with internal access so the test reads the value the server sends.
- [x] 1.9 Test for Example "Skill description and CLAUDE.md state no stale tool total" (`spec-example: che-word-mcp-tool-count-docs / Skill description and CLAUDE.md state no stale tool total`): every number followed by `tools` or `個工具` in `skills/che-word-mcp/SKILL.md` and `CLAUDE.md` equals `allTools.count`.
- [x] 1.10 Test for Example "README feature line and comparison table state the registered total" (`spec-example: che-word-mcp-tool-count-docs / README feature line and comparison table state the registered total`): covers README totals outside the tool section match the server — fails while `README.md` says `**234 MCP Tools**` or its `Tools Count` row says `233`, and while `README_zh-TW.md` says `**233 MCP 工具**` or its `工具數量` row says `233`.
- [x] 1.11 Test for Example "server.json description states no stale tool total" (`spec-example: che-word-mcp-tool-count-docs / server.json description states no stale tool total`): every number followed by `tools` in the `description` of `server.json` equals `allTools.count`; the version-row check of 1.6 also catches rows that start with a version without `v`.

## 2. Documents

- [x] 2.1 `README.md`: the tool tables list all 248 registered tools exactly once, grouped into categories whose headings state their row counts; the section heading reads `(248 Total)`; the note after the tables no longer names an old total; the version history table becomes one line pointing to `CHANGELOG.md`. Verified by tests 1.2, 1.4 and 1.6 passing.
- [x] 2.2 `README_zh-TW.md`: same categories as `README.md`, all 248 tools listed once with Traditional Chinese descriptions, heading `（共 248 個）`, version history replaced by a pointer to `CHANGELOG.md`. Verified by tests 1.3, 1.5 and 1.6 passing.
- [x] 2.3 `mcpb/manifest.json`: `description` becomes one sentence naming what the server does, without a version or count. Verified by test 1.7 and by `Issue211VersionConsistencyTests` still passing.
- [x] 2.4 Server instructions: drop the totals 148, 18 and 146 from `serverInstructions` without changing its other text. Verified by test 1.8.
- [x] 2.5 `skills/che-word-mcp/SKILL.md` and `CLAUDE.md`: drop the totals 83 and 146; the version update checklist in `CLAUDE.md` notes that `Issue306ToolCountDocsTests` checks the README counts. Verified by test 1.9.
- [x] 2.6 Both READMEs: the feature line and the comparison-table total outside the tool section state 248. Verified by test 1.10.

## 3. Whole suite

- [x] 3.1 The full test suite passes after the changes: `swift test` reports no failures, so no existing test depended on the old instructions text or manifest description.
