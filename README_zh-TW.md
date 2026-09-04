# che-word-mcp

以 Swift 原生開發的 MCP (Model Context Protocol) 伺服器，用於操作 Microsoft Word 文件 (.docx)。這是**首個 Swift OOXML 函式庫**，直接操作 Office Open XML 而不依賴任何第三方 Word 函式庫。

[English](README.md)

## 特色

- **純 Swift 實作**：不需要 Node.js、Python 或其他執行環境
- **直接操作 OOXML**：直接處理 XML，不需要安裝 Microsoft Word
- **單一執行檔**：只有一個 binary 檔案
- **233 MCP 工具**：完整的文件操作功能（涵蓋 documents / tables / hyperlinks / headers / sections / styles / numbering / content controls / comments / footnotes / equations / fields / Track Changes）
- **Round-trip 靜默損毀已修正（v3.13.5，[#56](https://github.com/PsychQuant/che-word-mcp/issues/56)）**：5 個 sub-stack-completion rounds（R5 / R5-CONT / R5-CONT-2 / R5-CONT-3 / R5-CONT-4）關掉了 6-AI 跨驗證 rounds 4-8 找到的 30 個 findings（16 P0 + 21 P1）。`ooxml-swift` 升到 v0.19.5（v0.19.4 因 verify-gate 暫不發布）。**MCP 端零 source 變更** — fix 全在 ooxml-swift。Round 4 walker symmetry 跨 headers/footers/footnotes/endnotes（`accept_revision` / `reject_revision` / `get_hyperlinks` / `replace_text` 在所有 part 都能找到目標）。Round 5 per-container relationships round-trip（`update_hyperlink` URL sync 對應 owning part 的 rels 檔）。Round 6 `delete_hyperlink` mirror + container `<w:tbl>` capture 保留。Round 7 `reject_revision` typed clearMarker（file/API state 收斂）。Round 8 `accept_revision` typed clearMarker（mirror）+ matrix-pin asymmetry-guard 移除 + `Document.repairContainerFileNames` 將 `document.xml.rels` + `[Content_Types].xml` 標記 dirty。Convergence: Devil's Advocate 寫了 5 個 adversarial tests，全部 PASSED。詳見 [closing summary](https://github.com/PsychQuant/che-word-mcp/issues/56#issuecomment-4322638865) 與 [v3.13.5 release notes](https://github.com/PsychQuant/che-word-mcp/releases/tag/v3.13.5)。
- **Save Durability Stack（v3.5.3+）**：atomic-rename save（#36）、actor-based 並行安全（#39）、`keep_bak` opt-in rollback（#38）、`autosave_every` Design B pre-mutation snapshot + 顯式 `recover_from_autosave`（#37、#40 v3.7.0）。預設 `autosave_every: 1`（每次 mutation 前 snapshot 上一個 state）；想完全關閉請傳 `autosave_every: 0`。
- **Dual-Mode 存取**：Direct Mode（唯讀、一步完成）與 Session Mode（完整生命週期）
- **Round-trip Fidelity（v3.3.0+）**：`save_document` 保留 typed model 不管理的 OOXML parts（`word/theme/`、`webSettings.xml`、`people.xml`、`commentsExtended/Extensible/Ids`、`glossary/`、`customXml/`）byte-for-byte。修復先前 lossy-by-design pipeline 每次儲存都會 strip 頁首/頁尾/theme/字體的問題。
- **Theme + 頁首頁尾 + 浮水印 CRUD（v3.3.0+）**：12 個新工具操作 `word/theme/theme1.xml` 編輯、頁首頁尾列舉與刪除、浮水印 VML 偵測。直接解 NTPU 學位論文中文字體 fallback 路徑：`update_theme_fonts({ minor: { ea: "DFKai-SB" } })`。
- **Comment Threads + People + Notes Update + Web Settings（v3.4.0+）**：13 個新工具，涵蓋協作註解 metadata、`people.xml` 作者紀錄、in-place endnote/footnote 編輯（保留 ID）、`webSettings.xml` 設定。
- **完整 LaTeX 子集 for `insert_equation`（v3.2.0+）**：委派給 [`latex-math-swift`](https://github.com/PsychQuant/latex-math-swift)。支援 `\frac`、`\sqrt`、`\hat`/`\bar`/`\tilde` accent、`\left/\right` delimiter、`\sum`/`\int`/`\prod` n-ary 含 bound、function names、limits、`\text{}`、全部希臘字母（含 `\varepsilon` 變體）、常用運算子。
- **Text-Anchor 插入**：`insert_caption` / `insert_image_from_path` 支援 `after_text` / `before_text`，省去先 search 再 insert 的兩段式流程
- **批次操作**：`replace_text_batch` / `search_text_batch` 把 N 次 RPC 壓縮成一次
- **Session State API**：SHA256 + mtime 磁碟 drift 偵測、`revert_to_disk` / `reload_from_disk` / `check_disk_drift`
- **結構化 Readback**：`list_captions` / `list_equations` / `update_all_fields`（F9 等效），論文審閱工作流必備
- **完整 OOXML 支援**：完整支援表格、樣式、圖片、頁首/頁尾、註解、腳註等
- **跨平台**：支援 macOS（以及其他支援 Swift 的平台）

## 版本歷史

| 版本 | 日期 | 變更 |
|------|------|------|
| **v3.13.5** | 2026-04-27 | **R5 stack-completion**（closes [#56](https://github.com/PsychQuant/che-word-mcp/issues/56) round-trip 靜默損毀）。Bump ooxml-swift v0.19.3 → v0.19.5（v0.19.4 因 verify-gate 暫不發布）。5 個 sub-stack rounds（R5 / R5-CONT / R5-CONT-2 / R5-CONT-3 / R5-CONT-4）關掉 6-AI 跨驗證 rounds 4-8 的 30 個 findings（16 P0 + 21 P1）。**Round 4** walker symmetry 跨 headers/footers/footnotes/endnotes（`accept_revision` / `reject_revision` / `get_hyperlinks` / `replace_text` 在所有 part 都能找到目標）。**Round 5** per-container relationships round-trip。**Round 6** `delete_hyperlink` mirror + container `<w:tbl>` capture 保留。**Round 7** `reject_revision` typed clearMarker（file/API state 收斂）。**Round 8** `accept_revision` typed clearMarker（mirror）+ matrix-pin asymmetry-guard 移除 + `repairContainerFileNames` rels-dirty。Convergence: Devil's Advocate 寫了 5 個 adversarial tests，全部 PASSED。**MCP 端零 source 變更** — fix 全在 ooxml-swift。詳見 [closing summary](https://github.com/PsychQuant/che-word-mcp/issues/56#issuecomment-4322638865)。|
| v3.13.4 | 2026-04-26 | **(skip — 因 verify-gate 暫不發布)**。R3 stack 內容已併入 v3.13.5。|
| v3.13.3 | 2026-04-26 | Bump ooxml-swift v0.19.2 → v0.19.3。關掉 #56 round-2 verify 的 8 P0 + 3 must-fix P1（Hyperlink API path 視覺樣式恢復、tgtFrame/docLocation Reader filter、ordered children 保留 source order；sort path contentControls + commentIds/footnoteIds/endnoteIds/hasPageBreak emission；非文字 wrapper 保留；nested hyperlink/SDT/fieldSimple round-trip；nextBookmarkId 校準；bookmark wrap-around 還原）。無 source 變更。|
| v3.13.2 | 2026-04-26 | Bump ooxml-swift v0.19.1 → v0.19.2。關掉 #56 round-1 verify 的 4 個 blocking findings（F1 `Hyperlink.toXML()` emit Reader 解出的 runs/rawAttributes/rawChildren；F2 `add_bookmark`/`delete_bookmark` 同步 `bookmarkMarkers`；F3 ins/del/moveFrom/moveTo round-trip 保留 position+revisionId+wrapper；F4 namespace 保留從 document.xml 擴展到 header/footer/footnote/endnote）。無 source 變更。|
| v3.13.1 | 2026-04-25 | `pPr` double-emission 在 sort-by-position round-trip 的 silent regression — hot-fix（ooxml-swift v0.19.1）。|
| v3.13.0 | 2026-04-25 | **`document.xml` lossless round-trip + tool-mediated wrapper edits**（closes [#56](https://github.com/PsychQuant/che-word-mcp/issues/56) P0）。Hybrid model 保留 namespace map（34 xmlns）、bookmarks、結構化 wrapper（`<w:hyperlink>` / `<w:fldSimple>` / `<mc:AlternateContent>`）。|
| v3.12.0 | 2026-04-25 | **Programmatic Track Changes 生成**（closes [#45](https://github.com/PsychQuant/che-word-mcp/issues/45)）— 3 個新工具（`insert_text_as_revision` / `delete_text_as_revision` / `move_text_as_revision`）+ `format_text` / `set_paragraph_format` 加 `as_revision` flag。Emit `<w:ins>` / `<w:del>` / `<w:moveFrom>` / `<w:moveTo>` / `<w:rPrChange>` / `<w:pPrChange>` markup。|
| v3.11.0 | 2026-04-25 | **Tables / Hyperlinks / Headers extensions**（closes [#49](https://github.com/PsychQuant/che-word-mcp/issues/49) [#50](https://github.com/PsychQuant/che-word-mcp/issues/50) [#51](https://github.com/PsychQuant/che-word-mcp/issues/51)）— 16 個新工具：table conditional styles（10 region types）、nested tables（最多 5 層）、explicit layout、table indent；3 種 typed hyperlinks（URL / bookmark / email）；even/odd header toggle / link-to-previous / `get_section_header_map`。|
| v3.10.0 | 2026-04-24 | **Styles + Numbering + Sections foundation**（closes [#46](https://github.com/PsychQuant/che-word-mcp/issues/46) [#47](https://github.com/PsychQuant/che-word-mcp/issues/47) [#48](https://github.com/PsychQuant/che-word-mcp/issues/48)）— 19 個新工具 + 6 個 extended args。`get_style_inheritance_chain`、`link_styles`、`set_latent_styles`、`add_style_name_alias`；完整 Numbering CRUD lifecycle；section vertical alignment / page-number format / break-type / title-page distinction / per-section header refs。|
| v3.9.0 | 2026-04-24 | **Content Controls (SDT) read/write**（closes [#44](https://github.com/PsychQuant/che-word-mcp/issues/44)）— 7 個新工具，12 種 SDT 區分（richText / plainText / picture / date / dropDownList / comboBox / checkBox / bibliography / citation / group / repeatingSection / repeatingSectionItem）。Nested SDT trees、deterministic id allocator、`keep_content` unwrap、whitelist-validated XML replacement。|
| v3.8.0 | 2026-04-24 | **頁首/頁尾 raw-element 保留 + counter-isolation flag**（closes [#52](https://github.com/PsychQuant/che-word-mcp/issues/52)）。|
| v3.7.2 | 2026-04-24 | #42 verification 的 3-issue bundle（closes [#53](https://github.com/PsychQuant/che-word-mcp/issues/53)、[#54](https://github.com/PsychQuant/che-word-mcp/issues/54)、[#55](https://github.com/PsychQuant/che-word-mcp/issues/55) 路徑遊歷漏洞修補）。|
| v3.7.1 | 2026-04-24 | `update_all_fields` 不再吃掉 headers/footers（closes [#42](https://github.com/PsychQuant/che-word-mcp/issues/42)）。|
| v3.7.0 | 2026-04-24 | **插入崩潰防護 + autosave Design B**（closes [#40](https://github.com/PsychQuant/che-word-mcp/issues/40)、[#41](https://github.com/PsychQuant/che-word-mcp/issues/41)）。v3.6.0 shipped autosave_every Design A（mutation 後計數），無法在 crash on K（K%N≠0）保留 K-1 mutation。v3.7.0 切換到 **Design B**（snapshot 在每個 mutating handler 開始時觸發、在 mutation 執行前）；預設 `autosave_every` 從 `0` 翻成 `1`（每次 mutation 前 snapshot 上一個 state）。傳 `autosave_every: 0` 顯式關閉。**BREAKING（行為）**：依賴 Design A 語義或預設關閉的 caller。同時新增 Phase A `CHE_WORD_MCP_LOG_LEVEL=debug` 結構化 logging gate 供 #41 調查。基於 ooxml-swift 0.13.3，後者 kill 了 `DocxReader.concurrentPerform`（`recover_from_autosave` 必要的 parsing determinism）並把 `nextImageRelationshipId` 改用 rId allocator。**v3.6.0 遷移**：原本顯式傳 `autosave_every: 0` 的 code 不受影響；省略該 arg 的 code 現在會拿到 `1`（最安全）— 想恢復 v3.6.0 預設關閉行為請在 `open_document` 加 `autosave_every: 0`。 |
| v3.6.0 | 2026-04-23 | **Autosave + checkpoint + recover_from_autosave**（closes [#37](https://github.com/PsychQuant/che-word-mcp/issues/37)）。`open_document` 加 `autosave_every: Int = 0` 參數；N > 0 時每 N 次 mutation 觸發 checkpoint 寫入 `<source>.autosave.docx`（分離檔案，**不**是 eager-save 到 source）。新增工具：`checkpoint(doc_id, path?)` 手動快照，`recover_from_autosave(doc_id, discard_changes?)` 把 in-memory state 取代成 autosave bytes。`get_session_state` 加 `autosave_detected` + `autosave_path` 欄位。`save_document` / `finalize_document` 成功後自動清掉 `<source>.autosave.docx`。Phase 4 of save-durability-stack SDD。|
| v3.5.5 | 2026-04-23 | **`keep_bak` opt-in 提供 rollback escape hatch**（closes [#38](https://github.com/PsychQuant/che-word-mcp/issues/38)）。`save_document` 加可選 `keep_bak: Bool = false`；`true` 且 target 已存在時 server 在 atomic-rename save 之前把舊檔搬到 `<path>.bak`（單一槽，會覆蓋舊 `.bak`）。如果未來 release 帶進 silent OOXML damage，使用者可 `mv <path>.bak <path>` 還原。`.bak` 放在 server 層 NOT ooxml-swift，`macdoc` CLI 用戶不會被 `.bak` 副作用打擾。Phase 3 of save-durability-stack SDD。|
| v3.5.4 | 2026-04-23 | **`class WordMCPServer` → `actor WordMCPServer`**（closes [#39](https://github.com/PsychQuant/che-word-mcp/issues/39)）。8 個 mutable session state dictionaries 變成 actor-isolated；compiler 強制每個 cross-actor 存取必須 `await`。消除 pre-v3.5.4 12 個並行 `insert_image_from_path` 觸發的 Dictionary hash table 腐壞 race condition。Phase 2 of save-durability-stack SDD。|
| v3.5.3 | 2026-04-23 | **Atomic-rename save**（closes [#36](https://github.com/PsychQuant/che-word-mcp/issues/36)）。Bump 到 ooxml-swift 0.13.2，把 `DocxWriter.write` 重構為先寫 `<url>.tmp.<UUID>` + `fsync` + `replaceItemAt`。任何 throw 或 process kill 中途中斷都會留下原檔不變（POSIX `rename(2)` 同 volume 是 kernel-atomic；跨 volume 自動 fallback 到 copy+delete）。397/397 ooxml-swift tests pass；新增 concurrent-observer regression test。Phase 1 of save-durability-stack SDD。|
| v3.5.2 | 2026-04-23 | **Rels overlay merge**（closes [#35](https://github.com/PsychQuant/che-word-mcp/issues/35)）— Reader-loaded NTPU 論文 no-op `save_document` round-trip 後完整保留 theme / webSettings / people / customXml / commentsExtended / commentsIds rels。v3.5.0/v3.5.1 修了 parts 層；v3.5.2 修了 rels 層。無 che-word-mcp source 變更，修復全在 ooxml-swift v0.13.1（`RelationshipsOverlay` + relationship-driven `extractImages`）。|
| v3.5.1 | 2026-04-23 | **Universal binary**（`x86_64 + arm64`）— 修復 Intel Mac 相容性。v3.5.0 release-build 漏跑 `lipo -create` 步驟導致只發 arm64。無 source 變更，drop-in replacement。|
| v3.5.0 | 2026-04-23 | **True byte-preservation via dirty tracking**（closes [#23 round-2](https://github.com/PsychQuant/che-word-mcp/issues/23) + [#32](https://github.com/PsychQuant/che-word-mcp/issues/32) [#33](https://github.com/PsychQuant/che-word-mcp/issues/33) [#34](https://github.com/PsychQuant/che-word-mcp/issues/34))。Reader-loaded NTPU 論文 no-op `save_document` round-trip 後完整保留 13 fontTable + 6 distinct headers + 4 footers + three-segment PAGE field + `<w15:presenceInfo>` identity。基於 ooxml-swift 0.13.0（`modifiedParts: Set<String>` + `Header.originalFileName` + overlay-mode skip-when-not-dirty）。`list_people` 回傳 dual identity：`person_id`（GUID, rename 跨版本穩定）+ `display_name_id`（= author legacy）。|
| v3.4.0 | 2026-04-23 | **Phase 2B + 2C 合併**（closes #24 #25 #29 #30 #31）：comment threads（`list_comment_threads` / `get_comment_thread` / `sync_extended_comments`）、people（`list_people` / `add_person` / `update_person` / `delete_person`）、notes update（`get_endnote` / `update_endnote` / `get_footnote` / `update_footnote`，保留 note ID）、web settings（`get_web_settings` / `update_web_settings`）。13 個新 MCP 工具。|
| v3.3.0 | 2026-04-23 | **Phase 2A**（closes #26 #27 #28）：theme tools（`get_theme` / `update_theme_fonts` / `update_theme_color` / `set_theme`）、headers（`list_headers` / `get_header` / `delete_header`）、watermarks（`list_watermarks` / `get_watermark`）、footers（`list_footers` / `get_footer` / `delete_footer`）。12 個新 MCP 工具。底層升級到 ooxml-swift 0.12.x（preserve-by-default round-trip 架構）。|
| v3.2.0 | 2026-04-23 | **`insert_equation` LaTeX parser 委派給 `latex-math-swift`**（closes #22）。完整 LaTeX 子集：`\frac`、`\sqrt`、`\hat`/`\bar`/`\tilde`、`\left`/`\right`、`\sum`/`\int`/`\prod` 含 bound、`\ln`/`\sin`/`\cos`/`\tan`/`\log`/`\exp`/`\max`/`\min`/`\det`、`\sup`/`\inf`/`\lim`、`\text{}`、全部希臘字母（含 `\varepsilon` 變體）、常用運算子。18 個經濟學 fixture 公式現在全部能 parse。新增 `MathAccent`（透過 ooxml-swift 0.11.0）。|
| v3.1.0 | 2026-04-22 | 9 個 readback 工具：Caption CRUD（`list_captions` / `get_caption` / `update_caption` / `delete_caption`）、`update_all_fields`（F9 等效 SEQ 重編號）、Equation CRUD（`list_equations` / `get_equation` / `update_equation` / `delete_equation`）。底層使用新的 ooxml-swift 0.10.0 `FieldParser` + `OMMLParser`。|
| v3.0.0 | 2026-04-22 | **BREAKING**：session state API。新增 `get_session_state` / `revert_to_disk` / `reload_from_disk` / `check_disk_drift` 工具。`open_document` 的 track_changes 預設從 true 翻成 false。`close_document` 遇 dirty 文件改回傳 `E_DIRTY_DOC` 文字回應，列出三條復原路徑（`save_document` / `discard_changes: true` / `finalize_document`）。|
| v2.3.0 | 2026-04-22 | Text-anchor 複合工具 — `insert_caption` / `insert_image_from_path` 支援 `after_text` / `before_text` / `text_instance`，省掉 `search_text + insert_*` 的兩段式流程（論文圖表 caption 工作流 RPC 減半）。|
| v2.2.0 | 2026-04-22 | Batch API — `replace_text_batch`（依序執行、結尾單次儲存、`dry_run` / `stop_on_first_failure`）+ `search_text_batch`（多 query 聚合回應，支援 Direct + Session Mode）。|
| v2.1.0 | 2026-04-22 | Expose v2.0.0 參數到 `inputSchema` — `insert_caption` / `insert_equation` / `insert_image_from_path` / `replace_text` 的 schema 公開新增的參數（中文標籤、`components`、`into_table_cell`、`scope`、`regex`）。|
| v2.0.0 | 2026-04-22 | **BREAKING**：`word-mcp-insertion-primitives` Spectra change。真正的 OOXML SEQ 欄位（原本是寫死字串）、OMML `MathComponent` AST（原本字串替換）、圖片自動長寬比 + 表格儲存格目標、跨 run 安全的 `replace_text` 含 `scope` + regex 回溯引用。|
| v1.19.0 | 2026-04-15 | 論文審閱 Markdown 匯出：`export_revision_summary_markdown` / `compare_documents_markdown` / `export_comment_threads_markdown`。**BREAKING**：`get_revisions` + `compare_documents` 的 `full_text` 參數換成 `summarize`（預設反轉）。|
| v1.18.0 | 2026-04-14 | 修復 `get_revisions` 硬編 30 字元截斷（v1.2.0 以來的 bug）；新增 `full_text` opt-in。|
| v1.17.0 | 2026-03-11 | Session 狀態管理：dirty tracking、autosave、`finalize_document`、`get_document_session_state`、shutdown flush（contributed by [@ildunari](https://github.com/ildunari)）|
| v1.16.0 | 2026-03-10 | Dual-Mode：15 個唯讀工具支援 `source_path`（Direct Mode）；新增 MCP server instructions |
| v1.15.2 | 2026-03-07 | 改善 `list_all_formatted_text` tool description，讓 LLM 更準確傳遞必要參數 |
| v1.15.1 | 2026-03-01 | 修復 heading heuristic style fallback（從 style 繼承鏈解析 fontSize）|
| v1.15.0 | 2026-03-01 | Practical Mode：EMF→PNG 自動轉換 + heading heuristic（無 Word 標題樣式時統計推斷）|
| v1.14.0 | 2026-03-01 | 嵌入 `word-to-md-swift` library：不需外部 macdoc binary，恢復 `doc_id` 支援 |
| v1.13.0 | 2026-03-01 | 升級 ooxml-swift 至 v0.5.0：多核心平行解析（大型文件 ~0.64s）|
| v1.12.1 | 2026-03-01 | 升級 ooxml-swift 至 v0.4.0：大型文件效能修復（>30s → ~2.3s）|
| v1.12.0 | 2026-02-28 | `export_markdown` 改用 `source_path`，移除 `doc_id`，加入 lock file 檢查 |
| v1.11.1 | 2026-02-28 | 修復 `export_markdown` stdout 模式（pipe fsync 問題）|
| v1.11.0 | 2026-02-28 | `export_markdown` 改為委託 `macdoc` CLI；移除 `word-to-md-swift` 依賴 |
| v1.9.0 | 2026-02-28 | `export_markdown` 改用 `word-to-md-swift` 大幅提升 Markdown 輸出品質（共 145 個工具）|
| v1.8.0 | 2026-02-03 | 移除硬性 diff 上限，新增 `max_results` 和 `heading_styles` 參數至 `compare_documents` |
| v1.7.0 | 2026-02-03 | 新增 `compare_documents` 工具，Server 端文件比對（共 105 個工具）|
| v1.2.1 | 2026-01-16 | 修復 MCP SDK 相容性（actor→class、新增 capabilities）|
| v1.2.0 | 2026-01-16 | 新增 12 個工具（共 95 個）|
| v1.1.0 | 2026-01-16 | 修復 MCPB manifest.json 格式 |
| v1.0.0 | 2026-01-16 | 初始版本，83 個工具 |

## 快速安裝

### Claude Desktop

#### Option A：MCPB 一鍵安裝（推薦）

從 [Releases](https://github.com/PsychQuant/che-word-mcp/releases) 下載最新 `.mcpb` 檔，雙擊安裝。

#### Option B：手動設定

編輯 `~/Library/Application Support/Claude/claude_desktop_config.json`：

```json
{
  "mcpServers": {
    "che-word-mcp": {
      "command": "/usr/local/bin/CheWordMCP"
    }
  }
}
```

### Claude Code (CLI)

#### Option A：安裝為 Plugin（推薦）

Plugin 內建 **version-aware wrapper**，首次使用會自動從 GitHub Release 下載 binary（plugin 升級時也會自動重抓新版 binary），不需要自己跑 `swift build`。

兩步驟——註冊 marketplace 一次，然後安裝 plugin：

```bash
# 1. 註冊 marketplace（僅需一次）
claude plugin marketplace add PsychQuant/psychquant-claude-plugins

# 2. 安裝 plugin
claude plugin install che-word-mcp@psychquant-claude-plugins
```

> **已在 Claude Code 裡？** 等效的 slash command `/plugin marketplace add PsychQuant/psychquant-claude-plugins` 和 `/plugin install che-word-mcp@psychquant-claude-plugins` 效果相同。

> **說明：** Plugin 包了一層 wrapper 自動下載 binary。如果 `~/bin/CheWordMCP` 不存在（或 sidecar `~/bin/.CheWordMCP.version` 比 plugin 釘選版本舊），下次觸發 MCP 時會自動從 GitHub Releases 重新下載。

#### Option B：獨立 MCP 安裝

只要 MCP server、不需要 plugin 的 slash commands / skills / hooks：

```bash
# 若 ~/bin 不存在先建
mkdir -p ~/bin

# 下載最新 release binary
curl -L https://github.com/PsychQuant/che-word-mcp/releases/latest/download/CheWordMCP -o ~/bin/CheWordMCP
chmod +x ~/bin/CheWordMCP

# 註冊到 Claude Code
# --scope user    : 所有專案都可用（存在 ~/.claude.json）
# --transport stdio: 本地 binary 透過 stdin/stdout 互動
# --              : 分隔 claude options 和實際命令
claude mcp add --scope user --transport stdio che-word-mcp -- ~/bin/CheWordMCP
```

> **💡 提示：** 把 binary 放在本地路徑如 `~/bin/`，避免放到 Dropbox / iCloud / OneDrive 等雲端同步資料夾——同步操作可能造成 MCP 連線中斷。

### 從原始碼編譯（選擇性）

追 main branch 或想貢獻 patch 時才需要。

#### 系統需求

- macOS 13.0+ (Ventura 或更新版本)
- Swift 5.9+

```bash
git clone https://github.com/PsychQuant/che-word-mcp.git
cd che-word-mcp
swift build -c release

# 安裝
cp .build/release/CheWordMCP ~/bin/
```

## AI Agent 使用方式

### 直接告訴 Agent

最簡單的方式 - 直接告訴 AI agent 使用它：

```
使用 che-word-mcp 建立一個新的 Word 文件，標題為「報告」，並儲存到 ~/Documents/report.docx
```

如果 che-word-mcp 已設定，agent 會自動使用 MCP 工具。

### AGENTS.md / CLAUDE.md

如需更一致的結果，將以下內容加入專案或全域指示檔：

```markdown
## Word 文件操作

使用 `che-word-mcp` 讀取和寫入 Microsoft Word (.docx) 檔案。

核心流程：
1. `open_document` - 開啟現有的 .docx 檔案
2. `get_text` / `get_paragraphs` - 讀取文件內容
3. `insert_paragraph` / `format_text` - 修改內容
4. `save_document` - 儲存變更

建立新文件：
1. `create_document` - 建立新文件
2. 使用 `insert_paragraph`、`insert_table` 等工具添加內容
3. `save_document` - 儲存為 .docx 檔案

匯出選項：
- `export_text` - 匯出為純文字
- `export_markdown` - 匯出為 Markdown
```

### Claude Code Skill

對於 Claude Code，skill 可提供更豐富的上下文：

```bash
# 下載 skill
mkdir -p .claude/skills/che-word-mcp
curl -o .claude/skills/che-word-mcp/SKILL.md \
  https://raw.githubusercontent.com/PsychQuant/che-word-mcp/main/skills/che-word-mcp/SKILL.md
```

或從專案複製：

```bash
cp -r /path/to/che-word-mcp/skills/che-word-mcp .claude/skills/
```

## 可用工具（共 233 個）

### 文件管理 (6 個)

| 工具 | 說明 |
|------|------|
| `create_document` | 建立新的 Word 文件 |
| `open_document` | 開啟現有的 .docx 檔案（v3.0.0 起 track_changes 預設為 `false`）|
| `save_document` | 儲存文件為 .docx |
| `close_document` | 關閉文件（dirty 時需 `discard_changes: true` 才能丟棄變更）|
| `finalize_document` | 儲存並關閉（一步到位）|
| `list_open_documents` | 列出所有已開啟的文件 |

### Session State API (5 個，v3.0.0+)

| 工具 | 說明 |
|------|------|
| `get_session_state` | 回傳 `{ source_path, disk_hash_hex, disk_mtime_iso8601, is_dirty, track_changes_enabled }` |
| `get_document_session_state` | 舊版 session 快照（保留以維持向下相容）|
| `revert_to_disk` | 重新讀取來源檔案，丟棄記憶體中的編輯（destructive by design）|
| `reload_from_disk` | 協作式重載；dirty 文件需帶 `force: true` |
| `check_disk_drift` | 僅回報狀態：`{ drifted, disk_mtime, stored_mtime, disk_hash_matches }` |

### 內容操作 (8 個)

| 工具 | 說明 |
|------|------|
| `get_text` | 取得純文字內容 |
| `get_paragraphs` | 取得所有段落（含格式資訊）|
| `insert_paragraph` | 插入新段落 |
| `update_paragraph` | 更新段落內容 |
| `delete_paragraph` | 刪除段落 |
| `replace_text` | 跨 run 安全的搜尋取代，支援 `scope`（body\|all）+ `regex` + `$1..$N` 回溯引用 |
| `replace_text_batch` | **v2.2.0** — 依序執行 N 次取代、結尾單次儲存、`dry_run` / `stop_on_first_failure` |
| `search_text_batch` | **v2.2.0** — 多 query 聚合搜尋，支援 Direct + Session Mode |

### 格式化 (3 個)

| 工具 | 說明 |
|------|------|
| `format_text` | 設定文字格式（粗體、斜體、顏色、字型）|
| `set_paragraph_format` | 設定段落格式（對齊、間距）|
| `apply_style` | 套用內建或自訂樣式 |

### 表格 (6 個)

| 工具 | 說明 |
|------|------|
| `insert_table` | 插入表格（可含資料）|
| `get_tables` | 取得所有表格資訊 |
| `update_cell` | 更新儲存格內容 |
| `delete_table` | 刪除表格 |
| `merge_cells` | 合併儲存格（水平或垂直）|
| `set_table_style` | 設定表格邊框和底色 |

### 樣式管理 (4 個)

| 工具 | 說明 |
|------|------|
| `list_styles` | 列出所有可用樣式 |
| `create_style` | 建立自訂樣式 |
| `update_style` | 更新樣式定義 |
| `delete_style` | 刪除自訂樣式 |

### 清單 (3 個)

| 工具 | 說明 |
|------|------|
| `insert_bullet_list` | 插入項目符號清單 |
| `insert_numbered_list` | 插入編號清單 |
| `set_list_level` | 設定清單縮排層級 |

### 頁面設定 (5 個)

| 工具 | 說明 |
|------|------|
| `set_page_size` | 設定頁面大小（A4、Letter 等）|
| `set_page_margins` | 設定頁邊距 |
| `set_page_orientation` | 設定直向或橫向 |
| `insert_page_break` | 插入分頁符號 |
| `insert_section_break` | 插入分節符號 |

### 頁首與頁尾 (13 個)

寫入工具 (5)：
| 工具 | 說明 |
|------|------|
| `add_header` | 新增頁首內容（v3.3.0+ 用 `RelationshipIdAllocator` — overlay mode 不會 rId 衝突）|
| `update_header` | 更新頁首內容（保留檔名 + rId；in-place 覆寫 archiveTempDir）|
| `add_footer` | 新增頁尾內容 |
| `update_footer` | 更新頁尾內容 |
| `insert_page_number` | 插入頁碼欄位 |

讀取與刪除工具 (8，**v3.3.0+**，closes #26 #27)：
| 工具 | 說明 |
|------|------|
| `list_headers` | 列舉所有 header parts，含 type（default/first/even）+ section_id + has_watermark |
| `get_header` | 讀取文字 + 完整 XML + watermark 結構 |
| `delete_header` | 移除 typed model entry + tempDir 檔案 + Relationship + Content_Types Override |
| `list_watermarks` | 掃描所有 header 中的 VML `PowerPlusWaterMarkObject` shapes（text 或 image）|
| `get_watermark` | 單一 header 的 watermark 詳細資訊（無 watermark 回 `null`）|
| `list_footers` | 列舉所有 footer parts，含 type + section_id + has_page_number |
| `get_footer` | 讀取文字 + XML + 解析後的 fields（PAGE / NUMPAGES / REF / STYLEREF）|
| `delete_footer` | 與 delete_header 對稱 |

### Theme 編輯 (4 個，**v3.3.0+**，closes #28)

| 工具 | 說明 |
|------|------|
| `get_theme` | 讀取 `word/theme/theme1.xml` 的 major/minor 字體 slot（latin/ea/cs）+ 色盤（accent1-6, hyperlink, followedHyperlink）|
| `update_theme_fonts` | 部分更新字體 slot — 例：`{ minor: { ea: "DFKai-SB" } }` 修復 NTPU 論文中文字體 |
| `update_theme_color` | 按 slot 名稱 hex color 更新（拒絕無效 slot + 非 6 字元 hex）|
| `set_theme` | 低階 escape hatch — 完整覆寫 theme1.xml（驗證 `<a:theme>` 根 + well-formed XML）|

### 圖片 (7 個)

| 工具 | 說明 |
|------|------|
| `insert_image` | 插入內嵌圖片（PNG、JPEG）|
| `insert_image_from_path` | **v2.0.0+** — width/height 可省略（`ImageDimensions.detect` 自動長寬比），支援 `into_table_cell` + `after_text` / `before_text` anchor |
| `insert_floating_image` | 插入浮動圖片（文繞圖）|
| `update_image` | 更新圖片屬性 |
| `delete_image` | 刪除圖片 |
| `list_images` | 列出 document part 的圖片；每列帶 `referenced: yes / NO (orphan) / unknown`，孤兒（relationship 有、body 無引用，macdoc#175 訊號）另出 ⚠ 具名 rId 並標「new this session／pre-existing at open」（#199） |
| `set_image_style` | 設定圖片邊框和效果 |

### 圖表標題 (5 個)

| 工具 | 說明 |
|------|------|
| `insert_caption` | **v2.0.0+** — 輸出真正的 OOXML SEQ 欄位（原本是寫死的字串）。支援中英標籤（`Figure`/`Table`/`Equation`/`圖`/`表`/`公式`）、5 種 anchor（`paragraph_index` / `after_image_id` / `after_table_index` / `after_text` / `before_text`）、可選 `STYLEREF` 章節編號前綴 |
| `list_captions` | **v3.1.0** — 列出所有 caption 段落，含 label / sequence_number / caption_text / paragraph_index |
| `get_caption` | **v3.1.0** — 單一 caption 詳細資訊（含 STYLEREF 抽出的 `chapter_number`）|
| `update_caption` | **v3.1.0** — 修改 caption 文字或 label，不破壞 SEQ 欄位結構 |
| `delete_caption` | **v3.1.0** — 移除 caption 段落 |

### 公式 (5 個)

| 工具 | 說明 |
|------|------|
| `insert_equation` | **v2.0.0+** — 透過 `MathComponent` AST（9 種型別）輸出結構正確的 OMML。主要路徑：`components:` tree；備援：`latex:` 子集（`\frac`、`\sqrt`、`x^{y}`、希臘字母、∑/∫/∏）|
| `list_equations` | **v3.1.0** — 列出所有 `<m:oMath>` run，含 display_mode 旗標 |
| `get_equation` | **v3.1.0** — 單一公式詳細資訊，含 component 概要 |
| `update_equation` | **v3.1.0** — 置換指定公式的 components tree |
| `delete_equation` | **v3.1.0** — 移除公式 run 或空段落 |

### 匯出 (5 個)

| 工具 | 說明 |
|------|------|
| `export_text` | 匯出為純文字 |
| `export_markdown` | 匯出為 Markdown（內嵌 `word-to-md-swift`）|
| `export_revision_summary_markdown` | **v1.19.0** — 單一文件的修訂時間軸（論文審閱）|
| `compare_documents_markdown` | **v1.19.0** — 多文件累積修訂時間軸 |
| `export_comment_threads_markdown` | **v1.19.0** — 註解對話串，含 author 別名正規化 |

### 超連結與書籤 (6 個)

| 工具 | 說明 |
|------|------|
| `insert_hyperlink` | 插入外部超連結 |
| `insert_internal_link` | 插入連結至書籤 |
| `update_hyperlink` | 更新超連結 |
| `delete_hyperlink` | 刪除超連結 |
| `insert_bookmark` | 插入書籤 |
| `delete_bookmark` | 刪除書籤 |

### 註解與修訂 (13 個)

註解寫入與讀取 (7)：
| 工具 | 說明 |
|------|------|
| `insert_comment` | 插入註解 |
| `update_comment` | 更新註解文字 |
| `delete_comment` | 刪除註解 |
| `list_comments` | 列出所有註解 |
| `reply_to_comment` | 回覆現有註解 |
| `resolve_comment` | 標記註解為已解決 |
| `list_comment_threads` | **v3.4.0** — 列舉 thread 結構（root_comment_id + replies + resolved + durable_id），用 typed `Comment.parentId`（從 `commentsExtended.xml` 解析）|

註解 thread 工具 (2，**v3.4.0+**，closes #29)：
| 工具 | 說明 |
|------|------|
| `get_comment_thread` | 讀取 root + 走遍 children 建構完整 reply tree |
| `sync_extended_comments` | 回報 typed comment count，用於 triplet sync 規劃 |

修訂追蹤 (4)：
| 工具 | 說明 |
|------|------|
| `enable_track_changes` | 啟用追蹤修訂 |
| `disable_track_changes` | 停用追蹤修訂 |
| `accept_revision` | 接受修訂 |
| `reject_revision` | 拒絕修訂 |

### People — 註解作者 (4 個，**v3.4.0+**，closes #30)

| 工具 | 說明 |
|------|------|
| `list_people` | 解析 `word/people.xml` 的 `<w15:person>` 紀錄 |
| `add_person` | 新增 entry；不存在則 auto-create `people.xml` part；重名加 `_2` 後綴 |
| `update_person` | 更新 display_name（author 屬性 swap）|
| `delete_person` | 移除 entry；回報 `comments_orphaned` 數 |

### 腳註與尾註 (10 個)

寫入與刪除 (4)：
| 工具 | 說明 |
|------|------|
| `insert_footnote` | 插入腳註 |
| `delete_footnote` | 刪除腳註 |
| `insert_endnote` | 插入尾註 |
| `delete_endnote` | 刪除尾註 |

列舉、讀取與更新 (6，**v3.4.0+**，closes #24 #25)：
| 工具 | 說明 |
|------|------|
| `list_footnotes` | 支援 Direct Mode |
| `list_endnotes` | 支援 Direct Mode |
| `get_footnote` | 按整數 ID 讀取文字 + runs |
| `update_footnote` | In-place 替換文字，保留 footnote_id（cross-references 仍有效）|
| `get_endnote` | 按整數 ID 讀取文字 + runs |
| `update_endnote` | In-place 替換文字，保留 endnote_id |

### Web Settings (2 個，**v3.4.0+**，closes #31)

| 工具 | 說明 |
|------|------|
| `get_web_settings` | 解析 `word/webSettings.xml` 旗標元素（`relyOnVML` / `optimizeForBrowser` / `allowPNG` / `doNotSaveAsSingleFile`）；無 part 時回 `{ error: "no webSettings part" }` |
| `update_web_settings` | 按 key 部分更新；不存在則 auto-create part |

### 欄位代碼 (8 個)

| 工具 | 說明 |
|------|------|
| `insert_if_field` | 插入 IF 條件欄位 |
| `insert_calculation_field` | 插入計算欄位（SUM、AVERAGE 等）|
| `insert_date_field` | 插入日期時間欄位 |
| `insert_page_field` | 插入頁碼欄位 |
| `insert_merge_field` | 插入合併列印欄位 |
| `insert_sequence_field` | 插入自動編號序列 |
| `insert_content_control` | 插入 SDT 內容控制項 |
| `update_all_fields` | **v3.1.0** — F9 等效的 SEQ 重編號，涵蓋 body + headers + footers + footnotes + endnotes。當 `pStyle=="Heading N"` 匹配 SEQ `resetLevel` 時支援章節重置 |

### 重複區段 (1 個)

| 工具 | 說明 |
|------|------|
| `insert_repeating_section` | 插入重複區段（Word 2012+）|

### 進階功能 (8 個)

| 工具 | 說明 |
|------|------|
| `insert_toc` | 插入目錄 |
| `insert_text_field` | 插入表單文字欄位 |
| `insert_checkbox` | 插入表單核取方塊 |
| `insert_dropdown` | 插入表單下拉選單 |
| `set_paragraph_border` | 設定段落邊框 |
| `set_paragraph_shading` | 設定段落背景色 |
| `set_character_spacing` | 設定字元間距 |
| `set_text_effect` | 設定文字動畫效果 |

> **備註**：上述分類涵蓋主要工具。截至 v3.13.5 總工具面共 **233 個**，包含 Content Controls (SDT)、Styles + Numbering + Sections (v3.10.0+)、Tables + Hyperlinks + Headers extensions (v3.11.0+)、Programmatic Track Changes (v3.12.0+)、Document Comparison、Revision Tracking、Field Codes、Theme Editing、Header/Footer/Watermark CRUD、Comment Threads + People、Notes Update、Web Settings、Formatting 等其他專門工具。啟動 server 後呼叫 `tools/list` 可取得完整清單。

## 使用範例

### 建立含標題和內文的文件

```
建立一個新的 Word 文件叫做 "report"：
- 標題：「季度報告」
- 一級標題：「簡介」
- 一段說明報告目的的文字
儲存到 ~/Documents/report.docx
```

### 建立含表格和圖片的文件

```
建立一個文件：
- 標題「產品目錄」
- 從 ~/images/logo.png 插入圖片
- 一個 4x3 的產品資訊表格
- 為表格加上邊框
儲存到 ~/Documents/catalog.docx
```

### 建立專業報告

```
建立一個文件：
- 自訂頁邊距（四邊各 1 吋）
- 頁首顯示公司名稱
- 頁尾顯示頁碼
- 目錄
- 多個章節標題
- 參考文獻的腳註
儲存為 ~/Documents/annual_report.docx
```

## 技術細節

### OOXML 結構

伺服器產生符合標準的 Office Open XML 文件，結構如下：

```
document.docx (ZIP)
├── [Content_Types].xml
├── _rels/
│   └── .rels
├── word/
│   ├── document.xml      # 主要內容
│   ├── styles.xml        # 樣式定義
│   ├── settings.xml      # 文件設定
│   ├── fontTable.xml     # 字型定義
│   ├── numbering.xml     # 清單定義
│   ├── comments.xml      # 註解
│   ├── footnotes.xml     # 腳註
│   ├── endnotes.xml      # 尾註
│   ├── header1.xml       # 頁首內容
│   ├── footer1.xml       # 頁尾內容
│   ├── media/            # 嵌入圖片
│   │   └── image*.{png,jpeg}
│   └── _rels/
│       └── document.xml.rels
└── docProps/
    ├── core.xml          # 中繼資料
    └── app.xml           # 應用程式資訊
```

### 依賴套件

- [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) (v0.12.0+) — Model Context Protocol 實作
- [ooxml-swift](https://github.com/PsychQuant/ooxml-swift) (**v0.12.0+**) — OOXML 解析 + **preserve-by-default round-trip 架構**（PreservedArchive、RelationshipIdAllocator、ContentTypesOverlay）、`FieldParser`、`OMMLParser`、`updateAllFields()`、`MathAccent`
- [latex-math-swift](https://github.com/PsychQuant/latex-math-swift) (**v0.1.0+**) — LaTeX 子集 → OMML `MathComponent` AST parser（v3.2.0+ 由 `insert_equation` 使用）
- [markdown-swift](https://github.com/PsychQuant/markdown-swift) (v0.2.0+) — Markdown 生成
- [word-to-md-swift](https://github.com/PsychQuant/word-to-md-swift) (v0.4.0+) — Word 轉 Markdown

## 與其他方案比較

| 功能 | Anthropic Word MCP | python-docx | docx npm | **che-word-mcp** |
|------|-------------------|-------------|----------|------------------|
| 語言 | Node.js | Python | Node.js | **Swift** |
| 後端 | AppleScript | OOXML | OOXML | **OOXML** |
| 需要 Word | 是 | 否 | 否 | **否** |
| 執行環境 | Node.js | Python | Node.js | **無** |
| 單一執行檔 | 否 | 否 | 否 | **是** |
| 工具數量 | ~10 | N/A | N/A | **233** |
| 圖片支援 | 有限 | 是 | 是 | **是** |
| 註解 | 否 | 有限 | 有限 | **是** |
| 追蹤修訂 | 否 | 否 | 否 | **是** |
| 目錄 | 否 | 有限 | 否 | **是** |
| 表單欄位 | 否 | 否 | 否 | **是** |

## 效能測試

Apple Silicon (M4 Max, 128GB RAM) 測試結果：

### 讀取效能

| 檔案大小 | 時間 |
|----------|------|
| 40 KB（論文大綱）| **72 ms** |
| 431 KB（複雜文件）| **31 ms** |

### 寫入效能

| 操作 | 內容 | 時間 |
|------|------|------|
| 基本寫入 | 建立 + 3 段落 + 儲存 | **19 ms** |
| 複雜文件 | 標題 + 段落 + 表格 + 清單 | **21 ms** |
| 大量寫入 | **50 個段落** + 儲存 | **28 ms** |

### 為什麼這麼快？

- **原生 Swift 編譯** - 無需啟動解譯器
- **直接操作 OOXML** - 不需要 Microsoft Word 程序
- **高效 ZIP 處理** - 使用 ZIPFoundation 壓縮
- **記憶體操作** - 只在儲存時寫入磁碟

相比 python-docx（啟動約 200ms）或 docx npm（啟動約 150ms），che-word-mcp 快 **10-20 倍**。

## 授權

MIT License

## 作者

鄭澈 ([@PsychQuant](https://github.com/PsychQuant))

### Contributors

- [@ildunari](https://github.com/ildunari) — session state management（v1.17.0）

## 相關專案

- [che-apple-mail-mcp](https://github.com/PsychQuant/che-apple-mail-mcp) - Apple Mail MCP 伺服器
- [che-ical-mcp](https://github.com/PsychQuant/che-ical-mcp) - macOS 行事曆 MCP 伺服器
