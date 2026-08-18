# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.23.0] - 2026-08-18

### Changed

- **`get_tables` 預設回傳完整內容**（#177，PR #179）。先前它不接受 `summarize`，
  並用四個硬寫常數無條件截斷：header 取首列欄數、3 列、3 欄、每格 15 字。三種截斷裡
  **只有列會印 `... (N more rows)`**，欄與字數截斷完全靜默——造成工具自己的輸出前後矛盾
  （一個規則的 2×5 表格，header 說 5 欄、body 只給 3 欄，中間沒有交代）。

  這違反 spec `word-mcp-markdown-export` 的 normative SHALL：「on **every** tool that
  returns potentially long text」預設須回傳完整內容、無上界。修法照 repo 既有 doctrine
  （#1 → #5 建立、`truncateText` helper、`summarize` 已在 5 個工具的 schema）：

  - schema 加 `summarize: Bool`（預設 false）
  - 預設輸出所有列、所有欄、每格完整文字
  - `summarize: true` 才省略，且**三種省略都標示**（列／欄／cell 文字走 `truncateText`）
  - header 改報**最寬列**而非首列，不規則時標 `(ragged: min..max columns per row)`

  **行為變更（刻意）**：既有呼叫端會看到更長的輸出。需要精簡輸出者傳 `summarize: true`。
  規則表格的 header 輸出不變。

  同型缺陷仍在另外四個工具（`get_paragraphs` / `list_footnotes` / `list_endnotes` /
  `list_all_formatted_text`）→ #178。

- **bump ooxml-swift 1.5.0 → 2.0.1** — Word round-trip fidelity。一次 mutation 不再
  靜默改寫文件。以真實 A4 官方表單走一次 `update_cell` 實測：

  | 元素 | 升級前 | 升級後 |
  |---|---|---|
  | `<w:tcBorders>` | 40 → **0** | 40 |
  | `<w:tcMar>` | 40 → **0** | 40 |
  | `<w:tblCellMar>` / `<w:tblLook>` | 1 → **0** | 1 |
  | `<w:tblLayout>` | 1 → **2**（重複，無效 OOXML） | 1 |
  | `<w:pgSz>` | A4 → **US Letter** | A4 |
  | `<w:footerReference>` | **消失** | 保留 |
  | `<w:docGrid>` | `type` 掉失、`linePitch` 571 → 360 | 原樣 |

  上游 refs：ooxml-swift #99（`tcBorders`）、#101（`tcMar`）、#97（`tblPr`）、
  #84（`sectPr`）、#104（`appendParagraph` typed-view 迴歸）。
  升級鏈另含 latex-math-swift v0.3.0 與 word-to-md-swift v0.8.0。

### Verification

- 全套 322 tests / 11 skipped / 0 failures（清乾淨重建，從 GitHub 解析真實 tag）
- 真實表單端到端走完整 MCP 工具鏈（`open_document` → `update_cell` → `save_document`）：
  十個元素與原檔全數相符
- `get_tables`：8 個新測試（含兩個防「修過頭」的控制組）＋三份真實官方表單的 header 驗證

## [3.22.0] - 2026-07-18

### Changed

- **Self-produced docx now upgrades to the typed DSL channel** — bumps
  ooxml-swift 1.4.0 → 1.5.0 (upstream PsychQuant/ooxml-swift#85: authoring
  path emits transcoder-canonical document.xml with chokepoint-stamped
  `w14:paraId`). `export_script` on MCP-authored pure-paragraph documents
  reports `word/document.xml` on the `dsl` channel (per-part ratio 1.0) and
  named content `slots` anchor on the stamped paraIds. Previously all parts
  fell to the raw carryPart floor (`dsl_ratio: 0`). Refs #173 (PR #174,
  6-AI verify PASS, tag `idd-173-verified`).
