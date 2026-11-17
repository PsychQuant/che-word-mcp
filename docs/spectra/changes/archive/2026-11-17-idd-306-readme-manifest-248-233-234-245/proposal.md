## Why

The tool count and version history of che-word-mcp are written by hand in several places (the two READMEs, `mcpb/manifest.json`, the server instructions sent at MCP `initialize`, the skill description, `CLAUDE.md`). No test compares them with the tools the server registers, so each new tool updated only some of them: the server registers 248 tools while the English README lists 192 and claims 234, the Traditional Chinese README lists 131 and claims 233, and the server instructions say 148 (PsychQuant/che-word-mcp#306).

## What Changes

- Both READMEs list every registered tool exactly once in their tool tables; each category heading states the number of rows under it; the total heading equals the registered tool count.
- Both READMEs replace their version history tables with one line pointing to `CHANGELOG.md`.
- The `description` of `mcpb/manifest.json` no longer names a version or a tool count.
- The server instructions, `skills/che-word-mcp/SKILL.md` and `CLAUDE.md` no longer state a tool total; any total they state must equal the registered count.
- A test target file checks all of the above against `allTools`, so the next drift fails `swift test`.

## Non-Goals

- No tool's behaviour, name or input schema changes.
- The Direct Mode tool list inside the server instructions is not corrected here (PsychQuant/che-word-mcp#308).
- The copies in PsychQuant/macdoc (plugin README, `CLAUDE.md`) are out of reach of this repository's tests (PsychQuant/macdoc#289).
- Rejected: generating the README tool tables from source. The tables carry hand-written descriptions and grouping; a test that checks counts and membership keeps them honest at lower cost.

## Capabilities

### New Capabilities

- `che-word-mcp-tool-count-docs`: statements of the tool count and the tool tables in user-facing documents agree with the registered tools.

### Modified Capabilities

(none)

## Impact

- Affected specs: che-word-mcp-tool-count-docs (new)
- Affected code:
  - New: Tests/CheWordMCPTests/Issue306ToolCountDocsTests.swift
  - Modified: README.md, README_zh-TW.md, mcpb/manifest.json, Sources/CheWordMCP/Server.swift (server instructions text and its access level only), skills/che-word-mcp/SKILL.md, CLAUDE.md
