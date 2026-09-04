# che-word-mcp

A Swift-native MCP (Model Context Protocol) server for Microsoft Word document (.docx) manipulation. This is the **first Swift OOXML library** that directly manipulates Office Open XML without any third-party Word dependencies.

[中文說明](README_zh-TW.md)

## Features

- **Pure Swift Implementation**: No Node.js, Python, or external runtime required
- **Direct OOXML Manipulation**: Works directly with XML, no Microsoft Word installation needed
- **Single Binary**: Just one executable file
- **234 MCP Tools**: Comprehensive document manipulation across documents, tables, hyperlinks, headers, sections, styles, numbering, content controls, comments, footnotes, equations, fields, and Track Changes
- **Office.js OOXML Roadmap P0 = 100%**: All eight P0 sub-issues closed (umbrella [#43](https://github.com/PsychQuant/che-word-mcp/issues/43)). Surface coverage is now competitive with Office.js for the read/write side of every P0 capability.
- **Round-trip silent corruption closed (v3.13.5, [#56](https://github.com/PsychQuant/che-word-mcp/issues/56))**: 5 sub-stack-completion rounds (R5 / R5-CONT / R5-CONT-2 / R5-CONT-3 / R5-CONT-4) closed 30 findings (16 P0 + 21 P1) across rounds 4-8 of 6-AI cross-verification. Bumps `ooxml-swift` to v0.19.5 (v0.19.4 held back per verify-gate). **No MCP source changes** — fix architecture lives entirely in `ooxml-swift`. Round 4 walker symmetry across headers/footers/footnotes/endnotes (`accept_revision` / `reject_revision` / `get_hyperlinks` / `replace_text` reach all parts). Round 5 per-container relationships round-trip (`update_hyperlink` URL sync targets owning part rels). Round 6 `delete_hyperlink` mirror + container `<w:tbl>` capture preserved. Round 7 `reject_revision` typed clearMarker (file/API state convergence). Round 8 `accept_revision` typed clearMarker (mirror) + matrix-pin asymmetry-guard removal + `Document.repairContainerFileNames` marks `document.xml.rels` + `[Content_Types].xml` dirty. Convergence: Devil's Advocate wrote 5 adversarial tests targeting the convergence-cycle pattern; all PASSED. See [closing summary](https://github.com/PsychQuant/che-word-mcp/issues/56#issuecomment-4322638865) and [v3.13.5 release notes](https://github.com/PsychQuant/che-word-mcp/releases/tag/v3.13.5).
- **Programmatic Track Changes (v3.12.0+, [#45](https://github.com/PsychQuant/che-word-mcp/issues/45))**: Generate Word-native reviewable redlines via `insert_text_as_revision` / `delete_text_as_revision` / `move_text_as_revision`, plus `as_revision: true` flag on `format_text` / `set_paragraph_format`. Emits `<w:ins>` / `<w:del>` / `<w:moveFrom>` / `<w:moveTo>` / `<w:rPrChange>` / `<w:pPrChange>` markup. Side-effect contract: `as_revision: true` requires track changes enabled; throws `track_changes_not_enabled` otherwise (no silent auto-enable). Author resolution: explicit arg → `revisions.settings.author` → `"Unknown"`.
- **Tables / Hyperlinks / Headers extensions (v3.11.0+, [#49](https://github.com/PsychQuant/che-word-mcp/issues/49) [#50](https://github.com/PsychQuant/che-word-mcp/issues/50) [#51](https://github.com/PsychQuant/che-word-mcp/issues/51))**: 16 new tools — table conditional styles (10 region types) / nested tables (max 5 deep) / explicit layout / table indent; three typed hyperlinks (URL / bookmark / email); even/odd header toggle / link-to-previous / `get_section_header_map`.
- **Styles + Numbering + Sections foundation (v3.10.0+, [#46](https://github.com/PsychQuant/che-word-mcp/issues/46) [#47](https://github.com/PsychQuant/che-word-mcp/issues/47) [#48](https://github.com/PsychQuant/che-word-mcp/issues/48))**: 19 new tools + 6 extended args — `get_style_inheritance_chain`, `link_styles`, `set_latent_styles`, `add_style_name_alias`, full Numbering CRUD lifecycle (definitions / overrides / list continuity / GC), section vertical alignment / page-number format / break-type / title-page distinction / per-section header references.
- **Content Controls (SDT) read/write (v3.9.0+, [#44](https://github.com/PsychQuant/che-word-mcp/issues/44))**: 7 new tools covering 12-type discrimination (richText / plainText / picture / date / dropDownList / comboBox / checkBox / bibliography / citation / group / repeatingSection / repeatingSectionItem). Nested SDT trees, deterministic max+1 SDT id allocator, `keep_content` unwrap on delete, whitelist-validated XML replacement.
- **Save Durability Stack (v3.5.3+)**: atomic-rename save ([#36](https://github.com/PsychQuant/che-word-mcp/issues/36)), actor-based concurrency safety ([#39](https://github.com/PsychQuant/che-word-mcp/issues/39)), `keep_bak` opt-in rollback ([#38](https://github.com/PsychQuant/che-word-mcp/issues/38)), `autosave_every` Design B pre-mutation snapshot with explicit `recover_from_autosave` ([#37](https://github.com/PsychQuant/che-word-mcp/issues/37), [#40](https://github.com/PsychQuant/che-word-mcp/issues/40) v3.7.0). Default `autosave_every: 1` (every mutation snapshots prior state). Pass `autosave_every: 0` to opt out.
- **Dual-Mode Access**: Direct Mode (read-only, one step via `source_path`) and Session Mode (full lifecycle via `doc_id`)
- **True Byte-preservation Round-trip Fidelity (v3.5.0+)**: `save_document` overlay mode uses `WordDocument.modifiedParts` dirty tracking — untouched typed parts (`document.xml`, `styles.xml`, `fontTable.xml`, `header*.xml`, `footer*.xml`, `comments.xml`, `footnotes.xml`, `endnotes.xml`) and unknown parts (`theme/`, `webSettings.xml`, `people.xml`, `commentsExtended/Extensible/Ids`, `glossary/`, `customXml/`) byte-for-byte preserved. NTPU thesis no-op `save_document` round-trip retains 13 fontTable entries + 6 distinct headers + 4 footers + three-segment PAGE field + `<w15:presenceInfo>` identity.
- **Theme + Header/Footer/Watermark CRUD (v3.3.0+)**: `word/theme/theme1.xml` editing, header/footer enumeration + deletion, watermark VML detection. NTPU thesis Chinese font fix path: `update_theme_fonts({ minor: { ea: "DFKai-SB" } })`.
- **Comment Threads + People + Notes Update + Web Settings (v3.4.0+)**: 13 tools for collaborative comment metadata, `people.xml` author records (dual identity: GUID + legacy author), in-place endnote/footnote editing (preserves IDs), `webSettings.xml` configuration.
- **Full LaTeX Subset for `insert_equation` (v3.2.0+)**: Delegated to [`latex-math-swift`](https://github.com/PsychQuant/latex-math-swift). Supports `\frac`, `\sqrt`, `\hat`/`\bar`/`\tilde` accents, `\left/\right` delimiters, `\sum`/`\int`/`\prod` n-ary with bounds, function names, limits, `\text{}`, all Greek letters (including `\varepsilon` variants), and common operators.
- **Text-Anchor Insertion**: Insert captions / images relative to matched text (`after_text` / `before_text`), no pre-search call required
- **Batch Operations**: `replace_text_batch` / `search_text_batch` collapse N round-trips into one
- **Session State API**: SHA256 + mtime-based disk drift detection, `revert_to_disk` / `reload_from_disk` / `check_disk_drift`
- **Structural Readback**: `list_captions` / `list_equations` / `update_all_fields` (F9-equivalent) for manuscript review workflows
- **Cross-platform**: Works on macOS (universal binary `x86_64 + arm64` since v3.5.1)

## Version History

| Version | Date | Changes |
|---------|------|---------|
| **v4.0.0** | 2026-08-19 | **`execute_script` 契約修正（breaking）** — 驗證失敗改為 tool error（[#180](https://github.com/PsychQuant/che-word-mcp/issues/180)）；新增 `overwrite` 參數且**預設拒絕**覆寫既有 `output_path`（[#181](https://github.com/PsychQuant/che-word-mcp/issues/181)）。覆寫閘移進 ooxml-swift 的共用入口 `scriptPipelineExecute`，兩面由結構取得保護；重建結果改為寫同目錄暫存路徑、驗過才搬進位，所以驗證失敗不再破壞輸出路徑。需 ooxml-swift 3.0.1。5-lens verify（Codex leg 因配額未執行，已記錄）。 |
| **v3.22.0** | 2026-07-18 | **Self-produced docx upgrades to typed DSL** (closes-via-idd [#173](https://github.com/PsychQuant/che-word-mcp/issues/173), PR [#174](https://github.com/PsychQuant/che-word-mcp/pull/174)). Bumps ooxml-swift 1.4.0 → 1.5.0 (upstream [ooxml-swift#85](https://github.com/PsychQuant/ooxml-swift/issues/85): transcoder-canonical authoring — stamped `w14:paraId`, no inter-element whitespace, full Word-canonical root cloud). `export_script` on MCP-authored pure-paragraph docs now reports `document.xml` on the `dsl` channel (ratio 1.0); `slots` anchor on stamped paraIds. Part-level boundary documented in tool descriptions: rich tables / legacy paraId-less content demote the whole part to raw pending [ooxml-swift#86](https://github.com/PsychQuant/ooxml-swift/issues/86). Consumer regression `Issue173SelfProducedDSLUpgradeTests` (RED on 1.4.0 / GREEN on 1.5.0). 6-AI verify PASS. |
| **v3.13.5** | 2026-04-27 | **R5 stack-completion** (closes [#56](https://github.com/PsychQuant/che-word-mcp/issues/56) silent corruption). Bumps ooxml-swift v0.19.3 → v0.19.5 (v0.19.4 held back per verify-gate). 30 findings closed (16 P0 + 21 P1) across 5 sub-stacks (R5 / R5-CONT / R5-CONT-2 / R5-CONT-3 / R5-CONT-4) and rounds 4-8 of 6-AI cross-verification. **Round 4** walker symmetry across headers/footers/footnotes/endnotes (`accept_revision` / `reject_revision` / `get_hyperlinks` / `replace_text` reach all parts). **Round 5** per-container relationships round-trip (`update_hyperlink` URL sync targets owning part rels). **Round 6** `delete_hyperlink` mirror + container `<w:tbl>` capture preserved. **Round 7** `reject_revision` typed clearMarker (file/API state convergence). **Round 8** `accept_revision` typed clearMarker (mirror) + matrix-pin asymmetry-guard removal + `repairContainerFileNames` rels-dirty. Convergence: Devil's Advocate wrote 5 adversarial tests targeting the convergence-cycle pattern; all PASSED. **No che-word-mcp source changes** — entire fix architecture in ooxml-swift. See [closing summary](https://github.com/PsychQuant/che-word-mcp/issues/56#issuecomment-4322638865). |
| v3.13.4 | 2026-04-26 | **(skipped — held back per verify-gate)**. R3 stack content rolled into v3.13.5. |
| v3.13.3 | 2026-04-26 | Bumps ooxml-swift v0.19.2 → v0.19.3. Closes 8 P0 + 3 must-fix P1 from #56 round-2 verify (Hyperlink API path visual-style restoration / tgtFrame / docLocation Reader filter / ordered children source-order preservation; sort-path contentControls + commentIds / footnoteIds / endnoteIds / hasPageBreak emission; non-text wrapper preservation; nested hyperlink/SDT/fieldSimple round-trip; nextBookmarkId calibration; bookmark wrap-around restoration). No source changes. |
| v3.13.2 | 2026-04-26 | Bumps ooxml-swift v0.19.1 → v0.19.2. Closes 4 blocking findings from #56 round-1 verify (F1 `Hyperlink.toXML()` emits Reader-collected runs/rawAttributes/rawChildren; F2 `add_bookmark`/`delete_bookmark` sync `bookmarkMarkers`; F3 ins/del/moveFrom/moveTo round-trip preserves position+revisionId+wrapper; F4 namespace preservation extends from `document.xml` to header/footer/footnote/endnote). No source changes. |
| v3.13.1 | 2026-04-25 | `pPr` double-emission silent regression on sort-by-position round-trip — hot-fix (ooxml-swift v0.19.1). |
| v3.13.0 | 2026-04-25 | **`document.xml` lossless round-trip + tool-mediated wrapper edits** (closes [#56](https://github.com/PsychQuant/che-word-mcp/issues/56) P0). Hybrid model preserves namespace map (34 xmlns), bookmarks, structural wrappers (`<w:hyperlink>` / `<w:fldSimple>` / `<mc:AlternateContent>`). |
| v3.12.0 | 2026-04-25 | **Programmatic Track Changes generation** (closes [#45](https://github.com/PsychQuant/che-word-mcp/issues/45)) — 3 new tools (`insert_text_as_revision` / `delete_text_as_revision` / `move_text_as_revision`) + `as_revision` flag on `format_text` / `set_paragraph_format`. Emits `<w:ins>` / `<w:del>` / `<w:moveFrom>` / `<w:moveTo>` / `<w:rPrChange>` / `<w:pPrChange>` markup. |
| v3.11.0 | 2026-04-25 | **Tables / Hyperlinks / Headers extensions** (closes [#49](https://github.com/PsychQuant/che-word-mcp/issues/49) [#50](https://github.com/PsychQuant/che-word-mcp/issues/50) [#51](https://github.com/PsychQuant/che-word-mcp/issues/51)) — 16 new tools: table conditional styles (10 region types) / nested tables (max 5 deep) / explicit layout / table indent; three typed hyperlinks (URL / bookmark / email); even/odd header toggle / link-to-previous / `get_section_header_map`. |
| v3.10.0 | 2026-04-24 | **Styles + Numbering + Sections foundation** (closes [#46](https://github.com/PsychQuant/che-word-mcp/issues/46) [#47](https://github.com/PsychQuant/che-word-mcp/issues/47) [#48](https://github.com/PsychQuant/che-word-mcp/issues/48)) — 19 new tools + 6 extended args. `get_style_inheritance_chain`, `link_styles`, `set_latent_styles`, `add_style_name_alias`; full Numbering CRUD lifecycle; section vertical alignment / page-number format / break-type / title-page distinct / per-section header refs. |
| v3.9.0 | 2026-04-24 | **Content Controls (SDT) read/write** (closes [#44](https://github.com/PsychQuant/che-word-mcp/issues/44)) — 7 new tools, 12-type discrimination (richText / plainText / picture / date / dropDownList / comboBox / checkBox / bibliography / citation / group / repeatingSection / repeatingSectionItem). Nested SDT trees, deterministic id allocator, `keep_content` unwrap, whitelist-validated XML replacement. |
| v3.8.0 | 2026-04-24 | **Header/footer raw-element preservation + counter-isolation flag** (closes [#52](https://github.com/PsychQuant/che-word-mcp/issues/52)). |
| v3.7.2 | 2026-04-24 | 3-issue bundle from #42 verification (closes [#53](https://github.com/PsychQuant/che-word-mcp/issues/53), [#54](https://github.com/PsychQuant/che-word-mcp/issues/54), [#55](https://github.com/PsychQuant/che-word-mcp/issues/55) path traversal hardening). |
| v3.7.1 | 2026-04-24 | `update_all_fields` no longer strips headers/footers (closes [#42](https://github.com/PsychQuant/che-word-mcp/issues/42)). |
| v3.7.0 | 2026-04-24 | **Insert crash hardening + autosave Design B** (closes [#40](https://github.com/PsychQuant/che-word-mcp/issues/40), [#41](https://github.com/PsychQuant/che-word-mcp/issues/41)). v3.6.0 shipped autosave_every Design A (post-mutation counter) which couldn't preserve K-1 mutations on crash at K when K%N≠0. v3.7.0 switches to **Design B** (snapshot fires at the START of every mutating handler before the mutation runs); default `autosave_every` flipped from `0` to `1` (every mutation snapshots prior state). Pass `autosave_every: 0` to opt out. **BREAKING (effective)**: callers who relied on Design A semantics or default disabled. Also adds Phase A `CHE_WORD_MCP_LOG_LEVEL=debug` structured logging gate for #41 investigation. Built on ooxml-swift 0.13.3 which kills `DocxReader.concurrentPerform` (parsing determinism prerequisite for `recover_from_autosave`) and refactors `nextImageRelationshipId` to use the rId allocator. **Migration from v3.6.0**: code passing `autosave_every: 0` explicitly is unaffected; code that omitted the arg now gets `1` (full safety) — to restore v3.6.0 disabled-by-default behavior, add `autosave_every: 0` to `open_document` calls. |
| v3.6.0 | 2026-04-23 | **Autosave + checkpoint + recover_from_autosave** (closes [#37](https://github.com/PsychQuant/che-word-mcp/issues/37)). `open_document` gains `autosave_every: Int = 0` parameter — when N > 0, every Nth mutation triggers a checkpoint write to `<source>.autosave.docx` (separate file, NOT eager-save to source). New tools: `checkpoint(doc_id, path?)` for manual snapshot, `recover_from_autosave(doc_id, discard_changes?)` to replace in-memory state with autosave bytes. `get_session_state` adds `autosave_detected` + `autosave_path` fields. Successful `save_document` / `finalize_document` cleans up `<source>.autosave.docx`. Phase 4 of save-durability-stack SDD. |
| v3.5.5 | 2026-04-23 | **`keep_bak` opt-in for rollback escape hatch** (closes [#38](https://github.com/PsychQuant/che-word-mcp/issues/38)). `save_document` gains optional `keep_bak: Bool = false`; when `true` and target exists, server renames target → `<path>.bak` BEFORE atomic-rename save (single slot, overwrites prior `.bak`). User can `mv <path>.bak <path>` to roll back if a future save ships silent OOXML damage. `.bak` lives at server layer NOT ooxml-swift — `macdoc` CLI users don't get unwanted `.bak` files. Phase 3 of save-durability-stack SDD. |
| v3.5.4 | 2026-04-23 | **`class WordMCPServer` → `actor WordMCPServer`** (closes [#39](https://github.com/PsychQuant/che-word-mcp/issues/39)). 8 mutable session state dictionaries become actor-isolated; compiler enforces every cross-actor access via `await`. Eliminates the Dictionary hash-table corruption race that pre-v3.5.4 12-parallel `insert_image_from_path` calls triggered. Phase 2 of save-durability-stack SDD. |
| v3.5.3 | 2026-04-23 | **Atomic-rename save** (closes [#36](https://github.com/PsychQuant/che-word-mcp/issues/36)). Bumps to ooxml-swift 0.13.2 which refactors `DocxWriter.write` to write `<url>.tmp.<UUID>` + `fsync` + `replaceItemAt`. Any throw or process kill mid-write leaves the original byte-preserved (POSIX `rename(2)` is kernel-atomic; cross-volume falls back to copy+delete). 397/397 ooxml-swift tests pass; concurrent-observer regression test added. Phase 1 of save-durability-stack SDD. |
| v3.5.2 | 2026-04-23 | **Rels overlay merge** (closes [#35](https://github.com/PsychQuant/che-word-mcp/issues/35)) — Reader-loaded NTPU thesis no-op `save_document` round-trip now preserves theme / webSettings / people / customXml / commentsExtended / commentsIds rels. v3.5.0/v3.5.1 fixed the parts layer; v3.5.2 fixes the rels layer. No che-word-mcp source change — fix entirely in ooxml-swift v0.13.1 (`RelationshipsOverlay` + relationship-driven `extractImages`). |
| v3.5.1 | 2026-04-23 | **Universal binary** (`x86_64 + arm64`) — restores Intel Mac compatibility. v3.5.0 was arm64-only because release-build skipped the documented `lipo -create` step. No source changes — drop-in replacement. |
| v3.5.0 | 2026-04-23 | **True byte-preservation via dirty tracking** (closes [#23 round-2](https://github.com/PsychQuant/che-word-mcp/issues/23) + [#32](https://github.com/PsychQuant/che-word-mcp/issues/32) [#33](https://github.com/PsychQuant/che-word-mcp/issues/33) [#34](https://github.com/PsychQuant/che-word-mcp/issues/34)). Reader-loaded NTPU theses survive no-op `save_document` round-trip with all 13 fontTable + 6 distinct headers + 4 footers + three-segment PAGE field + `<w15:presenceInfo>` identity preserved. Built on ooxml-swift 0.13.0 (`modifiedParts: Set<String>` + `Header.originalFileName` + overlay-mode skip-when-not-dirty). `list_people` returns dual identity: `person_id` (GUID, stable across rename) + `display_name_id` (= author legacy). |
| v3.4.0 | 2026-04-23 | **Phase 2B + 2C combined** (closes #24 #25 #29 #30 #31): comment threads (`list_comment_threads` / `get_comment_thread` / `sync_extended_comments`), people (`list_people` / `add_person` / `update_person` / `delete_person`), notes update (`get_endnote` / `update_endnote` / `get_footnote` / `update_footnote` — preserves note IDs), web settings (`get_web_settings` / `update_web_settings`). 13 new MCP tools. |
| v3.3.0 | 2026-04-23 | **Phase 2A** (closes #26 #27 #28): theme tools (`get_theme` / `update_theme_fonts` / `update_theme_color` / `set_theme`), headers (`list_headers` / `get_header` / `delete_header`), watermarks (`list_watermarks` / `get_watermark`), footers (`list_footers` / `get_footer` / `delete_footer`). 12 new MCP tools. Bumped to ooxml-swift 0.12.x for preserve-by-default round-trip. |
| v3.2.0 | 2026-04-23 | **`insert_equation` LaTeX parser delegated to `latex-math-swift`** (closes #22). Full LaTeX subset: `\frac`, `\sqrt`, `\hat`/`\bar`/`\tilde`, `\left`/`\right`, `\sum`/`\int`/`\prod` with bounds, `\ln`/`\sin`/`\cos`/`\tan`/`\log`/`\exp`/`\max`/`\min`/`\det`, `\sup`/`\inf`/`\lim`, `\text{}`, all Greek letters (incl. `\varepsilon` variants), common operators. 18 econometrics fixture equations now all parse. Adds `MathAccent` via ooxml-swift 0.11.0. |
| v3.1.0 | 2026-04-22 | 9 readback tools: Caption CRUD (`list_captions` / `get_caption` / `update_caption` / `delete_caption`), `update_all_fields` (F9-equivalent SEQ recount), Equation CRUD (`list_equations` / `get_equation` / `update_equation` / `delete_equation`). Built on new ooxml-swift 0.10.0 `FieldParser` + `OMMLParser`. |
| v3.0.0 | 2026-04-22 | **BREAKING**: session state API. New tools `get_session_state` / `revert_to_disk` / `reload_from_disk` / `check_disk_drift`. `open_document` track_changes default flipped from true to false. `close_document` dirty-check now returns `E_DIRTY_DOC` text response with recovery options (`save_document` / `discard_changes: true` / `finalize_document`). |
| v2.3.0 | 2026-04-22 | Text-anchor compound tool — `insert_caption` / `insert_image_from_path` accept `after_text` / `before_text` / `text_instance`. Eliminates the `search_text + insert_*` two-call pattern (~50% RPC reduction for thesis caption workflows). |
| v2.2.0 | 2026-04-22 | Batch API — `replace_text_batch` (sequential, single save at end, `dry_run`/`stop_on_first_failure` flags) + `search_text_batch` (aggregated multi-query response, Direct + Session Mode). |
| v2.1.0 | 2026-04-22 | Expose v2.0.0 params via `inputSchema` — schemas for `insert_caption` / `insert_equation` / `insert_image_from_path` / `replace_text` now advertise new params (Chinese labels, `components`, `into_table_cell`, `scope`, `regex`). |
| v2.0.0 | 2026-04-22 | **BREAKING**: `word-mcp-insertion-primitives` Spectra change. Real OOXML SEQ fields (was literal text), OMML `MathComponent` AST (was string substitution), auto-aspect image sizing + table-cell target, cross-run-safe `replace_text` with `scope` + regex backreferences. |
| v1.19.0 | 2026-04-15 | Manuscript review markdown export: `export_revision_summary_markdown` / `compare_documents_markdown` / `export_comment_threads_markdown`. **BREAKING**: `get_revisions` + `compare_documents` `full_text` param replaced by `summarize` (inverted default). |
| v1.18.0 | 2026-04-14 | Fix `get_revisions` hardcoded 30-char truncation (bug since v1.2.0); add `full_text` opt-in. |
| v1.17.0 | 2026-03-11 | Session state management: dirty tracking, autosave, `finalize_document`, `get_document_session_state`, shutdown flush (contributed by [@ildunari](https://github.com/ildunari)) |
| v1.16.0 | 2026-03-10 | Dual-Mode: 15 read-only tools now support `source_path` (Direct Mode); MCP server instructions added |
| v1.15.2 | 2026-03-07 | Improve `list_all_formatted_text` tool description for better LLM parameter handling |
| v1.15.1 | 2026-03-01 | Fix heading heuristic style fallback (resolve fontSize from style inheritance chain) |
| v1.15.0 | 2026-03-01 | Practical Mode: EMF→PNG auto-conversion + heading heuristic for style-less documents |
| v1.14.0 | 2026-03-01 | Embed `word-to-md-swift` library: no external macdoc binary needed, restore `doc_id` support |
| v1.13.0 | 2026-03-01 | Upgrade ooxml-swift to v0.5.0: parallel multi-core parsing (~0.64s for large docs) |
| v1.12.1 | 2026-03-01 | Upgrade ooxml-swift to v0.4.0: large document performance fix (>30s → ~2.3s) |
| v1.12.0 | 2026-02-28 | `export_markdown` uses `source_path` only, removes `doc_id`, adds lock file check |
| v1.11.1 | 2026-02-28 | Fix `export_markdown` stdout mode (pipe fsync issue) |
| v1.11.0 | 2026-02-28 | `export_markdown` delegates to `macdoc` CLI; removed `word-to-md-swift` dependency |
| v1.9.0 | 2026-02-28 | `export_markdown` upgraded to use `word-to-md-swift` for high-quality output (145 total) |
| v1.8.0 | 2026-02-03 | Remove hard diff limit, add `max_results` & `heading_styles` params to `compare_documents` |
| v1.7.0 | 2026-02-03 | Add `compare_documents` tool for server-side document diff (105 total) |
| v1.2.1 | 2026-01-16 | Fix MCP SDK compatibility (actor→class, add capabilities) |
| v1.2.0 | 2026-01-16 | Add 12 new tools (95 total): search, hyperlinks, bookmarks, footnotes, endnotes, revisions, properties |
| v1.1.0 | 2026-01-16 | Fix MCPB manifest.json format for Claude Desktop |
| v1.0.0 | 2026-01-16 | Initial release with 83 tools, refactored to use ooxml-swift |

## Quick Start

### For Claude Desktop

#### Option A: MCPB One-Click Install (Recommended)

Download the latest `.mcpb` file from [Releases](https://github.com/PsychQuant/che-word-mcp/releases) and double-click to install.

#### Option B: Manual Configuration

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "che-word-mcp": {
      "command": "/usr/local/bin/CheWordMCP"
    }
  }
}
```

### For Claude Code (CLI)

#### Option A: Install as Plugin (Recommended)

The plugin bundles a version-aware wrapper that **auto-downloads the binary** on first use (and re-downloads whenever the plugin itself is updated — no `swift build` needed).

Two steps — register the marketplace once, then install the plugin:

```bash
# 1. Register the marketplace (one-time)
claude plugin marketplace add PsychQuant/psychquant-claude-plugins

# 2. Install the plugin
claude plugin install che-word-mcp@psychquant-claude-plugins
```

> **Inside Claude Code?** The slash-command equivalents `/plugin marketplace add PsychQuant/psychquant-claude-plugins` and `/plugin install che-word-mcp@psychquant-claude-plugins` work the same way.

> **Note:** The plugin wraps the MCP binary with auto-download. If the binary is missing from `~/bin/CheWordMCP` (or the sidecar `~/bin/.CheWordMCP.version` is older than the plugin's pinned version), it will be downloaded from GitHub Releases on next invocation.

#### Option B: Install as standalone MCP

If you only need the MCP server without plugin features (slash commands, skills, SessionStart hooks):

```bash
# Create ~/bin if needed
mkdir -p ~/bin

# Download the latest release
curl -L https://github.com/PsychQuant/che-word-mcp/releases/latest/download/CheWordMCP -o ~/bin/CheWordMCP
chmod +x ~/bin/CheWordMCP

# Register with Claude Code
# --scope user    : available across all projects (stored in ~/.claude.json)
# --transport stdio: local binary execution via stdin/stdout
# --              : separator between claude options and the command
claude mcp add --scope user --transport stdio che-word-mcp -- ~/bin/CheWordMCP
```

> **💡 Tip:** Install the binary into a local directory like `~/bin/`. Avoid cloud-synced folders (Dropbox, iCloud, OneDrive) — their sync operations can break MCP connections.

### Build from Source (Optional)

Use this only if you want to track `main` or contribute patches.

#### Prerequisites

- macOS 13.0+ (Ventura or later)
- Swift 5.9+

```bash
git clone https://github.com/PsychQuant/che-word-mcp.git
cd che-word-mcp
swift build -c release

# Install
cp .build/release/CheWordMCP ~/bin/
```

## Two Modes of Operation

### Direct Mode (`source_path`) — Read-only, no state

Pass a file path directly. No need to call `open_document` first. Best for quick inspection.

```
# Just pass source_path — one step
list_images: { "source_path": "/path/to/file.docx" }
search_text: { "source_path": "/path/to/file.docx", "query": "keyword" }
get_document_info: { "source_path": "/path/to/file.docx" }
```

**19 tools support Direct Mode:**

| Category | Tools |
|----------|-------|
| Read content | `get_text`, `get_document_text`, `get_paragraphs`, `get_document_info`, `search_text` |
| List elements | `list_images`, `list_styles`, `get_tables`, `list_comments`, `list_hyperlinks`, `list_bookmarks`, `list_footnotes`, `list_endnotes`, `get_revisions` |
| Properties | `get_document_properties`, `get_section_properties`, `get_word_count_by_section`, `estimate_paragraph_for_page` |
| Export | `export_markdown` |

### Session Mode (`doc_id`) — Full read/write lifecycle

Call `open_document` first, then use `doc_id` for all subsequent operations. Required for editing.

```
open_document: { "path": "/path/to/file.docx", "doc_id": "mydoc" }
insert_paragraph: { "doc_id": "mydoc", "text": "Hello World" }
save_document: { "doc_id": "mydoc", "path": "/path/to/output.docx" }
close_document: { "doc_id": "mydoc" }
```

> **Dual-mode tools** accept both `source_path` and `doc_id`. If you already have a document open, use `doc_id` to avoid re-reading from disk.

## Usage with AI Agents

### Just ask the agent

```
Use che-word-mcp to read all images from ~/Documents/report.docx
```

The agent will automatically use Direct Mode (no need to open/close).

### AGENTS.md / CLAUDE.md

```markdown
## Word Document Manipulation

Use `che-word-mcp` for reading and writing Microsoft Word (.docx) files.

**Read-only** (Direct Mode — one step):
- `get_document_text` / `get_paragraphs` — read content
- `list_images` / `search_text` — inspect elements
- `export_markdown` — convert to Markdown

**Edit** (Session Mode — open→edit→save):
1. `open_document` → get doc_id
2. `insert_paragraph` / `replace_text` / `format_text` — modify
3. `save_document` → write to disk
4. `close_document` → release memory
```

### Claude Code Skill

```bash
mkdir -p .claude/skills/che-word-mcp
curl -o .claude/skills/che-word-mcp/SKILL.md \
  https://raw.githubusercontent.com/PsychQuant/che-word-mcp/main/skills/che-word-mcp/SKILL.md
```

## Available Tools (234 Total)

### Paragraph Index Conventions

`paragraph_index` / `index` are historical parameter names and do not always
count the same OOXML surface. **Different insert / mutate / readback tools
use different conventions** — there is no universal default to assume.
Three coordinate systems coexist:
`body.children` insertion index (used by some inserts), top-level paragraph
ordinal (used by most mutate operations and inline equation insertion),
and `get_paragraphs` readback order (for inspection). See
[docs/paragraph-index-conventions.md](docs/paragraph-index-conventions.md)
for the per-tool inventory before reusing an index across tools.

### Document Management (6 tools)

| Tool | Description |
|------|-------------|
| `create_document` | Create a new Word document |
| `open_document` | Open an existing .docx file (track_changes default `false` since v3.0.0) |
| `save_document` | Save document to .docx file |
| `close_document` | Close an open document (pass `discard_changes: true` to drop dirty edits) |
| `finalize_document` | Save and close in one guarded step |
| `list_open_documents` | List all open documents |

### Session State API (5 tools, v3.0.0+)

| Tool | Description |
|------|-------------|
| `get_session_state` | Snapshot `{ source_path, disk_hash_hex, disk_mtime_iso8601, is_dirty, track_changes_enabled }` |
| `get_document_session_state` | Legacy session snapshot (preserved for backward compat) |
| `revert_to_disk` | Re-read source path, discard in-memory edits (destructive-by-design) |
| `reload_from_disk` | Cooperative reload; requires `force: true` on dirty doc |
| `check_disk_drift` | Informational — returns `{ drifted, disk_mtime, stored_mtime, disk_hash_matches }` |

### Content Operations (9 tools)

| Tool | Description |
|------|-------------|
| `get_text` | Get plain text content |
| `get_paragraphs` | Get all paragraphs with formatting |
| `estimate_paragraph_for_page` | **v3.18.0+** — estimate a Word UI page number to a `get_paragraphs` candidate range (heuristic JSON with confidence + warning) |
| `insert_paragraph` | Insert a new paragraph |
| `update_paragraph` | Update paragraph content |
| `delete_paragraph` | Delete a paragraph |
| `replace_text` | Cross-run-safe find & replace with `scope` (body\|all) + `regex` + `$1..$N` backreferences |
| `replace_text_batch` | **v2.2.0** — sequential N-replacement batch, single save at end, `dry_run` / `stop_on_first_failure` |
| `search_text_batch` | **v2.2.0** — aggregated multi-query search, works in Direct + Session Mode |

### Formatting (3 tools)

| Tool | Description |
|------|-------------|
| `format_text` | Apply text formatting (bold, italic, color, font) |
| `set_paragraph_format` | Set paragraph formatting (alignment, spacing) |
| `apply_style` | Apply built-in or custom styles |

### Tables (15 tools, **v3.11.0+ extensions** [#49](https://github.com/PsychQuant/che-word-mcp/issues/49))

Core (6):
| Tool | Description |
|------|-------------|
| `insert_table` | Insert a table with optional data |
| `get_tables` | Get all tables information |
| `update_cell` | Update cell content |
| `delete_table` | Delete a table |
| `merge_cells` | Merge cells horizontally or vertically |
| `set_table_style` | Set table borders and shading |

Row / column / cell (8):
| Tool | Description |
|------|-------------|
| `add_row_to_table`, `delete_row_from_table` | Row management |
| `add_column_to_table`, `delete_column_from_table` | Column management |
| `set_cell_width`, `set_cell_vertical_alignment` | Cell sizing + alignment |
| `set_row_height`, `set_table_alignment` | Row height + table alignment |

Advanced (5, **v3.11.0**):
| Tool | Description |
|------|-------------|
| `set_table_conditional_style` | Apply firstRow / lastRow / bandedRows etc. (10 region types) via `<w:tblStylePr>` |
| `insert_nested_table` | Insert table-in-cell, depth-limited to 5 (throws `nested_too_deep`) |
| `set_table_layout` | Switch fixed / autofit |
| `set_header_row` | Mark row as `<w:tblHeader/>` for repeat-on-page-break |
| `set_table_indent` | Table-level left indent (`<w:tblInd>`) |

### Style Management (8 tools + 6 extended args, **v3.10.0+** [#48](https://github.com/PsychQuant/che-word-mcp/issues/48))

Core (4):
| Tool | Description |
|------|-------------|
| `list_styles` | List all available styles (Direct Mode supported) |
| `create_style` | Create custom style — extended with 6 v3.10 args: `based_on`, `linked_style_id`, `next_style_id`, `q_format`, `hidden`, `semi_hidden` |
| `update_style` | Update style definition — same 6 extended args |
| `delete_style` | Delete custom style |

Inheritance + linkage (4, **v3.10.0**):
| Tool | Description |
|------|-------------|
| `get_style_inheritance_chain` | Traverse `basedOn` chain upward to root with cycle detection |
| `link_styles` | Bidirectional `<w:link>` between paragraph and character style pair |
| `set_latent_styles` | Control Quick Style Gallery defaults via `<w:latentStyles>` block |
| `add_style_name_alias` | Localized `<w:name>` alias per BCP 47 lang code |

### Numbering / Lists (12 tools, **v3.10.0+ definition lifecycle** [#46](https://github.com/PsychQuant/che-word-mcp/issues/46))

Inline list creation (4):
| Tool | Description |
|------|-------------|
| `insert_bullet_list` | Insert bullet list |
| `insert_numbered_list` | Insert numbered list |
| `set_list_level` | Set list indentation level |
| `set_outline_level` | Set paragraph outline level (TOC inclusion) |

Definition CRUD (8, **v3.10.0**):
| Tool | Description |
|------|-------------|
| `list_numbering_definitions` | Enumerate every abstractNum + num pair |
| `get_numbering_definition` | Fetch single num by id |
| `create_numbering_definition` | New abstractNum + paired num (max 9 levels) |
| `override_numbering_level` | `<w:lvlOverride>` for per-level start values |
| `assign_numbering_to_paragraph` | `<w:numPr>` attachment by paragraph index |
| `continue_list` | Resume numbering across paragraphs |
| `start_new_list` | Reset numbering to start |
| `gc_orphan_numbering` | Sweep unreferenced num definitions (abstractNums preserved) |

### Sections / Page Setup (12 tools, **v3.10.0+ extensions** [#47](https://github.com/PsychQuant/che-word-mcp/issues/47))

Basic page setup (5):
| Tool | Description |
|------|-------------|
| `set_page_size` | Set page size (A4, Letter, etc.) |
| `set_page_margins` | Set page margins |
| `set_page_orientation` | Set portrait or landscape |
| `insert_page_break` | Insert page break |
| `insert_section_break` | Insert section break |

Section properties (7, **v3.10.0**):
| Tool | Description |
|------|-------------|
| `get_all_sections` | Return SectionInfo array per section in document order |
| `set_section_break_type` | `nextPage` / `continuous` / `evenPage` / `oddPage` |
| `set_section_vertical_alignment` | `<w:vAlign>` for cover pages |
| `set_page_number_format` | `<w:pgNumType w:fmt>` for Roman numerals etc. |
| `set_line_numbers_for_section` | `<w:lnNumType>` for legal documents |
| `set_title_page_distinct` | Toggle `<w:titlePg/>` per section |
| `set_section_header_footer_references` | Assign per-type rId (default/first/even) |

### Headers & Footers (17 tools, **v3.11.0+ even/odd + section map** [#51](https://github.com/PsychQuant/che-word-mcp/issues/51))

Write tools (5):
| Tool | Description |
|------|-------------|
| `add_header` | Add header content (uses `RelationshipIdAllocator` since v3.3.0+ — collision-free rIds in overlay mode) |
| `update_header` | Update header content (preserves filename + rId; in-place tempDir overwrite) |
| `add_footer` | Add footer content |
| `update_footer` | Update footer content |
| `insert_page_number` | Insert page number field |

Read + delete tools (8, **v3.3.0+**, closes #26 #27):
| Tool | Description |
|------|-------------|
| `list_headers` | Enumerate header parts with type (default/first/even) + section_id + has_watermark |
| `get_header` | Read text + full XML + watermark structure |
| `delete_header` | Remove typed model entry + tempDir file + Relationship + Content_Types Override |
| `list_watermarks` | Scan all headers for VML `PowerPlusWaterMarkObject` shapes (text or image) |
| `get_watermark` | Single-header watermark detail (returns `null` if no watermark) |
| `list_footers` | Enumerate footer parts with type + section_id + has_page_number |
| `get_footer` | Read text + XML + parsed field structure (PAGE / NUMPAGES / REF / STYLEREF) |
| `delete_footer` | Symmetric with delete_header |

Even/odd + section linkage (4, **v3.11.0**):
| Tool | Description |
|------|-------------|
| `enable_even_odd_headers` | Toggle document-level `<w:evenAndOddHeaders/>` flag |
| `link_section_header_to_previous` | Word-compat clone semantics |
| `unlink_section_header_from_previous` | Symmetric unlink |
| `get_section_header_map` | Return per-section header / footer file assignments |

### Theme Editing (4 tools, **v3.3.0+**, closes #28)

| Tool | Description |
|------|-------------|
| `get_theme` | Read major/minor font slots (latin/ea/cs) + color scheme (accent1-6, hyperlink, followedHyperlink) from `word/theme/theme1.xml` |
| `update_theme_fonts` | Partial-update font slots — e.g. `{ minor: { ea: "DFKai-SB" } }` for NTPU thesis Chinese font fix |
| `update_theme_color` | Slot-named hex color update with validation (rejects invalid slot + non-6-char-hex) |
| `set_theme` | Low-level escape hatch — replace theme1.xml verbatim (validates `<a:theme>` root + well-formed XML) |

### Images (7 tools)

| Tool | Description |
|------|-------------|
| `insert_image` | Insert inline image (PNG, JPEG) |
| `insert_image_from_path` | **v2.0.0+** — width/height optional (auto-aspect via `ImageDimensions.detect`), supports `into_table_cell` + `after_text` / `before_text` anchors |
| `insert_floating_image` | Insert floating image with text wrap |
| `update_image` | Update image properties |
| `delete_image` | Delete image |
| `list_images` | List the images `word/document.xml` can list, one line per row: `- id: "rIdN", file: "name", size: WxHpx, referenced: yes / NO (orphan) / unknown` (quoted values are data; `id:` is the key). Orphans (relationship declared, no reference from the body — the macdoc#175 signature) are named `"part:rId"` with a ⚠ and, in Session Mode, labelled `new since baseline` / `in baseline` with the save gate's own prediction; relationships that cannot be listed (media missing / external) and other-part orphans get their own lines (#199) |
| `set_image_style` | Set image border and effects |

### Captions (5 tools)

| Tool | Description |
|------|-------------|
| `insert_caption` | **v2.0.0+** — real OOXML SEQ field (not literal text). Accepts English + Chinese labels (`Figure`/`Table`/`Equation`/`圖`/`表`/`公式`), 5-way anchor (`paragraph_index` / `after_image_id` / `after_table_index` / `after_text` / `before_text`), optional `STYLEREF` chapter number prefix |
| `list_captions` | **v3.1.0** — enumerate caption paragraphs with label / sequence_number / caption_text / paragraph_index |
| `get_caption` | **v3.1.0** — detailed single caption info including optional `chapter_number` from STYLEREF |
| `update_caption` | **v3.1.0** — modify caption text or label without breaking the SEQ field structure |
| `delete_caption` | **v3.1.0** — remove caption paragraph |

### Equations (5 tools)

| Tool | Description |
|------|-------------|
| `insert_equation` | **v2.0.0+** — emits structurally correct OMML via `MathComponent` AST (9 types). Primary: `components:` tree; fallback: `latex:` subset (`\frac`, `\sqrt`, `x^{y}`, Greek, ∑/∫/∏) |
| `list_equations` | **v3.1.0** — enumerate `<m:oMath>` runs with display_mode flag |
| `get_equation` | **v3.1.0** — detailed single equation info with component summary |
| `update_equation` | **v3.1.0** — replace target equation's components tree |
| `delete_equation` | **v3.1.0** — remove equation run or empty paragraph |

### Export (5 tools)

| Tool | Description |
|------|-------------|
| `export_text` | Export as plain text |
| `export_markdown` | Export as Markdown (uses embedded `word-to-md-swift`) |
| `export_revision_summary_markdown` | **v1.19.0** — per-document revision timeline for manuscript review |
| `compare_documents_markdown` | **v1.19.0** — multi-document cumulative revision timeline |
| `export_comment_threads_markdown` | **v1.19.0** — comment threading with author alias normalization |

### Hyperlinks & Bookmarks (10 tools, **v3.11.0+ typed variants** [#50](https://github.com/PsychQuant/che-word-mcp/issues/50))

Generic + bookmarks (7):
| Tool | Description |
|------|-------------|
| `insert_hyperlink` | Insert external hyperlink |
| `insert_internal_link` | Insert link to bookmark |
| `insert_cross_reference` | Insert cross-reference |
| `update_hyperlink` | Update hyperlink |
| `delete_hyperlink` | Delete hyperlink |
| `insert_bookmark` | Insert bookmark |
| `delete_bookmark` | Delete bookmark |

Typed hyperlinks (3, **v3.11.0**, auto-create Hyperlink character style):
| Tool | Description |
|------|-------------|
| `insert_url_hyperlink` | External URL with optional tooltip + history flag |
| `insert_bookmark_hyperlink` | Internal anchor link (`w:anchor`, no rId) |
| `insert_email_hyperlink` | `mailto:` with optional URL-encoded subject |

### Comments & Revisions (13 tools)

Comment write + read (7):
| Tool | Description |
|------|-------------|
| `insert_comment` | Insert comment |
| `update_comment` | Update comment text |
| `delete_comment` | Delete comment |
| `list_comments` | List all comments |
| `reply_to_comment` | Reply to existing comment |
| `resolve_comment` | Mark comment as resolved |
| `list_comment_threads` | **v3.4.0** — enumerate threads (root_comment_id + replies + resolved + durable_id) using typed `Comment.parentId` from `commentsExtended.xml` |

Comment thread tools (2, **v3.4.0+**, closes #29):
| Tool | Description |
|------|-------------|
| `get_comment_thread` | Read root + walk children for full reply tree |
| `sync_extended_comments` | Report typed comment count for triplet sync planning |

Revision tracking — accept/reject side (7):
| Tool | Description |
|------|-------------|
| `enable_track_changes` | Enable track changes (sets `revisions.settings.author` for default author resolution) |
| `disable_track_changes` | Disable track changes |
| `get_revisions` | Enumerate all revisions (Direct Mode supported) |
| `accept_revision` | Accept revision by id |
| `reject_revision` | Reject revision by id |
| `accept_all_revisions` | Bulk accept |
| `reject_all_revisions` | Bulk reject |

Revision tracking — programmatic write side (3, **v3.12.0** [#45](https://github.com/PsychQuant/che-word-mcp/issues/45)):
| Tool | Description |
|------|-------------|
| `insert_text_as_revision` | Insert text wrapped in `<w:ins>` revision markup. Splits straddling runs at `position` (preserves prior + post text + formatting). Args: `doc_id`, `paragraph_index`, `position`, `text`, optional `author`, `date`. |
| `delete_text_as_revision` | Mark `[start, end)` runs with `<w:del>` and substitute `<w:t>` → `<w:delText>`. Single-paragraph only (cross-paragraph delete out of scope). |
| `move_text_as_revision` | Emit paired `<w:moveFrom>` / `<w:moveTo>` with adjacent revision ids. Single-paragraph moves rejected (callers should use delete + insert). |

Plus 2 extended args on existing tools (additive, default `false`):
- `format_text` gains `as_revision: bool` — produces `<w:rPrChange>` revision instead of silent format mutation. Also accepts `run_index`, `author`, `date`.
- `set_paragraph_format` gains `as_revision: bool` — produces `<w:pPrChange>` revision.

**Side-effect contract**: `as_revision: true` requires `enable_track_changes` to have been called. Disabled track changes throws `track_changes_not_enabled` instead of silent auto-enable. **Author resolution chain**: explicit non-empty `author` arg → `revisions.settings.author` → literal `"Unknown"`.

### People — Comment Authors (4 tools, **v3.4.0+**, closes #30)

| Tool | Description |
|------|-------------|
| `list_people` | Parse `<w15:person>` entries from `word/people.xml` |
| `add_person` | Add new entry; auto-create `people.xml` part when absent; duplicate-name `_2` suffix |
| `update_person` | Update display_name (author attribute swap) |
| `delete_person` | Remove entry; report `comments_orphaned` count |

### Footnotes & Endnotes (10 tools)

Write + delete (4):
| Tool | Description |
|------|-------------|
| `insert_footnote` | Insert footnote |
| `delete_footnote` | Delete footnote |
| `insert_endnote` | Insert endnote |
| `delete_endnote` | Delete endnote |

List + read + update (6, **v3.4.0+**, closes #24 #25):
| Tool | Description |
|------|-------------|
| `list_footnotes` | Direct Mode supported |
| `list_endnotes` | Direct Mode supported |
| `get_footnote` | Read text + runs by integer ID |
| `update_footnote` | In-place text replacement, preserves footnote_id (cross-references stay valid) |
| `get_endnote` | Read text + runs by integer ID |
| `update_endnote` | In-place text replacement, preserves endnote_id |

### Web Settings (2 tools, **v3.4.0+**, closes #31)

| Tool | Description |
|------|-------------|
| `get_web_settings` | Parse `word/webSettings.xml` flag elements (`relyOnVML`, `optimizeForBrowser`, `allowPNG`, `doNotSaveAsSingleFile`); returns `{ error: "no webSettings part" }` when absent |
| `update_web_settings` | Partial update by key; auto-create part if absent |

### Field Codes (7 tools)

| Tool | Description |
|------|-------------|
| `insert_if_field` | Insert IF conditional field |
| `insert_calculation_field` | Insert calculation (SUM, AVERAGE, etc.) |
| `insert_date_field` | Insert date/time field |
| `insert_page_field` | Insert page number field |
| `insert_merge_field` | Insert mail merge field |
| `insert_sequence_field` | Insert auto-numbering sequence |
| `update_all_fields` | **v3.1.0** — F9-equivalent SEQ recount across body + headers + footers + footnotes + endnotes. Supports chapter-reset when `pStyle=="Heading N"` matches SEQ `resetLevel` |

### Content Controls / SDT (10 tools, **v3.9.0+ full read/write** [#44](https://github.com/PsychQuant/che-word-mcp/issues/44))

Insert + form helpers (5):
| Tool | Description |
|------|-------------|
| `insert_content_control` | 12-type discrimination (`richText` / `plainText` / `picture` / `date` / `dropDownList` / `comboBox` / `checkBox` / `bibliography` / `citation` / `group` / `repeatingSection` (rejected — use `insert_repeating_section`) / `repeatingSectionItem`). Optional args: `list_items` (required for dropDown/comboBox), `date_format`, `lock_type`. |
| `insert_repeating_section` | Insert repeating section (Word 2012+); accepts `allow_insert_delete_sections: bool` (default `true`) |
| `insert_checkbox` | Insert checkbox SDT |
| `insert_dropdown` | Insert dropdown SDT |
| `insert_text_field` | Insert plain-text SDT |

Read tools (3):
| Tool | Description |
|------|-------------|
| `list_content_controls` | Enumerate every SDT, flat (default) or nested tree mode (Direct Mode supported) |
| `get_content_control` | Fetch single SDT by `id`, `tag`, or `alias`. Returns full metadata + `<w:sdtContent>` XML. Surfaces `not_found` / `multiple_matches` errors. |
| `list_repeating_section_items` | Enumerate items inside a repeating-section SDT in document order |

Modify tools (4):
| Tool | Description |
|------|-------------|
| `update_content_control_text` | Replace text content of plainText / richText / date / bibliography / citation SDTs. Preserves `<w:sdtPr>` byte-identical. Returns `unsupported_type` for picture / dropdown / combo / checkbox / group / repeatingSection. |
| `replace_content_control_content` | Replace full `<w:sdtContent>` XML with whitelist validation (rejects input containing `<w:sdt>`, `<w:body>`, `<w:sectPr>`, or XML declaration) |
| `delete_content_control` | Remove SDT, optionally unwrapping children (`keep_content: true` default) |
| `update_repeating_section_item` | Replace text of single item by index (`out_of_bounds` for invalid index) |

SDT id allocation uses deterministic max+1 (was random in pre-v3.9.0). `list_custom_xml_parts` ships as empty-list stub for forward compat (real impl in `che-word-mcp-customxml-databinding` Change B).

### Advanced Features (10 tools)

| Tool | Description |
|------|-------------|
| `insert_toc` | Insert table of contents |
| `insert_table_of_figures` | Insert table of figures |
| `insert_index`, `insert_index_entry` | Index generation |
| `set_paragraph_border` | Set paragraph border |
| `set_paragraph_shading` | Set paragraph background color |
| `set_character_spacing` | Set character spacing |
| `set_text_effect` | Set text animation effect |
| `insert_horizontal_line`, `insert_drop_cap`, `insert_symbol` | Decorative elements |

> **Note**: The counts above cover key tool categories. Total surface is **233 tools** as of v3.13.5 including Document Comparison, Track Changes (read + programmatic write side via `<w:ins>` / `<w:del>` / `<w:moveFrom>` / `<w:moveTo>` / `<w:rPrChange>` / `<w:pPrChange>`), Content Controls (12-type SDT discrimination), Field Codes, Theme Editing, Header/Footer/Watermark CRUD with even/odd + section linkage, Comment Threads + People (dual identity), Notes Update, Web Settings, Styles (inheritance + linkage + latent + alias), Numbering (full definition lifecycle), Sections (vertical alignment + page-number format + title-page distinct + per-section refs), Tables (conditional / nested / layout / indent), Hyperlinks (typed url/bookmark/email), and Formatting helpers (with `as_revision` flag). Run the server and call `tools/list` for the complete, authoritative set.

## Usage Examples

### Create a Document with Headings and Text

```
Create a new Word document called "report" with:
- Title: "Quarterly Report"
- Heading: "Introduction"
- A paragraph explaining the report purpose
Save it to ~/Documents/report.docx
```

### Create a Document with Table and Images

```
Create a document with:
- A title "Product Catalog"
- Insert an image from ~/images/logo.png
- A 4x3 table with product information
- Apply borders to the table
Save it to ~/Documents/catalog.docx
```

### Create a Professional Report

```
Create a document with:
- Custom page margins (1 inch all around)
- A header with company name
- A footer with page numbers
- Table of contents
- Multiple sections with headings
- Footnotes for references
Save it as ~/Documents/annual_report.docx
```

## Technical Details

### OOXML Structure

The server generates valid Office Open XML documents with complete structure:

```
document.docx (ZIP)
├── [Content_Types].xml
├── _rels/
│   └── .rels
├── word/
│   ├── document.xml      # Main content
│   ├── styles.xml        # Style definitions
│   ├── settings.xml      # Document settings
│   ├── fontTable.xml     # Font definitions
│   ├── numbering.xml     # List definitions
│   ├── comments.xml      # Comments
│   ├── footnotes.xml     # Footnotes
│   ├── endnotes.xml      # Endnotes
│   ├── header1.xml       # Header content
│   ├── footer1.xml       # Footer content
│   ├── media/            # Embedded images
│   │   └── image*.{png,jpeg}
│   └── _rels/
│       └── document.xml.rels
└── docProps/
    ├── core.xml          # Metadata
    └── app.xml           # Application info
```

### Dependencies

- [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) (v0.12.0+) — Model Context Protocol implementation
- [ooxml-swift](https://github.com/PsychQuant/ooxml-swift) (**v0.12.0+**) — OOXML parsing + **preserve-by-default round-trip architecture** (PreservedArchive, RelationshipIdAllocator, ContentTypesOverlay), `FieldParser`, `OMMLParser`, `updateAllFields()`, `MathAccent`
- [latex-math-swift](https://github.com/PsychQuant/latex-math-swift) (**v0.1.0+**) — LaTeX subset → OMML `MathComponent` AST parser (used by `insert_equation` v3.2.0+)
- [markdown-swift](https://github.com/PsychQuant/markdown-swift) (v0.2.0+) — Markdown generation
- [word-to-md-swift](https://github.com/PsychQuant/word-to-md-swift) (v0.4.0+) — Word to Markdown conversion

### Developer Notes — Real-World Fixture Testing

`Tests/CheWordMCPTests/RealWorldDocxRoundTripSmokeTests.swift` validates the
ooxml-swift Reader / Writer pair against real-world Word output (e.g., academic
theses, contracts) rather than synthesized fixtures. Drop confidential `.docx`
files into `test-files/` (gitignored — they never reach version control), then:

```bash
cd mcp/che-word-mcp
swift test --filter RealWorldDocxRoundTripSmokeTests
```

Per-fixture assertions: `xmllint --noout` clean, bookmark / hyperlink /
fldSimple / AlternateContent count parity, SHA256 of concatenated `<w:t>`
content matches. The test silently `XCTSkip`s when `test-files/` is empty so
clean clones / CI do not false-fail. Mirrors the `.note` smoke pattern from
[PsychQuant/macdoc#81](https://github.com/PsychQuant/macdoc/issues/81).

## Comparison with Other Solutions

| Feature | Anthropic Word MCP | python-docx | docx npm | **che-word-mcp** |
|---------|-------------------|-------------|----------|------------------|
| Language | Node.js | Python | Node.js | **Swift** |
| Backend | AppleScript | OOXML | OOXML | **OOXML** |
| Requires Word | Yes | No | No | **No** |
| Runtime | Node.js | Python | Node.js | **None** |
| Single Binary | No | No | No | **Yes** |
| Tools Count | ~10 | N/A | N/A | **233** |
| Images | Limited | Yes | Yes | **Yes** |
| Comments | No | Limited | Limited | **Yes** |
| Track Changes | No | No | No | **Yes** |
| TOC | No | Limited | No | **Yes** |
| Form Fields | No | No | No | **Yes** |

## Performance

Benchmarks on Apple Silicon (M4 Max, 128GB RAM):

### Read Performance

| File Size | Time |
|-----------|------|
| 40 KB (thesis outline) | **72 ms** |
| 431 KB (complex document) | **31 ms** |

### Write Performance

| Operation | Content | Time |
|-----------|---------|------|
| Basic write | Create + 3 paragraphs + Save | **19 ms** |
| Complex document | Title + Paragraphs + Table + List | **21 ms** |
| Bulk write | **50 paragraphs** + Save | **28 ms** |

### Why So Fast?

- **Native Swift binary** - No interpreter startup overhead
- **Direct OOXML manipulation** - No Microsoft Word process
- **Efficient ZIP handling** - ZIPFoundation for compression
- **In-memory operations** - Only writes to disk on save

Compared to python-docx (~200ms startup) or docx npm (~150ms startup), che-word-mcp is **10-20x faster**.

## License

MIT License

## Author

Che Cheng ([@PsychQuant](https://github.com/PsychQuant))

### Contributors

- [@ildunari](https://github.com/ildunari) — session state management (v1.17.0)

## Related Projects

- [che-apple-mail-mcp](https://github.com/PsychQuant/che-apple-mail-mcp) - Apple Mail MCP server
- [che-ical-mcp](https://github.com/PsychQuant/che-ical-mcp) - macOS Calendar MCP server