- **DSL-upgrade honesty boundary in tool descriptions** —
  `export_script` / `get_script_coverage` now state the part-level
  all-or-nothing semantics: only `word/document.xml` attempts DSL upgrade;
  a rich table (or legacy paraId-less paragraph) demotes the whole part to
  raw. Mixed documents (e.g. the original 8-table reproduction) stay raw
  until upstream rich-table canonical coverage lands
  (PsychQuant/ooxml-swift#86).

## [3.21.1] - 2026-07-16

### Fixed — 6-AI verify findings (R1 blocking + R2 in-scope; Refs [PsychQuant/macdoc#134](https://github.com/PsychQuant/macdoc/issues/134))

- **execute_script verification integrity**: the reference is now pinned in
  memory BEFORE the output is written — `output_path ==
  verify_byte_equal_against` no longer produces a guaranteed-true
  output-vs-output comparison, and a mistyped reference path errors before
  any write side effect (R1 B1).
- **Location-bearing parse errors**: TranscodeError now maps to MCP errors
  carrying line/column and the transcoder's reason (R1 B2); export-side
  errors are attributed to the correct parameter (slots vs source_path,
  R2 #1).
- **Strict typing on optional params**: present-but-mistyped `slots` /
  `verify_byte_equal_against` error loudly; explicit JSON null counts as
  absent (R1 F1, R2 #11). Verdict fields ride the execute response only
  when verification actually ran (R1 F2).
- **Deterministic arrays**: coverage parts and broken_parts are sorted at
  the MCP layer (R2 #5).
- **Test hardening**: raw-form op-level slot demonstrated through the MCP
  surface; gated cross-check gains the slot step AND a live CLI --coverage
  aggregate comparison; part-set-asymmetry regression pins compareParts'
  union semantics (R1 F5/F6, R2 #2/#4). Suite: 312 tests.
- **CHANGELOG**: restored the 3.20.0 header eaten during the 3.21.0 entry
  insertion (R1 B3). Ungated suite count at 3.21.0 release time was 306;
  the number grew to 312 with the verify-round tests in this release.

## [3.21.0] - 2026-07-16

### Added — script-pipeline tools: word-imitation parity with the macdoc CLI (Refs [PsychQuant/macdoc#134](https://github.com/PsychQuant/macdoc/issues/134))

Three MCP tools riding the exact ooxml-swift transcoder code path that
`macdoc word reverse` uses — parity by construction (zero reimplemented
transcode logic; Spectra change che-word-mcp-script-pipeline-parity):

- **`export_script`** — docx → full-fidelity `.mdocx.swift` rebuild script
  (raw byte-equal floor + typed DSL upgrades). Optional strict-mode content
  slots (`{name, para_id}`): designation failure = tool error naming the
  slot, no file written.
- **`get_script_coverage`** — dual-track coverage (per-part DSL/raw channel,
  bytes, ratio + aggregate), same numbers as the CLI `--coverage` report.
- **`execute_script`** — script → rebuilt docx, optional Stage-B byte-equal
  verification against a reference (broken-part list on mismatch).

Two-layer parity guard: ungated in-process export→execute Stage-B test, plus
a dual-gated cross-check (`MACDOC_TEMPLATE_DIR` + `MACDOC_CLI_PATH`) proving
MCP and CLI export byte-identical scripts for a real Word template.

### Changed — dependency line: ooxml-swift 0.24 → 1.4.0

Cross-major bump (with word-to-md-swift 0.7.0, latex-math-swift 0.2.0)
measured empty: zero source changes. Full suite green (306 tests).



## [3.20.0] - 2026-05-04

### Added — `splice_omath_from_source` + `splice_paragraph_omath_from_source` MCP tools (closes [#160](https://github.com/PsychQuant/che-word-mcp/issues/160))

Two new MCP tools wrapping ooxml-swift v0.24.0's [`spliceOMath`](https://github.com/PsychQuant/ooxml-swift/issues/57) API for cross-document verbatim copy of `<m:oMath>` XML blocks. Unblocks the kiki830621/collaboration_guo_analysis Phase 7 inline-math restoration pipeline.

#### `splice_omath_from_source` (single-OMath, low-level)

```typescript
{
  // Source side (one of):
  source_path?: string,        // Direct mode (read-only, opens temporarily)
  source_doc_id?: string,      // Session mode (already-open doc)
  source_paragraph_index: number,    // body-paragraph index in source

  // Target side (Session mode required):
  doc_id: string,
  target_paragraph_index: number,

  // Splice config:
  position: "atStart" | "atEnd" | "afterText" | "beforeText",
  anchor?: string,             // required when position="afterText" / "beforeText"
  instance?: number,           // 1-based anchor occurrence (default 1)
  omath_index?: number,        // 0-based, default 0 (joint document-order across both source carriers)
  rpr_mode?: "full" | "omathOnly" | "discard",  // default "full"
  namespace_policy?: "lenient" | "strict"        // default "lenient"
}
```

Returns `Spliced 1 OMath block (...)` on success or structured `Error: splice_omath_from_source: ...` on failure (covers `sourceHasNoOMath` / `omathIndexOutOfRange` / `targetParagraphOutOfRange` / `anchorNotFound` / `namespaceMismatch`).

#### `splice_paragraph_omath_from_source` (paragraph-level batch, high-level)

Same surface as `splice_omath_from_source` minus `position` / `anchor` / `instance` / `omath_index` — splices ALL OMath blocks from source paragraph in source-document order, auto-deriving anchor for each from ~10 chars of source-text-context. Returns `Spliced N OMath block(s) into target_paragraph_index=K` or `Error: ...: context anchor not found for omath_index=I, snippet='...'` (with partial-success state remaining in target).

#### Tests

`Issue160SpliceOMathFromSourceTests` — 8 cases covering Direct/Session source modes, atEnd / afterText positions, missing-arg / out-of-range / no-OMath errors, batch mode, and rPr `.discard` mode.

#### Dependencies

- ooxml-swift bumped from `0.21.0` → `0.24.0` (required by new splice API)
- Full suite: 297 tests, 0 failures, 9 pre-existing skips

## [3.19.0] - 2026-05-04

### Fixed — `find_inline_math_gaps` caption detection (closes [#136](https://github.com/PsychQuant/che-word-mcp/issues/136))

Two-layer caption detection upgrade. Previous text-only heuristic produced both false negatives (`Figure 1` / `Tab. 1` / `表3-1` / `表　1` / `Caption`-styled body text) AND false positives (`Table reservations are required...` mistaken as caption).

**Layer 1 (primary)**: `Paragraph.style?.lowercased().contains("caption")` — Word's canonical OOXML signal. Catches `Caption` / `ImageCaption` / `TableCaption` etc.

**Layer 2 (fallback)**: 7 English prefixes + 9 CJK prefixes (incl. U+3000 ideographic space) + CJK no-separator regex `^[表圖图]\d` + label-only `表格` / `图表`. Digit-after-prefix guard rejects body sentences like `Table reservations...`.

`isLikelyTableCaption(_ text: String) -> Bool` → `(_ paragraph: Paragraph) -> Bool` (private → internal for `@testable`).

#### Thesis impact

- 「圖 1.1」「圖 1.2」 → Layer 2 CJK + U+0020 + digit ✓
- 「表 3.2」 → same path ✓
- Caption-styled paragraphs without 圖/表 prefix → Layer 1 catches via `style` ✓
- Body sentences "Table" / "Figure" → Layer 2 digit guard rejects ✓

PR [#157](https://github.com/PsychQuant/che-word-mcp/pull/157) (commit `b40d600`). 17 new tests in `Issue136CaptionDetectionTests.swift`.

### Fixed — `estimate_paragraph_for_page` structural weights v2 (closes [#142](https://github.com/PsychQuant/che-word-mcp/issues/142))

Pre-fix heuristic walked `doc.getParagraphs()` directly, treating each paragraph as `text.count + 1` chars. Three failure modes:

1. Tables silently skipped (`getParagraphs()` has `case .table: break` — correct semantically for paragraph-index purposes, but undercounts vertical space)
2. Inline images contributed ~2 chars (`flattenedDisplayText()` doesn't walk `Run.drawing`)
3. Display equations under-counted (OMath transliteration ~10 chars vs visual height 1.5-2 lines)

**Walker upgrade**: new `collectStructuralBlocks()` returning `[StructuralBlock]` enum (`.paragraph` / `.table` / `.imageOnlyParagraph(drawingCount:)` / `.displayEquationParagraph`). Body-paragraph blocks remain the indexable unit (`paragraph_index` semantics preserved).

**Per-block weights** (12pt thesis calibration):
- text paragraph: `text.count + 1` (unchanged)
- table: `tableRows × avgCellChars` (200/row fallback for empty layout-only)
- image: +200 chars per drawing
- display equation: 120 chars

**API additions** (additive, non-breaking):
- New `structural_breakdown` field with 9 sub-fields (paragraphs_with_text / tables_counted / tables_total_chars / image_only_paragraphs / image_chars_added / display_equations / equation_chars_added / estimated_total_chars / char_breakdown_method)
- `method` field: `"char_count_heuristic"` → `"char_count_heuristic_v2"` (callers can detect upgrade)

#### Thesis impact (concrete)

| Element | Pre-fix weight | Post-fix weight | Improvement |
|---|---|---|---|
| 23 figures | ~50 chars total | ~4600 chars | **~95×** |
| 14 tables | 0 (silently skipped) | ~1400 chars (cell-precise) | from 0 to detected |
| 18 display equations | ~10 chars | ~120 chars | ~12× |

Advisor's "在第14頁，公式不一致" workflow now gets a usable page-to-paragraph mapping on formula-heavy thesis docs.

PR [#158](https://github.com/PsychQuant/che-word-mcp/pull/158) (commit `0f1bd60`). 6 new tests in `Issue142EstimateParagraphForPageStructuralWeightsTests.swift` + `Issue89` regression check (text-only fixtures unchanged, just `method` literal updated to `_v2`).

#### Backward compatibility

- `getParagraphs()` UNCHANGED — 30+ other callers (paragraph-index family, find_inline_math_gaps, etc.) unaffected
- `paragraph_count` semantics: still body-paragraph blocks only — `paragraph_index` math invariant preserved
- `chars_per_page` override path UNCHANGED
- Pre-existing #89 tests pass unchanged (only `method` literal v1→v2)

### Verification

- `swift build`: clean
- `swift test`: 289 pass, 9 pre-existing skips, 0 failures
- 1 P3 follow-up filed: [#159](https://github.com/PsychQuant/che-word-mcp/issues/159) (display-equation fixture limitation, non-blocking)

## [3.18.1] - 2026-05-03

### Fixed (transitive) — `search_text` includes inline OMath text content (auto-resolves [#155](https://github.com/PsychQuant/che-word-mcp/issues/155))

Transitive dependency bump only. `Package.resolved` pinned at `ooxml-swift v0.21.11` → `v0.22.1` ([release notes](https://github.com/PsychQuant/ooxml-swift/releases/tag/v0.22.1)). Closes [PsychQuant/ooxml-swift#43](https://github.com/PsychQuant/ooxml-swift/issues/43) which collapses the `Paragraph.getText()` vs `flattenedDisplayText()` divergence.

Effect on `che-word-mcp__search_text`: callers can now grep for inline math symbols (α / β / γ / θ / λ / t) that previously fell into silent zero gaps because the legacy `getText()` path stripped OMath. Position arithmetic now matches anchor-matching (`before_text` / `after_text`) paths.

No MCP source change. `Server.swift:10310` still calls `para.getText()`, but that method now delegates to the canonical text-extraction path.

#### Downstream

- **`kiki830621/collaboration_guo_analysis#6`** (thesis 30 inline math symbols): unblocked from automation. Re-running `search_text "進行t檢定"` against `碩士論文.docx` para 324 now returns a match.
- **`PsychQuant/che-word-mcp#155`** (parent / mirror): auto-resolves.

#### How this release was made

`/idd-all #43 --cwd /Users/che/Developer/macdoc/packages/ooxml-swift` (cross-repo IDD orchestration v2.40.0). Closing summary at [ooxml-swift#43](https://github.com/PsychQuant/ooxml-swift/issues/43#issuecomment-4365430488).

## [3.18.0] - 2026-05-03

### Added — `insert_equation` argument-contract hardening (closes #105 #106 #107)

PR [#111](https://github.com/PsychQuant/che-word-mcp/pull/111) closes three sister tickets surfaced by `#98` verify follow-up:

- **#106 (P2)** — `insert_equation` no longer silently picks a winner when both `components` and `latex` are passed. The handler now returns a structured error before either parser runs:
  > `Error: insert_equation: pass either 'components' (JSON tree) OR 'latex' (LaTeX subset), not both`
- **#107 (P2)** — `display_mode` rejects non-boolean values (e.g., `"true"` string from a misconfigured agent caller). Pre-fix, `args["display_mode"]?.boolValue` returned `nil` for strings and silently fell back to `?? true`, routing inline-intent calls as display-mode. Post-fix:
  > `Error: insert_equation: display_mode must be a boolean true/false, not a string or other JSON type`
- **#105 (P3)** — `paragraph_index` schema description clarified to distinguish display-mode (body.children index) from inline-mode (top-level paragraph ordinal) per the post-#91 inline branch behavior. The dedicated handler-level guard `args["paragraphIndex"]!` replaces the now-unreachable defensive `guard case .paragraphIndex(let idx)` arm; the `InsertLocationError.inlineModeRequiresParagraphIndex` catch arm is removed.

#### What changed

- `Server.swift:8843` `insertEquation(args:)` — added two pre-check guards (components+latex conflict, display_mode strict-bool) before entering the existing parsing logic.
- `Server.swift:2521-2570` `insert_equation` tool schema — `description` documents the MCP-vs-lib `display_mode` default divergence (MCP defaults to true because agent callers normally want block equations); `paragraph_index` description split into display-mode + inline-mode semantics.
- `Server.swift` — removed unreachable `throw InsertLocationError.inlineModeRequiresParagraphIndex` and its catch arm (post-#98 the pre-check already returns early before that path is hit).

#### Tests

`Issue98InsertEquationLibBypassTests` extended with 6 new tests pinning the contract:

- `testInsertEquationRejectsComponentsAndLatexTogether` — runtime conflict-error
- `testInsertEquationRejectsStringDisplayMode` — runtime type-error for `"false"` string
- `testParagraphIndexSchemaDocumentsDisplayAndInlineOrdinals` — schema text contract
- `testDisplayModeSchemaDocumentsMCPDefaultDivergence` — MCP-vs-lib default note
- `testHandlerDocumentsDisplayAppendFallback` — append-at-end semantics doc-comment
- `testServerNoLongerThrowsOrCatchesDeadInlineModeRequiresParagraphIndex` — dead-code removal

Full suite: 243 → 249 tests, 0 failures, 9 pre-existing skips.

#### 6-AI verify findings addressed

PR went through 5 Claude reviewers + Codex (gpt-5.5 xhigh). Verdict: PASS with follow-up. 0 blocking, 5 P2 follow-up findings, 6 P3 nits. Six follow-up issues opened from the review:

- [#124](https://github.com/PsychQuant/che-word-mcp/issues/124) — sibling fail-open hardening (`paragraph_index` / `text_instance` / `into_table_cell.*` `intValue` accepts strings → silent default)
- [#125](https://github.com/PsychQuant/che-word-mcp/issues/125) — JSON null vs absent semantics for `latex` / `display_mode`
- [#126](https://github.com/PsychQuant/che-word-mcp/issues/126) — runtime regression test for #105 with `[paragraph, table/SDT, paragraph]` fixture
- [#127](https://github.com/PsychQuant/che-word-mcp/issues/127) — `paragraphIndex!` force-unwrap → defensive guard or narrowed type
- [#128](https://github.com/PsychQuant/che-word-mcp/issues/128) — schema "若搭配其他 anchor" phrasing alignment with #71 anchor whitelist
- [#129](https://github.com/PsychQuant/che-word-mcp/issues/129) — echo received value in argument-validation error messages

## [3.17.8] - 2026-05-01

### Fixed — `insert_equation` MCP tool now uses lib `InsertLocation` overload + structured errors (closes #98)

[#98](https://github.com/PsychQuant/che-word-mcp/issues/98) — `insert_equation` handler bypassed the lib `WordDocument.insertEquation(at: InsertLocation, latex:, displayMode:)` overload (added in #84/#91) and called the non-throwing `insertParagraph(_:at: Int)` overload directly. Three bug surfaces:

1. **Silent-clamp** on out-of-range `paragraph_index` — `insertParagraph(_:at: Int)` clamps to last paragraph (`Document.swift:266-270`). Tool reported success but inserted at the wrong location.
2. **Lib overload bypass** — handler self-built OMML and routed through `insertParagraph` for all anchor types instead of delegating to the lib overload that handles bounds-check + structured errors centrally.
3. **Inline mode structural bug** — handler always created a NEW `Paragraph(runs: [eqRun])` regardless of `display_mode`. Lib semantics (matching `#84`/`#91` design): inline mode appends OMML run to the EXISTING paragraph at `paragraph_index`.

#### What changed

`Server.swift:8843+` `insertEquation(args:)` handler refactored. Both `latex` and `components` invocation paths now use the same insertion mechanic:

- **OMML build**: both paths feed into `[MathComponent]` (via `parseLatex` or `parseMathComponent`), then `MathComponent.toOMML()` produces structurally correct OMML (e.g., `\frac{a}{b}` → `<m:f><m:num>a</m:num><m:den>b</m:den></m:f>`). The handler does NOT delegate to lib's `Document.insertEquation(at:latex:displayMode:)` overload because that internally uses `MathEquation` which is `@available(*, deprecated, ...)` flat output (Field.swift:301): emits `<m:r><m:t>processed_string</m:t></m:r>` (Word renders as plain text, not as a live equation), and worse, wraps in `<w:p>` for displayMode causing nested `<w:p><w:p>` invalid OOXML when used inside a Paragraph context.
- **Display mode insert**: build new `Paragraph` carrying the OMML, route through lib's throwing `insertParagraph(_:at: InsertLocation)` for centralized bounds-check + structured errors.
- **Inline mode insert**: handler-side append OMML run to the existing paragraph at `paragraph_index` (lib has no structured-OMML inline-append API). Bounds-check replicates lib's `topLevelParagraphCount` pattern (Document.swift:3990-3997).
- **Both paths set `eqRun.rawXML` AND `eqRun.properties.rawXML`** to match lib's #85 BLOCKING #2 pattern — post-cluster #99-#103 flatten walker sees freshly-inserted equations before the next save→reload cycle.
- **Catch chain extended** with two new arms:
  - `InsertLocationError.inlineModeRequiresParagraphIndex` → `Error: insert_equation: inline mode requires paragraph_index anchor`
  - `InsertLocationError.invalidParagraphIndex(idx)` → `Error: insert_equation: paragraph_index N out of range`
- **Pre-check added**: `!displayMode && paragraphIndex == nil` returns a clearer message than letting it fall through to `invalidParagraphIndex(body.children.count)`.
- Existing `Inserted equation (display mode: <bool>, <anchorInfo>)` success-message format preserved (CHANGELOG-stable substring contract).

#### BREAKING — inline mode semantics changed (both paths)

> **Pre-fix**: `insert_equation(display_mode: false, paragraph_index: 5)` inserted a NEW `Paragraph(runs: [eqRun])` at index 5.
>
> **Post-fix**: `insert_equation(display_mode: false, paragraph_index: 5)` appends the OMML run to the EXISTING paragraph at index 5 (matching lib's #84/#91 design intent for inline equations).

This applies to **both `latex` and `components` invocation paths** uniformly post-v2 unification.

**Migration for callers depending on the pre-fix "new paragraph for inline" behavior**:

- Use `display_mode: true` for "new paragraph containing equation" (display equation = new paragraph by definition)
- Or call `insert_paragraph` separately followed by `insert_equation` with the new paragraph's index

This is a structural correctness fix — the pre-fix behavior was a bug, not a backward-compat surface worth preserving.

#### Tests

- `Issue98InsertEquationLibBypassTests` (NEW): 7 tests pinning the post-fix contract:
  - `testInlineModeWithOutOfRangeIndexReturnsStructuredError` — inline + bad index → structured error
  - `testInlineModeWithoutParagraphIndexReturnsStructuredError` — inline + no anchor → structured error
  - `testDisplayModeWithOutOfRangeIndexReturnsStructuredError` — display + bad index → structured error (no silent clamp)
  - `testInlineModeWithValidIndexAppendsOMMLRunToExistingParagraph` — pins BREAKING new behavior for latex path (no new paragraph; OMML survives in runs/unrecognizedChildren)
  - `testComponentsPathSilentClampReplaced` — components path also rejects bad index
  - `testComponentsPathInlineModeAppendsToExistingParagraph` — pins BREAKING new behavior for components path (matches latex path post-v2)
  - `testLatexPathProducesStructuredOMMLForFraction` — saved doc must contain `<m:f>` (math fraction) for `\frac{a}{b}`, NOT deprecated MathEquation flat `(a)/(b)` — pins the OMML quality regression Codex caught in 6-AI verify

Full suite: 236 → 243 tests, 0 failures, 9 pre-existing skips.

#### 6-AI verify findings addressed

- **P1 (Codex)**: latex path was using lib's deprecated `MathEquation` flat output → handler now keeps `MathComponent` AST for both paths
- **P1 (Logic + Devil's Advocate + Codex)**: components path inline mode still created new paragraph → handler-side inline append unifies both paths
- **P2 (Devil's Advocate)**: bounds-check counter asymmetry between paths → both paths use same `topLevelParagraphCount` pattern post-v2
- **P2 (Devil's Advocate)**: test 4 weak assertion + hidden cluster #99-#103 dependency → strengthened to inspect either runs[].rawXML or unrecognizedChildren OMML

#### Reference

- Lib `MathComponent.toOMML()` produces structurally correct OMML (`Sources/OOXMLSwift/Models/MathComponent.swift`)
- Lib's deprecated `MathEquation` (Field.swift:301) — observed defective: truncates `\frac{a}{b}` → `(a)/(b` (missing `)`) AND emits nested `<w:p>` for displayMode
- Sibling cluster #99-#103 (shipped in v3.17.7) — bilateral mirror coverage for direct-child OMML

## [3.17.7] - 2026-05-01

### Changed — ooxml-swift dep bump 0.21.10 → 0.21.11 (transitive only, no MCP source changes)

Closes 5-issue cluster [PsychQuant/che-word-mcp#99](https://github.com/PsychQuant/che-word-mcp/issues/99) + [#100](https://github.com/PsychQuant/che-word-mcp/issues/100) + [#101](https://github.com/PsychQuant/che-word-mcp/issues/101) + [#102](https://github.com/PsychQuant/che-word-mcp/issues/102) + [#103](https://github.com/PsychQuant/che-word-mcp/issues/103) — bilateral mirror coverage for direct-child OMML at 4 wrapper positions, plus library-wide design principles.

#### Cluster scope

Pre-fix `Paragraph.flattenedDisplayText` and `Document.replaceInParagraphSurfaces` shared a symmetric blind spot: direct-child OMML (`<m:oMath>` / `<m:oMathPara>` not wrapped in `<w:r>`) was silently dropped at 4 wrapper positions:

- Position 1 (`<w:p>` direct child) — Pandoc `$$...$$` display math (#99)
- Position 2 (`<w:hyperlink>` direct child) — LaTeX→docx hyperlink-wrapped math (#100)
- Position 3 (`<mc:Fallback>` direct child) — Office.js fallback emit (#101)
- Position 4 nested wrapper (e.g. `<w:hyperlink><w:fldSimple>...<m:oMath>`) (#102)
- Plus #103 docstring sync (DA-5 docstring claimed mirror invariant; pre-fix that claim was broken in the OMML axis)

Real-world impact: anchor lookups against paragraphs containing display math silently 0-matched → `replace_text` / `insert_paragraph` / `insert_image_from_path` / `insert_caption` `before_text` / `after_text` failed to find paragraphs that contained inline math.

#### Two ooxml-swift artifacts land via this dep bump

- `b73e372` — `feat: bilateral mirror coverage for direct-child OMML at 4 wrapper positions`
- 2 NEW spec capabilities promoted to `openspec/specs/`:
  - `ooxml-paragraph-text-mirror` — defines mirror invariant + `ReplaceResult` informative refusal contract
  - `ooxml-library-design-principles` — Correctness primacy + Human-like operations as foundational normative invariants for all `ooxml-swift` mutators

#### MCP impact

- `replace_text` (and other anchor-lookup tools using `findBodyChildContainingText`) — now find paragraphs containing direct-child OMML at all 4 wrapper positions
- NEW `ReplaceResult` enum (in `OOXMLSwift`) — public type carrying `.replaced(count:)` / `.refusedDueToOMMLBoundary(occurrences:)` / `.mixed(replacedCount:, refusedOccurrences:)` cases. The boundary-detection variant (new public `WordDocument.replaceTextWithBoundaryDetection` API) refuses replacements crossing OMML boundaries with informative occurrence info instead of producing structurally valid but semantically incorrect output.
- Existing `replace_text` MCP tool unchanged in this release (remains backward-compatible); future MCP-layer adapter to expose `replaceTextWithBoundaryDetection` semantics tracked separately.

#### Mirror invariant — asymmetric by design

`flattenedDisplayText` and `replaceTextWithBoundaryDetection` walk the same wrapper surfaces and detect direct-child OMML at the same 4 positions, but diverge on detected OMML — by design:

- Reads include OMML `visibleText` (anchor lookup universe extends to math)
- Writes treat OMML as opaque structural units (refuse cross-OMML mutation rather than silently delete equations or produce visible artifacts like `"see δref X"`)

#### Verification

Spectra change `flatten-replace-omml-bilateral-coverage` (now archived). 16 new tests in `Issue99FlattenReplaceOMMLBilateralTests`. ooxml-swift suite: 813 → 829 tests, 0 failures, 1 pre-existing skip. Round-trip fidelity matrix-pin unchanged (Decision 4 raw passthrough preserved).

#### Tests

- ooxml-swift: 813 → 829 (+16 sub-tests)
- che-word-mcp: 236 passing (no new MCP tests, pure transitive bump)

Backward compatible. Strict superset of pre-fix behavior.

## [3.17.6] - 2026-04-30

### Changed — ooxml-swift dep bump 0.21.9 → 0.21.10 (transitive only, no MCP source changes)

Closes [PsychQuant/che-word-mcp#104](https://github.com/PsychQuant/che-word-mcp/issues/104) — `update_all_fields` returned silent no-op (`"no SEQ fields found"`) on docs containing valid SEQ paragraphs at body top level when the fldChar block was emitted in **canonical 5-run form** (each `<w:fldChar>` / `<w:instrText>` / `<w:t>` in its own `<w:r>` sibling — what DocxReader produces post-roundtrip and what native Word always emits). Pre-fix worked only on in-memory `wrapCaptionSequenceFields` output before save.

#### Form-level vs container-level distinction

This fix is **form-level** (baked vs canonical fldChar emission), orthogonal to v3.17.5's #94 **container-level** fix (`.table` / `.contentControl` recursion). The two address independent walker dimensions.

#### Two ooxml-swift commits land via this dep bump

- `537de62` — `fix: FieldParser detects canonical 5-run fldChar form` — two-phase parse: Phase-1 baked form (existing) + Phase-2 `parseFiveRunSpan` state machine (idle → seenBegin → seenInstrText → seenSeparate → seenCached → emit). Probes BOTH `Run.rawXML` AND `Run.rawElements` (DocxReader stores fldChar/instrText as `RawElement` per allowlist `recognizedRunChildren = ["rPr", "t", "drawing", "oMath", "oMathPara"]`).
- `58fe4f9` — `fix: canonical-form cached run rawXML splice + P1 verify follow-up` — Logic + Devil's Advocate runtime test surfaced a P1: the first canonical-branch implementation only mutated `Run.text`, but `Run.toXML()` short-circuits on non-nil rawXML — would silently no-op rewrite while reporting populated counter dict. Fixed via new `rewriteCanonicalCachedText` helper that splices new value into embedded `<w:t>` while preserving `<w:rPr>` siblings and `xml:space="preserve"`, AND keeps `Run.text` in sync.

#### MCP impact

- `update_all_fields` → now finds and updates SEQ fields in canonical 5-run form (post-roundtrip / native Word emission). Previously only worked on in-memory `wrapCaptionSequenceFields` output before save.
- `list_captions` → benefits transitively via shared `FieldParser`.

#### Verification

6-AI ensemble verify (5 Claude + Codex gpt-5.5 xhigh) — 4 PASS / 2 WARN / 0 BLOCK. Production reproducer (rescue-swift-v317.docx via DocxReader path) confirmed working. P1 sub-bug surfaced and fixed in-scope. 5 P3 follow-ups filed in ooxml-swift (#29 SEQ Table coverage / #30 multi-paragraph counter / #31 multi-SEQ same paragraph / #32 DoS hardening / #33 discriminator invariant). Verify report: [comment-4346442620](https://github.com/PsychQuant/che-word-mcp/issues/104#issuecomment-4346442620). Closing summary: [comment-4348201118](https://github.com/PsychQuant/che-word-mcp/issues/104#issuecomment-4348201118).

#### Tests

- ooxml-swift: 813 tests, 0 failures, 1 pre-existing skip (was 809 → 813, +4 sub-tests in `Issue104FieldParserCanonicalFormTests`)
- che-word-mcp: 236 passing (no new MCP tests, pure transitive bump)

Backward compatible. Strict superset of pre-fix behavior.

## [3.17.5] - 2026-04-30

### Changed — ooxml-swift dep bump 0.21.8 → 0.21.9 (transitive only, no MCP source changes)

Triple release of [PsychQuant/che-word-mcp#87](https://github.com/PsychQuant/che-word-mcp/issues/87) + [PsychQuant/che-word-mcp#93](https://github.com/PsychQuant/che-word-mcp/issues/93) + [PsychQuant/che-word-mcp#94](https://github.com/PsychQuant/che-word-mcp/issues/94), all lib-only fixes verified by 6-AI ensemble (5 Claude reviewers + Codex gpt-5.5 xhigh).

#### #87 — `Comment.paragraphIndex` linker uses flat-paragraph counter (observable behavior change)

`DocxReader`'s comment-link pass previously wrote `Comment.paragraphIndex = body.children.enumerated() index`. With the new flat-paragraph counter walker (mirrors `Document.collectTopLevelParagraphs`), the invariant `comment.paragraphIndex == getParagraphs().firstIndex { contains commentId }` now holds for all body layouts.

**MCP impact**: `list_comments` `paragraph_index` field now consistently 0-indexed against `get_paragraphs()` flat list, regardless of how many tables / SDTs precede the commented paragraph. Pre-fix off-by-N (where N = number of non-paragraph BodyChild siblings before the commented paragraph). Callers using documented `get_paragraphs()[paragraph_index]` pattern: now correct. Callers manually compensating with `paragraph_index - 1` (or `- N`) to work around the bug: **will over-correct** and need to remove their compensation.

#### #93 — `wrap_caption_seq` SEQ run inherits source `position` (caption visual format fix)

Pre-fix caption like 「圖 4-1：xxx」 became 「圖 4-：xxx1」 after `wrap_caption_seq` because the new SEQ run had `position = nil` while source-loaded `preText` / `postText` had `position > 0`. `Paragraph` emit bifurcates by position field — positioned section vs legacy post-content section — so SEQ landed at end of paragraph instead of spliced at match position.

**MCP impact**: `wrap_caption_seq` now produces visually-correct captions on real Word docs (where source-loaded paragraphs have `position > 0` runs). The pre-existing test pattern used `Paragraph(text: "...")` (which produces `position = nil`) and shared the legacy emit path — bug only visible on real docx data.

**Known incompleteness**: `insert_bookmark=true` × source-loaded paragraph still has the same gap on `bookmarkStart`/`bookmarkEnd` markers (filed as **PsychQuant/ooxml-swift#24**). Default `insert_bookmark=false` unaffected.

#### #94 — `update_all_fields` traverses `.table` and `.contentControl` containers

Pre-fix body loop only processed top-level `.paragraph` BodyChild — silently skipped `.table` and `.contentControl(_, children:)`. SEQ fields anchored inside table cells or block-level SDTs were never updated, returning `update_all_fields completed: 0 SEQ fields found` for thesis docs (where caption paragraphs commonly live inside the table they describe). Same gap that #68 (v0.20.6) closed for `findBodyChildContainingText`.

**MCP impact**: `update_all_fields` now finds and updates SEQ fields inside body-level table cells / block-level SDT children — automates the "Adam opens Word → Ctrl+A → F9" workflow step for thesis pipelines. Heading-count semantics: only top-level direct `.paragraph` body children count toward chapter-reset (container-nested headings do NOT trigger SEQ resets — conservative choice documented and pinned by test).

**Known incompleteness** (filed as follow-ups):
- **PsychQuant/ooxml-swift#25** — header / footer / footnote / endnote SEQ scans still walk flat `.paragraphs` view (drops `.table` / `.contentControl` siblings). SEQ inside header/footer table cells, footer SDT children, footnote/endnote tables still silently skipped.
- **PsychQuant/ooxml-swift#26** — `FieldParser.parse(paragraph:)` only walks `para.runs[*].rawXML`. Misses `para.contentControls` (inline SDT containing fields), `para.hyperlinks[*].runs[*].rawXML`, `para.fieldSimples` (`<w:fldSimple>` wrappers), `para.alternateContents[*].fallbackRuns[*].rawXML`. Same recipe as #92's OMML wrapper-paths fix.
- **PsychQuant/ooxml-swift#27** — verify-with-user-fixture: real thesis docx roundtrip test (no fixture from kiki830621/collaboration_guo_analysis#5).

Plus **PsychQuant/ooxml-swift#28** — refactor follow-up: extract `BodyChildVisitor` protocol to dedupe 5+ near-identical body-children walkers (consensus P3 from regression + devils-advocate reviewers).

#### Test status

- ooxml-swift suite: 805 → 809 (+4 from #94 only — #87 and #93 add tests under their own test files which were counted separately in 791→796→800→805 progression). 0 failures, 1 pre-existing skip.
- che-word-mcp suite: 236 passing (no new MCP tests, no regressions, 9 pre-existing skips).
- Backward compatible (except #87 documented behavior change).

## [3.17.4] - 2026-04-29

### Changed — ooxml-swift dep bump 0.21.7 → 0.21.8 (transitive only, no MCP source changes)

Paired release of [PsychQuant/che-word-mcp#91](https://github.com/PsychQuant/che-word-mcp/issues/91) + [PsychQuant/che-word-mcp#92](https://github.com/PsychQuant/che-word-mcp/issues/92), both lib-only post-#85 verify follow-ups.

#### #91 — `insertEquation` inline-mode error semantics

`WordDocument.insertEquation(at: InsertLocation, latex:, displayMode:)` previously silently no-op'd or accepted out-of-bounds indices in two failure classes. Both now surface dedicated `InsertLocationError` cases:

- `InsertLocationError.inlineModeRequiresParagraphIndex` — thrown when inline mode is requested with `.atEnd` / `.bookmark` / `.contentControlByTag` etc.
- `InsertLocationError.invalidParagraphIndex(Int)` — thrown when `paragraphIndex` is negative or `≥ topLevelParagraphCount`

**MCP impact**: `insert_equation` calls with `paragraph_index` out of bounds, or with anchors that are semantically invalid for inline math, now return structured errors instead of silent fallthrough/no-op. Same v3.15.x family `Error: <tool>: <body>` prefix discipline.

#### #92 — `flattenedDisplayText` OMML wrapper-path coverage

`Paragraph.flattenedDisplayText()` walked OMML in the top-level `runs` loop only after #85's v0.21.5 fix. The 3 sibling surface paths (`hyperlinks[].runs` / `fieldSimples[].runs` / `alternateContents[].fallbackRuns`) used `runs.map { $0.text }.joined()` and silently dropped any `<m:oMath>` inside those wrappers.

Solution: extracted the OMML walk into `flattenRunsWithOMML(_:)` private static helper at `Sources/OOXMLSwift/Models/InsertLocation.swift:310-320` and routed all 4 wrapper paths through it. `contentControls` path remains on its `flattenContentControlText` helper (different recursion strategy, established in #63). Cheap `raw.contains("oMath")` short-circuit avoids `OMMLParser` invocation on plain runs.

**MCP impact**: anchor lookups (`replace_text` / `insert_paragraph` / `insert_image_from_path` / `insert_caption` `before_text`/`after_text`) against paragraphs containing inline math inside hyperlink/fldSimple/AC fallback wrappers now succeed where they previously silently 0-matched. Strict superset of pre-fix behavior — anchors that previously found text continue to find it.

#### Follow-ups filed (out of v3.17.4 scope)

Devils-advocate verify of #92 surfaced 4 sibling bugs at neighboring container levels (DA-1..DA-4) + 1 docstring qualifier (DA-5). Filed as #99-#103 for separate disposition. NOT regressions introduced by v3.17.4.

#### Test status

- 236 passing (no new MCP tests, no regressions, 9 pre-existing skips)
- Backward compatible

## [3.17.3] - 2026-04-29

### Changed — ooxml-swift dep bump 0.21.6 → 0.21.7 (transitive only, no MCP source changes)

Pure dep bump exposing the public anchor lookup API from [PsychQuant/ooxml-swift#86](https://github.com/PsychQuant/che-word-mcp/issues/86):

- `WordDocument.findBodyChildContainingText(_:nthInstance:)` is now `public` (was `private`)
- `WordDocument.bodyChildContainsText(_:needle:)` is now `public static` (was `private static`)
- `WordDocument.tableContainsText(_:needle:)` is now `public static` (was `private static`)

#### Why this matters for MCP consumers

External Swift SPM consumers (rescue scripts, dxedit CLI, third-party tooling) previously had to reimplement anchor lookup with diverging semantics:
- Some skipped `.contentControl(_, children:)` recursion
- Some skipped `.table` cell traversal (pre-#68 default)
- Some used different `nthInstance` counting rules (top-level body child vs flattened paragraph)

Now they can call the canonical `WordDocument.findBodyChildContainingText` directly, getting *exactly* what `che-word-mcp`'s `insert_paragraph` / `insert_image_from_path` / `insert_caption` etc. tools see when they resolve `after_text` / `before_text` anchors.

#### Internal cleanup follow-up

The MCP layer (`Server.swift`) currently has its own `anchorIndex` resolution helpers that mirror parts of the lib's logic. A future internal refactor can de-duplicate by routing those helpers through the now-public `WordDocument.findBodyChildContainingText`. Out of scope for this dep bump; will be tracked as a separate refactor issue if/when it surfaces friction.

#### Test status

236 tests passing (0 failures, 9 pre-existing skips). No new tests added; no regressions surfaced by ooxml-swift dep bump.

#### Backward compatibility

Pure additive (private → public visibility change). No API removals, no behavioral changes for existing callers. Backward compatible.

## [3.17.2] - 2026-04-29

### Changed — ooxml-swift dep bump 0.21.2 → 0.21.6 (transitive only, no MCP source changes)

Pure dep bump pulling in 4 ooxml-swift releases worth of hardening + new APIs. No MCP tool surface changes; behavior is mostly identical for typical callers, with new typed errors surfacing on edge cases (malicious input, dirty fallback edits) and 2 deprecation warnings firing on previously-supported lossy mutation APIs.

#### v0.21.3 — XML hardening (closes [PsychQuant/ooxml-swift#7](https://github.com/PsychQuant/ooxml-swift/issues/7))

- DTD reject — pre-scans document XML for `<!DOCTYPE` and throws `XMLHardeningError.dtdNotAllowed` (OOXML disallows DTD; no false positives on legitimate input)
- 64KB attribute-value cap — throws `XMLHardeningError.attributeValueTooLarge(name:limit:)` on multi-MB `mc:Ignorable` payloads (DoS amplification defense)
- SAX-based root-element attribute parsing — handles `<wordml:document>` / default-namespace docs without regression to original #56 bug
- Attribute-name whitelist on emit — throws `XMLHardeningError.invalidAttributeName(name:)` instead of letting malformed names from source transit to Writer output

#### v0.21.4 — roundtrip loud-fail (closes [PsychQuant/ooxml-swift#6](https://github.com/PsychQuant/ooxml-swift/issues/6))

- `AlternateContent.fallbackRunsModified` dirty flag — throws `RoundtripError.unserializedFallbackEdit(position:)` when in-memory fallbackRuns mutation isn't propagated to rawXML. Closes the #56 silent UX failure where `replace_text` reported success but disk write was stale.
- `Run.commentIds` `@available(*, deprecated)` with migration guidance to `commentRangeMarkers` (single source of truth since Phase 4). Stored `commentIds` no longer populated by Reader since v0.21.4; full removal scheduled for v0.22.

#### v0.21.5 — insertEquation flexibility (closes [PsychQuant/che-word-mcp#84 #85](https://github.com/PsychQuant/che-word-mcp/issues/84))

- New `Document.insertEquation(at: InsertLocation, ...)` overload — replaces the legacy `at: String` paragraph-text resolver with the unified InsertLocation enum. The String overload is `@available(*, deprecated)` until v0.22.
- `flattenedDisplayText` extension covers OMML — anchor-text resolution (used by `insertEquation`, `insert_paragraph` `after_text` / `before_text`) now traverses display-mode equations and surfaces their visible text. Previously, insert calls anchored on text inside equations would fail with `textNotFound`.

#### v0.21.6 — mutation surface fix (closes [PsychQuant/ooxml-swift#5](https://github.com/PsychQuant/ooxml-swift/issues/5))

- `Hyperlink.text` setter `@available(*, deprecated, message: "Mutates runs destructively (loses formatting / rawElements). Use .runs directly to preserve formatting; assign a single Run to replace, append/insert Runs to extend.")` — pre-fix, calling `hyperlink.text = "new"` discarded all `RunProperties` (bold/italic/color/font/size/rStyle) and `Run.rawElements` (e.g., embedded VML). Removal scheduled for v0.22.
- Position field cascade `Int = 0` → `Int? = nil` across 13 typed-child models (`Hyperlink`, `Run`, `AlternateContent`, `FieldSimple`, `Field`, `ParagraphChildMarkers` + subtypes). Tri-state semantics: `nil` (unset, new mutations), `0` (legacy front-pinned default — preserved for backward compatibility), `> 0` (explicit ordering from XML round-trip). 27 Paragraph.swift sites bulk-transformed via `(position ?? 0) > 0` patterns.
- `Run.toXMLThrowing` autosense for `xml:space="preserve"` — fires only when text starts/ends with whitespace OR contains consecutive whitespace runs. Avoids attribute bloat on the common case.

#### Plus 3 unreleased docs commits on ooxml-swift main

- [PsychQuant/ooxml-swift#17](https://github.com/PsychQuant/ooxml-swift/issues/17) — Bidirectional reference comments at both `needsPPr` emit gates pointing to `Issue4PPrRegressionGuardTests.testEmptyPPrSelfClosingProducesNoUnrecognizedAndDropsEmptyBlock` (lock-in test for drop-empty-pPr invariant)
- [PsychQuant/ooxml-swift#15](https://github.com/PsychQuant/ooxml-swift/issues/15) — Pattern divergence documented at both walker sites (parseRun's function-local `recognizedRunChildren` vs parseParagraph's static `walkerPreConsumed` — different mental models, complementary mechanisms)
- [PsychQuant/ooxml-swift#14](https://github.com/PsychQuant/ooxml-swift/issues/14) — Foreign-namespace pPr asymmetry documented at `parseParagraphProperties` consumer (`<x:pPr xmlns:x="other-ns">` is silently dropped — intentional conservative response to spec-illegal input)

#### Test status

236 tests passing (0 failures, 9 pre-existing skips). No new tests added; no regressions surfaced by ooxml-swift dep bump.

#### Backward compatibility

- Deprecation warnings: `Hyperlink.text` setter, `Run.commentIds` (both fire only when callers actively use the lossy/legacy API; no behavioral change unless caller writes to those properties)
- New typed errors: `XMLHardeningError.*` (only on malicious/malformed input), `RoundtripError.unserializedFallbackEdit` (only on dirty AlternateContent edits) — code that previously silently lost data now throws fail-fast
- No API removals (all v0.21.x deprecations queued for v0.22)

## [3.17.0] - 2026-04-28

### Added — wrap_caption_seq MCP tool (Refs #62)

Phase 2 of the cross-repo `wrap_caption_seq` work — exposes the lib API (ooxml-swift v0.21.0 `WordDocument.wrapCaptionSequenceFields`) as an MCP tool. Phase 1 shipped the lib in v3.16.2. This release wires the MCP wrapper.

#### Real-world need

Documents pasted from external sources (LaTeX-converted Word, Google Docs, Pandoc) carry caption numbering as **plain text** instead of real Word SEQ fields. As a result, `insert_table_of_figures` / `insert_table_of_tables` produce empty TOFs because there are no SEQ fields to scan. `wrap_caption_seq` rescues these documents in one bulk pass: regex-match the caption text, replace the numeric portion with a real SEQ field whose `cachedResult` preserves the user-typed numeral.

#### Tool surface

```jsonc
{
  "name": "wrap_caption_seq",
  "args": {
    "doc_id":            "p1",                         // required
    "pattern":           "圖 4-(\\d+)：",                // required — regex with EXACTLY ONE capture group
    "sequence_name":     "Figure",                     // required — SEQ identifier (matches insert_caption / list_captions)
    "format":            "ARABIC",                     // optional — ARABIC | ROMAN | ALPHABETIC (default ARABIC)
    "scope":             "body",                       // optional — body | all (default body; all → scope_not_implemented in v3.17.0)
    "insert_bookmark":   false,                        // optional — opt-in bookmark wrap
    "bookmark_template": "fig${number}"                // required when insert_bookmark=true; must contain literal ${number}
  }
}
```

Returns JSON with snake_case keys:

```json
{
  "matched_paragraphs":  3,
  "fields_inserted":     3,
  "paragraphs_modified": [0, 1, 2],
  "skipped":             []
}
```

Each `skipped` entry carries `paragraph_index` + `reason` (e.g. `"already wraps SEQ Figure"`). Top-level `paragraphs_modified` indices are body.children-relative — same convention as `insert_paragraph`.

#### Idempotency contract

Re-running on the same document reports already-wrapped paragraphs in `skipped` with `reason: "already wraps SEQ <name>"` and never double-wraps. Detection covers BOTH typed `FieldSimple` SEQ emissions AND `Run.rawXML`-embedded 5-run `<w:fldChar>` blocks. The lib's match-counter inlines existing SEQ `cachedResult` digits when matching, so the regex still recognizes wrapped captions on re-runs.

#### Pre-mutation validation (Error: wrap_caption_seq: ...)

All preconditions checked BEFORE document mutation, returning `"Error: wrap_caption_seq: <body>"` per #70 tool-prefix convention:

- `pattern failed to compile: <NSError reason>`
- `pattern must contain exactly one capture group, got <N>`
- `format '<X>' not recognized. Valid: ARABIC / ROMAN / ALPHABETIC.`
- `scope '<X>' not recognized. Valid: body / all.`
- `bookmark_template required when insert_bookmark is true`
- `bookmark_template must contain literal '${number}' placeholder, got '<X>'`
- `scope_not_implemented: all (Phase 1 ships .body only; .all lands in v3.17.x)`

`doc_id` not opened throws `WordError.documentNotFound` per existing convention.

#### Phase 1 scope deferral

`scope: "all"` (cross-container — headers/footers/footnotes/endnotes) returns `Error: wrap_caption_seq: scope_not_implemented: all` and lands in v3.17.x alongside an integration test. The Phase 1 `body` walk does already recurse into `.table` (rows × cells × paragraphs + nestedTables) and `.contentControl(_, children:)` (recursive).

#### Bookmark wrap (opt-in)

Default off — passing 23 plain captions through with `insert_bookmark: false` adds zero bookmarks (avoids polluting `list_bookmarks`). When on, `bookmark_template` MUST contain literal `${number}` placeholder; the captured numeric replaces it (e.g. `fig${number}` → `fig7` for `Figure 7.`).

#### Tests

5 sub-tests in `Issue62WrapCaptionSeqTests`:
- `testWrapCaptionSeqEndToEndOnThreeFigureCaptions` (Scenario 1)
- `testWrapCaptionSeqIdempotentReRun` (Scenario 2)
- `testWrapCaptionSeqRejectsZeroCaptureGroupPattern` (Scenario 3, exact error string)
- `testWrapCaptionSeqRejectsBookmarkTrueWithoutTemplate` (Scenario 5)
- `testWrapCaptionSeqAfterCallEnablesUpdateAllFieldsAndTOF` (end-to-end value test)

Suite: `231 → 236` (+5, 0 fail / 9 skip). No ooxml-swift dep bump (still v0.21.0 from v3.16.2).

#### Backward compatibility

Pure addition. No tool removed, no schema change to existing tools, no error-message format change. New tool name `wrap_caption_seq`; dispatcher chain unchanged for all other cases.

## [3.16.2] - 2026-04-28

### Changed — bump ooxml-swift dep 0.20.5 → 0.21.0 (Refs #62 #68)

Pure dep bump; no MCP-layer source changes. Picks up two ooxml-swift fixes that surface transparently to MCP callers via the existing tool dispatch:

#### #68 — text anchor lookup recurses into table cells + block-level SDT (ooxml-swift v0.20.6)

`InsertLocation.findBodyChildContainingText` now traverses `.table` (rows × cells × paragraphs + nestedTables) and `.contentControl(_, children:)` (recursive). Pre-fix anchor text inside a table cell or block-level `<w:sdt>` was silently skipped → `textNotFound` thrown even though the text was present.

**MCP impact** — `insert_paragraph` / `insert_image_from_path` / `insert_equation` / `insert_caption` calls using `before_text` / `after_text` now succeed when the anchor text lives inside a table cell or block-level SDT (common in thesis docs with figure/table captions inside table cells). Returned position is the **top-level** `body.children` index of the containing table/SDT — insert lands at body level adjacent to the entire structure, not inside cells. Use `into_table_cell` for inside-cell inserts.

Also picks up empty-needle guard: passing `before_text: ""` / `after_text: ""` now returns `textNotFound` instead of silently inserting at index 1.

#### #62 — wrapCaptionSequenceFields lib API available (ooxml-swift v0.21.0)

`WordDocument.wrapCaptionSequenceFields(...)` is now linked into the binary. **Not yet exposed as an MCP tool** — the `wrap_caption_seq` MCP wrapper ships in v3.17.0 (Phase 2 of the cross-repo work). Existing MCP tools are unaffected.

### Tests

Suite unchanged: `231 → 231` (0 fail / 9 skip). Dep bump is exercised end-to-end via the existing test surface; ooxml-swift itself ships 716 tests of which 10 cover the #62 lib API and 10 cover the #68 traversal fix.

### Backward compatibility

Strict superset of v3.16.1 behavior. The only externally observable change is that previously-`textNotFound` calls (anchor text in table cells / block SDT) now succeed. No tool removed, no schema change, no error-message format change.

## [3.16.1] - 2026-04-28

### Changed — anchor-presence whitelist drift prevention (Refs #80)

Pure refactor; no runtime behavior change. Closes #80 forward-looking risk surfaced during /idd-verify of #71 (security + devil's advocate).

#### Pre-fix risk

`anchorPresence` static dict (7 anchor name → predicate map at `Server.swift:58`) was synced manually with 4 per-tool literal anchor arrays at lines ~6649 / ~7897 / ~8829 / ~12181. Future PR adding new anchor to one tool's call-site array but forgetting `anchorPresence` → `detectPresentAnchors` silently skips unknown name → conflict-detection regresses to silent priority winner for that anchor. NO drift in v3.16.0; risk forward-looking only.

#### Fix

- New `static let toolAnchorWhitelists: [String: [String]]`: single source of truth keyed by MCP tool name (snake_case) → accepted anchor list.
- New `detectPresentAnchors(_:tool:)` overload: looks up dict, delegates to existing `(args, anchors:)` overload. Defensive: unknown tool returns `[]`.
- 4 conflict-detection call sites switched to `(args, tool: "insert_paragraph")` form, replacing duplicated literal arrays.
- 4 new tests in `AnchorDXConsistencyTests`:
  - `testToolAnchorWhitelistsSubsetOfAnchorPresence` — invariant: every name in any tool's whitelist must exist in `anchorPresence.keys`. Catches the documented drift mode.
  - `testToolAnchorWhitelistsCoversFourTargetTools` — pin: dict must cover exactly the 4 #61-target tools.
  - `testDetectPresentAnchorsByToolMatchesByExplicitAnchors` — overload parity.
  - `testDetectPresentAnchorsByUnknownToolReturnsEmpty` — defensive.

Old `(args, anchors:)` overload preserved (no breaking change to API surface). Doc note added recommending the new `(tool:)` overload for #61-target tools.

Suite: `227 → 231` (+4, 0 fail / 9 skip). No `ooxml-swift` dep bump (still v0.20.5).

#### Out of scope (follow-up surfaces)

Verify-80 Devil's Advocate flagged two remaining drift surfaces NOT closed by this refactor:
- Schema descriptions in `inputSchema.properties.*.description` text still hardcode anchor names (3rd duplicate copy)
- Dispatcher `if let / else if let` chain at handlers (lines ~5698 / 5776 / 5854 / 6128) reads `args["anchor_name"]` directly, not via dict

Removing an anchor from `toolAnchorWhitelists` would silently disable conflict detection but the dispatcher would still process it. These are pre-existing risks, not introduced by this PR. Track as separate enhancement if pursued.

## [3.16.0] - 2026-04-28

### Changed — Bundle B anchor DX consistency (Refs #70 #71 #72)

**BREAKING (input validation only)** — three coordinated MCP-layer changes across the 4 `#61`-target tools (`insert_paragraph` / `insert_equation` display mode / `insert_image_from_path` / `insert_caption`). Behavior change ONLY for callers passing 2+ anchors or explicit `text_instance` ≤ 0; single-anchor and omitted-text_instance paths unchanged.

Spectra change: `anchor-dx-consistency`. SemVer rationale (minor not major): no schema break, no tool removal, no required-param additions — restricting previously-undefined behavior (silent priority order was an implementation detail that leaked, never documented as contract). See `openspec/changes/anchor-dx-consistency/design.md` *Cross-cutting: backward-compat note + SemVer rationale* for full reasoning.

#### #71 (behavior) — silent priority on conflicting anchors → structured error

Pre-fix: `insert_paragraph(after_text="foo", index=3)` silently picked `after_text` per a hardcoded priority chain and ignored `index`. AI callers got a misleading "success" message and assumed both args were honored.

Post-fix: returns `"Error: insert_paragraph: received conflicting anchors: after_text + index. Specify exactly one."` (anchors alphabetically sorted). Same pattern applied to all 4 tools. New static helper `WordMCPServer.detectPresentAnchors(_:anchors:)` with per-anchor type-aware predicates — JSON `null` and wrong-type values do NOT count as present (matches existing dispatcher semantics).

Per-tool anchor sets:

| Tool | Anchor set |
|---|---|
| `insert_paragraph` | `into_table_cell` / `after_image_id` / `after_text` / `before_text` / `index` |
| `insert_equation` (display mode) | `into_table_cell` / `after_image_id` / `after_text` / `before_text` / `paragraph_index` |
| `insert_equation` (inline mode) | _no anchors accepted_ — pre-existing v3.15.1 rejection unchanged |
| `insert_image_from_path` | `into_table_cell` / `after_image_id` / `after_text` / `before_text` / `index` |
| `insert_caption` | `paragraph_index` / `after_image_id` / `after_table_index` / `after_text` / `before_text` |

Modifiers (`text_instance`, `position`, `style`) are NOT anchors and don't count toward conflict.

`insert_caption`'s pre-existing `anchorCount == 1` check is replaced by the unified helper-based check. Side effect: zero-anchor error format changed from `"Error: exactly one of paragraph_index / ... must be provided (got N)"` to `"Error: insert_caption: at least one anchor required (...). Specify exactly one."` — semantically identical, format aligned with new convention.

#### #72 (validation) — `text_instance ≤ 0` rejected when explicitly specified

Pre-fix: schema accepted any Int; explicit `text_instance: 0` or negative passed through to lib without validation.

Post-fix: explicit `text_instance < 1` returns `"Error: <tool>: text_instance must be ≥ 1, got <N>."` Omitted `text_instance` continues to default to `1` (silent — that's coalescing, not user input). Reason: `instance: 0` has no defined lib semantics ("zeroth match" is undefined); rejecting pushes callers toward the documented contract.

#### #70 (DX) — tool-prefix all `return "Error: ..."` lines in 4 tools

Pre-fix: half of error paths used `throw WordError.*` (structured, gets tool name from caller's catch handler at `dispatch()` level); the other half used raw `return "Error: ..."` strings (no tool identifier). When 5 tools all returned `"Error: text 'foo' not found"` an AI parsing the response couldn't tell which call failed.

Post-fix: all 32 `return "Error: ..."` lines in the 4 `#61`-target tools rewritten as `"Error: <tool>: <body>"`. `throw WordError.*` paths unchanged.

Examples:
- `"Error: text 'foo' not found (instance 1)"` → `"Error: insert_paragraph: text 'foo' not found (instance 1)"`
- `"Error: image rId 'rId99' not found"` → `"Error: insert_image_from_path: image rId 'rId99' not found"`
- `"Error: into_table_cell requires all three fields"` → `"Error: insert_equation: into_table_cell requires all three fields"`

**Scope deliberately limited to 4 tools.** The remaining 41 `return "Error: ..."` lines elsewhere in `Server.swift` (~50 unfamiliar handlers) are tackled by a separate `error-prefix-sweep` follow-up change. Rationale in design §3 *Phasing*: bundling them would push past the 15-task scope guideline and risk subtle handler-name mistakes.

#### Tests

`AnchorDXConsistencyTests.swift` — 25 new sub-tests:
- 9 helper unit tests (presence detection, null / wrong-type / modifier exclusion, whitelist)
- 4 conflict-rejection integration tests (across 4 tools, including the alphabetical-sort 3-anchor case)
- 4 backward-compat happy-path tests (single anchor still dispatches; insertEquation inline rejection preserved; modifier params don't count)
- 6 `text_instance` validation tests (explicit 0 / -1 / -3 across 4 tools + 1 omitted-default)
- 1 grep-based regression pin asserting zero un-prefixed `return "Error: ..."` lines in the 4 target tools

Suite: `201 → 227` (+26, 0 fail / 9 skip). No `ooxml-swift` dep bump (still v0.20.5).

#### Verify-71 hot-fix (2026-04-28)

Devil's Advocate caught DX inconsistency in `insertImageFromPath`: conflict-detection sat after `fileExists` guard + `resolveImageDimensions(throws)` + entry log write, so a "bad path + 2 anchors" call surfaced the file-IO error instead of the conflict error. Bundle is literally named `anchor-dx-consistency` — moved conflict check to be the FIRST validation after parameter guards. Other 3 tools were already correct. New regression pin `testInsertImageFromPathConflictReportedBeforeBadPathError`.

#### Migration guidance

If your existing prompts pass 2+ anchors expecting silent priority winner: drop the redundant ones. Error message itemizes the conflict. Example:

```
Before (worked silently): insert_paragraph({ doc_id, text, after_text: "foo", index: 3 })
                          → silently picked after_text, ignored index, returned success message

After (v3.16.0+):         insert_paragraph({ doc_id, text, after_text: "foo", index: 3 })
                          → "Error: insert_paragraph: received conflicting anchors: after_text + index. Specify exactly one."
```

If your prompts pass `text_instance: 0` expecting "find any": drop the param entirely (defaults to 1 = first match).

If you grep tool outputs for un-prefixed error strings (`"text '...' not found"`): update grep to match `"Error: <tool>: text '...' not found"` — body is unchanged, only prefix added.

#### Out of scope (deferred)

- `error-prefix-sweep` (separate change) — 41 remaining `return "Error: ..."` lines in non-`#61`-target handlers across `Server.swift`. Mechanical, low-risk, ships as v3.16.x patch.
- `#67` (insert_equation inline anchors) — closing as wontfix-with-rationale outside Spectra. Inline equations are a structurally different shape (run-inside-paragraph); paragraph-level anchor set semantics are ill-defined for inline mode.
- Lib-layer index-convention unification — PsychQuant/ooxml-swift#10, separate process.

## [3.15.3] - 2026-04-28

### Fixed — Bundle A2 polish from v3.15.2 verify R3-R6 follow-ups (Refs #76 #77 #78 #79)

Cleanup release for the four P3-level findings opened during /idd-verify of v3.15.2 Bundle A. All trivial; no production behavior change; `196 → 201` tests.

#### #76 (docs) — schema description doc rot

Two adjacent schema description fixes in `Server.swift`:

- `insert_caption` (line 4781): description said `'三種 anchor (paragraph_index / after_image_id / after_table_index)'` but the schema has exposed 5 anchors (+ `after_text` + `before_text`) for several releases. Updated to enumerate all 5.
- `insert_equation.paragraph_index` (line 2491): description said `'段落索引'` (which reads as paragraph-only index) but the handler passes to `Document.insertParagraph(_:at:Int)` which is `body.children`-indexed. Now explicitly notes it is a `body.children` index distinct from `get_paragraphs`'s paragraph-only count, and cross-references [PsychQuant/ooxml-swift#10](https://github.com/PsychQuant/ooxml-swift/issues/10) for the lib-layer convention split.

Schema description text only — no schema field additions / removals, no behavior change.

#### #77 (docs) — `insert_caption` shared/unique anchor split wording

v3.15.2 wording `"insert_caption is a 4th insert tool with its own anchor set including after_table_index"` implied a disjoint set. In reality `insert_caption` shares 3 of 5 anchors (`after_image_id` / `after_text` / `before_text`) with the unified set + `paragraph_index`. Unique to caption: `after_table_index` + `position` modifier. Replaced 3 occurrences with the explicit shared / adds / lacks enumeration: `"shares after_image_id / after_text / before_text / paragraph_index, adds after_table_index + position, lacks into_table_cell"`.

#### #78 (test) — extend #69 append-index regression pin

`testInsertParagraphAppendMessageUsesBodyChildrenIndex` (added in v3.15.2) only covered `[para, table, para]`. The same `getParagraphs() vs body.children.count` divergence applies to ALL non-paragraph BodyChild variants, not just `.table`. Added 3 new sub-tests covering `.bookmarkMarker` / `.rawBlockElement` / block-level `.contentControl` to lock against future regression to `getParagraphs().count - 1` that might pass the table case but break for SDT / TOC bookmark anchors / vendor extensions.

#### #79 (test) — round-trip depth + cross-family negative

The original v3.15.2 #69 test only asserted message format; it never actually called `insert_paragraph` again with the reported index to demonstrate true round-trip. Two new tests:

- `testInsertParagraphAppendIndexRoundTripsForInsertCalls` — append, parse reported index from message, call `insert_paragraph(index=N+1)`, verify via `get_paragraphs` that the new paragraph lands after the appended one. Demonstrates the insert-family round-trip the #69 fix optimizes for.
- `testInsertParagraphAppendIndexCannotRoundTripToUpdate` — append, parse index, call `update_paragraph(index=N)` and assert it throws `WordError.invalidIndex`. Pins the cross-family trade-off acknowledged in the v3.15.2 CHANGELOG (where N is body.children index but `update_paragraph` interprets it as paragraph-only count). Tracks PsychQuant/ooxml-swift#10 as the deeper unification path.

### Tests

`swift test --disable-sandbox` — `196 → 201` (+5 from this release: 3 BodyChild variants for #78 + 2 round-trip variants for #79). 0 fail / 9 pre-existing skips.

### Backward compatibility

Pure docs + tests. No production code change. No schema field additions or removals. No behavioral surface affected.

### No ooxml-swift dep bump

Still v0.20.5 (unchanged).

---

## [3.15.2] - 2026-04-28

### Fixed — Bundle A polish from v3.15.1 R2 verify (Refs #69 #73 #74 #75)

Cleanup release for the four P3-level findings left over from #61's R2 verify (codex + devil's advocate) plus #69 (pre-existing index mis-report exposed by #61 follow-ups). All trivial; no behavior change in normal call paths; `194 → 196` tests.

#### #69 (bug) — `insert_paragraph` append message reports `body.children` index

`Server.swift:6659` reported `getParagraphs().count - 1` for the append branch. `getParagraphs()` is recursive over `body.children` but skips tables and SDT markers (`Document.swift:205-228`), so in a doc with body `[para, table, para]` + appended para, it reported `at index 2` while `body.children.count - 1` was `3`. Since `Document.insertParagraph(_:at:Int)` interprets its int as a `body.children` index (`Document.swift:266-270`), the reported number was not round-trippable as `paragraph_index` for subsequent **`insert_*`** calls. Now uses `body.children.count - 1`, matching the convention `insert_equation` already used at `Server.swift:8799`. See "Backward compatibility" below for the cross-tool-family trade-off and link to the underlying lib-layer issue.

#### #74 (bug) — `insert_image_from_path` debug log mis-labeled `after_image_id`

v3.15.1 wired `after_image_id` into `insert_image_from_path`'s dispatch (`Server.swift:7891`) but the structured-entry log's `anchorKind` detection (`Server.swift:7844-7848`) only checked `into_table_cell` / `after_text` / `before_text`. Calls using `after_image_id` were silently labeled `index` in debug output. Detection priority now mirrors dispatch priority. Debug-log only; no behavior change.

#### #73 (test) — `insert_equation` F5 partial-dict regression pin

v3.15.1 added F5 partial-dict guards to all three insert tools at `Server.swift:8762` (equation), but the test sweep only covered paragraph + image_from_path. Adds `testInsertEquationMalformedIntoTableCellReportsError` to pin the equation guard.

#### #75 (docs) — `'3 insert tools'` wording precision

CHANGELOG / manifest / marketplace.json / plugin.json described scope as `'across the 3 insert tools'` / `'across all 3 tools'`, but the repo has a 4th insert tool (`insert_caption`) which has a partially-overlapping anchor set (shares `after_image_id` / `after_text` / `before_text` / `paragraph_index` with the unified set, adds `after_table_index` + `position`, lacks `into_table_cell`). v3.15.1's anchor unification scope was the 3 #61-target tools (`insert_paragraph` / `insert_equation` / `insert_image_from_path`). Replaced ambiguous phrasing with explicit enumeration.

### Tests

`swift test --disable-sandbox` — `185 → 194 → 196` (+2 from this release: `testInsertEquationMalformedIntoTableCellReportsError` for #73 + `testInsertParagraphAppendMessageUsesBodyChildrenIndex` for #69). 0 fail / 9 pre-existing skips.

### Backward compatibility

- `insert_paragraph` append message changed from `'at index N'` (where N counted via `getParagraphs().count - 1`) to `'at index M'` (where M = `body.children.count - 1`). For docs without tables / SDTs, N == M (no observable change). For docs with tables / SDTs, M and N differ.
- **The change is a trade-off, not a strict correctness fix.** che-word-mcp has TWO `paragraph_index` semantic families across ~23 tools: (a) the 4 `insert_*` tools interpret int as `body.children` index; (b) `update_paragraph` / `delete_paragraph` / `format_text` / `insert_text_as_revision` / etc. (~19 tools, via lib `Document.bodyIndexForParagraph` at `Document.swift:2528`) interpret int as paragraph-only count (skip tables / SDTs). Pre-fix message N matched family (b); post-fix M matches family (a). Pipeline `insert_paragraph (append) → insert_paragraph (index=N+1)` is now correct; pipeline `insert_paragraph (append) → update_paragraph (index=M+1)` now throws `WordError.invalidIndex` (where it previously succeeded). The fix optimizes for the more common "append then insert near end" workflow at the cost of the cross-family pipeline.
- The deeper lib-layer inconsistency is tracked in [PsychQuant/ooxml-swift#10](https://github.com/PsychQuant/ooxml-swift/issues/10) — a unified semantic for the int parameter would close the trade-off entirely.
- `insert_image_from_path` debug-log label change is observable only when `CHE_WORD_MCP_LOG_LEVEL=debug`.
- All other changes are docs / tests; no behavioral surface affected.

### No ooxml-swift dep bump

Still v0.20.5 (unchanged).

---

## [3.15.1] - 2026-04-28

### Added / Fixed — Verify findings F1+F2+F3+F5 closed (Refs #61)

Verify ensemble (5 Claude reviewers + Codex gpt-5.5 xhigh) on v3.15.0 caught 4 in-scope gaps. v3.15.1 closes all 4 symmetrically across the 3 #61-target insert tools (`insert_paragraph` / `insert_equation` / `insert_image_from_path`). Note: `insert_caption` is a 4th insert tool with a partially-overlapping anchor set (shares `after_image_id` / `after_text` / `before_text` / `paragraph_index` with the unified set, adds `after_table_index` + `position`, lacks `into_table_cell`); it is intentionally outside this unification scope.

#### F1 (P1) — `after_image_id` anchor wired into 3 tools

`InsertLocation.afterImageId(String)` existed in lib since #44 but only `insert_caption` exposed it as an MCP-layer parameter. v3.15.0 inherited that gap. v3.15.1 wires it into:

- `insert_paragraph` — schema + handler dispatch (display path is N/A for paragraph)
- `insert_equation` — display mode only (inline rejects, see F2)
- `insert_image_from_path` — schema + handler dispatch

```jsonc
// Pre-fix v3.15.0:
{ "tool": "insert_paragraph", "args": { "doc_id": "d", "text": "...", "after_image_id": "rId5" } }
// → Silent fallthrough — paragraph appended at end (after_image_id arg dropped)

// Post-fix v3.15.1:
{ "tool": "insert_paragraph", "args": { "doc_id": "d", "text": "...", "after_image_id": "rId5" } }
// → "Inserted paragraph after image 'rId5'"
```

Anchor priority unified across all 3 #61-target tools:
```
into_table_cell > after_image_id > after_text > before_text > index > append
```

#### F2 (P1) — `into_table_cell` wired into `insert_equation`

Display-mode equation is structurally a new paragraph (handler line 8708 `let eqPara = Paragraph(runs: [eqRun])`), so cell placement is well-defined. ≤10 LOC + 1 test.

```jsonc
{ "tool": "insert_equation", "args": { "doc_id": "d", "latex": "\\frac{a}{b}", "display_mode": true, "into_table_cell": { "table_index": 0, "row": 0, "col": 0 } } }
// → "Inserted equation (display mode: true, into table[0] cell (row: 0, col: 0))"
```

Inline mode (`display_mode=false`) rejects with structured error — anchor semantics ambiguous when appending OMML run into existing paragraph; use `paragraph_index` for inline placement.

#### F3 (P2) — equation success message includes anchor info

Closes the same v3.14.4 LOOKUP over-claim pattern. Pre-fix v3.15.0 returned `"Inserted equation (display mode: true)"` regardless of which anchor path ran — caller couldn't distinguish anchor hit vs append fallthrough. Now mirrors `insert_paragraph`:

```
"Inserted equation (display mode: true, after text 'EQ_HERE' (instance 1))"
"Inserted equation (display mode: true, into table[0] cell (row: 0, col: 0))"
"Inserted equation (display mode: true, after image 'rId5')"
"Inserted equation (display mode: true, before text 'X' (instance 2))"
"Inserted equation (display mode: true, at index 17)"
```

This avoids the v3.14.4 翻車 pattern where CHANGELOG claimed observable behavior that wasn't verifiable from the response.

#### F5 (P2) — malformed `into_table_cell` partial dict returns structured error

Pre-fix in all 3 #61-target insert tools (`insert_paragraph` / `insert_equation` / `insert_image_from_path`): passing `into_table_cell: { "table_index": 0 }` (missing `row` + `col`) silently fell through to next anchor or append, leading to wrong-position insertion that the caller couldn't detect. Post-fix:

```jsonc
{ "tool": "insert_paragraph", "args": { "doc_id": "d", "text": "...", "into_table_cell": { "table_index": 0 } } }
// → "Error: into_table_cell requires all three fields (table_index, row, col); got partial dict"
```

Same fix in `insert_paragraph` + `insert_equation` + `insert_image_from_path` (cross-cutting consistency).

#### Inline equation reject expanded

Inline mode now rejects **all** anchor params (after_text / before_text / after_image_id / into_table_cell), not just the 2 in v3.15.0. Mirror error message updated.

#### Tests

`Tests/CheWordMCPTests/Issue61V315PointReleaseTests.swift` (9 sub-tests):
- F1: `testInsertParagraphAfterImageIdResolvesAnchor`, `testInsertParagraphAfterImageIdNotFoundReturnsError`
- F1+F2: `testInsertEquationAfterImageIdDisplayModeResolvesAnchor`, `testInsertEquationIntoTableCellDisplayMode`, `testInsertEquationIntoTableCellRejectedInInlineMode`
- F1: `testInsertImageFromPathAfterImageIdResolvesAnchor`
- F3: `testInsertEquationMessageIncludesAfterTextAnchor`
- F5: `testInsertParagraphMalformedIntoTableCellReportsError`, `testInsertImageFromPathMalformedIntoTableCellReportsError`

#### Test suite

- 185 → 194 tests / 0 fail / 9 pre-existing skips

#### No ooxml-swift dep bump

Still on v0.20.5 — all needed lib APIs (`InsertLocation.afterImageId`, `.intoTableCell`) existed since #44.

#### Backward compatibility

All schema additions optional. Existing v3.15.0 callers unchanged. Only behavior change: malformed `into_table_cell` partial dict (new structured error) and richer equation success message (suffix added; substring `"Inserted equation"` still present).

#### Follow-up issues opened

- F4 (P2): Inline equation should support more general design (e.g. `into_paragraph_with_text`)
- F6 (P2): Text anchor doesn't traverse table-cell paragraphs / block-level SDT
- F7 (P3): `getParagraphs().count - 1` mis-reports index when doc has tables (pre-existing)
- F8 (P3): Error message lacks tool-prefix — `"Error: text 'X' not found"` shared across 5 callers
- F9 (P3): Multiple anchor params silently picks priority winner (cross-cutting DX trap)
- F10 (P3): `text_instance ≤ 0` returns opaque `textNotFound` instead of normalized

---

## [3.15.0] - 2026-04-28

### Added — `insert_paragraph` / `insert_equation` accept anchor parameters (Refs #61)

Closes the MCP-side wire-up gap where `insert_paragraph` and `insert_equation` accepted only `index` / `paragraph_index`, while `insert_image_from_path` already supported the rich anchor set (`after_text` / `before_text` / `text_instance` / `into_table_cell`). Pre-fix the anchor JSON arguments were silently dropped — handler dispatch ignored them, falls through to legacy index path or appends at end. Lib API `Document.insertParagraph(_: at: InsertLocation)` has supported all six anchor cases since #44; this release closes the MCP-layer plumbing.

#### What this fixes for MCP users

```jsonc
// Pre-fix (silent fallthrough — anchor dropped, paragraph appended at end):
{ "tool": "insert_paragraph", "args": { "doc_id": "d", "text": "...", "after_text": "abstract" } }
// → "Inserted paragraph at index 569" (NOT after the abstract anchor)

// Post-fix v3.15.0:
{ "tool": "insert_paragraph", "args": { "doc_id": "d", "text": "...", "after_text": "abstract" } }
// → "Inserted paragraph after text 'abstract' (instance 1)"

// Same anchor set now also works for display-mode equations:
{ "tool": "insert_equation", "args": { "doc_id": "d", "latex": "a^2+b^2=c^2", "display_mode": true, "after_text": "Equation 4-1:" } }
// → "Inserted equation (display mode: true)" — equation lands in correct position
```

#### Anchor priority (mirrors `insert_image_from_path`)

1. `into_table_cell` (insert_paragraph only)
2. `after_text` (with `text_instance`)
3. `before_text` (with `text_instance`)
4. `index` / `paragraph_index`
5. append at end

#### Inline equation rejects anchors (scope guard)

`insert_equation` with `display_mode=false` (inline) **rejects** `after_text` / `before_text` with structured error — semantics ambiguous between "append OMML run into the existing para containing this text" vs "insert a new para before/after the target para". Inline placement still uses `paragraph_index`. Display-mode equations build a new paragraph, so anchor semantics are unambiguous.

#### Errors

`textNotFound` / `tableIndexOutOfRange` / `tableCellOutOfRange` now return structured error messages instead of silent fallthrough — AI callers can surface the failure instead of getting a misleading "success" with paragraph at the wrong position.

#### Implementation

- `Sources/CheWordMCP/Server.swift` — `insert_paragraph` schema (line 720) gains `into_table_cell` / `after_text` / `before_text` / `text_instance`; handler `insertParagraph(args:)` (line 6550) wires anchor priority dispatch to `Document.insertParagraph(_: at: InsertLocation)`. `insert_equation` schema (line 2436) gains `after_text` / `before_text` / `text_instance`; handler `insertEquation(args:)` (line 8591) accepts anchors only in display mode.
- No `ooxml-swift` dep bump — v0.20.5 has all needed lib APIs from #44.

#### Tests

- `Tests/CheWordMCPTests/Issue61InsertParagraphAnchorsSmokeTests.swift` — 5 sub-tests:
  - `testInsertParagraphAfterTextResolvesAnchor` — verifies INSERTED_AFTER lands between anchor and tail
  - `testInsertParagraphBeforeTextResolvesAnchor` — verifies INSERTED_BEFORE lands before anchor
  - `testInsertParagraphTextInstanceDisambiguates` — `text_instance: 2` targets the second of two duplicate anchors
  - `testInsertParagraphIntoTableCellAppendsToCell` — paragraph appends inside the specified cell
  - `testInsertParagraphAfterTextNotFoundReturnsError` — missing anchor reports `textNotFound`
- `Tests/CheWordMCPTests/Issue61InsertEquationAnchorsSmokeTests.swift` — 4 sub-tests:
  - `testInsertEquationAfterTextDisplayModeResolvesAnchor`
  - `testInsertEquationBeforeTextDisplayModeResolvesAnchor`
  - `testInsertEquationAnchorRejectedInInlineMode`
  - `testInsertEquationMissingAnchorReportsTextNotFound`

#### Test suite

- 176 → 185 tests / 0 fail / 9 skipped (pre-existing skips, unrelated to #61)

#### Backward compatibility

All anchor parameters are optional. Existing callers using `index` / `paragraph_index` continue to work unchanged. No schema removal, no behavior change for non-anchor calls.

#### Real-world impact

Closes the inconsistency that forced thesis-rescue / template-population workflows to fall back to "insert at end + manual cut/paste in Word UI" or binary-search guessing on `paragraph_index`. AI callers can now reliably target anchor points by surrounding context across the 3 #61-target insert tools (`insert_paragraph` / `insert_equation` / `insert_image_from_path`); `insert_caption` retains a partially-overlapping anchor set (shares `after_image_id` / `after_text` / `before_text` / `paragraph_index`, adds `after_table_index` + `position`, lacks `into_table_cell`).

---

## [3.14.5] - 2026-04-28

### Fixed — `findBodyChildContainingText` covers all editable surfaces (Refs #63 verify F1)

Bumps `ooxml-swift` v0.20.4 → v0.20.5. Closes the v3.14.4 CHANGELOG over-claim about `insert_image_from_path before_text/after_text` coverage.

#### What this fixes for MCP users

v3.14.4's CHANGELOG explicitly listed `insert_image_from_path(after_text: "[tab:foo]")` against an inline-SDT-wrapped anchor as fixed. Verify caught that the **REPLACE** path (`replace_text`) was fixed but the **LOOKUP** path (`findBodyChildContainingText`, used by `InsertLocation.afterText` / `.beforeText` resolution) was NOT — it only inspected `para.runs`, ignoring `paragraph.contentControls` / `hyperlinks` / `fieldSimples` / `alternateContents`.

So `insert_image_from_path` / `insert_paragraph` / `insert_caption` `before_text`/`after_text` against an SDT-wrapped anchor still threw `textNotFound` post-v3.14.4.

Post-fix v3.14.5: lookup mirrors REPLACE surface coverage. All inline wrappers (fldSimple / hyperlink / alternateContents / inlineSDT) work for both REPLACE and LOOKUP paths.

#### Implementation

ooxml-swift v0.20.5 adds:
1. `TextReplacementEngine.flatTextOfContentXML(_:)` — read-only XML walker mirroring `replaceInContentXML` flattening rules (skips `<w:delText>` / `<w:instrText>` / nested `<w:sdt>` subtrees), returns joined display text.
2. `Paragraph.flattenedDisplayText()` extension — concatenates display text across runs + hyperlinks + fieldSimples + alternateContents + contentControls (recursive into nested SDT children).
3. `findBodyChildContainingText` now uses `flattenedDisplayText()` instead of `para.runs.map { $0.text }.joined()`.

#### Test coverage

| Suite | Tests | Status |
|---|---|---|
| `OOXMLSwiftPackageTests` | 693 → **696** | pass / 0 fail / 1 skip |
| `CheWordMCPPackageTests` | 174 → **176** | pass / 0 fail / 9 skip |

New regression tests:
- `Issue63InsertAnchorInlineSDTTests` (lib): 3 wrappers × `afterText`/`beforeText`/`insertImage` resolution
- `Issue63InsertAnchorInlineSDTSmokeTests` (MCP): 2 smoke tests pinning the lib-layer fix

#### Backward compatibility

Surgical fix — adds new code paths only:
- `findBodyChildContainingText` now finds MORE anchors (a strict superset of pre-fix behavior)
- Existing call sites that anchor on plain `para.runs` text still work identically
- New helpers (`flatTextOfContentXML`, `flattenedDisplayText`) are additive

---

## [3.14.4] - 2026-04-27

### Fixed — `replace_text` reaches text inside inline `<w:sdt>` content controls (closes #63)

Bumps `ooxml-swift` v0.20.3 → v0.20.4. Closes GitHub issue #63 (`replace_text` / `replace_text_batch` / `before_text` / `after_text` silently 0-matched on text wrapped in inline SDT content controls).

**No che-word-mcp source changes** — fix architecture lives in `ooxml-swift`. See [PsychQuant/ooxml-swift v0.20.4 release notes](https://github.com/PsychQuant/ooxml-swift/releases/tag/v0.20.4) for full details.

#### What this fixes for MCP users

Pre-fix v3.14.3 `Document.replaceInParagraphSurfaces` covered `paragraph.runs` / `hyperlinks` / `fieldSimples` / `alternateContents` but **not** `paragraph.contentControls`. Text wrapped in inline `<w:sdt>` (common in docx output from external converters: pandoc / Quarto / LaTeX→docx wrap cross-ref placeholders `[tab:foo]` / `[fig:bar]` / `[Smith 2020]` in inline SDTs by convention) was silently 0-matched.

User-visible symptoms (issue body `Repro` table):
- `replace_text(find: "[tab:foo]")` returned `"Replaced 0 occurrence(s)"` even though the text was visually present in the document
- `insert_image_from_path(after_text: "[tab:foo]")` raised "text '[tab:foo]' not found"
- Bracket-free needle (`tab:foo`) also failed — confirming the bug was the SDT wrapper, not bracket characters
- Workaround required anchoring on bracketless prose suffix (less stable across docx revisions)

Post-fix v3.14.4: all 4 inline wrappers (`<w:fldChar>` paired field / `<w:fldSimple>` REF / `<w:hyperlink>` / **`<w:sdt>` inline SDT**) yield 1 match for the same payload. Differential test in [Issue63InlineSDTReplaceTests.swift](https://github.com/PsychQuant/ooxml-swift/blob/v0.20.4/Tests/OOXMLSwiftTests/Issue63InlineSDTReplaceTests.swift) covers all 4 wrappers × 4 needles + nested SDT recursion + round-trip wrapper preservation.

#### Root-cause clarification (issue title was misleading)

Issue title called out "literal `[ ]` brackets". The brackets are **coincidence** — external converters happen to wrap bracketed cross-refs in inline SDTs. The actual trigger is the SDT wrapping itself; bracket-free text inside inline SDTs failed too. Fix architecture targets the wrapper coverage gap, not bracket-as-regex-char escaping.

#### Implementation

`ooxml-swift` adds:
1. `TextReplacementEngine.replaceInContentXML` — XML DOM walker that parses `ContentControl.content` (raw inline-XML fragment), flattens `<w:t>` descendants in document order with offset map (mirroring `flattenRuns`), runs the same literal/regex find logic, splices replacements back into `<w:t>` string content.
2. `Document.replaceInContentControl` — recursive helper covering `cc.content` + `cc.children` (nested SDT).
3. Wired into `Document.replaceInParagraphSurfaces` after the `alternateContents` loop.

Skipped during the walk (correct by design):
- `<w:delText>` (TC deletion text — not displayed)
- `<w:instrText>` (field instruction code — not display)
- nested `<w:sdt>` subtrees (typed `cc.children`, handled by outer recursion to avoid double-replacement)

Round-trip discipline: only `<w:t>` element string content is mutated; `xml:space="preserve"` and other attributes survive verbatim because attribute sets are never touched.

#### Test coverage

| Suite | Tests | Status |
|---|---|---|
| `OOXMLSwiftPackageTests` | 690 → **693** | pass / 0 fail / 1 skip |
| `CheWordMCPPackageTests` | 172 → **174** | pass / 0 fail / 9 skip |

#### Backward compatibility

Surgical fix — adds new code paths only. No existing behavior changed:
- `paragraph.runs` / `hyperlinks` / `fieldSimples` / `alternateContents` replacement paths untouched.
- `ContentControl` model unchanged (`content: String` storage preserved). Future SDD-warranted refactor toward typed inner runs tracked separately.

#### Out of scope (separate follow-ups)

- `ContentControl` model upgrade from `content: String` (raw XML) to typed `[Run]` / mixed-element list. SDD-warranted refactor; current surgical fix maintains model invariant.
- `paragraph.smartTags` / `bidiOverrides` / `customXmlBlocks` / `unrecognizedChildren` (raw-carriers) — designed to be byte-equivalent passthrough, must not be modified by `replace_text`.

---

## [3.14.3] - 2026-04-27

### Added — Sub-stack E of paragraph-level content-equality (closes #66)

Bumps `ooxml-swift` v0.20.2 → v0.20.3. Closes GitHub issue #66 (paragraph `w14:paraId` / `w14:textId` attributes silently dropped at parse time).

**No che-word-mcp source changes** — fix architecture lives entirely in `ooxml-swift`. See [PsychQuant/ooxml-swift v0.20.3 release notes](https://github.com/PsychQuant/ooxml-swift/releases/tag/v0.20.3) for full details.

#### What this fixes for MCP users

Pre-fix v3.14.2 silently dropped Word's revision-tracking GUIDs (`w14:paraId` / `w14:textId`) on `<w:p>` opening tags. User-visible symptoms:
- Paragraph identity lost across collaborative-edit sessions
- Comment threading anchors broken on round-trip (Word uses w14:paraId to bind comments to specific paragraphs)
- Document revision history annotations not preserved

Post-fix v3.14.3:
- `w14:` retention: 10.55% → **93.98%**
- `document.xml` size loss: 10.95% → **8.02%**

#### Combined sub-stack D + E impact (since v3.14.1)

| Preservation class | v3.14.1 | v3.14.3 | Total |
|---|---|---|---|
| `<w:lang>` retention | 50% | 98.89% | (D) +48.89 pp |
| `w14:` retention | 5% | 93.98% | (E) +88.98 pp |
| `document.xml` size loss | 16.66% | 8.02% | (D+E) -8.64 pp |

#### Architecture

Sub-stack E of the `che-word-mcp-paragraph-level-content-equality` Spectra change. Plain attribute passthrough — two new optional `String?` fields on `Paragraph`. Word's GUIDs are 8-character hex tokens (NOT RFC 4122 UUIDs), so opaque-string round-trip is correct.

The cross-cutting matrix-pin `testDocumentContentEqualityInvariant` is now LOAD-BEARING across **5 preservation classes** (rFonts / noProof / lang / kern / w14:) spanning run-level + paragraph-level + paragraph-mark scope. Any future regression in any class fails CI.

#### Defensive design (R2 review fixes)

- **XML attribute escaping**: `openingPTag()` helper routes attribute values through `escapeXMLAttribute` even though Word's GUIDs are constrained to hex.
- **Empty-string-as-absent guard**: `parseParagraph` rejects `w14:paraId=""` source attrs (schema-invalid per ECMA-376 ST_LongHexNumber; Word's repair path silently drops them).

#### Backward compatibility

`Paragraph.w14ParaId` and `Paragraph.w14TextId` are optional (default nil). All pre-existing API consumers continue to work unchanged.

## [3.14.2] - 2026-04-27

### Added — Sub-stack D of paragraph-level content-equality (closes #65)

Bumps `ooxml-swift` v0.20.1 → v0.20.2. Closes GitHub issue #65 (paragraph-mark `<w:pPr><w:rPr>` silently dropped at parse time).

**No che-word-mcp source changes** — fix architecture lives entirely in `ooxml-swift`. See [PsychQuant/ooxml-swift v0.20.2 release notes](https://github.com/PsychQuant/ooxml-swift/releases/tag/v0.20.2) for full details.

#### What this fixes for MCP users

Pre-fix v3.14.1 silently dropped paragraph-mark formatting — the `<w:rPr>` nested inside `<w:pPr>` that controls the pilcrow ¶ glyph appearance (font, size, color, language tag, kerning). User-visible symptoms: traditional Chinese pilcrow font (DFKai-SB) being replaced with Latin font on round-trip; document language tags being silently lost; w14:* paragraph-mark effects (textOutline, glow, etc.) disappearing.

Post-fix v3.14.2:
- `<w:lang>` retention: 50% → **98.89%**
- `<w:rFonts>` retention: 88% → 98.77%
- `<w:noProof>` retention: 92% → 100%
- `<w:kern>` retention: 84% → 99.93%
- `document.xml` size loss: 16.66% → **10.95%**

#### Architecture

Sub-stack D of the `che-word-mcp-paragraph-level-content-equality` Spectra change. Reuses `parseRunProperties` verbatim — `<w:rPr>` schema inside `<w:pPr>` is identical to run-level CT_RPr per ECMA-376 §17.3.1.27, so all of sub-stack C's typed extraction (4-axis rFonts, noProof, kern, 3-axis lang) and `rawChildren` passthrough (w14:* effects) come for free.

The cross-cutting matrix-pin `testDocumentContentEqualityInvariant` ratchets in lockstep: `<w:lang>` floor 0.45→0.95; `<w:rFonts>`/`<w:noProof>`/`<w:kern>` 0.95; sizeLossRatio ceiling 0.175→0.12. Any future regression in run-level OR paragraph-level `RunProperties` handling now fails the matrix-pin.

#### Backward compatibility

`ParagraphProperties.markRunProperties` is optional (default nil). All pre-existing API consumers continue to work — paragraphs without source `<w:pPr><w:rPr>` emit no synthetic empty wrappers.

#### Coming next

Sub-stack E (#66 w14:paraId/textId on `<w:p>`) ships as v3.14.3 — completes the path to `< 5%` round-trip loss and enables the strong demo claim「edit 一個字 → document.xml shrinks <1%」.

## [3.14.1] - 2026-04-27

### Fixed — Sub-stack C-CONT of #58/#59/#60 (closes triple-confirmed P0 from sub-stack C verify)

Bumps `ooxml-swift` v0.20.0 → v0.20.1. Closes triple-confirmed P0 from R2 + R5 + Codex independent verify of v0.20.0.

**No che-word-mcp source changes** — fix architecture lives entirely in `ooxml-swift`. See [PsychQuant/ooxml-swift v0.20.1 release notes](https://github.com/PsychQuant/ooxml-swift/releases/tag/v0.20.1) for full details.

#### What MCP users see (vs v3.14.0)

The following common Word-document elements were silently lost on round-trip in v3.14.0; v3.14.1 restores them:

- **`<w:spacing>`** (character spacing — typeset documents)
- **`<w:caps>` / `<w:smallCaps>`** (small-caps formatting)
- **`<w:position>`** (vertical position offset)
- **`<w:shd>`** (run-level shading / highlighting)
- **`<w:bdr>`** (run-level border)
- **`<w:em>`** (CJK emphasis marks)
- **`<w:effect>`** (text effects: shimmer, blink, etc.)
- **`<w:vanish>` / `<w:specVanish>` / `<w:webHidden>`** (visibility flags)
- **`<w:outline>` / `<w:shadow>` / `<w:emboss>` / `<w:imprint>`** (legacy text effects)
- **`<w:bCs>` / `<w:iCs>` / `<w:dstrike>`** (complex-script + double-strikethrough)

Any tool that opens + saves a document with these elements (e.g., `delete_text`, `replace_text`, `format_text`, `insert_paragraph`) no longer silently strips them.

#### Bug

`parseRunProperties` had a `recognizedRprChildren` Set that listed 16+ rPr child kinds as "recognized" — meaning rawChildren capture would skip them. But parseRunProperties had NO typed extraction for those kinds → they neither become typed fields NOR get captured into rawChildren → silent drop.

#### Fix

Trimmed Set to ONLY actually-typed-extracted-or-emitted kinds. Everything else falls through to rawChildren and round-trips byte-equivalent.

#### Round-trip size impact

Thesis fixture `document.xml`:
- Pre-fix v3.13.x: 32% loss
- v3.14.0: 17.75% loss (+14.25 pp from typed-rPr extraction)
- **v3.14.1: 16.66% loss** (additional 1.09 pp from rawChildren capture of previously-silent-dropped elements)

Matrix-pin floor tightened from 0.19 → 0.175.

#### Methodology lesson (6th refinement)

R2 found this as P2 ('inline comment is false; pre-existing parity gap'). R5 escalated to P0 by recognizing the affected elements are common. Codex confirmed the P0 + identified 3 additional P1 (deferred to follow-up SDD).

**P2 from one reviewer can become P0 when another applies real-world impact lens.** Severity = bug presence + blast radius. Use 6-AI verify diversity to surface maximum blast radius for each bug class.

### Deferred (Codex P1, separate follow-up SDD)

- Schema-order rawChildren tail-append (CT_RPr order constraints)
- `characterSpacing` / `textEffect` parser-side extraction gap
- Static `recognizedRprChildren` Set allocation (perf optimization)
- Ratio-floor maintenance burden

### Spectra change

Ships sub-stack C-CONT of `che-word-mcp-issue-58-59-60-document-content-preservation`. After this hotfix, sub-stack C's #60 closure is verified clean for the ACTUAL field-loss audit scope.

## [3.14.0] - 2026-04-27

### Added — Sub-stack C of #58/#59/#60 (closes #60 RunProperties field-loss audit)

Bumps `ooxml-swift` v0.19.13 → v0.20.0. Closes [#60](https://github.com/PsychQuant/che-word-mcp/issues/60). **Architectural completion of the "if not typed, preserve as raw" principle** that started in sub-stack A (#58 BodyChild) and continued in sub-stack B (#59 WhitespaceOverlay).

**No che-word-mcp source changes** — fix architecture lives entirely in `ooxml-swift`. See [PsychQuant/ooxml-swift v0.20.0 release notes](https://github.com/PsychQuant/ooxml-swift/releases/tag/v0.20.0) for the architectural deep-dive.

#### What MCP users see (vs v3.13.13)

- **`<w:rFonts>` 4-axis preservation** — Chinese theses, multi-script documents, and any file using different fonts for Latin / High-ANSI / East-Asian / Complex Script axes round-trip correctly. Pre-fix `eastAsia="DFKai-SB"` (traditional Chinese) was silently replaced with the `ascii` value on save.
- **`<w:noProof/>`** (suppress spell/grammar check) preserved through round-trip — any tool that opens + saves a document with no-proof runs no longer enables Word's red squigglies on previously-suppressed text.
- **`<w:kern w:val="N"/>`** (font kerning threshold) preserved — Office.js-emitted documents with kerning settings round-trip correctly.
- **`<w:lang>` 3-axis preservation** (Latin val + East-Asian eastAsia + Bidi bidi) — multi-script language tags survive intact.
- **`<w14:*>` namespace effects** preserved as raw rPr children — `<w14:textOutline>`, `<w14:textFill>`, `<w14:glow>`, `<w14:shadow>`, `<w14:reflection>`, `<w14:scene3d>`, `<w14:props3d>`, `<w14:ligatures>`, etc. Pre-fix silently dropped on read.

#### Architectural recap (from ooxml-swift v0.20.0)

- New typed structs `RFontsProperties` (4 axes + hint) and `LanguageProperties` (3 axes)
- New `RunProperties.rFonts`, `noProof`, `kern`, `lang`, `rawChildren` fields
- `parseRunProperties` extended with extraction + recognized-rPr-children Set covering 30+ typed kinds
- `RunProperties.toXML()` emits new typed fields then replays rawChildren in source-document order
- Backward compat: legacy `fontName` retained; mirrors `rFonts.ascii`

#### Matrix-pin extension (LOAD-BEARING)

`testDocumentContentEqualityInvariant` gains preservation-class-3 ratio-floor assertions. Any regression in run-level rPr preservation trips the matrix-pin before the bug class can ship.

#### Round-trip size impact

Thesis fixture `document.xml`:
- Pre-fix (v3.13.x): 32% loss
- Post-sub-stack-C: 17.75% loss (improvement of 14.25 percentage points)
- Future paragraph-mark rPr fix (separate follow-up SDD) should drop loss to < 5%

#### Out-of-scope (revealed by matrix-pin, separate follow-up)

The matrix-pin uncovered two pre-existing bugs NOT in #60 scope:

1. `ParagraphProperties` lacks `markRunProperties` field — `<w:pPr><w:rPr>` paragraph-mark formatting silently dropped at parse time
2. `Paragraph` parser doesn't preserve `w14:paraId`/`w14:textId` attributes on `<w:p>`

Both tracked as follow-up SDD.

### Spectra change

This release closes the cross-cutting `che-word-mcp-issue-58-59-60-document-content-preservation` Spectra change (sub-stacks A/B/B-CONT/B-CONT-2/B-CONT-2-CONT/C complete) and the cross-cutting matrix-pin (`testDocumentContentEqualityInvariant`).

## [3.13.13] - 2026-04-27

### CRITICAL HOTFIX — Sub-stack B-CONT-2-CONT of #58/#59/#60 (reverts v3.13.12 TIER-0 over-fix)

Bumps `ooxml-swift` v0.19.12 → v0.19.13. **CRITICAL**: v3.13.12 silently stripped `<w:del>` deleted-text content on every round-trip. Triple-confirmed by R2 + R5 + Codex 6-AI verify on v0.19.12.

**Affected version: v3.13.12** (DO NOT USE in production for any document with tracked-change deletions).

**No che-word-mcp source changes** — fix architecture lives entirely in `ooxml-swift`. See [PsychQuant/ooxml-swift v0.19.13 release notes](https://github.com/PsychQuant/ooxml-swift/releases/tag/v0.19.13) for full deep-dive.

#### What MCP users see (vs v3.13.12 — MANDATORY UPGRADE)

- **`<w:del>` round-trip preserves deleted text content**. Pre-v3.13.13 (i.e., v3.13.12), opening any `.docx` with tracked deletions, mutating any part to mark it dirty, then saving → all `<w:delText>` content silently destroyed (only the opening/closing tags remained, with empty content). `accept_revision` would commit nothing; `reject_revision` would have nothing to restore.
- **Affected workflows**: any tool sequence that touches a tracked-change document — `delete_text` / `replace_text` / `format_text` / `insert_paragraph` etc. on documents with prior `<w:del>` revisions.

#### Bug analysis

v3.13.12 added `"delText"` to `parseRun`'s `recognizedRunChildren` Set to fix the v3.13.11 counter-desync (R5 P0-1). Mechanically correct for the desync, but broke a load-bearing invariant in the writer:

- Pre-v3.13.12: parseRun captured `<w:delText>` into `Run.rawElements`. Writer's gate at `Paragraph.swift:787` skipped synthetic emission because rawElements covered it; rawElements loop emitted `<w:delText>content</w:delText>` verbatim.
- v3.13.12 (BROKEN): rawElements stayed empty; writer's gate fired synthetic emission with run.text="" → empty `<w:delText></w:delText>` written.

The §2.33 test only counted opening tags (1=1 pre/post), and §2.34 only checked in-memory `Revision.originalText` (populated independently). Both passed falsely.

#### Fix

Reverted `"delText"` from `recognizedRunChildren`. Added `includeDelText: Bool = true` parameter to `advanceWhitespaceCounter(forSkippedXML:)`. parseRun's rawElements loop passes `includeDelText: false` when capturing `<w:delText>` — explicit `<w:del>` loop already advances delTextCounter, preventing double-advance without removing delText from rawElements (which writer needs).

New test `testDelTextContentPreservedThroughRoundTrip` is a **payload-parity** test (asserts actual content survives) — distinguishes from the prior counter-parity tests that missed this regression.

#### Methodology lesson (5th refinement, Codex insight)

Operationalize 6-AI verify cycle by splitting predictions into **counter-parity** tests (opening-tag counts) AND **payload-parity** tests (actual content). Future predictions about duplicate/loss scenarios should require a payload-parity test before the prediction is accepted as falsified.

### Spectra change

Ships sub-stack B-CONT-2-CONT of `che-word-mcp-issue-58-59-60-document-content-preservation`. Sub-stack C (#60 RunProperties audit) ships next as v3.14.0.

## [3.13.12] - 2026-04-27 — DO NOT USE (silently strips <w:del> content)

### Fixed — Sub-stack B-CONT-2 of #58/#59/#60 (closes 6 P0 + 3 P1 from sub-stack B-CONT 6-AI verify)

Bumps `ooxml-swift` v0.19.11 → v0.19.12. Closes 6 P0 + 3 P1 from the [sub-stack B-CONT 6-AI verify](https://github.com/PsychQuant/che-word-mcp/issues/59#issuecomment-4324076688) — 4-reviewer convergence.

**No che-word-mcp source changes** — fix architecture lives entirely in `ooxml-swift`. See [PsychQuant/ooxml-swift v0.19.12 release notes](https://github.com/PsychQuant/ooxml-swift/releases/tag/v0.19.12) for the architectural deep-dive.

#### What MCP users see (vs v3.13.11)

- **Tracked-deletion of whitespace across multiple `<w:del>` blocks** now round-trips correctly. Pre-fix v3.13.11 silently lost the second (and subsequent) deletion's whitespace because `parseRun`'s `recognizedRunChildren` Set didn't include `"delText"` — `delTextCounter` advanced twice per delText (once via rawElements path's `countDelTextElements`, once via explicit loop), so the second deletion's overlay-recovery query landed at the wrong index.
- **Whitespace recovery now works in documents containing**: unrecognized container body-level elements (vendor extensions in headers/footers), hyperlinks with nested `<w:fldSimple>` / `<mc:AlternateContent>` / `<w:smartTag>`, fieldSimple containing non-`<w:r>` children, smart-tagged paragraphs, customXml wrappers, bidirectional override blocks. Pre-fix all 5+ sites missed `advanceWhitespaceCounter` and silently corrupted post-element whitespace.

#### Important note on R5 finding

R5 Devil's Advocate predicted a CRITICAL data corruption bug in v3.13.11 (`<w:delText>` duplicate emission via writer-side amplification of the parseRun rawElements path). **This prediction was FALSIFIED** by code trace + targeted regression test (§2.33): `Paragraph.swift:787` gate (`!run.text.isEmpty || (run.rawElements?.isEmpty ?? true)`) skips explicit `<w:delText>` emission when rawElements covers it. v3.13.11 was NOT corrupting `<w:del>` round-trips — the fix is for the underlying counter desync (R5 P0-1) which DID exist. v3.13.12 retains the test as a regression guard for the writer-gate invariant.

**Methodology refinement**: adversarial reviewers can correctly identify a bug class but mis-grade severity by missing protective gates elsewhere in the codebase. Verify-cycle response should TEST predictions, not assume them — this saved us from a misframed BLOCK and added a regression guard for the writer-gate behavior.

#### Architectural recap (sub-stack B-CONT-2 changes)

- TIER-0 (R5 P0-1): added `"delText"` to `recognizedRunChildren` Set at `DocxReader.swift:1847`. parseRun's rawElements loop now skips delText (already captured by explicit `<w:del>` loop). Eliminates double-count.
- TIER-1 (R2 + Codex 5 P0): `Self.advanceWhitespaceCounter(forSkippedXML: ...)` call added at parseContainerChildBodyChildren raw fallback, parseHyperlink rawChildren else-branch, parseFieldSimple non-`<w:r>` else-branch (also documents independent content-loss bug for non-run fldSimple children), parseParagraph smartTag/customXml/dir/bdo (4 raw-carrier blocks).

### Deferred (B-CONT-2 TIER-2)

- §2.43 central raw-capture helper refactor — high-value but adds touchpoint risk; future raw-capture additions still require manual `advanceWhitespaceCounter` call. Tracked.
- §2.44 `buildAllPartsWhitespaceFixture` upgrade with real-world content classes — sterile fixture remains; per-test class coverage suffices for now. Long-term consolidation tracked.
- §2.45/§2.46 container-part + delText parity in matrix-pin — sub-stack C scope addition.
- B-CONT MAY-tier carries forward (concurrency, single-quoted attr, perf gate).

### Spectra change

Ships sub-stack B-CONT-2 of `che-word-mcp-issue-58-59-60-document-content-preservation`. Sub-stack C (#60 RunProperties audit) ships next as v3.14.0.

## [3.13.11] - 2026-04-27

### Fixed — Sub-stack B-CONT of #58/#59/#60 (closes 4 P0 + 3 P1 from sub-stack B 6-AI verify)

Bumps `ooxml-swift` v0.19.10 → v0.19.11. Closes 4 P0 + 3 P1 from the [sub-stack B 6-AI verify](https://github.com/PsychQuant/che-word-mcp/issues/59#issuecomment-4323956207) — 4-reviewer convergence (R2 Logic + R5 Devil's Advocate + Codex; R1 PASS-WITH-WARNINGS) on a counter-desync class with two root causes.

**No che-word-mcp source changes** — fix architecture lives entirely in `ooxml-swift`. See [PsychQuant/ooxml-swift v0.19.11 release notes](https://github.com/PsychQuant/ooxml-swift/releases/tag/v0.19.11) for the architectural deep-dive.

#### What MCP users see (vs v3.13.10)

- **Whitespace recovery now works in real-world documents** — pre-fix v3.13.10 worked only for documents WITHOUT tables, tabs, mc:AlternateContent, or tracked-change wrappers (i.e., almost no real Word file). v3.13.10's tests passed because matrix-pin fixtures were sterile (bare `<w:r><w:t>` with no surrounding OOXML). v3.13.11's prefix-match boundary fix + raw-capture counter sync correctly handle all document types.
- **`get_paragraph_runs` for tables, tracked-change documents, and Office.js-emitted content** now returns whitespace-only runs intact. Pre-fix returned `""` for whitespace-only `<w:t xml:space="preserve">` whenever the surrounding XML contained any `<w:tab>` / `<w:tbl>` / etc. — silently dropped indentation in dialogue, alignment runs, leading/trailing whitespace.
- **Tracked-deletion of whitespace** (`<w:delText xml:space="preserve">`) now round-trips. Pre-fix `accept_revision` would commit the deletion correctly but `reject_revision` couldn't restore the deleted whitespace bytes.
- **Whitespace-only comments preserved verbatim** — pre-fix `parseComments` trimmed recovered overlay text, destroying whitespace-only comment annotations.
- **Entity-encoded whitespace** (`&#x09;`, `&nbsp;`, etc.) now decoded and recovered correctly — pre-fix scanner ran whitespace check on raw entity bytes which fail `Character.isWhitespace`.

#### Architectural recap

Two root causes triple-confirmed by sub-stack B 6-AI verify:

1. **Prefix-match collision** — `WhitespaceOverlay.swift:54`'s `xml.range(of: "<w:t")` was a prefix match. Also fired on `<w:tab>`, `<w:tbl>`, `<w:tc>`, `<w:tr>`, `<w:tblPr>`, `<w:tcPr>`, `<w:trPr>`, etc. DOM walker is exact-match. Counter desynced immediately in any document with tables or tabs. **Fix**: tag-name boundary check (next char must be `>`, ` `, `\t`, `\n`, `\r`, or `/`).

2. **Skipped raw subtrees** — scanner counted `<w:t>` inside raw-captured wrappers but parseRun never visited them. Affected sites: `parseAlternateContent` `<mc:Choice>` skip; `parseInsRevisionWrapper` non-run-child paths × 4; `parseBodyChildren` `.rawBlockElement` capture; `parseParagraph` unrecognized-child catch-all; `parseRun` `rawElements` capture for nested `<mc:AlternateContent>` etc. **Fix**: parser-side counter advance via new `DocxReader.advanceWhitespaceCounter(forSkippedXML:)` at 7 sites.

Plus 3 SHOULD-tier P1 closures: `<w:delText>` overlay coverage (R5), comments trimming removed (Codex), entity-encoded whitespace decoded (R5).

#### Methodology lesson refined

Sub-stack A taught: matrix-pin needs symmetric assertions baked in from design (across container variants). Sub-stack B taught: matrix-pin baked in from design ≠ matrix-pin fixtures with real content (sterile fixtures hid every P0). Sub-stack B-CONT confirms: real-world OOXML content classes (tables, alternate-content, revision wrappers, entity-encoded chars) must be IN the fixtures.

### Deferred (B-CONT MAY-tier)

- Static state concurrency hazard (R5 + Codex P1) — `currentWhitespaceContext` is unsynchronized process-wide state. Documented; works only because DocxReader is single-threaded by convention. Tracked for follow-up.
- Single-quoted `xml:space='preserve'` (R5 P2) — Word doesn't emit, accepted limitation.
- Performance gate (Codex P2) — no benchmark.

### Spectra change

Ships sub-stack B-CONT of `che-word-mcp-issue-58-59-60-document-content-preservation`. Sub-stack C (#60 RunProperties audit) ships next as v3.14.0.

## [3.13.10] - 2026-04-27

### Fixed — Sub-stack B of #58/#59/#60 (closes #59 whitespace preservation)

Bumps `ooxml-swift` v0.19.9 → v0.19.10. Closes [#59](https://github.com/PsychQuant/che-word-mcp/issues/59) — Foundation `XMLDocument` strips whitespace-only `<w:t xml:space="preserve">[whitespace]</w:t>` text node `stringValue` to `""` regardless of the `xml:space` attribute or `nodePreserveWhitespace` parse option. Structural Foundation/libxml2 limitation, not a configuration bug.

**No che-word-mcp source changes** — fix architecture lives entirely in `ooxml-swift`. See [PsychQuant/ooxml-swift v0.19.10 release notes](https://github.com/PsychQuant/ooxml-swift/releases/tag/v0.19.10) for the architectural deep-dive.

#### What MCP users see (vs v3.13.9)

- **Whitespace-only text now survives `get_paragraph_runs`, `get_text`, `export_markdown`** — pre-fix the run text came back as `""` for any whitespace-only `<w:t xml:space="preserve">` (5+ space indents in dialogue, alignment runs, leading/trailing whitespace). Post-fix the recovered whitespace bytes are returned verbatim.
- **Round-trip preservation** — opening a `.docx`, mutating something, and saving no longer silently strips whitespace runs. Thesis-fixture probe: source has 346 whitespace-only `<w:t>` elements totalling 683 chars; pre-fix Reader recovered 190 (349 chars) — **334 chars silently lost on read alone**. Post-fix: 100% recovery.
- **Coverage extends across all 6 `<w:t>`-bearing parts**: `document.xml`, `header*.xml`, `footer*.xml`, `footnotes.xml`, `endnotes.xml`, `comments.xml`. Each gets its own `WhitespaceParseContext` (overlay + monotonic counter) — applies to every operation that traverses runs in any of those parts.

#### Architectural approach (recap from ooxml-swift v0.19.10)

Pre-parse byte-stream scan via new internal `WhitespaceOverlay`. Records whitespace content keyed by element sequence index in DOM document order. `parseRun` consults the overlay when `t.stringValue.isEmpty`. Same shape as the v0.13.0 `WordDocument.modifiedParts` byte-preservation overlay — contained, surgical, no parser swap.

**Why not switch parsers**: 1-2 weeks of work + new dependency + affects all 10 `XMLDocument(data:)` call sites in DocxReader.swift. Whitespace overlay is contained, surgical, follows existing patterns.

#### Methodology — comprehensive matrix-pin from design

Sub-stack A's 4 sub-cycles (A → A-CONT → A-CONT-2 → A-CONT-3, mirroring R5→R5-CONT-4 for #56) demonstrated that matrix-pins added reactively to verify findings always lag the bug by one round. Sub-stack B's matrix-pin (`testWhitespacePreservedAcrossAllSixPartTypes`) exercises ALL 6 part types in 1 fixture from design — symmetric assertions baked in, not added after the fact. The next-round verify can't surface symmetric-sibling regressions because all 6 are exercised by the same test.

### Spectra change

Ships sub-stack B of `che-word-mcp-issue-58-59-60-document-content-preservation`. Sub-stack C (#60 RunProperties audit) ships next as v3.14.0. Sub-stack A's deferred A-CONT-4 follow-ups (paragraph-level container delete state-inconsistency + body SDT recursion asymmetry + insertBookmark perf) tracked but out of scope for sub-stack B/C.

## [3.13.9] - 2026-04-27

### Fixed — Sub-stack A-CONT-3 mini-cycle of #58 (silent correctness regression + API symmetry)

Bumps `ooxml-swift` v0.19.8 → v0.19.9. Closes 3 P0 from the [sub-stack A-CONT-2 6-AI verify](https://github.com/PsychQuant/che-word-mcp/issues/58#issuecomment-4323715199), **including a critical silent-correctness fix** for v3.13.8.

**No che-word-mcp source changes** — fix architecture lives entirely in `ooxml-swift`. Sub-cycle 4 for #58 (A → A-CONT → A-CONT-2 → A-CONT-3). Same convergence-cycle pattern as R5 → R5-CONT-4 (5 sub-cycles for #56).

#### What MCP users see (vs v3.13.8)

- **`delete_bookmark` for header/footer bookmarks ACTUALLY PERSISTS to disk.** v3.13.8 silently lost the deletion: in-memory model showed bookmark gone, `getBookmarks()` returned no match, but the saved `.docx` still contained the bookmark. Triple-confirmed by R2 + R5 + Codex during A-CONT-2 verify. Critical correctness regression — must-upgrade for any v3.13.8 user calling `delete_bookmark` on container bookmarks.
- **`list_bookmarks` returns paragraph-level bookmarks inside header/footer paragraphs**, not just body-level container markers. Pre-A-CONT-3 only the rarer body-level case was surfaced.
- **`insert_bookmark` rejects names that already exist anywhere** — including in headers, footers, footnotes, endnotes. Pre-A-CONT-3 a TOC anchor in a header survived `insert_bookmark(name: ...)` and produced silent duplicate-name violations.

### Tests

172 tests pass / 9 skipped / 0 failures (against released ooxml-swift v0.19.9).

### Spectra change

Sub-stack A-CONT-3 mini-cycle. Re-numbers planned sub-stack B → v3.13.10 (sub-stack C unchanged at v3.14.0).

## [3.13.8] - 2026-04-27

### Fixed — Sub-stack A-CONT-2 mini-mini-cycle of #58 (API-layer + SDT recursion + matrix-pin fixture)

Bumps `ooxml-swift` v0.19.7 → v0.19.8. Closes 2 P0 + 1 P1 from the [sub-stack A-CONT 6-AI verify](https://github.com/PsychQuant/che-word-mcp/issues/58#issuecomment-4323658377) which returned BLOCK with v3.13.7 shipping a partial fix (parser-side mirror landed but API-layer + SDT recursion gaps remained).

**No che-word-mcp source changes** — fix architecture lives entirely in `ooxml-swift`. Sub-cycle 3 for #58 (A → A-CONT → A-CONT-2). Same convergence-cycle pattern as R5 → R5-CONT-4 (5 sub-cycles for #56).

#### What MCP users see (vs v3.13.7)

- **`list_bookmarks` returns body-level TOC anchors inside headers / footers / footnotes / endnotes** (not just body). v3.13.7 preserved them on disk but only surfaced body-scope ones to MCP.
- **`delete_bookmark` can delete those names successfully**. v3.13.7 threw `notFound` despite `list_bookmarks` returning them — state inconsistency now resolved.
- **Block-level SDTs (Structured Document Tags) inside headers are visible to typed-model walkers** (incl. `nextBookmarkId` calibration on nested bookmark ids). v3.13.7 captured them as `.rawBlockElement` — XML byte-preserved but typed-model invisible.

### Tests

172 tests pass / 9 skipped / 0 failures (against released ooxml-swift v0.19.8).

### Spectra change

Sub-stack A-CONT-2 mini-mini-cycle. Re-numbers planned sub-stack B → v3.13.9 (sub-stack C unchanged at v3.14.0).

## [3.13.7] - 2026-04-27

### Fixed — Sub-stack A-CONT mini-cycle of #58 (parser asymmetry)

Bumps `ooxml-swift` v0.19.6 → v0.19.7. Closes 2 P0 + 1 P1 + 1 P2 from the [sub-stack A 6-AI verify](https://github.com/PsychQuant/che-word-mcp/issues/58#issuecomment-4323205184) which returned BLOCK with the sub-stack A v3.13.6 release shipping a partial fix.

**No che-word-mcp source changes** — fix architecture lives entirely in `ooxml-swift`. Same convergence-cycle pattern as the #56 R5-CONT-4 stack: per-task gate caught the body.xml parser entry point; 6-AI verify caught the symmetric sibling in the container parser entry point that the per-task gate missed.

#### What MCP users see

- **`list_bookmarks` now returns body-level TOC anchors** (e.g., `_Toc<digits>` patterns). Previously: preserved on disk by v3.13.6 but invisible to MCP discovery.
- **Body-level bookmarks in headers / footers / footnotes / endnotes survive body-mutating saves on those parts.** Previously: silently dropped on save (same data-loss class #58 was meant to close, just in a different parser entry point).

### Tests

172 tests pass / 9 skipped / 0 failures (against released ooxml-swift v0.19.7).

### Spectra change

Sub-stack A-CONT mini-cycle. Re-numbers planned sub-stack B → v3.13.8 (sub-stack C unchanged at v3.14.0).

## [3.13.6] - 2026-04-27

### Fixed — Sub-stack A of #58/#59/#60 document-content-preservation

Bumps `ooxml-swift` v0.19.5 → v0.19.6 + `word-to-md-swift` v0.6.0 → v0.6.1. Closes [PsychQuant/che-word-mcp#58](https://github.com/PsychQuant/che-word-mcp/issues/58) — body-level `<w:bookmarkStart>` / `<w:bookmarkEnd>` (e.g., TOC `_Toc<digits>` anchors) now survive body-mutating save. Reproduced on the thesis fixture pre-fix: 1 of 45 bookmarks lost on round-trip.

**No che-word-mcp source changes** — fix architecture lives entirely in `ooxml-swift` (`BodyChild` enum extension under "if not typed, preserve as raw" principle). Three internal switch sites in `Server.swift` got new no-op cases for `.bookmarkMarker` / `.rawBlockElement` to satisfy compiler exhaustiveness.

#### What MCP users see

- `list_bookmarks` now returns the full bookmark count on docs with body-level (multi-paragraph-spanning) bookmarks. Previously TOC anchors going through Word's `_Toc<digits>` pattern were silently lost on save.
- All `replace_text` / `insert_paragraph` / `format_text` / etc. body-mutating tools preserve body-level bookmark structure across the save.

### Tests

172 tests pass / 9 skipped / 0 failures (against released ooxml-swift v0.19.6 + word-to-md-swift v0.6.1).

### Spectra change

This release implements sub-stack A of `che-word-mcp-issue-58-59-60-document-content-preservation`. Sub-stacks B (#59 whitespace overlay) and C (#60 RunProperties audit) ship as v3.13.7 / v3.14.0 in subsequent releases under the same Spectra change.

## [3.13.5] - 2026-04-27

### Fixed — R5 stack-completion (6 P0 + 5 P1 + R5-CONT 7 P0 + 5 P1 + R5-CONT-2 5 P0 + 4 P1 + R5-CONT-3 1 P0 + 4 P1 + R5-CONT-4 1 P0 + 3 P1 from #56 rounds 4-8 verify)

Bumps `ooxml-swift` dependency from `0.19.3` → `0.19.5` (v0.19.4 was held back per verify-gate; see [ooxml-swift v0.19.5 release notes](https://github.com/PsychQuant/ooxml-swift/releases/tag/v0.19.5)). **No che-word-mcp source changes** — the regressions and their fixes all live in ooxml-swift.

The R3 stack landed in `ooxml-swift` v0.19.4 but each subsequent 6-AI verify round caught additional structural-pattern findings (walker asymmetry, sentinel collision, attribute-escape gaps, block-level SDT propagation, container-symmetric `replace_text`, container `<w:tbl>` capture in round 4 → bodyChildren canonical container storage migration in round 5 → paragraphIndex semantics + accept/reject + update/delete mirror invariants in round 6 → `reject_revision` typed-case clearMarker in round 7 → `accept_revision` typed-case clearMarker + matrix-pin asymmetry-guard removal in round 8). v3.13.5 ships the entire stack as a single coordinated bump.

#### R5 round-by-round summary

| Round | Verify ID | Findings | What it fixed for MCP users |
|-------|-----------|----------|------------------------------|
| 4 | R5 stack | 6 P0 + 5 P1 | `accept_revision` / `reject_revision` / `accept_all_revisions` / `reject_all_revisions` now find wrappers in headers/footers/footnotes/endnotes (not body-only); `get_hyperlinks` walks all parts; `replace_text` recurses into container bodyChildren; SDT children in container tables / nested tables / contentControls no longer silently dropped on save |
| 5 | R5-CONT | 7 P0 + 5 P1 | Per-container relationships round-trip (`update_hyperlink` URL sync targets owning part rels, not document-scope); container `toXML()` emits `.contentControl` arm; `getHyperlinks` walks all parts; readers populate typed `Revision` for container-scoped wrappers |
| 6 | R5-CONT-2 | 5 P0 + 4 P1 | `delete_hyperlink` targets owning part rels (mirror of update side); `reject_revision` typed `.insertion` routes by source; container `<w:tbl>` capture preserved through round-trip; per-paragraph counter unifies writer's `paragraphIndex` vs lookup helper's flat-counter semantics |
| 7 | R5-CONT-3 | 1 P0 + 4 P1 | `reject_revision` typed cases (`.deletion` / `.formatting` / `.paragraphChange` / `.formatChange` / `.moveFrom` / `.moveTo`) clear paragraph-level + run-level revision state — file persistence converges with API state; `sourceToPartKey` throws on orphan container source; multi-instance same-type container collision repair |
| 8 | R5-CONT-4 | 1 P0 + 3 P1 | `accept_revision` typed cases mirror the reject-side clearMarker pattern across all 7 typed branches; matrix-pin tightening removes the asymmetry guard + ternary anti-pattern that hid prior P0s; `Document.repairContainerFileNames()` marks `word/_rels/document.xml.rels` + `[Content_Types].xml` dirty after rename — Word can open the saved file |

#### Convergence

R5-CONT-4 closes the cycle. The matrix-pin tightening removes the `if operation == "reject"` guard and `XCTAssertNil(<bool> ? 1000 : nil)` ternary anti-pattern that hid prior P0s. Devil's Advocate wrote 5 adversarial tests targeting the convergence-cycle pattern; all PASSED. Verify report: https://github.com/PsychQuant/che-word-mcp/issues/56#issuecomment-4322610741

### Tests

172 tests pass / 9 skipped / 0 failures (vs v3.13.4 baseline; no test additions since this release is pure dep bump).

### Caveats

- `ooxml-swift` R5-CONT-4 deferred §17.5 (legacy doc-scope sweep in `removeHyperlinkRelTarget`) per Codex disagreement with one Logic reviewer's "over-aggressive" assessment. Documented in [ooxml-swift CHANGELOG.md](https://github.com/PsychQuant/ooxml-swift/blob/v0.19.5/CHANGELOG.md) Caveats section. No MCP-tool-visible behavior change either way.
- 3 R2-Logic MEDIUM findings tracked as R6 follow-ups in the verify report: matrix-pin text-preservation coverage, `accept .deletion` `replacingOccurrences` scope (pre-existing pattern from reject side), 3+ header same-fileName collision edge case in `repairContainerFileNames`.

## [3.13.4] - 2026-04-26

### Fixed — 6 P0 + 2 P1 from #56 round 3 verify (ooxml-swift v0.19.4)

Bumps `ooxml-swift` dependency from `0.19.3` → `0.19.4`. **No che-word-mcp source changes** — the regressions and their fixes all live in ooxml-swift.

The v3.13.3 release went through a third 6-AI cross-verification round ([report](https://github.com/PsychQuant/che-word-mcp/issues/56#issuecomment-4321007538)). Five of six reviewers (logic / regression / security / codex / devil's advocate) returned BLOCK — the R2 fixes themselves introduced 6 new P0 regressions (anti-pattern: "fixes that save absence but break preserve-order / sync mutation paths"). v3.13.4 closes those 6 P0 plus 2 P1 follow-ups via the spectra change `che-word-mcp-issue-56-r3-stack-completion`. Each fix shipped as an independent commit with its own failing-test → fix → scoped Codex verify gate, breaking the bundle-and-regress cycle.

#### R3-NEW-1 — `replace_text` / `update_hyperlink` round-trip on source-loaded hyperlinks

The MCP `replace_text` tool's edits inside source-loaded `<w:hyperlink>` were silently lost on save (writer prioritized cached `children` over mutated `runs`). v0.19.4 makes the writer mutation-aware (compares run-text from both surfaces). The pre-existing canary `testReplaceTextInsideHyperlinkAppliesAndPersists` (added in v3.13.1) now passes — was failing in v3.13.3.

#### R3-NEW-2 — `<w:sdt>` (content control) round-trips at source position

Paragraph-level `<w:sdt>` always emitted at end-of-paragraph regardless of source order. v0.19.4 adds `ContentControl.position` and routes through positioned-entry sort. Affects MCP `list_content_controls` / `update_content_control_text` / `replace_content_control_content` users whose source documents have inline SDTs between runs.

#### R3-NEW-3 — `insert_comment` emits anchor markers on source paragraphs

`insert_comment` on a paragraph that already had source comment ranges (e.g., `<w:commentRangeStart w:id="3"/>`) silently dropped the new commentId's anchor markers — comment side-bar showed the comment but no scope highlight. v0.19.4 changes the writer's gate from blanket `commentRangeMarkers.isEmpty` to per-id covered-set check.

#### R3-NEW-4 — Mixed-content revision wrappers visible to MCP revision tools

`<w:ins>` / `<w:del>` / `<w:moveFrom>` / `<w:moveTo>` wrappers containing non-run children (e.g., a hyperlink inside `<w:ins>`) were captured as raw XML but invisible to MCP `get_revisions` / `accept_revision` / `reject_revision` / `accept_all_revisions` / `reject_all_revisions` tools. v0.19.4 publishes a typed `Revision` alongside the raw capture and adds accept/reject support for the wrapper case.

#### R3-NEW-5 — `insert_bookmark` no longer collides with source ids in tables / headers / footers / notes

`nextBookmarkId` calibration only saw body top-level paragraphs and ran before headers/footers/notes were even loaded. A document with bookmark id 99 inside a table cell or header → calibration false-success → `insert_bookmark` allocates id 1 → silent collision with the source id. v0.19.4 calibration recursively walks all bookmark-bearing parts (body + tables + nested tables + content controls + headers + footers + footnotes + endnotes).

#### R3-NEW-6 — XML attribute escape closes injection sink

`RunProperties.toXML` (and the parallel `toChangeXML` for `<w:rPrChange>`) interpolated `rStyle` / `color` / `fontName` String values directly into XML attributes. A malicious source `<w:rStyle w:val='x"/><inj/>'/>` round-tripped as additional sibling elements → Word schema reject. v0.19.4 routes all three through a 5-character escape (`& < > " '`). Audit table in ooxml-swift's R3 test suite enumerates every direct-emit site across both packages.

### Fixed — 1 P1 follow-up

- **D-3 (vendor xmlns)** — `<w:hyperlink xmlns:vendor="..." vendor:custom="x">` round-trips with the namespace declaration intact (was losing `xmlns:vendor` while keeping `vendor:custom` → Word schema reject of unbound prefix).

### Breaking changes

- **D-8 / Hyperlink.id format change introduced in v3.13.3 (P1-7)** — `Hyperlink.id` follows `<rId-or-anchor-or-hl>@<position>` (e.g. `rId5@7`) instead of the v3.13.2 format `<rId-or-anchor-or-hl>` (e.g. `rId5`). Callers of MCP tools that find / edit / delete hyperlinks by id and stored pre-v3.13.3 ids will get not-found errors after upgrade. Mitigation: re-call `list_hyperlinks` to refresh the id cache.

### Tests

- 12 new ooxml-swift tests in `Issue56R3StackTests.swift` covering each P0 / P1 fix
- ooxml-swift suite: 582 tests pass / 1 skipped / 0 failures (570 v3.13.3 baseline + 12 new R3 tests)
- che-word-mcp suite: 172 tests pass / 9 skipped / **0 failures** (was 172 / 9 / **1** in v3.13.3 — the R3-NEW-1 canary `testReplaceTextInsideHyperlinkAppliesAndPersists` is now green)
- Codex CLI scoped verify after each P0 fix; flagged P1s fixed inline before commit (R3-NEW-4 nested w:id substring match, R3-NEW-5 nested-table walker, R3-NEW-6 toChangeXML color escape parity)

## [3.13.3] - 2026-04-26

### Fixed — 8 P0 + 3 must-fix P1 from #56 round 2 verify (ooxml-swift v0.19.3)

Bumps the `ooxml-swift` dependency from `0.19.2` → `0.19.3`. **No che-word-mcp source changes.**

The v3.13.2 release went through a second 6-AI cross-verification round ([report](https://github.com/PsychQuant/che-word-mcp/issues/56#issuecomment-4320157395)). Five of six reviewers (codex / logic / regression / security / devil's advocate) returned BLOCK — the requirements reviewer's PASS was overturned on every F1–F4 with concrete refutations. v3.13.3 ships the fixes for the 8 P0 + 3 must-fix P1 in four batches.

#### Batch A — Hyperlink suite

- **P0-1** — All 5 MCP `insert_*hyperlink` tools again render with blue + underline + Hyperlink character style. v0.19.2's writer rewrite walked `runs` directly without applying the legacy hardcoded `<w:rStyle Hyperlink>` / color / underline; new `RunProperties.rStyle` field carries the style.
- **P0-2** — Hyperlinks with `w:tgtFrame` / `w:docLocation` now round-trip these vendor / browser-target attributes (Reader's `recognizedAttrs` previously filtered them but no typed field stored them).
- **P0-3** — New ordered `HyperlinkChild` preserves source-document order between `<w:r>` and non-run children. `<w:hyperlink><w:r>A</w:r><w:sdt>X</w:sdt><w:r>B</w:r></w:hyperlink>` round-trips A→SDT→B (was A→B→SDT).
- **P1-7** — `Hyperlink.id` is unique per source position (`<rId-or-anchor>@<position>`) so MCP find / edit / delete by id no longer misroutes when two hyperlinks share a relationship id.

#### Batch B — Sort path completeness

- **P0-4** — Source paragraphs with `<w:sdt>` + any positioned child no longer drop the SDT on save (sort path now emits `contentControls`).
- **P0-5** — `insert_comment` / `insert_footnote` on a bookmarked source paragraph no longer silently lost: sort path emits the legacy `commentIds` / `footnoteIds` / `endnoteIds` / `hasPageBreak` / legacy `bookmarks` collections (skipped per-collection only when their positioned variants are populated, to avoid double-emit).
- **P0-8** — Source paragraphs with `<w:r>A</w:r><w:hyperlink>L</w:hyperlink><w:r>B</w:r>` round-trip with the visible text in source order; the legacy path's "all runs first then all hyperlinks" reordering is gone.

#### Batch C — Revision wrapper coverage

- **P0-6** — Track Changes insertion of pure non-text content (`<w:tab/>`, `<w:br/>`, `<w:drawing>`, `<w:fldChar>`) no longer drops the `<w:ins>` / `<w:del>` wrapper — Reader always creates the `Revision` entry regardless of inner text.
- **P0-7** — Track Changes insertion of nested `<w:hyperlink>` / `<w:sdt>` / `<w:fldSimple>` / `<mc:AlternateContent>` round-trips byte-equivalent (Reader captures the whole wrapper verbatim into `unrecognizedChildren` at the wrapper position; trade-off: per-run editing lost for these mixed wrappers).

#### Batch D — Bookmark hardening

- **P1-1** — `insert_bookmark` on a source-loaded document no longer collides with existing source bookmark ids; `DocxReader` calibrates `nextBookmarkId` past the max source id on load.
- **P1-4** — `insert_bookmark` on a pure API-built paragraph again wraps the existing run text (legacy `<w:bookmarkStart/><w:r>Hello</w:r><w:bookmarkEnd/>`), restoring v3.12.0 semantics. F2 had downgraded API-path bookmarks to zero-width point bookmarks at paragraph end.

### Test coverage

172 che-word-mcp tests pass + 570 ooxml-swift tests pass (557 from v0.19.2 + 13 new in `Issue56RoundtripCompletenessTests`). New cases are end-to-end Reader → Writer round-trip (vs v0.19.2's API-only construction), so Reader-side filter bugs are now exercised.

### Follow-up items deferred

The round 2 verify also surfaced 5 non-must-fix P1 + 9 P2 + 8 P3 items (devil's advocate NEW-A through NEW-G plus security defense-in-depth and pre-existing non-blocking items). These are filed as separate follow-up issues for staged remediation; v3.13.3 ships only the must-fix subset to land #56's lossless round-trip contract on the v3.13.x line.

## [3.13.2] - 2026-04-26

### Fixed — 4 blocking findings from #56 verification (ooxml-swift v0.19.2)

Bumps the `ooxml-swift` dependency from `0.19.1` → `0.19.2`. **No che-word-mcp source changes.**

The v3.13.1 release went through 6-AI cross-verification ([report](https://github.com/PsychQuant/che-word-mcp/issues/56#issuecomment-4319691177)). Five reviewers initially marked all four #56 Expected requirements as FULLY addressed; the Devil's Advocate reviewer downgraded all four to PARTIAL after surfacing 4 blocking sub-issues:

- **F1** — `Hyperlink.toXML()` ignored Reader-collected `runs` / `rawAttributes` / `rawChildren` (multi-run formatting + vendor attrs + nested children silently dropped on every round-trip)
- **F2** — `addBookmark` / `deleteBookmark` didn't sync `bookmarkMarkers` (new bookmarks silently dropped on save for source-loaded paragraphs; deletes left zombie `<w:bookmarkStart w:name=""/>` markers)
- **F3** — `<w:ins>` / `<w:moveFrom>` / `<w:moveTo>` Reader didn't assign `position` or `revisionId` to inner runs (sort-by-position emit collapsed all wrapper-internal runs to paragraph front; revision wrappers themselves dropped because sort path didn't regroup runs by `revisionId`)
- **F4** — Namespace preservation only covered `word/document.xml` (headers/footers/footnotes/endnotes still used hardcoded namespace templates; NTPU thesis-class headers with VML watermarks declaring `mc`/`wp`/`w14`/`w15` beyond the 5-namespace template silently regressed to the original #56 unbound-prefix bug)

All four fixes ship in `ooxml-swift` v0.19.2. che-word-mcp consumes them transparently via the dependency bump — no Server.swift changes.

### Test coverage

172 che-word-mcp tests pass + 557 ooxml-swift tests pass (548 from v0.19.1 + 9 new in `Issue56FollowupTests` covering each F1–F4 fix and their fallback behaviors).

### No breaking changes

233 existing MCP tools unchanged. All ooxml-swift v0.19.2 changes are additive (new fields default to empty; API-built objects produce byte-identical pre-fix output).

## [3.13.1] - 2026-04-25

### Fixed — `pPr` double-emission silent regression on sort-by-position round-trip (ooxml-swift v0.19.1)

Hot-fix bumping the `ooxml-swift` dependency from `0.19.0` → `0.19.1`. No che-word-mcp source changes.

**Symptom (caught during NTPU thesis verification of #56):** After v3.13.0 round-trip, paragraph properties were emitted twice — once via `parseParagraphProperties` and once via the position-sorted writer's `unrecognizedChildren` path. `xmllint --noout` accepted the output (legal XML), but `<w:p>` element size grew ~1 KB per round-trip and unrecognized-child counts climbed from 799 → 1333 (+67%) on the same fixture.

**Root cause (ooxml-swift):** `parseParagraph` consumed `<w:pPr>` via `parseParagraphProperties` BEFORE the child walker, but the child walker had no explicit `case "pPr"` — so on the second pass the same `<w:pPr>` node fell into the `default` branch and got re-captured into `unrecognizedChildren`. The sort-by-position writer then emitted both copies in source order.

**Fix:** 1-line `case "pPr": break` skip in `DocxReader.parseParagraph` child walker (PsychQuant/ooxml-swift@6bcd2d2). Added regression test `testParseParagraphSkipsPPrInChildWalker`.

**Verification (NTPU thesis, 169 KB, 570 paragraphs):**

| Metric | v3.13.0 (broken) | v3.13.1 (fixed) |
|---|---|---|
| Unrecognized children | 799 → 1333 | 229 → 229 |
| `<w:p>` byte growth per round-trip | ~1 KB | 0 |
| `xmllint --noout` | clean | clean |
| Bookmark / hyperlink / fldSimple count parity | ✓ | ✓ |
| Text SHA256 parity | ✓ | ✓ |

**No source changes** in che-word-mcp itself. Only `Package.swift` dependency bump and re-build. 173 che-word-mcp tests + 548 ooxml-swift tests pass.

## [3.13.0] - 2026-04-25

### Fixed — `document.xml` lossless round-trip + tool-mediated wrapper edits (Closes PsychQuant/che-word-mcp#56, P0)

Critical bug fix. Pre-v3.13.0, `save_document` silently corrupted `word/document.xml` on every body-mutating MCP call:

- **Strip 32 of 34 namespace declarations** from the `<w:document>` root → libxml2 reports "unbound prefix" on every body element that referenced `mc:`, `wp:`, `w14:`, etc.
- **Wipe 100% of `<w:bookmarkStart>` bookmarks** (a typical academic thesis loses all 45 cross-reference anchors).
- **Drop 354 `<w:t>` text nodes / 191 unique strings** — every text node living inside `<w:hyperlink>` (TOC entries, cross-refs), `<w:fldSimple>` (SEQ Table captions, REF), or `<mc:AlternateContent>` (math fallbacks) was silently dropped along with its wrapper.
- **`replace_text` silently failed** for any text inside the above wrappers — returned "Replaced 0 occurrence(s)" when the text was right there in the visible document.

Reporter (#56) caught the bug while attempting `open → insert_paragraph → save` on an NTPU master's thesis (169 KB, 42 OOXML parts, 45 bookmarks, 13 fonts including DFKai-SB).

### How v3.13.0 fixes it (built on ooxml-swift v0.19.0)

- **Document root namespace preservation** — Reader captures every source `xmlns:*` + `mc:Ignorable`; Writer rebuilds the root open tag verbatim.
- **Bookmark Reader parsing** — `<w:bookmarkStart>` / `<w:bookmarkEnd>` populate `Paragraph.bookmarks` + `Paragraph.bookmarkMarkers` (position-indexed for source-order Writer emit).
- **Wrapper hybrid model** — `Hyperlink` / `FieldSimple` / `AlternateContent` gain typed editable surfaces (`runs` / `fallbackRuns`) so MCP tools find content inside, plus raw passthrough fields (`rawAttributes` / `rawChildren` / `rawXML`) so unrecognized attributes / non-Run children survive byte-equivalent.
- **`<w:p>` schema completeness** — 6 raw-carrier types (`CommentRangeMarker`, `PermissionRangeMarker`, `ProofErrorMarker`, `SmartTagBlock`, `CustomXmlBlock`, `BidiOverrideBlock`) plus a fallback `unrecognizedChildren` collection ensure every legal `<w:p>` direct child round-trips.
- **Sort-by-position Writer emit** — `Paragraph.toXML()` collects `(position, xml)` tuples from every parallel array and emits in source order. Triggered when any source-loaded marker collection is non-empty; API-built paragraphs use the legacy emit path (zero breaking changes).
- **Tool-mediated wrapper edits** — `replace_text` / `replace_text_batch` now walk `Hyperlink.runs`, `FieldSimple.runs`, `AlternateContent.fallbackRuns`. Edits inside structural wrappers SHALL apply (no silent failure).

### New tests

- **`ToolMediatedWrapperEditTests`** (2 tests) — verifies `replace_text` finds text inside `<w:hyperlink>` and `<w:fldSimple>` and persists changes through save / reload while wrapper attributes (`w:anchor`, `w:instr` whitespace) are preserved.
- **`RealWorldDocxRoundTripSmokeTests`** — iterates `mcp/che-word-mcp/test-files/*.docx` (gitignored) and runs `xmllint --noout` + bookmark/hyperlink/fldSimple/AlternateContent count parity + SHA256 of concatenated `<w:t>` content per fixture. Silently `XCTSkip`s when the directory is empty (clean-clone CI safe).

### Breaking changes

None. `Hyperlink.text` is now a computed property but observationally equivalent for read access; the setter collapses to single-Run (matching pre-fix multi-run-overwrite behavior). 218 existing MCP tools unchanged.

### Built on ooxml-swift v0.19.0

## [3.12.0] - 2026-04-25

### Added — Programmatic Track Changes generation: 3 new tools + 2 extended args (Closes PsychQuant/che-word-mcp#45)

Closes the last P0 of the Office.js OOXML Roadmap (#43). v3.11.x had read-side Track Changes (`enable_track_changes`, `accept_revision`, `reject_revision`, `get_revisions`) but no WRITE-side surface — mutation tools rewrote silently, never producing `<w:ins>` / `<w:del>` markup. v3.12.0 adds the missing write side so AI assistants can produce auditable redline edits.

**3 new tools:**

- `insert_text_as_revision(doc_id, paragraph_index, position, text, author?, date?)` — inserts text wrapped in `<w:ins>` revision markup. Splits straddling runs at `position` (preserves prior + post text + formatting).
- `delete_text_as_revision(doc_id, paragraph_index, start, end, author?, date?)` — marks `[start, end)` runs with `<w:del>` and substitutes `<w:t>` → `<w:delText>`. Single-paragraph only (cross-paragraph delete out of scope).
- `move_text_as_revision(doc_id, from_paragraph_index, from_start, from_end, to_paragraph_index, to_position, author?, date?)` — emits paired `<w:moveFrom>` / `<w:moveTo>` with adjacent revision ids. Single-paragraph moves rejected (callers should use delete + insert).

**2 extended args (additive, default `false`):**

- `format_text` gains `as_revision: bool` — when `true`, produces `<w:rPrChange>` revision instead of silent format mutation. Also accepts `run_index`, `author`, `date` for revision-mode invocations.
- `set_paragraph_format` gains `as_revision: bool` — when `true`, produces `<w:pPrChange>` revision.

**Side-effect avoidance:** All revision-tracked operations require `enable_track_changes` to have been called first. When `as_revision: true` is passed but track changes is off, the tool returns `track_changes_not_enabled` error WITHOUT auto-enabling track changes. Avoids hidden state mutation per design decision.

**Author resolution:** 3-tier fallback — explicit non-empty `author` arg → `revisions.settings.author` (set by `enable_track_changes`) → literal `"Unknown"`.

### Built on ooxml-swift v0.18.0

This release pulls ooxml-swift v0.18.0 which adds 6 new `WordDocument` methods (`allocateRevisionId`, `insertTextAsRevision`, `deleteTextAsRevision`, `moveTextAsRevision`, `applyRunPropertiesAsRevision`, `applyParagraphPropertiesAsRevision`) and writer-side `Paragraph.toXML()` extensions that emit revision markup correctly (groups consecutive runs sharing `revisionId`, substitutes `<w:t>` → `<w:delText>` for deletions, embeds `<w:rPrChange>` / `<w:pPrChange>` properties).

### Tests

- 156 baseline + 13 net new = **169/169 tests pass**, 9 skipped (test scaffolds for future expansion):
  - 3 `ContractRedlineE2ETests` covering full redline workflow (insert + delete + format change), multi-author interleaving (settings vs explicit override), and side-effect avoidance guard
  - 24 `RevisionGenerationTests` at the ooxml-swift layer (multi-run wrapping, delText substitution, allocator semantics, all 5 generators)

### Migration

Additive — no breaking changes. `format_text` and `set_paragraph_format` defaults preserve v3.11.x behavior exactly.

## [3.11.0] - 2026-04-25

### Added — Tables / Hyperlinks / Headers extensions (closes [#49](https://github.com/PsychQuant/che-word-mcp/issues/49) [#50](https://github.com/PsychQuant/che-word-mcp/issues/50) [#51](https://github.com/PsychQuant/che-word-mcp/issues/51))

Implements the `che-word-mcp-tables-hyperlinks-headers-builtin` SDD. Brings 16 new MCP tools completing the dependent triplet of the Office.js Roadmap P0 set (built on v3.10.0 styles + sections foundation).

#### 1. Table tools (5 new)

- `set_table_conditional_style` — apply firstRow / lastRow / bandedRows etc. (10 region types) via `<w:tblStylePr>`
- `insert_nested_table` — insert table-in-cell (depth-limited to 5 — surfaces `nested_too_deep` error)
- `set_table_layout` — switch fixed / autofit
- `set_header_row` — mark row as `<w:tblHeader/>` for repeat-on-page-break
- `set_table_indent` — table-level left indent (`<w:tblInd>`)

#### 2. Hyperlink tools (3 new typed)

- `insert_url_hyperlink` — external URL with optional tooltip + history flag
- `insert_bookmark_hyperlink` — internal anchor link (`w:anchor`, no rId)
- `insert_email_hyperlink` — `mailto:` with optional URL-encoded subject
- All 3 auto-create the `Hyperlink` character style if missing (idempotent)

#### 3. Header tools (4 new)

- `enable_even_odd_headers` — toggle document-level `<w:evenAndOddHeaders/>` flag
- `link_section_header_to_previous` / `unlink_section_header_from_previous` — Word-compat clone semantics
- `get_section_header_map` — return per-section header / footer file assignments

### Foundation: ooxml-swift v0.17.0

- Table model: `conditionalStyles`, `tableIndent`, `explicitLayout`, `nestedTables` per cell, diagonal borders (`tl2br` / `tr2bl`)
- New types: `TableConditionalStyleType` (10 cases), `TableConditionalStyleProperties`, `TableConditionalStyle`
- Hyperlink model: `history: Bool` field (`w:history="0"` only when false)
- Document model: `evenAndOddHeaders: Bool` for settings.xml round-trip
- WordDocument 9 new mutation methods (Table 5 + Hyperlink 1 + Header 3), all explicitly mark relevant XML parts dirty
- Reader: recursive parseTable with depth limit 5 (throws `WordError.invalidDocx`)
- Writer: extendedTablePropertiesXML, cell.toXML emits nested tables + trailing empty paragraph (OOXML compliance)
- New WordError cases: `nestedTooDeep(depth:max:)`, `hyperlinkNotFound(String)`

### Tests

- ooxml-swift: 507/507 pass (+16 new across TableAdvancedTests / HyperlinkTypedTests / HeaderMultiTypeTests)
- che-word-mcp: 157/157 pass (+11 new TablesHyperlinksHeadersToolsTests, +3 new MeetingMinutesE2ETests covering financial report / academic paper / corporate proposal scenarios)

### Backwards compatibility

All new tools are additive. No existing tool signatures changed.

### Office.js Roadmap progress

After this release, P0 set has only #45 (Track Changes — independent) remaining. Roadmap moves to P1 territory.

## [3.10.0] - 2026-04-24

### Added — Styles + Numbering + Sections foundation (closes [#46](https://github.com/PsychQuant/che-word-mcp/issues/46) [#47](https://github.com/PsychQuant/che-word-mcp/issues/47) [#48](https://github.com/PsychQuant/che-word-mcp/issues/48))

Implements the `che-word-mcp-styles-sections-numbering-foundations` SDD. Brings 19 new MCP tools + 6 extended args completing the Office.js Roadmap P0 foundation triplet.

#### 1. Style tools (4 new + 6 extended args)

- `get_style_inheritance_chain` — traverse `basedOn` chain upward to root with cycle detection
- `link_styles` — bidirectional `<w:link>` between paragraph and character style pair
- `set_latent_styles` — control Quick Style Gallery defaults via `<w:latentStyles>` block
- `add_style_name_alias` — localized `<w:name>` alias per BCP 47 lang code
- `create_style` / `update_style` extended with: `based_on`, `linked_style_id`, `next_style_id`, `q_format`, `hidden`, `semi_hidden`

#### 2. Numbering tools (8 new)

- `list_numbering_definitions` — enumerate every abstractNum + num pair
- `get_numbering_definition` — fetch single num by id
- `create_numbering_definition` — new abstractNum + paired num (max 9 levels)
- `override_numbering_level` — `<w:lvlOverride>` for per-level start values
- `assign_numbering_to_paragraph` — `<w:numPr>` attachment by paragraph index
- `continue_list` / `start_new_list` — manage list continuity
- `gc_orphan_numbering` — sweep unreferenced num definitions (abstractNums preserved)

#### 3. Section tools (7 new)

- `set_line_numbers_for_section` — `<w:lnNumType>` for legal documents
- `set_section_vertical_alignment` — `<w:vAlign>` for cover pages
- `set_page_number_format` — `<w:pgNumType w:fmt>` for Roman numerals etc.
- `set_section_break_type` — `nextPage` / `continuous` / `evenPage` / `oddPage`
- `set_title_page_distinct` — toggle `<w:titlePg/>` per section
- `set_section_header_footer_references` — assign per-type rId (default/first/even)
- `get_all_sections` — return SectionInfo array per section in document order

### Foundation: ooxml-swift v0.16.0

- Style model gains `linkedStyleId` / `hidden` / `semiHidden` / `aliases` + new `WordDocument.latentStyles`
- Numbering model gains `Num.lvlOverrides` + 3 new `NumberFormat` cases (ordinal / cardinalText / decimalZero)
- Section model gains 8 new fields on SectionProperties + 5 new types (HeaderFooterReferences / LineNumbers / LineNumberRestart / SectionVerticalAlignment / SectionPageNumberFormat)
- WordDocument: 16 new mutation methods, all explicitly marking the relevant XML part dirty
- WordError additions: `styleNotFound`, `typeMismatch`, `numIdNotFound`, `abstractNumIdNotFound`

### Tests

- ooxml-swift: 491/491 pass (+26 new across StylesInheritanceTests / NumberingLifecycleTests / SectionPropertiesExtendedTests)
- che-word-mcp: 143/143 pass (+21 new StylesNumberingSectionsToolsTests, +3 new CorporateTemplateE2ETests covering corporate template / academic preface / tiered list scenarios)

### Backwards compatibility

All new tools are additive. Existing `create_style` / `update_style` callers see no breaking changes (new args are all optional). One internal note: ooxml-swift v0.16.0 introduces `SectionVerticalAlignment` and `SectionPageNumberFormat` as new types (not renames — `Image.VerticalAlignment` and `Footer.PageNumberFormat` are unchanged).

## [3.9.0] - 2026-04-24

### Added — Content Controls (SDT) read/write tool suite (closes [#44](https://github.com/PsychQuant/che-word-mcp/issues/44))

Implements the `che-word-mcp-content-controls-read-write` SDD. Enables full lifecycle management of Word's Structured Document Tags (SDTs / Content Controls): discover, read, modify, delete, plus advanced insert with new SDT types.

#### 1. New read tools (3)

- `list_content_controls` — enumerate every SDT in a document, flat (default) or nested tree mode. Supports both session (`doc_id`) and direct (`source_path`) modes.
- `get_content_control` — fetch a single SDT by `id`, `tag`, or `alias`. Returns full metadata + `<w:sdtContent>` XML. Surfaces `not_found` / `multiple_matches` errors.
- `list_repeating_section_items` — enumerate items inside a repeating-section SDT in document order.

#### 2. New write tools (4)

- `update_content_control_text` — replace text content of plain-text / rich-text / date / bibliography / citation SDTs. Preserves `<w:sdtPr>` byte-identical. Returns `unsupported_type` for picture / dropdown / combo / checkbox / group / repeating-section.
- `replace_content_control_content` — replace the full `<w:sdtContent>` XML with whitelist validation. Rejects input containing `<w:sdt>`, `<w:body>`, `<w:sectPr>`, or XML declaration.
- `delete_content_control` — remove an SDT, optionally unwrapping children (`keep_content: true` default). Block-level wrappers unwrap into the body container.
- `update_repeating_section_item` — replace text of a single item by index. Surfaces `out_of_bounds` for invalid index.

#### 3. Tool extensions

- `insert_content_control` accepts 4 new types: `bibliography`, `citation`, `group`, `repeatingSectionItem`. New optional args: `list_items` (required for `dropDownList` / `comboBox`), `date_format`, `lock_type`. The `repeatingSection` type is now explicitly rejected with a redirect to `insert_repeating_section`.
- `insert_repeating_section` accepts new optional `allow_insert_delete_sections: bool` arg (default `true`).
- SDT id allocation now uses deterministic max-plus-one (was `Int.random(in: 100000...999999)` with collision risk).

#### 4. Stub for forward compatibility

- `list_custom_xml_parts` ships as an empty-list stub so tooling can target the schema today; real implementation lands in Change B (`che-word-mcp-customxml-databinding`).

### Foundation: ooxml-swift v0.15.0 / v0.15.1

- New `SDTParser` surfaces `<w:sdt>` as first-class `Paragraph.contentControls: [ContentControl]` (was opaque `Run.rawXML` blob)
- 12-type discrimination (richText / plainText / picture / date / dropDownList / comboBox / checkbox / bibliography / citation / group / repeatingSection / repeatingSectionItem)
- Nested SDT tree preservation (children + parentSdtId)
- New `BodyChild.contentControl(ContentControl, children: [BodyChild])` enum case for block-level SDTs at `<w:body>` / `<w:tc>` level
- WordDocument mutation methods: `updateContentControl(id:newText:)`, `replaceContentControlContent(id:contentXML:)`, `deleteContentControl(id:keepContent:)`, `allocateSdtId() -> Int`
- New `WordError` cases: `contentControlNotFound`, `unsupportedSDTType`, `disallowedElement`, `repeatingSectionItemOutOfBounds`
- v0.15.1 patch: `RepeatingSection.toXML()` emits `<w:id>` so MCP tools can locate sections by SDT id

### Tests

- ooxml-swift: 465/465 pass (+14 ContentControlMutationTests, +6 SDTParserTests)
- che-word-mcp: 117/117 pass (+17 ContentControlToolsTests, +1 InvoiceTemplateE2ETests)

### Backwards compatibility

All new tools are additive. Existing `insert_content_control` / `insert_repeating_section` callers see no breaking changes (new args are optional). One internal behavior change: SDT ids are now deterministic sequential (max+1) instead of random — callers relying on random uniqueness across documents must switch to tag-based lookup.

### Migration

- ooxml-swift: minor bump 0.14.0 → 0.15.1 (new `BodyChild.contentControl` enum case — exhaustive switches must add the new case)
- word-to-md-swift: bumped to 0.6.0 with handler for the new case

## [3.8.0] - 2026-04-24

### Added — Header/footer raw-element preservation + counter-isolation flag (closes [#52](https://github.com/PsychQuant/che-word-mcp/issues/52))

Bundles two coordinated features from the `che-word-mcp-header-footer-raw-element-preservation` SDD:

#### 1. VML watermarks / OLE objects survive `update_all_fields` round-trip

ooxml-swift [v0.14.0](https://github.com/PsychQuant/ooxml-swift/releases/tag/v0.14.0) ships `Run.rawElements` carrier (new `RawElement` struct: `name` + `xml`). `DocxReader.parseRun` now collects unknown direct children of `<w:r>` (e.g., `<w:pict>` VML watermarks, `<w:object>` OLE embeds, `<w:ruby>`) into rawElements; `Run.toXML` emits them verbatim after typed children.

Result: NTPU thesis VML watermarks at `w:hdr` → `w:p` → `w:r` → `w:pict` → `v:shape` survive any header round-trip including the v3.7.1 case (`update_all_fields` on doc with header SEQ field).

This **removes the v3.7.1 known-limitation paragraph**: header WITH legitimately-placed SEQ + co-located VML/drawings now byte-preserves correctly. Updated `Header.toXML()` / `Footer.toXML()` declare `xmlns:v` / `xmlns:o` / `xmlns:w10` at root so descendant VML elements resolve when re-read.

#### 2. `update_all_fields` gains `isolate_per_container` opt-in parameter

```json
{
  "tool": "update_all_fields",
  "arguments": {
    "doc_id": "thesis",
    "isolate_per_container": true
  }
}
```

Default `false` preserves prior global-counter-sharing behavior (body 3 Figure + header 1 Figure → header sees count 4). When `true`, each container family (body / each header / each footer / footnotes / endnotes) maintains independent SEQ counter dicts (header sees count 1).

Surfaces the Word F9 per-container semantic for chapter-caption running headers and similar use cases. Returned summary reflects body's final counter state; per-container values inspectable via SEQ runs' rawXML.

### Tests

- 100/100 che-word-mcp tests pass + 11 in-progress adjacent (no regression from dep bump or MCP tool surface change)
- ooxml-swift v0.14.0 ships **451/451 tests** (was 408 → +43 across this + prior sessions' work)

### Compatibility

- **No removed APIs** — all changes additive
- **MCP tool surface**: `update_all_fields` gains optional `isolate_per_container` parameter; default `false` preserves v3.7.x behavior
- **Behavior changes** (from ooxml-swift v0.14.0):
  - `update_all_fields` (and any code path that re-emits headers/footers) now byte-preserves VML watermarks, OLE objects, and other unknown OOXML constructs in headers/footers — was previously silently stripped at the Run layer
  - Saved `word/header*.xml` / `word/footer*.xml` declare additional namespaces — observable in byte content
- Universal binary (x86_64 + arm64) preserved

### Migration from v3.7.x

Existing callers see no behavioral change unless:
1. They call `update_all_fields` on a doc with VML watermarks in headers — those now survive (was silent data loss)
2. They explicitly opt into `isolate_per_container: true` for per-container counter semantics

### Refs

- PsychQuant/che-word-mcp#52 — Header.toXML raw-XML preservation
- Bundles deferred work from PsychQuant/che-word-mcp#54 sub-finding #8 (counter-isolation flag)
- ooxml-swift v0.14.0 release notes for typed-model details

## [3.7.2] - 2026-04-24

### Fixed — 3-issue bundle from #42 verification (closes [#53](https://github.com/PsychQuant/che-word-mcp/issues/53), [#54](https://github.com/PsychQuant/che-word-mcp/issues/54), [#55](https://github.com/PsychQuant/che-word-mcp/issues/55))

Pure dep bump (`ooxml-swift` 0.13.4 → [0.13.5](https://github.com/PsychQuant/ooxml-swift/releases/tag/v0.13.5)) consuming three follow-ups that were opened during #42 verification:

#### #55 — Path traversal security baseline (P2 pre-existing)

`isSafeRelativeOOXMLPath()` validator + DocxReader sanitization + Header/Footer setter validation. Defense-in-depth against malicious .docx with `Target="../../../etc/passwd"` style rels (read sink + write sink).

#### #53 — Multi-instance Header/Footer auto-suffix (P3 latent)

`addHeader()` × N with default type now produces `header1.xml`, `header2.xml`, `header3.xml` instead of all colliding to `header1.xml`. Mirror for footers + `*WithPageNumber` variants.

#### #54 — `updateAllFields` coverage extensions (P3 test gaps)

Bundles 4 sub-findings: (a) regex schema-drift stderr warning, (b) cross-container counter-sharing doc-comment, (c) header-SEQ no-op test, (d) footnote/endnote round-trip tests.

### Synergy

- #55's sanitization fallback path benefits from #53's auto-suffix logic (multiple rejected paths can't collapse to `header1.xml`)
- #54's stderr warning extends #42 + #41's observability infrastructure
- All 3 bundled in single ooxml-swift release; che-word-mcp consumes via single PATCH bump

### Tests

- 100/100 che-word-mcp tests pass unchanged + 11 new tests from in-progress adjacent work
- ooxml-swift v0.13.5 ships **444/444 tests** (was 408 → +36)

### Compatibility

- **No che-word-mcp source changes** — fix is entirely in ooxml-swift dep
- **No MCP API changes** — all 173+ tools work identically
- Universal binary (x86_64 + arm64) preserved
- Behavior changes (from ooxml-swift):
  - DocxReader silently drops headers/footers with unsafe rel.target (with stderr warning)
  - `addHeader()` × N produces sequential fileNames
  - `update_all_fields` warns on regex schema drift

### Refs

- PsychQuant/che-word-mcp#53, #54, #55 (all opened during #42 verify on 2026-04-24)

## [3.7.1] - 2026-04-24

### Fixed — `update_all_fields` no longer strips headers/footers (closes [#42](https://github.com/PsychQuant/che-word-mcp/issues/42))

Pre-v3.7.1 `update_all_fields` triggered silent data loss on every academic template workflow with VML watermarks (NTPU / 台大 / 政大 thesis templates). Calling `update_all_fields` once + saving stripped 6 headers × ~3600 bytes of template structure (watermarks, page numbers, chapter title STYLEREF) down to 318-byte `<w:p/>` stubs. Variant table from #42 conclusively pinned the locus to `update_all_fields` — no other tool exhibited the strip.

### Resolution

v3.7.1 consumes [`ooxml-swift v0.13.4`](https://github.com/PsychQuant/ooxml-swift/releases/tag/v0.13.4) which fixes the root cause: `WordDocument.updateAllFields` now propagates dirty bits honestly. Each container (body / headers / footers / footnotes / endnotes) tracks whether ANY SEQ field was actually rewritten; only confirmed-dirty containers get inserted into `modifiedParts`. Containers without SEQ stay out of `modifiedParts` → overlay-mode `DocxWriter` skips re-emission → original bytes preserved byte-for-byte.

### Tests

- 100/100 che-word-mcp tests pass unchanged (no consumer-side regression)
- Underlying ooxml-swift v0.13.4 ships **407/407 tests** including 4 new `WordDocumentUpdateAllFieldsHeaderPreservationTests`

### Compatibility

- **No source code changes** to che-word-mcp itself — fix is entirely in ooxml-swift dep.
- **No API change**: `update_all_fields` MCP tool signature unchanged; behavior strictly stronger (preserves what it should preserve).
- Universal binary (x86_64 + arm64) preserved.
- **Known limitation**: header that legitimately contains a SEQ field (rare — chapter caption in running header) still re-emits via `Header.toXML()` and strips co-located VML. Out of scope for this PATCH; tracked for follow-up.

### Refs

- PsychQuant/che-word-mcp#42 — incident report from 2026-04-23 NTPU thesis rescue workflow

## [3.7.0] - 2026-04-24

### Changed — autosave Design B + default flip; insert crash hardening

Two coordinated v3.6.0 production blocker fixes from the `che-word-mcp-insert-crash-autosave-fix` SDD:

#### #40 — autosave_every redesigned to Design B; default flipped 0 → 1

Pre-v3.7.0 implementation was Design A: counter incremented AFTER mutation succeeded; checkpoint fired when `count % N == 0`. Failure mode: for `autosave_every: N + crash on mutation K where K%N≠0`, mutations between checkpoints were lost. Worst case (#40 incident): `autosave_every: 3 + crash on mutation 3 = 0 mutations preserved` because counter never incremented (mutation crashed before `storeDocument` ran).

v3.7.0 switches to **Design B**: snapshot dispatch fires at the START of every mutating handler (specifically, at the entry of `storeDocument` BEFORE `openDocuments[docId]` is overwritten). The dispatcher reads `openDocuments[docId]` (the OLD pre-mutation state) and writes it to `<sourcePath>.autosave.docx`. On crash mid-mutation K, the autosave file holds the post-mutation-(K-1) state.

**Default flip**: `autosave_every` default value flipped from `0` (disabled) to `1` (snapshot before every mutation). Maximum safety; perf-conscious callers must explicitly pass `autosave_every: 0` to opt out.

```swift
// Server.swift:storeDocument refactor
internal func storeDocument(...) async throws {
    // Phase C (Design B): snapshot BEFORE we overwrite openDocuments[docId].
    if markDirty {
        dispatchAutosaveCheckpointIfDue(docId: docId)
    }
    // ... existing mutation commit ...
    if markDirty, autosaveEvery[docId] != nil {
        autosaveCounter[docId] = (autosaveCounter[docId] ?? 0) + 1
    }
}
```

**BREAKING (effective)** for v3.6.0 callers:
- Code that omitted `autosave_every` now gets `1` (every mutation snapshots prior state). To restore v3.6.0 disabled-by-default behavior, add `autosave_every: 0` to `open_document` calls.
- Code that passed `autosave_every: 0` explicitly is unaffected.
- Code that passed `autosave_every: N > 0` now sees Design B semantics — snapshot fires at mutation N+1 start (capturing post-mutation-N state), not at mutation N completion.

#### #41 — Phase A structured logging for sequential insert crash investigation

Adds `CHE_WORD_MCP_LOG_LEVEL=debug` env-var-gated diagnostic logger. Off by default (zero overhead in production). When enabled, emits one-line stderr events for `insertImageFromPath` entry/exit, `storeDocument` entry/exit, `dispatchAutosaveCheckpoint` exit. New `WordMCPServer(forceDebugLogging:)` test seam constructor for XCTest introspection.

The 3rd-sequential-insert crash root cause requires runtime instrumentation against an NTPU-style fixture; this release ships the infrastructure so any future session with the fixture can capture the trace via `swift test --filter InsertCrashRegressionTests`. Per SDD non-goals, Phases B/C/D ship regardless of Phase A repro outcome.

#### Defensive hardening from ooxml-swift v0.13.3

- `DocxReader.read` is now fully serial (libxml2 thread-safety + recovery determinism)
- `nextImageRelationshipId` delegates to allocator-based `nextRelationshipId` (fragile naïve counter eliminated)

### Tests

- 93 baseline + 7 new = **100/100 tests pass** (1 InsertCrashRegression skipped — fixture not present):
  - `StructuredLoggingTests` (2 scenarios): default-off, debug-on event capture
  - `InsertCrashRegressionTests` (1 scenario, XCTSkip fallback): 3-sequential-insert smoke
  - `AutosaveDesignBTests` (4 scenarios): mid-batch durability, Nth-mutation timing, N=0 disable, save cleanup + counter reset
- Pre-existing v3.6.0 `AutosaveCheckpointTests` updated to match Design B semantics (3 of 9 scenarios edited; 6 unchanged).

### Compatibility

- **MCP API surface** — no removed tools; `autosave_every` parameter now defaults to `1` (was `0`); `CHE_WORD_MCP_LOG_LEVEL` env var is optional.
- **No `ooxml-swift` API change** — bumped from `0.13.2` to `0.13.3` (PATCH, internal refactor).
- Universal binary (x86_64 + arm64) preserved.

### Refs

- PsychQuant/che-word-mcp#40 — autosave Design B
- PsychQuant/che-word-mcp#41 — sequential insert crash investigation
- Phase A + B + C + D of [`che-word-mcp-insert-crash-autosave-fix`](https://github.com/PsychQuant/macdoc/tree/main/openspec/changes/che-word-mcp-insert-crash-autosave-fix) Spectra change

## [3.6.0] - 2026-04-23

### Added — Autosave + checkpoint + recover_from_autosave (closes [#37](https://github.com/PsychQuant/che-word-mcp/issues/37))

`save_document` is the only durability checkpoint pre-v3.6.0 — accumulated in-memory edits between explicit saves are lost on MCP crash. v3.0.0's `autosave: true` flag wrote to the source path on every mutation (eager-save), which defeats post-crash recovery against externally-edited targets (e.g., Word.app saved newer content between sessions).

v3.6.0 introduces a per-mutation throttled checkpoint to a **separate file** (`<source>.autosave.docx`) plus an explicit `recover_from_autosave` tool. Caller sees the autosave file via `get_session_state.autosave_detected: true` and decides whether to recover; the server never auto-recovers on `open_document`.

### New MCP tools

```
checkpoint(doc_id, path?)
  → Manual snapshot. Writes current in-memory bytes to `path` (or
    `<source>.autosave.docx` by default). Does NOT clear is_dirty.

recover_from_autosave(doc_id, discard_changes?)
  → Replace in-memory state with bytes from `<source>.autosave.docx`.
    Refuses with E_DIRTY_DOC if session has uncommitted mutations
    unless discard_changes: true (mirrors close_document dirty-check).
    Sets is_dirty: true after recovery; autosave file persists until
    next successful save_document cleans it up.
```

### New `open_document` argument

```
autosave_every: Int = 0
  → 0 disables autosave (default, preserves pre-v3.6.0 behavior).
  → N > 0 → every Nth successful mutation triggers a checkpoint write
    to `<source>.autosave.docx`. Counter is per-session (resets on close).
```

### `get_session_state` response additions

```
autosave_detected: Bool      // true when <source>.autosave.docx exists
autosave_path: String?       // file path or "(none)"
```

### Cleanup semantics

- Successful `save_document` deletes `<source>.autosave.docx` if it exists
- Successful `finalize_document` does the same
- `checkpoint` and `recover_from_autosave` do NOT touch the cleanup logic

### Architecture

Per the SDD Decision (Phase 4): per-N-mutations is the simplest throttle that captures the stated incident pattern (12 mutations → 1 save). Time-based throttle (autosave every 30s) and WAL journal-based recovery were rejected as over-engineering for v1. Single overwriteable autosave file (no `<source>.autosave-<ts>.docx` rotation) keeps retention policy out of scope.

```swift
// Server.swift
private var autosaveEvery: [String: Int] = [:]      // 0 = disabled
private var autosaveCounter: [String: Int] = [:]    // increments per mutation

// In storeDocument(markDirty: true) — after the dictionary writes:
if let n = autosaveEvery[docId], n > 0,
   let sourcePath = documentOriginalPaths[docId] {
    let next = (autosaveCounter[docId] ?? 0) + 1
    autosaveCounter[docId] = next
    if next % n == 0 {
        try DocxWriter.write(doc, to: URL(fileURLWithPath: sourcePath + ".autosave.docx"))
    }
}
```

Both new dicts are actor-isolated stored properties — same concurrency safety as v3.5.4's actor refactor.

### Tests

- `AutosaveCheckpointTests.swift` (NEW) — 9 tests covering all 5 new spec requirements:
  - `testAutosaveEveryNthMutation` — N=3, 7 mutations, checkpoints at #3 and #6
  - `testAutosaveEveryZeroDisables` — 100 mutations, no autosave
  - `testSaveDocumentCleansUpAutosave` — autosave deleted on save success
  - `testCheckpointDefaultPath` — manual checkpoint to autosave path; is_dirty preserved
  - `testCheckpointExplicitPath` — manual checkpoint to arbitrary path; autosave path untouched
  - `testOpenDocumentDetectsExistingAutosave` — stale autosave file flagged
  - `testOpenDocumentReportsFalseAutosave` — false when no autosave
  - `testRecoverFromAutosaveReplacesSession` — 12-paragraph autosave replaces 1-paragraph session, is_dirty: true
  - `testRecoverFromAutosaveRefusedOnDirty` — E_DIRTY_DOC without discard_changes
- **93/93 che-word-mcp tests pass** (was 84 → +9).

### Compatibility

- **Additive API** — `autosave_every` defaults to 0 (disabled) so existing callers see no behavior change. `checkpoint` + `recover_from_autosave` are net-new tools (no existing call site to break).
- **Tool count** bumped from 171+ to **173+** (added `checkpoint` + `recover_from_autosave`).
- **No `ooxml-swift` change** — implemented entirely in che-word-mcp server layer.
- Universal binary (`x86_64 + arm64`) preserved.

### Refs

- This is **Phase 4 (final)** of the [`che-word-mcp-save-durability-stack`](https://github.com/PsychQuant/macdoc/tree/main/openspec/changes/che-word-mcp-save-durability-stack) Spectra change. Phases 1-3 closed in v3.5.3 / v3.5.4 / v3.5.5. SDD will be archived after this release.

## [3.5.5] - 2026-04-23

### Added — `keep_bak` opt-in for rollback escape hatch (closes [#38](https://github.com/PsychQuant/che-word-mcp/issues/38))

Pre-v3.5.5 `save_document` overwrote the target unconditionally. If a future save shipped silent OOXML damage (think v3.4.0 header strip, v3.5.0 rels regen), the original was permanently destroyed — no rollback path.

v3.5.3's atomic-rename save guarantees the target is never partial / zero-byte / absent, but it does NOT preserve the *previous-save* contents. `keep_bak` adds an opt-in escape hatch.

### Architecture

```swift
// che-word-mcp/Sources/CheWordMCP/Server.swift
private func persistDocumentToDisk(
    _ document: WordDocument, docId: String, path: String,
    keepBak: Bool = false   // NEW
) throws {
    let url = URL(fileURLWithPath: path)
    if keepBak, FileManager.default.fileExists(atPath: path) {
        let bakURL = url.appendingPathExtension("bak")
        if FileManager.default.fileExists(atPath: bakURL.path) {
            try FileManager.default.removeItem(at: bakURL)   // single-slot, no rotation
        }
        try FileManager.default.moveItem(at: url, to: bakURL)
    }
    try DocxWriter.write(document, to: url)   // atomic-rename (v3.5.3)
    // ... session state refresh (unchanged) ...
}
```

`save_document` MCP tool gains `keep_bak: bool` argument (default `false`):

```jsonc
{
  "name": "save_document",
  "arguments": {
    "doc_id": "thesis",
    "keep_bak": true     // optional, default false
  }
}
```

Per the SDD Decision (Phase 3): `.bak` lives at the **server layer**, NOT `ooxml-swift` — keeps `DocxWriter` unopinionated about file-system side effects so other consumers (e.g., `macdoc` CLI) don't get surprise `.bak` files.

### Behavior

- `keep_bak: true` + target exists → target moved to `<path>.bak` BEFORE atomic-rename save. Single-slot: any prior `.bak` is overwritten. User can `mv <path>.bak <path>` to roll back.
- `keep_bak: true` + target does not exist (first save) → no-op (nothing to back up).
- `keep_bak: false` (default) → no `.bak` side-effect (preserves pre-v3.5.5 behavior).
- `.bak` cleanup is the caller's responsibility — server never auto-deletes.

### Tests

- 80 baseline tests pass unchanged + 4 new `BakPreservationTests`:
  - `testKeepBakTruePreservesPreSaveBytes` — SHA256 of `.bak` matches original.
  - `testKeepBakDefaultOptOut` — no `.bak` when arg omitted.
  - `testConsecutiveSavesOverwriteBak` — second save's `.bak` matches first save's output, not original-original.
  - `testFirstTimeSaveNoBak` — fresh save with non-existent target produces no `.bak`.
- **84/84 che-word-mcp tests pass**.

### Compatibility

- **No API breaking change** — `keep_bak` is additive; default `false` matches pre-v3.5.5 behavior.
- **No `ooxml-swift` change** — fix is entirely in `che-word-mcp` server layer.
- Universal binary (`x86_64 + arm64`) preserved.

### Refs

- This is **Phase 3** of the [`che-word-mcp-save-durability-stack`](https://github.com/PsychQuant/macdoc/tree/main/openspec/changes/che-word-mcp-save-durability-stack) Spectra change. Phase 1 (#36) shipped in v3.5.3, Phase 2 (#39) in v3.5.4, Phase 4 (#37) follows.

## [3.5.4] - 2026-04-23

### Fixed — class → actor refactor for concurrency safety (closes [#39](https://github.com/PsychQuant/che-word-mcp/issues/39))

Pre-v3.5.4 `WordMCPServer` was declared as `class` with 8 unsynchronized `var` dictionary properties:

```swift
class WordMCPServer {
    internal var openDocuments: [String: WordDocument] = [:]
    private var documentOriginalPaths: [String: String] = [:]
    private var documentDirtyState: [String: Bool] = [:]
    private var documentAutosave: [String: Bool] = [:]
    private var documentTrackChangesEnforced: [String: Bool] = [:]
    private var documentDiskHash: [String: Data] = [:]
    private var documentDiskMtime: [String: Date] = [:]
    // ...
}
```

When parallel async tasks (e.g., 12 concurrent `insert_image_from_path` calls in the 2026-04-23 incident) all called `try await storeDocument(doc, for: docId)`, those tasks landed on different threads and mutated the same `Dictionary` hash table without synchronization → hash table corruption → MCP process crash during subsequent `save_document` (which tried to read the corrupted state).

v3.5.3's atomic-rename save prevented data loss when the crash hit, but the underlying race remained — closed by this actor refactor.

### Architecture

```swift
// v3.5.4+:
actor WordMCPServer { ... }   // compiler-enforced isolation
```

Properties:
- All 8 mutable dictionaries become **actor-isolated stored properties** — every cross-actor access requires `await` (compiler-checked at every call site).
- Same-actor calls (e.g., `await self.storeDocument(...)` from `insertImageFromPath`) do NOT introduce a suspension point — Swift's actor model optimizes them to synchronous calls. Read-mutate-write cycles within mutating handlers run atomically.
- MCP swift-sdk handlers are already `async throws`, so the signature change surface is small. Test helpers gain `await` at call sites.

### Reentrancy audit

Every `await self.<method>()` path in mutating handlers (`insertImageFromPath` → `storeDocument`, `saveDocument` → `persistDocumentToDisk`, `closeDocument` → `removeSession`, `openDocument` → `initializeSession`, `flushDirtyDocumentsOnShutdown` loop) was audited:

- All mutating handlers perform state mutations in a single synchronous block (no `await` between dictionary writes).
- `storeDocument` / `persistDocumentToDisk` are sync internally; `async throws` exists only for caller-side compatibility.
- No reordering needed — invariants trivially preserved.

### Tests

- 79 baseline tests pass unchanged + 1 new `ActorIsolationStressTests.testParallelInsertImageDoesNotCrash` (50 concurrent inserts × 5 iterations = 250 mutations against the same `doc_id`; asserts no crash + final image count == 50).
- ThreadSanitizer note: macOS Xcode/SwiftPM has a known bug loading TSan too late for `swift test -Xswiftc -sanitize=thread`. The actor model itself provides compile-time race-freedom; the stress test verifies behavior + state integrity. Pre-v3.5.4 reproduces the crash at as few as 12 concurrent inserts without any sanitizer.
- **80/80 che-word-mcp tests pass**.

### Compatibility

- **Public API** — all 146 MCP tools work identically; calls were already `async`.
- **Test helpers** — `isDocumentDirtyForTesting`, `isTrackChangesEnabledForTesting`, `imageCountForTesting` (NEW) require `await` from outside the actor. Updated `WordMCPServerTests.swift` + `SessionStateTests.swift` accordingly.
- Universal binary (`x86_64 + arm64`) preserved.

### Refs

- This is **Phase 2** of the [`che-word-mcp-save-durability-stack`](https://github.com/PsychQuant/macdoc/tree/main/openspec/changes/che-word-mcp-save-durability-stack) Spectra change. Phase 1 (#36 atomic save) shipped in v3.5.3. Phase 3 (#38 .bak) and Phase 4 (#37 autosave/checkpoint/recover) follow.

## [3.5.3] - 2026-04-23

### Fixed — Atomic-rename save in DocxWriter (closes [#36](https://github.com/PsychQuant/che-word-mcp/issues/36))

The 2026-04-23 incident (12 parallel `insert_image_from_path` + `save_document` → MCP crash → original 169KB docx replaced with 0-byte file) had the same root cause as a class of historical "save crash = data loss" reports: pre-v0.13.2 `DocxWriter.write` deleted the target file BEFORE computing the new bytes. Any throw or process kill between delete and write left the user with no recovery path.

### Resolution

v3.5.3 consumes [`ooxml-swift v0.13.2`](https://github.com/PsychQuant/ooxml-swift/releases/tag/v0.13.2) which refactors `DocxWriter.write(_:to:)` to the atomic-rename pattern:

1. Compute new bytes (overlay or scratch serialization).
2. Write bytes to `<url>.tmp.<UUID>` temp file.
3. `FileHandle.synchronize()` (fsync) to flush kernel buffers to disk.
4. `FileManager.replaceItemAt(url, withItemAt: tempURL, ...)` — POSIX `rename(2)` on same volume (kernel-atomic), copy+delete on cross-volume.
5. `defer { try? FileManager.removeItem(at: tempURL) }` cleans up on every exit path.

Properties:
- **Atomicity** — external observers see either full original or full new bytes at `url`, never partial / zero-byte / absent.
- **Throw-safe** — failure at any step (serialization, temp write, rename) leaves `url` byte-preserved.
- **fsync'd** — power loss after rename guarantees the new bytes are durable.

### Tests

- 79/79 che-word-mcp tests pass (no consumer-side regression).
- Underlying ooxml-swift v0.13.2 ships 397/397 tests including new `AtomicSaveTests` (6 tests) — headline test spins a concurrent observer thread polling `fileExists(atPath:)` during write; pre-v0.13.2 caught a window where the file was absent, v0.13.2 the observer never sees the gap.

### Compatibility

- **No source code changes** to che-word-mcp itself — fix is entirely in ooxml-swift dep.
- **No API change**: `DocxWriter.write` signature unchanged; semantic guarantee strictly stronger.
- Universal binary (`x86_64 + arm64`) preserved from v3.5.1.

### Refs

- This is Phase 1 of the [`che-word-mcp-save-durability-stack`](https://github.com/PsychQuant/macdoc/tree/main/openspec/changes/che-word-mcp-save-durability-stack) Spectra change. Phase 2 (#39 actor refactor), Phase 3 (#38 .bak preservation), Phase 4 (#37 autosave/checkpoint/recover) ship as subsequent releases.

## [3.5.2] - 2026-04-23

### Fixed — rels overlay merge preserves unknown rels types (closes [#35](https://github.com/PsychQuant/che-word-mcp/issues/35))

v3.5.0 + v3.5.1 closed [#23 round-2](https://github.com/PsychQuant/che-word-mcp/issues/23) at the **parts layer** (41/42 parts byte-equal on no-op round-trip) — but the **rels layer** still had two regressions:

**Root cause A** — `DocxReader.extractImages` was directory-driven: walked `word/media/` and used `targetToId[targetPath] ?? "rId_\(fileName)"` as fallback. The fallback produced ids like `rId_image1.png` violating the OOXML `rId[0-9]+` convention AND made `hasNewTypedRelationships` return true on no-op load → forced rels regeneration.

**Root cause B** — `writeDocumentRelationships` built rels **from the typed-model parts list only**. Original rels for **unknown types** (theme / webSettings / customXml / commentsExtensible / commentsIds / people) were silently dropped. After any legitimate edit (e.g., `addHeader`), NTPU theses lost theme inheritance + comment author identity even though parts were byte-preserved.

### Resolution

v3.5.2 consumes [`ooxml-swift v0.13.1`](https://github.com/PsychQuant/ooxml-swift/releases/tag/v0.13.1) which introduces:

1. **`RelationshipsOverlay`** — parallel to `ContentTypesOverlay` from v0.12.0. Parses original `word/_rels/document.xml.rels`; merges typed-model rels with preservation of unknown rel types.
2. **`writeDocumentRelationships` overlay-mode dispatch** — calls `RelationshipsOverlay.merge` in overlay mode; scratch mode preserves pre-v0.13.1 output.
3. **`extractImages` rewritten relationship-driven** — iterates `relationships.imageRelationships` (source of truth); tries multiple path normalizations; skips orphan rels rather than forge ids.

### Tests

- 79/79 che-word-mcp tests pass (no consumer-side regression).
- Underlying ooxml-swift v0.13.1 ships 391/391 tests including 3 new `RelationshipsOverlayTests` cases.

### Compatibility

- **No source code changes** to che-word-mcp itself — fix is entirely in ooxml-swift dep.
- **No API change**: `RelationshipsOverlay` is internal to ooxml-swift.
- **Behaviour change** (intended): no-op round-trip + edit round-trip both preserve unknown rels types. Callers who expected the lossy regenerate behavior — there are no known such callers.
- Universal binary (`x86_64 + arm64`) preserved from v3.5.1.

## [3.5.1] - 2026-04-23

### Fixed — universal binary (x86_64 + arm64)

v3.5.0 was shipped as **arm64-only** because the release-build step ran a single-arch `swift build -c release`. Intel Mac users (Mac Pro 2019, MacBook Pro 16" Intel, etc.) couldn't run the binary at all (`Bad CPU type in executable` from `exec`).

v3.5.1 follows the documented `mcp-deploy` Phase 1 workflow:

```bash
swift build -c release --arch arm64
swift build -c release --arch x86_64
lipo -create .build/arm64-apple-macosx/release/CheWordMCP \
              .build/x86_64-apple-macosx/release/CheWordMCP \
              -output mcpb/server/CheWordMCP
xattr -cr mcpb/server/CheWordMCP
codesign --force --sign - mcpb/server/CheWordMCP
```

Verified via `lipo -info`:

```
mcpb/server/CheWordMCP: Mach-O universal binary with 2 architectures: [x86_64:Mach-O 64-bit executable x86_64] [arm64]
```

### Compatibility

- **No source code changes** — same Server.swift / ooxml-swift v0.13.0 contract as v3.5.0.
- **Drop-in replacement**: existing `~/bin/CheWordMCP` (arm64) can be replaced via wrapper auto-download or manual `cp`. No config / API changes.
- All 79/79 tests still pass (no semantic change since v3.5.0).

## [3.5.0] - 2026-04-23

### Fixed — true byte-preservation via dirty tracking (closes [#23 round-2](https://github.com/PsychQuant/che-word-mcp/issues/23), [#32](https://github.com/PsychQuant/che-word-mcp/issues/32), [#33](https://github.com/PsychQuant/che-word-mcp/issues/33), [#34](https://github.com/PsychQuant/che-word-mcp/issues/34))

v3.3.0 + v3.4.0 closed [#23](https://github.com/PsychQuant/che-word-mcp/issues/23) at the **part-existence** level (preserve unknown parts byte-for-byte through `archiveTempDir` + `ContentTypesOverlay`), but the round-2 incident report showed the writer **still unconditionally re-emitted** every typed-managed part on every save. So a Reader-loaded NTPU thesis lost:

- 13 custom font declarations (`fontTable.xml` collapsed to a hardcoded 3-entry default)
- 6 distinct headers (all `.default` headers collapsed to `header1.xml` lookup)
- 4 distinct footers (same `.default` collapse)
- The verbose three-segment `<w:fldChar>` + `<w:instrText>PAGE</w:instrText>` PAGE field detection (only `<w:fldSimple>` matched)
- The full `<w15:presenceInfo>` person identity (only the `author` attribute survived; the GUID inside `userId="S::EMAIL::GUID"` was dropped)

after a single no-op `save_document` round-trip even though no typed mutation had occurred.

v3.5.0 fixes the architectural gap by consuming [`ooxml-swift v0.13.0`](https://github.com/PsychQuant/ooxml-swift/releases/tag/v0.13.0) which introduces:

1. `WordDocument.modifiedParts: Set<String>` — every mutating method instruments the corresponding part path; reader clears it as the final step
2. `Header.originalFileName` / `Footer.originalFileName` — preserves source archive paths so multi-instance same-type files don't collapse
3. `DocxWriter` overlay-mode skip-when-not-dirty — typed-part writers gated by `modifiedParts.contains(<part path>)`

### Server-side wiring (Task 2.2)

Every Server.swift archive-write helper now joins the dirty-tracking contract:

| Helper | New behavior |
|---|---|
| `writeThemeXML` | calls `doc.markPartDirty("word/theme/theme1.xml")` |
| `writeArchivePart` | calls `doc.markPartDirty(partPath)` |
| `deleteHeader` / `deleteFooter` | calls `doc.markPartDirty("[Content_Types].xml")` + `"word/_rels/document.xml.rels"` |
| `setDocumentProperties` | calls `doc.markPartDirty("docProps/core.xml")` (since `properties` is direct field assignment) |
| `updateNoteImpl` | calls `doc.markPartDirty("word/footnotes.xml" or "word/endnotes.xml")` (typed in-place mutation bypasses public methods) |

Without these, `save_document` overlay mode would skip re-emitting the touched parts.

### `<w15:presenceInfo>` parsing rewrite (closes [#34](https://github.com/PsychQuant/che-word-mcp/issues/34))

`extractPeople` was rewritten from single-attribute regex to a multi-line parser that captures the full `<w15:person>...</w15:person>` block including the nested `<w15:presenceInfo>` child. Extracted fields:

- `userId` triple-segment `S::EMAIL::GUID` decomposition (split on `::` with maxSplits=2)
- `providerId` (e.g., `AD`, `None`)
- optional `color`

`list_people` now returns dual-identity JSON entries:

```json
{
  "person_id": "<GUID, fallback to author>",
  "display_name_id": "<author, v3.4.0 legacy id>",
  "display_name": "<author>",
  "email": "<from userId middle>",
  "color": "...",
  "provider_id": "..."
}
```

`update_person` and `delete_person` accept **either** form — try GUID match first, fall back to author. Existing v3.4.0 callers continue to work unchanged.

### Detection helper strengthening (closes [#32](https://github.com/PsychQuant/che-word-mcp/issues/32) + [#33](https://github.com/PsychQuant/che-word-mcp/issues/33))

- `headerHasWatermark` adds `<v:shape ... o:spt="136">` regex co-detection alongside the existing `PowerPlusWaterMarkObject` substring match. Combined with the v0.13.0 `originalFileName` fix this means `list_watermarks` actually reads each header's distinct fileName instead of all looking up `header1.xml`.
- `footerHasPageNumber` now detects the verbose three-segment `<w:fldChar w:fldCharType="begin"/>` + `<w:instrText>PAGE</w:instrText>` + `<w:fldChar w:fldCharType="end"/>` pattern. Word emits this verbose form when the field caches results, so real-world footers were missed by the pre-v3.5.0 `<w:fldSimple>`-only regex.

### Tests

- 5 `PeoplePresenceInfoTests` — full presenceInfo + GUID/author dual-id update + delete via either identifier
- +4 multi-instance cases in `HeadersFootersToolsTests` — 3-header fixture proves `list_headers` returns 3 distinct entries, `list_watermarks` correctly identifies only header2, three-segment PAGE field detection works, editing header2 leaves headers 1+3 byte-equal
- +2 dirty-tracking proofs in `Phase2BCSmokeTests` — `update_web_settings` preserves fontTable byte-equal; `add_person` preserves all other typed parts byte-equal

**Total: 79 tests pass** (was 68; +11 v3.5.0 contract coverage).

### Migration: person_id semantic change

In v3.4.0 `list_people` returned `{"person_id": "<author>"}`. In v3.5.0 `person_id` is the GUID extracted from `<w15:presenceInfo w15:userId="S::email::GUID"/>`, **falling back to author** when the presenceInfo lacks the GUID form.

| Caller intent | v3.4.0 | v3.5.0 |
|---|---|---|
| Identify person stably across rename | use `person_id` (= author, broke on rename) | use `person_id` (= GUID, stable) |
| Identify person by display name | use `person_id` (= author) | use `display_name_id` (= author) — new field |
| Address person in update/delete | pass `person_id` (= author) | pass either `person_id` (GUID) or `display_name_id` (author) |

`update_person` / `delete_person` accept either form, so existing v3.4.0 callers passing the author string continue to work unchanged. Callers that want GUID-stable addressing should migrate to the new `person_id` field.

The v3.4.0 `person_id` semantic (= author) will be **removed in v4.0.0**. Until then, v3.5.0+ callers should prefer `display_name_id` for the legacy author identifier.

### Underlying architecture

[`ooxml-swift v0.13.0`](https://github.com/PsychQuant/ooxml-swift/releases/tag/v0.13.0) — full architectural details. 388/388 ooxml-swift tests pass.

## [3.4.0] - 2026-04-23

### Added — Phase 2B + 2C combined: comment threads + people + notes update + web settings (13 new MCP tools)

Combined release of Phase 2B + Phase 2C of [`che-word-mcp-ooxml-roundtrip-fidelity`](https://github.com/PsychQuant/macdoc/tree/main/openspec/changes/che-word-mcp-ooxml-roundtrip-fidelity). Closes [#24](https://github.com/PsychQuant/che-word-mcp/issues/24), [#25](https://github.com/PsychQuant/che-word-mcp/issues/25), [#29](https://github.com/PsychQuant/che-word-mcp/issues/29), [#30](https://github.com/PsychQuant/che-word-mcp/issues/30), [#31](https://github.com/PsychQuant/che-word-mcp/issues/31).

**Scope adjustment from spec**: Phase 2B and Phase 2C were originally scheduled as separate v3.4.0 + v3.5.0 releases for incremental user value. Implementations landed in one continuous SDD-apply session, so combining into a single v3.4.0 release saves users one upgrade cycle without losing functionality.

### Comment thread tools (closes #29)

| Tool | Purpose |
|---|---|
| `list_comment_threads` | Enumerate threads using typed `Comment.parentId` (populated from `commentsExtended.xml` at parse time); each entry has root_comment_id + replies[] + resolved + durable_id |
| `get_comment_thread` | Read root + walk children to build reply tree |
| `sync_extended_comments` | Report typed comment count for triplet sync planning (full triplet writeback is a Phase 2B+ refinement) |

### People tools (closes #30)

| Tool | Purpose |
|---|---|
| `list_people` | Parse `<w15:person>` entries from `word/people.xml` |
| `add_person` | Add new entry; auto-create `people.xml` part when absent; duplicate-name handling with `_2` suffix |
| `update_person` | Update display_name (author attribute swap) |
| `delete_person` | Remove entry; report `comments_orphaned` count |

### Notes update tools (closes #24 #25)

| Tool | Purpose |
|---|---|
| `get_endnote` / `get_footnote` | Read text + runs by integer ID |
| `update_endnote` / `update_footnote` | In-place replace, preserves note ID so `<w:endnoteReference>`/`<w:footnoteReference>` cross-references in `document.xml` stay valid |

### Web settings tools (closes #31)

| Tool | Purpose |
|---|---|
| `get_web_settings` | Parse `word/webSettings.xml` flag elements (`relyOnVML`, `optimizeForBrowser`, `allowPNG`, `doNotSaveAsSingleFile`); return `{ error: "no webSettings part" }` when absent |
| `update_web_settings` | Partial update by key; auto-create part if absent |

### Behavior notes

- **Comment thread metadata triplet sync** (`commentsExtended.xml` + `commentsExtensible.xml` + `commentsIds.xml`) is **partial** in this release. Existing `insert_comment`/`reply_to_comment`/`resolve_comment`/`delete_comment` writers still update only `comments.xml` + (for some paths) `commentsExtended.xml`. Full four-part triplet auto-sync is documented as a Phase 2B+ enhancement; users who need consistent extended metadata can call `sync_extended_comments` to verify state.
- **Person record auto-creation on `insert_comment`** is also a future refinement; for now, callers explicitly add person records via `add_person`.

### Tests

61 → 68 (+7 in `Phase2BCSmokeTests`):
- `list_comment_threads` on empty doc
- `sync_extended_comments` returns counts
- Full add → list → delete person round-trip
- Duplicate person name handling with suffix
- Unknown endnote ID error
- `get_web_settings` no-part error
- `update_web_settings` creates the part

### Out of scope (for a future v3.5.x or v4.0)

- Full four-part comment metadata triplet auto-sync inside existing comment write tools
- People record auto-creation when `insert_comment(author:)` references unknown author
- `commentsExtended.xml` parent/child writer refinement
- `commentsIds.xml` UUID-based durable ID generation on each write

## [3.3.0] - 2026-04-23

### Added — Phase 2A: theme + headers/footers/watermarks tools (12 new MCP tools)

Phase 2A of the [`che-word-mcp-ooxml-roundtrip-fidelity`](https://github.com/PsychQuant/macdoc/tree/main/openspec/changes/che-word-mcp-ooxml-roundtrip-fidelity) Spectra change. Closes [#26](https://github.com/PsychQuant/che-word-mcp/issues/26), [#27](https://github.com/PsychQuant/che-word-mcp/issues/27), [#28](https://github.com/PsychQuant/che-word-mcp/issues/28). Builds on v0.12.0 round-trip foundation.

**Theme tools** (`get_theme`, `update_theme_fonts`, `update_theme_color`, `set_theme`):
- Read/write `word/theme/theme1.xml` from preserved archive
- Partial-update major/minor font slots (latin/ea/cs)
- Slot-named color updates (accent1-6, hyperlink, followedHyperlink, dk1/lt1/dk2/lt2)
- Full-XML escape hatch for theme rewrites
- Solves NTPU thesis Chinese font fix: `update_theme_fonts(minor: { ea: "DFKai-SB" })` repairs the East-Asian font without touching other slots.

**Headers/Watermarks tools** (`list_headers`, `get_header`, `delete_header`, `list_watermarks`, `get_watermark`):
- Enumerate headers with type (default/first/even) + watermark detection
- Read header text + full XML + watermark structure
- Delete header part + tempDir file removal
- Watermark detection via `PowerPlusWaterMarkObject` shape ID + `o:spt="136"` sentinel
- Watermark text extraction via `<v:textpath string="...">` parsing

**Footers tools** (`list_footers`, `get_footer`, `delete_footer`):
- Enumerate footers with PAGE/NUMPAGES field detection
- Read footer text + full XML + parsed field structure (`<w:fldSimple>` + `<w:instrText>`)
- Delete footer part + tempDir file removal

### Changed — `add_header` / `update_header` / `add_footer` / `update_footer` use overlay-aware allocator

Via dependency bump to `ooxml-swift v0.12.2`, `WordDocument.nextRelationshipId` now reads `archiveTempDir`'s original `_rels/document.xml.rels` and uses `RelationshipIdAllocator` to compute collision-free `rId`s in overlay mode. Prior: naive `headers.count + footers.count` counter would collide with preserved unknown rels. Scratch mode behavior unchanged.

### Tests

49 → 61 tests (+12):
- `ThemeToolsTests` (6 tests): get_theme, partial font update, color slot update, invalid-slot rejection, set_theme malformed-XML rejection, no-theme-part error
- `HeadersFootersToolsTests` (6 tests): list_headers watermark detection, get_header XML+watermark, delete_header removal, list_watermarks text-watermark, list_footers page-number detection, get_footer PAGE field identification

### Dependencies

- `ooxml-swift` bumped from `^0.11.0` to `^0.12.0` (preserve-by-default round-trip), then patched via v0.12.1 (public archiveTempDir accessor) and v0.12.2 (overlay-aware nextRelationshipId)

### Out of scope (Phase 2B / 2C follow-up)

- Comment thread tools (`list_comment_threads`, `sync_extended_comments`, ...) — Phase 2B v3.4.0
- People tools (`list_people`, `add_person`, ...) — Phase 2B v3.4.0
- Notes update tools (`get_endnote`, `update_endnote`, `get_footnote`, `update_footnote`) — Phase 2C v3.5.0
- Web settings tools (`get_web_settings`, `update_web_settings`) — Phase 2C v3.5.0

## [3.2.0] - 2026-04-23

### Changed — `insert_equation` LaTeX parser delegates to new `latex-math-swift` package

Closes [#22](https://github.com/PsychQuant/che-word-mcp/issues/22) via the `che-word-mcp-latex-parser-expansion` Spectra change in `PsychQuant/macdoc/openspec/changes/`.

The previous in-source `parseLatexSubset` parser (`Server.swift:7253-7371`, 30-entry whitelist of Greek + symbols + the macros `\frac` and `\sqrt`) is replaced by delegation to `LaTeXMathSwift.LaTeXMathParser.parse(_ latex: String) throws -> [MathComponent]`. This dramatically expands the macro coverage and resolves the long-standing schema-vs-implementation drift.

**New macro coverage** (full list in `latex-math-swift` README):

- `\frac{a}{b}`, `\sqrt{a}`, `\sqrt[n]{a}`
- Structural sub/superscript `a_{b}`, `a^{b}`, `a_{b}^{c}`, `a^{c}_{b}` — both orderings normalize to the same `<m:sSubSup>` element editable in MS Word
- Accents `\hat{x}`, `\bar{x}`, `\tilde{x}`, `\dot{x}`, `\overline{x}` → emit `<m:acc>` (depends on new ooxml-swift 0.11.0 `MathAccent` type)
- Delimiter pairs `\left(...\right)`, `\left[...\right]`, `\left\{...\right\}`, `\left|...\right|`, `\left\|...\right\|`
- N-ary operators with bounds `\sum_{a}^{b}`, `\int_{a}^{b}`, `\prod_{a}^{b}` (and bare versions without bounds)
- Function names `\ln`, `\sin`, `\cos`, `\tan`, `\log`, `\exp`, `\max`, `\min`, `\det` followed by `(...)` argument
- Limit forms `\sup_{x}`, `\inf_{x}`, `\lim_{x \to 0}`
- Plain-text-in-math via `\text{...}`
- All ECMA-376 §22.1.2.93 lowercase + uppercase Greek letters plus variants (`\varepsilon`, `\vartheta`, `\varphi`, `\varpi`, `\varrho`, `\varsigma`)
- Common operators `\cdot`, `\times`, `\pm`, `\mp`, `\sim`, `\approx`, `\neq`, `\le`, `\ge`, `\to`, `\infty`, `\partial`, `\nabla`, `\cdots`, `\ldots`, `\mid`, `\quad`, `\,`

### Behavior expansion (review before upgrading)

Equations that previously returned `unrecognized token` errors now succeed. This is the explicit purpose of the change, but callers SHOULD audit any test fixtures that asserted on the *failure* of specific tokens (e.g., `\Delta`, `\hat`, `\varepsilon`, `\sup`, `\left`, `\ln` as standalone token) and update them to expect the new successful path.

### Schema description rewrite

The MCP `tools/list` schema for `insert_equation`'s `latex` parameter is rewritten to enumerate the accurate supported macro families (see `Server.swift:2153`). The previous misleading "narrow subset" summary is removed. LLM tool-use prompts that cached the old description will see updated guidance on next `tools/list` call.

### Tests

49/49 XCTest cases pass (was 45). The 4 new tests in `Tests/CheWordMCPTests/InsertEquationGoldenTests.swift` cover all 18 thesis fixture equations from issue #22 with three layers of verification (parse, OMML element coverage, OMMLParser round-trip).

### Out of scope (Phase 2 / Phase 3 follow-up)

- Pandoc-equivalent token coverage (`\overset`, `\underset`, `\begin{matrix}`, `\stackrel`, `\xrightarrow`, etc.) — deferred to a follow-up issue.
- Per-token `components:` JSON snippet hint embedded in error messages (issue #22 Option C) — useful UX but orthogonal; deferred.
- `che-pptx-mcp` adoption of `latex-math-swift` — separate change opened when PPTX equation tooling is prioritized.

### Dependencies

- `ooxml-swift` bumped to `^0.11.0` (adds `MathAccent`)
- New: `latex-math-swift ^0.1.0` (https://github.com/PsychQuant/latex-math-swift)

## [3.1.0] - 2026-04-22

### Added — 9 readback MCP tools (Caption CRUD + update_all_fields + Equation CRUD)

Closes [#17](https://github.com/PsychQuant/che-word-mcp/issues/17), [#19](https://github.com/PsychQuant/che-word-mcp/issues/19), [#21](https://github.com/PsychQuant/che-word-mcp/issues/21) via the `word-mcp-readback-primitives` Spectra change.

Built on new ooxml-swift 0.10.0 primitives (`FieldParser`, `OMMLParser`, `WordDocument.updateAllFields()`) that close the "write-side only" gap from v2.0.0. All 9 tools are thin MCP serialization layers over those parsers.

**Caption CRUD** (#17):
- `list_captions` — enumerate caption paragraphs with label / sequence_number / caption_text / paragraph_index.
- `get_caption` — detailed single caption info including optional `chapter_number` from STYLEREF.
- `update_caption` — modify caption text or label without breaking the SEQ field structure.
- `delete_caption` — remove caption paragraph (hint user to `update_all_fields` for renumbering).

**F9-equivalent** (#19):
- `update_all_fields` — recompute SEQ counters across body + headers + footers + footnotes + endnotes. Supports chapter-reset when `pStyle=="Heading N"` matches SEQ `resetLevel`. Non-SEQ fields (IF/DATE/PAGE/REF/etc.) preserved verbatim. Returns per-identifier final counts.

**Equation CRUD** (#21):
- `list_equations` — enumerate `<m:oMath>` runs with display_mode flag.
- `get_equation` — detailed single equation info with component summary.
- `update_equation` — replace target equation's components tree.
- `delete_equation` — remove equation run or empty paragraph.

### Internal changes

- `Server.swift`: changed `openDocuments` / `isDirty` / `storeDocument` from `private` to `internal` to allow the new `ReadbackTools.swift` extension to reach them. No external API impact.
- New file `ReadbackTools.swift` (~350 lines) houses the 9 handlers.

### Depends on

- ooxml-swift 0.10.0+

### Not in scope

- Full JSON→MathComponent parser for `update_equation` (minimal round-trip; equivalent to insert_equation's `components:` path). Advanced cases round-trip via `UnknownMath`.
- IF / DATE / PAGE field evaluation in `update_all_fields` — only SEQ counters recomputed.
- Integration tests for the 9 handlers — foundation tests (40 XCTest cases covering FieldParser/OMMLParser/updateAllFields) provide the guarantee. MCP-level integration tests deferred.

## [3.0.0] - 2026-04-22

### Added — session state API

Closes [#12](https://github.com/PsychQuant/che-word-mcp/issues/12), [#13](https://github.com/PsychQuant/che-word-mcp/issues/13), [#15](https://github.com/PsychQuant/che-word-mcp/issues/15) via the `word-mcp-session-lifecycle` Spectra change.

Four new MCP tools + a new `SessionState` module give explicit visibility and control over the in-memory / disk state:

- **`get_session_state`** — snapshot of `{ source_path, disk_hash_hex, disk_mtime_iso8601, is_dirty, track_changes_enabled }`. Superset of `get_document_session_state` (which is preserved for backward compat).
- **`revert_to_disk`** — re-read source path, discard in-memory edits, reset dirty flag. Destructive-by-design, no force flag needed.
- **`reload_from_disk`** — cooperative reload that requires `force: true` on a dirty doc. Picks up external editor changes while protecting unsaved work.
- **`check_disk_drift`** — informational check returning `{ drifted, disk_mtime, stored_mtime, disk_hash_matches }`. Never errors unless `doc_id` missing.

Internals: 2 new parallel maps `documentDiskHash` / `documentDiskMtime` track SHA256 hash + mtime of source file; refreshed on `open_document` and `persistDocumentToDisk`. `SessionState` module (`Sources/CheWordMCP/SessionState.swift`) exposes `computeSHA256`, `readMtime`, `checkDriftStatus` helpers + `SessionStateView` struct. 15 new XCTest cases.

### Changed (BREAKING)

- **`open_document`**: `track_changes` default flipped from implicit-true to explicit-`false`. Callers who want tracked edits must now pass `track_changes: true`. Rationale: majority of scripted workflows (R→Word, batch replace, thesis caption renumber) want clean edits; track-changes-on-default was a review-workflow artifact. Closes [#13](https://github.com/PsychQuant/che-word-mcp/issues/13).
- **`close_document`**: new `discard_changes: Bool = false`. When the doc is dirty and `discard_changes` is false/absent, returns an error message containing `E_DIRTY_DOC` listing three recovery paths (`save_document` / `discard_changes: true` / `finalize_document`). Previously the dirty check raised a generic "unsaved changes" error; now the response is machine-parseable and action-oriented. Closes [#12](https://github.com/PsychQuant/che-word-mcp/issues/12).

### Migration

```
# 2.x — implicit track-changes-on
open_document(path, doc_id)

# 3.x — pass track_changes: true to preserve 2.x behavior
open_document(path, doc_id, track_changes: true)
```

```
# 2.x — dirty close raised invalidParameter error
close_document(doc_id)  # → error "unsaved changes"

# 3.x — dirty close returns text response with E_DIRTY_DOC
close_document(doc_id)  # → "Error: E_DIRTY_DOC ..."
close_document(doc_id, discard_changes: true)  # → closes without save
```

### Not in scope (follow-up candidates)

- Multi-session concurrent editing / locking
- Undo/redo beyond `revert_to_disk`
- FSEvents-based file watching (drift detection is lazy by design)
- Diff-display in `check_disk_drift` response (just reports booleans + timestamps)
- Partial reload (`reload_from_disk` is all-or-nothing)

## [2.3.0] - 2026-04-22

### Added — text-anchor compound tool

Closes [#14](https://github.com/PsychQuant/che-word-mcp/issues/14). Eliminates the `search_text + insert_*` 2-call pattern by adding text-anchor parameters to insertion tools. A workflow that previously required 84 RPCs (Gao thesis: 12 images + 11 tables + 19 equations, each 2 calls for search + insert) can now be done in 42.

- **`insert_caption`** now accepts 5 anchor types (up from 3): `paragraph_index` | `after_image_id` | `after_table_index` | `after_text` | `before_text`. `text_instance: integer` (1-based, default 1) disambiguates when same phrase appears multiple times.

- **`insert_image_from_path`** now accepts `after_text` / `before_text` / `text_instance` in addition to `index` and `into_table_cell`.

- **Under the hood**: both handlers use new `InsertLocation.afterText(String, instance: Int)` and `.beforeText(...)` cases from ooxml-swift 0.9.0. Match is `substring contains` on flattened run text (cross-run safe, same algorithm as v2.0.0 `TextReplacementEngine`).

### Error handling

- **Text not found** → `Error: text 'X' not found (instance N)` with explicit search text + instance number. Fail fast, no fallback.
- **Multiple anchors provided** → `Error: exactly one of paragraph_index / after_image_id / after_table_index / after_text / before_text must be provided`.

### Depends on

- ooxml-swift 0.9.0+ (adds `.afterText` / `.beforeText` cases and `InsertLocationError.textNotFound`).

### Not in scope (follow-up)

- Regex / case-insensitive `after_text` matching (v1 is exact substring)
- Multi-paragraph-span matching
- `insert_paragraph` text-anchor support (schema exists but that tool isn't part of this bump)

## [2.2.0] - 2026-04-22

### Added — batch API tools

Two new MCP tools to reduce per-call round-trip for bulk operations (e.g., thesis caption renumber, which previously required 26+ separate `replace_text` calls). Closes [#18](https://github.com/PsychQuant/che-word-mcp/issues/18).

- **`replace_text_batch`** — args `{ doc_id, replacements: [{find, replace, scope?, regex?, match_case?}], stop_on_first_failure?: bool, dry_run?: bool }`. Sequential application (each item sees previous items' results). Single `storeDocument` at end (vs N saves for N `replace_text` calls). `dry_run: true` skips disk write (in-memory doc still mutated; caveat in schema).
- **`search_text_batch`** — args `{ doc_id | source_path, queries: [string | { query, case_sensitive? }] }`. Loops existing `search_text` handler per query, aggregates results into single response. Works in both Direct Mode and Session Mode.

### Semantics notes

- **Sequential ordering**: documented in `replace_text_batch` schema. Batch `[A→B, B→C]` applied in order results in `C` (not `B`).
- **Non-atomic**: per-item failures (invalid regex) reported in aggregate response; already-applied items stay applied. Use `stop_on_first_failure: true` to halt.
- **Per-item options** override: each replacement entry can set its own `scope` / `regex` / `match_case`.

### Not in scope (follow-up issues may address)

- True single-pass `TextReplacementEngine` batch API (current implementation loops `Document.replaceText`, still O(N · docSize))
- `dry_run` undo of in-memory mutation (current: only skips disk write; caller must `open_document` again to reset)

## [2.1.0] - 2026-04-22

### Fixed — MCP tool schemas expose v2.0.0 params

v2.0.0 rewrote the 4 tool handlers to accept new params (Chinese labels, `after_image_id`, `components`, `into_table_cell`, `scope`, `regex`, etc.) but **did not update the `inputSchema` JSON advertised via `tools/list`**. Result: Claude Code / Claude Desktop clients saw the OLD schema, never sent the new params, and the new handler branches never fired. This release corrects the schemas so v2.0.0 features are actually reachable.

Schema updates:

- **`insert_caption`**: `label` description lists all six valid values (`Figure` / `Table` / `Equation` / `圖` / `表` / `公式`). `paragraph_index` now optional; added `after_image_id: string` + `after_table_index: integer` (three-way anchor choice enforced in handler). Required reduced to `doc_id` + `label`.

- **`insert_equation`**: New `components: object` primary path (described with `type` discriminator + shape of `run` / `fraction` / `radical` / `subSuperScript` / `nary`). `latex` narrowed to subset-only fallback in description. Required reduced to `doc_id` only (must supply one of `components` / `latex`, enforced in handler).

- **`insert_image_from_path`**: `width` + `height` removed from `required` (auto-aspect supported). Added `into_table_cell: object` (shape `{ table_index, row, col }`). Required reduced to `doc_id` + `path`.

- **`replace_text`**: `all` removed from schema. Added `scope: string` (`body` | `all`), `regex: boolean`, `match_case: boolean`. Cross-run matching now described in the tool description.

### Infrastructure

No changes to internal engines — v2.0.0's `TextReplacementEngine`, `MathComponent` AST, `ImageDimensions`, `FieldCode` extensions, `InsertLocation` enum remain identical. This is strictly an MCP schema expose fix.

### Migration from 2.0.0

No code changes required. Clients that pulled v2.0.0 will start receiving the new `inputSchema` after the MCP server is restarted (or the plugin wrapper auto-downloads the v2.1.0 binary via version-aware check, shipped in plugin marketplace 2.0.1+).

## [2.0.0] - 2026-04-22

### Changed (BREAKING) — word-mcp-insertion-primitives Spectra change

Four MCP tools rewritten on new ooxml-swift 0.8.0 primitives. Closes [#6](https://github.com/PsychQuant/che-word-mcp/issues/6) (Phase 1-2), [#7](https://github.com/PsychQuant/che-word-mcp/issues/7) (fully), [#8](https://github.com/PsychQuant/che-word-mcp/issues/8) (Gaps A+D), [#9](https://github.com/PsychQuant/che-word-mcp/issues/9) (Phase 1-3).

- **`insert_caption` — now emits a real OOXML SEQ field**. The previous version wrote literal `{ SEQ Figure \* ARABIC }` characters into the docx; Word rendered those 23 characters verbatim. This release uses `SequenceField` (conforming to `FieldCode`) to emit proper `<w:fldChar>` begin/separate/end XML. Captions auto-number when Word opens the file and the user presses F9.
  - **New**: accepts Chinese labels `圖`, `表`, `公式` (plus English `Figure`, `Table`, `Equation`).
  - **New**: accepts exactly one of `paragraph_index` / `after_image_id` / `after_table_index` as the anchor (previously only `paragraph_index`).
  - **New**: `include_chapter_number: true` now emits a real `STYLEREF` field via `StyleRefField`, followed by `-`, then the `SEQ` field.

- **`insert_equation` — now emits structurally correct OMML**. The previous version passed LaTeX to `MathEquation` which did string substitution. This release introduces a `MathComponent` AST with nine types.
  - **New primary path**: `components:` argument — a JSON tree with `type` discriminators (`run`, `fraction`, `radical`, `subSuperScript`, `nary`).
  - **Narrowed `latex:` path**: limited to a documented subset (`\frac{a}{b}`, `\sqrt{a}`, `x^{y}`, `x_{y}`, Greek letters, ∑/∫/∏/·/×/±). Unrecognized tokens return an error naming the first bad token and referring callers to `components:`.

- **`insert_image_from_path` — width/height now optional, table-cell support added**.
  - **New**: one or both of `width` / `height` may be omitted; missing dimension auto-computed from the image's native pixel aspect ratio via `ImageDimensions.detect` (supports PNG, JPEG).
  - **New**: `into_table_cell: { table_index, row, col }` argument inserts the image as a paragraph inside the specified cell.

- **`replace_text` — now cross-run safe, with scope and regex options**. Previous per-run `contains(find)` matching failed silently across run boundaries (the thesis-workflow pain point in #7). New flatten-then-map algorithm.
  - **New**: cross-run matches succeed. Replacement text inherits the start run's formatting.
  - **New**: `scope: "body" | "all"` (default `"body"`). `"all"` scans headers, footers, footnotes, endnotes.
  - **New**: `regex: Bool` (default `false`) with `$1..$N` backreferences.
  - **Removed**: `all: Bool` argument. Behavior now always "replace all occurrences".

### Depends on

- ooxml-swift 0.8.0+ (was 0.5.6+).

## [1.19.0] - 2026-04-15

### Added (manuscript-review-markdown-export change in PsychQuant/macdoc)

- **New tools** — `export_revision_summary_markdown`, `compare_documents_markdown`, `export_comment_threads_markdown` (per-doc summary, multi-doc cumulative timeline, comment threading with author alias normalization). Closes [PsychQuant/che-word-mcp#2](https://github.com/PsychQuant/che-word-mcp/issues/2) [#3](https://github.com/PsychQuant/che-word-mcp/issues/3) [#4](https://github.com/PsychQuant/che-word-mcp/issues/4).
- **`AuthorAliasMap` helper** — shared canonicalization map used by the new comment-threading and timeline tools (e.g., `kllay's PC` → `Lay`).
- **ooxml-swift `WordDocument.getCommentsFull()`** — additive API returning the complete `Comment` struct including `parentId` for reply threading. Existing `getComments()` tuple API unchanged.

### Changed (BREAKING)

- **`get_revisions` and `compare_documents`** — `full_text: Bool = false` parameter REMOVED, replaced by `summarize: Bool = false` with INVERTED default. Default behavior now returns complete text with no upper bound. Pass `summarize: true` to elide individual entries longer than 5000 chars (head 30 + ` [...] ` + tail 30). Closes [PsychQuant/che-word-mcp#5](https://github.com/PsychQuant/che-word-mcp/issues/5).
  - **Migration**: callers passing `full_text: true` should remove the argument (default is now complete). Callers passing `full_text: false` should replace with `summarize: true`. The MCP server rejects `full_text` with an `invalidParameter` error pointing to the new parameter name.
  - **Rationale**: silent data loss via default truncation is harder to debug than context-window overflow. LLM callers can re-invoke with `summarize: true` if they hit context limits.
  - **Policy applies to**: all current and future che-word-mcp tools that return potentially long text. The `truncateText` internal helper now centrally enforces the 5000-char threshold.

### Notes

- This entry tracks Spectra change [`manuscript-review-markdown-export`](https://github.com/PsychQuant/macdoc/tree/main/openspec/changes/manuscript-review-markdown-export) in PsychQuant/macdoc, which advances umbrella tracking issue [PsychQuant/macdoc#75](https://github.com/PsychQuant/macdoc/issues/75).

## [1.18.0] - 2026-04-14

### Fixed
- **`get_revisions` — hardcoded `prefix(30)` truncation** — Original and new revision text was truncated to the first 30 characters with `...` appended, regardless of actual length. Long insertions (e.g., entire rewritten paragraphs in Word track changes) were unreadable from the tool output; short revisions (e.g., adding an `s` suffix) had misleading `...` appended. The underlying OOXML parser always captured the full run text — the truncation was purely a display-layer bug present since v1.2.0. Fixed by routing through the existing `truncateText()` helper with a 500-character default. ([#1](https://github.com/PsychQuant/che-word-mcp/issues/1))

### Added
- **`get_revisions` — `full_text` parameter** — Opt-in flag to disable truncation entirely. When `full_text: true`, revision text is returned verbatim regardless of length. Default remains `false` (500-character head/tail summary) to protect LLM context from runaway insertions. ([#1](https://github.com/PsychQuant/che-word-mcp/issues/1))

### Changed
- **`get_revisions` — output format** — Short revisions (≤ 500 chars) now return the full text with no `...` appended. Long revisions return `<first 30 chars> [...] <last 30 chars>` via `truncateText()`, matching the format used elsewhere in the codebase (heading/compare diff output). This is a breaking change for callers that depended on the literal `prefix(30)...` output.

## [1.17.0] - 2026-03-11

### Added
- **Session State Management** — Track dirty state, autosave, and track changes enforcement per document (contributed by [@ildunari](https://github.com/ildunari))
- **`finalize_document`** — Save and close in one guarded step, reusing original path when available
- **`get_document_session_state`** — Inspect session state (dirty, autosave, track changes, save/close readiness)
- **`autosave` parameter** — `open_document` and `create_document` now accept `autosave: true` for auto-persist after each edit
- **Shutdown flush** — Server auto-saves dirty documents with known paths on shutdown
- **Duplicate docId guard** — `create_document` and `open_document` reject reusing an already-open docId
- **Track changes by default** — Documents opened/created automatically enable track changes
- **Unit tests** — 12 tests covering session state, dirty tracking, autosave, finalize, and shutdown flush

### Changed
- `save_document` — `path` is now optional; reuses original opened path when omitted
- `close_document` — Blocks closing documents with unsaved changes (use `save_document` first or `finalize_document`)
- Total tool count: 146 → 148

## [1.16.0] - 2026-03-10

### Added
- **Dual-Mode Access** — 15 read-only tools now support both `source_path` (Direct Mode) and `doc_id` (Session Mode): `get_document_info`, `get_paragraphs`, `list_images`, `list_styles`, `get_tables`, `list_comments`, `list_hyperlinks`, `list_bookmarks`, `list_footnotes`, `list_endnotes`, `get_revisions`, `get_document_properties`, `search_text`, `get_word_count_by_section`, `get_section_properties`
- **MCP Server Instructions** — Server now returns structured instructions during `initialize` handshake, helping AI agents understand Direct Mode vs Session Mode usage patterns
- **`resolveDocument` helper** — Internal helper for dual-mode document resolution with lock file detection

### Improved
- Session-only tools (`insert_paragraph`, `save_document`, etc.) now include `（需先 open_document）` in description
- Dual-mode tools include `（支援 Direct Mode）` in description

## [1.15.2] - 2026-03-07

### Improved
- **list_all_formatted_text** — clarify tool description to explicitly list required `format_type` parameter values, reducing LLM misuse

## [1.15.1] - 2026-03-01

### Fixed
- **Heading Heuristic style fallback** — resolve fontSize and bold from paragraph style inheritance chain when runs don't have explicit formatting (fixes heuristic not triggering on real-world Word documents)

### Changed
- Upgrade `word-to-md-swift` 0.3.0 → 0.3.1

## [1.15.0] - 2026-03-01

### Added
- **Practical Mode: EMF→PNG auto-conversion** — non web-friendly image formats (EMF/WMF/TIFF/BMP) are automatically converted to PNG via AppKit during `export_markdown`
- **Practical Mode: Heading Heuristic** — statistically infers heading levels from font size distribution when documents lack Word Heading Styles (bold + short + larger-than-body → H1~H6)

### Changed
- Upgrade `word-to-md-swift` 0.2.0 → 0.3.0 (Practical Mode features)
- Upgrade `doc-converter-swift` 0.2.0 → 0.3.0 (`preserveOriginalFormat`, `headingHeuristic` options)
- Upgrade `ooxml-swift` 0.5.0 → 0.5.1 (EMF/WMF MIME type support)

## [1.14.0] - 2026-03-01

### Changed
- `export_markdown` switched from macdoc CLI delegation to embedded `word-to-md-swift` library
  - No external binary dependency (`~/bin/macdoc` no longer required)
  - Restored `doc_id` parameter: convert in-memory documents without saving to disk first
  - `source_path` still supported: direct .docx → Markdown conversion
  - Removed `marker` parameter (use macdoc CLI directly for Marker format)
  - Binary size impact: +1MB (32MB → 33MB)

### Added
- `word-to-md-swift` v0.2.0 as direct dependency (with `doc-converter-swift`, `markdown-swift`)

### Removed
- `MACDOC_PATH` environment variable support (no longer needed)
- macdoc CLI Process() delegation code

## [1.13.0] - 2026-03-01

### Changed
- Upgrade `ooxml-swift` 0.4.0 → 0.5.0 (parallel `parseBody` with multi-core)
  - Large documents parsed in parallel using `DispatchQueue.concurrentPerform`
  - 976K docx: ~1.8s → **~0.64s** (2.8x speedup, 47x vs original XPath)
  - Small documents (<200 elements) unaffected (serial path)

## [1.12.1] - 2026-03-01

### Changed
- Upgrade `ooxml-swift` 0.3.0 → 0.4.0 (XPath → children traversal performance fix)
  - Large documents (11K+ runs, e.g. 976K .docx) go from >30s hang to ~2.3s
  - Eliminates O(n²) XPath evaluation in `parseRun`, `parseDrawing`, `parseInlineDrawing`, `parseAnchorDrawing`

## [1.12.0] - 2026-02-28

### Changed
- `export_markdown` now uses `source_path` for direct .docx → Markdown conversion
  - No need to call `open_document` first — pass the file path directly
  - Removed `doc_id` parameter (was used for in-memory documents)
  - Added Word lock file (`~$`) detection — refuses conversion if file is open in Microsoft Word

## [1.11.1] - 2026-02-28

### Fixed
- Fix `export_markdown` stdout mode failing due to `fsync()` on pipe
  - Use temp file with `-o` flag instead of reading stdout pipe directly

## [1.11.0] - 2026-02-28

### Changed
- `export_markdown` now delegates to `macdoc` CLI instead of embedding `word-to-md-swift` library
  - Removes API mirroring burden (ConversionOptions changes no longer require MCP updates)
  - CLI uses streaming O(1) memory for large documents
  - Simplified parameters: `doc_id`, `path`, `marker`, `include_frontmatter`, `hard_line_breaks`
  - Removed `fidelity`, `figures_directory`, `metadata_output`, `use_html_extensions` (handled by macdoc)
  - Supports `MACDOC_PATH` environment variable for custom binary location

### Removed
- `word-to-md-swift` dependency (replaced by macdoc CLI delegation)
- `doc-converter-swift` transitive dependency

## [1.10.0] - 2026-02-28

### Changed
- Upgrade `export_markdown` with Tier 1-3 fidelity support:
  - `fidelity` parameter: `markdown` (default), `markdown_with_figures`, `marker`
  - `figures_directory`: image extraction for Tier 2+
  - `metadata_output`: lossless YAML sidecar for Tier 3
  - `include_frontmatter`, `use_html_extensions`, `hard_line_breaks` options
- Update MCP Swift SDK 0.10.2 → 0.11.0 (tool annotations, HTTP transport)
- Update `ooxml-swift` 0.2.0 → 0.3.0 (Equatable conformance, 179 tests)
- Update `word-to-md-swift` 0.1.0 → 0.2.0 (FigureExtractor, MetadataCollector, Tier 2/3)
- Update `doc-converter-swift` 0.1.0 → 0.2.0 (FidelityTier, extended ConversionOptions)

## [1.9.0] - 2026-02-28

### Changed
- `export_markdown` now uses `word-to-md-swift` library for significantly better Markdown output
  - Streaming architecture (O(1) memory)
  - Proper heading detection via semantic annotations
  - List detection (bullet + numbered) with nesting support
  - Table formatting with alignment
  - Inline styling (bold, italic, strikethrough, code)
  - Special character escaping
  - Optional YAML frontmatter
- Switched all dependencies from `path:` to `url:` remote dependencies
- Updated `ooxml-swift` to v0.2.0 (removed built-in `toMarkdown()`, now a clean OOXML parser)
- Updated description to reflect 145 tools

### Added
- `word-to-md-swift` v0.1.0 as new dependency for high-quality Word→Markdown conversion

## [1.8.0] - 2026-02-03

### Changed
- Remove `maxDiffs = 50` hard limit in `compare_documents` — full results returned by default (no irreversible truncation)
- Add `max_results` optional parameter (default 0 = unlimited) for caller-controlled diff limiting
- Add `heading_styles` optional parameter for custom heading style recognition in structure mode
- Improve structure mode heading detection with heuristic fallback (`keepNext` + short text, marked with `(?)`)
- Increase `truncateText` default from 200 to 500 characters

### Removed
- Hard-coded `maxDiffs = 50` truncation logic
- Old `.mcpb` and `.mcpb.zip` release artifacts from repository

## [1.7.0] - 2026-02-03

### Added
- `compare_documents` - Server-side document comparison with paragraph-level diff (total 105 tools)
  - Hash-based LCS algorithm for paragraph alignment
  - Four modes: `text` (default), `formatting`, `structure`, `full`
  - Smart MODIFIED detection via word-level Jaccard similarity (>50% threshold)
  - Context lines support (0-3 unchanged paragraphs around diffs)
  - ~90% token savings vs client-side diff with two `get_text_with_formatting` calls

### Changed
- Updated tool count from 104 to 105

## [1.6.0] - 2026-01-27

### Added
- New academic document analysis tools (total 104 tools):
  - `search_text_with_formatting` - Search text and display formatting at match positions (bold, italic, color markers)
  - `list_all_formatted_text` - List all text with specific formatting (e.g., all italic text, all bold text, specific color)
  - `get_word_count_by_section` - Word count by section with customizable markers (e.g., Abstract, Methods, References) and exclusion support

### Changed
- Updated tool count from 101 to 104

### Use Cases
- Academic paper review: quickly verify italic formatting for statistical terms
- Anonymization check: search for specific text and verify no highlighting remains
- Journal submission: count main text words excluding References section

## [1.5.0] - 2026-01-19

### Added
- `insert_image_from_path` - Insert image from file path (recommended for large images, avoids base64 transfer overhead)

### Changed
- Updated tool count from 100 to 101

### Fixed
- Fixed crash when inserting large images via base64 - now users can use file path instead

## [1.4.0] - 2026-01-18

### Added
- New image export tools (total 100 tools):
  - `export_image` - Export a single image to file by image ID
  - `export_all_images` - Export all images to a directory

### Changed
- Updated tool count from 98 to 100

## [1.3.0] - 2026-01-18

### Added
- New formatting inspection tools (total 98 tools):
  - `get_paragraph_runs` - Get all runs (text fragments) in a paragraph with formatting info (color, bold, italic, font size, etc.)
  - `get_text_with_formatting` - Get document text with Markdown-style format markers (**bold**, *italic*, {{color:red}}, etc.)
  - `search_by_formatting` - Search for text with specific formatting (e.g., find all red text, all bold text)
- Added `mcpb/PRIVACY.md` - Privacy policy documentation

### Changed
- Updated tool count from 95 to 98

## [1.2.1] - 2026-01-16

### Fixed
- Added missing `capabilities: .init(tools: .init())` to Server initialization
- This fixes the "Failed to connect" issue in Claude Code

## [1.2.0] - 2026-01-16

### Added
- New tools for enhanced document manipulation (total 95 tools):
  - `insert_text` - Insert text at specific position in paragraph
  - `get_document_text` - Alias for `get_text` with more intuitive naming
  - `search_text` - Search text and return all matching positions
  - `list_hyperlinks` - List all hyperlinks in document
  - `list_bookmarks` - List all bookmarks in document
  - `list_footnotes` - List all footnotes in document
  - `list_endnotes` - List all endnotes in document
  - `get_revisions` - Get all revision tracking records
  - `accept_all_revisions` - Accept all tracked changes at once
  - `reject_all_revisions` - Reject all tracked changes at once
  - `set_document_properties` - Set document metadata (title, author, etc.)
  - `get_document_properties` - Get document metadata

## [1.1.0] - 2026-01-16

### Fixed
- Fixed MCPB manifest.json format to comply with 0.3 specification
- Changed `author` from string to object format
- Changed `repository` from string to object format
- Removed unsupported fields: `id`, `platforms`, `capabilities`

## [1.0.0] - 2026-01-16

### Added
- Initial release with 83 MCP tools for Word document manipulation
- Complete OOXML support without Microsoft Word dependency
- Pure Swift implementation as single binary
- MCPB package for easy distribution

### Changed
- Refactored to use [ooxml-swift](https://github.com/PsychQuant/ooxml-swift) as external dependency
- Updated MCP SDK to 0.10.2

### Document Management
- `create_document`, `open_document`, `save_document`, `close_document`
- `list_open_documents`, `get_document_info`

### Content Operations
- `get_text`, `get_paragraphs`, `insert_paragraph`, `update_paragraph`
- `delete_paragraph`, `replace_text`

### Formatting
- `format_text`, `set_paragraph_format`, `apply_style`

### Tables
- `insert_table`, `get_tables`, `update_cell`, `delete_table`
- `merge_cells`, `set_table_style`

### Style Management
- `list_styles`, `create_style`, `update_style`, `delete_style`

### Lists
- `insert_bullet_list`, `insert_numbered_list`, `set_list_level`

### Page Setup
- `set_page_size`, `set_page_margins`, `set_page_orientation`
- `insert_page_break`, `insert_section_break`

### Headers & Footers
- `add_header`, `update_header`, `add_footer`, `update_footer`
- `insert_page_number`

### Images
- `insert_image`, `insert_floating_image`, `update_image`
- `delete_image`, `list_images`, `set_image_style`

### Export
- `export_text`, `export_markdown`

### Hyperlinks & Bookmarks
- `insert_hyperlink`, `insert_internal_link`, `update_hyperlink`
- `delete_hyperlink`, `insert_bookmark`, `delete_bookmark`

### Comments & Revisions
- `insert_comment`, `update_comment`, `delete_comment`, `list_comments`
- `reply_to_comment`, `resolve_comment`
- `enable_track_changes`, `disable_track_changes`
- `accept_revision`, `reject_revision`

### Footnotes & Endnotes
- `insert_footnote`, `delete_footnote`
- `insert_endnote`, `delete_endnote`

### Field Codes
- `insert_if_field`, `insert_calculation_field`, `insert_date_field`
- `insert_page_field`, `insert_merge_field`, `insert_sequence_field`
- `insert_content_control`

### Advanced Features
- `insert_repeating_section`, `insert_toc`
- `insert_text_field`, `insert_checkbox`, `insert_dropdown`
- `insert_equation`, `set_paragraph_border`, `set_paragraph_shading`
- `set_character_spacing`, `set_text_effect`
