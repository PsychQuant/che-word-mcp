## Purpose

User-facing documents of che-word-mcp state how many tools the server offers and list them. This capability keeps those statements equal to the tools the server registers (`allTools`), and lets `swift test` fail when they drift apart.

## ADDED Requirements

### Requirement: README tool tables list every registered tool once

`README.md` and `README_zh-TW.md` SHALL each contain a tool section whose tables, taken together, name every tool in `allTools` exactly once in their first column, and SHALL NOT name a tool that `allTools` does not register. The tool section of `README.md` SHALL start at the heading `## Available Tools` and the one of `README_zh-TW.md` at the heading `## 可用工具`; it SHALL end at the next level-2 heading.

#### Scenario: A registered tool is missing from a README table

- **WHEN** `allTools` registers a tool whose name does not appear in the first column of any tool table of a README
- **THEN** the documentation test fails and names the missing tool and the README

#### Scenario: A README table names an unregistered tool

- **WHEN** the first column of a README tool table names a tool that `allTools` does not register
- **THEN** the documentation test fails and names that tool

##### Example: README.md lists each registered tool once

- **GIVEN** the tools registered by `allTools`
- **WHEN** the first-column tool names of every table in the tool section of `README.md` are collected
- **THEN** each registered tool is collected exactly once and no other name is collected

##### Example: README_zh-TW.md lists each registered tool once

- **GIVEN** the tools registered by `allTools`
- **WHEN** the first-column tool names of every table in the tool section of `README_zh-TW.md` are collected
- **THEN** each registered tool is collected exactly once and no other name is collected

### Requirement: README tool counts agree with the tables and the server

In each README, every level-3 heading inside the tool section that states a count of tools SHALL state the number of tool rows in the tables under it, and the heading of the tool section SHALL state the number of tools in `allTools`. `README.md` writes a category count as `(N tools` and the total as `(N Total)`; `README_zh-TW.md` writes a category count as `(N 個` and the total as `（共 N 個）`.

#### Scenario: A category heading states a stale count

- **WHEN** a category heading states a count different from the number of tool rows under it
- **THEN** the documentation test fails and names the heading, the stated count and the row count

##### Example: README.md headings agree with their tables

- **GIVEN** `README.md` whose tool section heading is `## Available Tools (248 Total)` and `allTools` registers 248 tools
- **WHEN** each category heading such as `### Document Management (6 tools)` is compared with the rows under it
- **THEN** every stated count equals its row count and the total equals 248

##### Example: README_zh-TW.md headings agree with their tables

- **GIVEN** `README_zh-TW.md` whose tool section heading is `## 可用工具（共 248 個）` and `allTools` registers 248 tools
- **WHEN** each category heading such as `### 文件管理 (6 個)` is compared with the rows under it
- **THEN** every stated count equals its row count and the total equals 248

### Requirement: Version history is kept only in the changelog

`README.md` and `README_zh-TW.md` SHALL NOT keep a version history table. Each SHALL point to `CHANGELOG.md` for the history of releases.

#### Scenario: A README keeps its own version table

- **WHEN** a README contains a table row that starts with a version such as `| v4.0.0 |` or `| **v4.0.0** |`
- **THEN** the documentation test fails

##### Example: Version history points to CHANGELOG

- **GIVEN** `README.md` and `README_zh-TW.md`
- **WHEN** each is searched for a table row starting with a version number and for a link to `CHANGELOG.md`
- **THEN** neither has such a row and both link to `CHANGELOG.md`

### Requirement: Manifest description names no version or tool count

The `description` field of `mcpb/manifest.json` SHALL NOT contain a version number (such as `v3.17.8` or `4.10.0`) or a count of tools, because it is shown on the Claude Desktop extensions page and is not updated by the release checks.

#### Scenario: The description names a release

- **WHEN** the `description` of `mcpb/manifest.json` contains a version number or a number followed by `tools`
- **THEN** the documentation test fails

##### Example: Manifest description names no version or count

- **GIVEN** `mcpb/manifest.json`
- **WHEN** its `description` is searched for a version number and for a tool count
- **THEN** neither is found

### Requirement: No stale tool total in instructions, skill or developer notes

The server instructions returned at MCP `initialize` (`WordMCPServer.serverInstructions`), `skills/che-word-mcp/SKILL.md` and `CLAUDE.md` SHALL NOT state a total number of tools other than the number of tools in `allTools`. A phrase of a number followed by `tools` (or `個工具`) counts as a stated total.

#### Scenario: The instructions state an old total

- **WHEN** the server instructions contain `148 tools` and `allTools` registers 248 tools
- **THEN** the documentation test fails and names the stale number

##### Example: Server instructions state no stale tool total

- **GIVEN** `WordMCPServer.serverInstructions` and the tools registered by `allTools`
- **WHEN** every number followed by `tools` in the instructions is collected
- **THEN** each collected number equals the number of tools in `allTools`

##### Example: Skill description and CLAUDE.md state no stale tool total

- **GIVEN** `skills/che-word-mcp/SKILL.md`, `CLAUDE.md` and the tools registered by `allTools`
- **WHEN** every number followed by `tools` or `個工具` in those files is collected
- **THEN** each collected number equals the number of tools in `allTools`
