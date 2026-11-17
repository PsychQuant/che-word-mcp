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
- **Theme + 頁首頁尾 + 浮水印 CRUD（v3.3.0+）**：12 個新工具操作 `word/theme/theme1.xml` 編輯、頁首頁尾列舉與刪除、浮水印 VML 偵測。直接解 document中文字體 fallback 路徑：`update_theme_fonts({ minor: { ea: "DFKai-SB" } })`。
- **Comment Threads + People + Notes Update + Web Settings（v3.4.0+）**：13 個新工具，涵蓋協作註解 metadata、`people.xml` 作者紀錄、in-place endnote/footnote 編輯（保留 ID）、`webSettings.xml` 設定。
- **完整 LaTeX 子集 for `insert_equation`（v3.2.0+）**：委派給 [`latex-math-swift`](https://github.com/PsychQuant/latex-math-swift)。支援 `\frac`、`\sqrt`、`\hat`/`\bar`/`\tilde` accent、`\left/\right` delimiter、`\sum`/`\int`/`\prod` n-ary 含 bound、function names、limits、`\text{}`、全部希臘字母（含 `\varepsilon` 變體）、常用運算子。
- **Text-Anchor 插入**：`insert_caption` / `insert_image_from_path` 支援 `after_text` / `before_text`，省去先 search 再 insert 的兩段式流程
- **批次操作**：`replace_text_batch` / `search_text_batch` 把 N 次 RPC 壓縮成一次
- **Session State API**：SHA256 + mtime 磁碟 drift 偵測、`revert_to_disk` / `reload_from_disk` / `check_disk_drift`
- **結構化 Readback**：`list_captions` / `list_equations` / `update_all_fields`（F9 等效），論文審閱工作流必備
- **完整 OOXML 支援**：完整支援表格、樣式、圖片、頁首/頁尾、註解、腳註等
- **跨平台**：支援 macOS（以及其他支援 Swift 的平台）

## 版本歷史

各版本的變更見 [CHANGELOG.md](CHANGELOG.md)。

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

## 表單整理工具（`source_path` → `output_path`）

`classify_form` 與 `apply_form`（#300）用 ooxml-swift 的 DocxForm 整理已填寫的表單，也就是 `macdoc word form classify|apply` 背後的函式庫。兩者只收檔案路徑，不用 `doc_id`：DocxForm 以字串修改 `word/document.xml` 裡被點名的元素，其餘 part 逐位元組照抄，文件不會經過 session 持有的 typed model。它們讀的是磁碟上的檔案，所以呼叫前要先把 session 裡的編輯存檔。

```
classify_form: { "source_path": "/path/to/form.docx", "include_grid": true }
apply_form: { "source_path": "/path/to/form.docx", "output_path": "/path/to/tidy.docx",
              "fields": ["1A2B3C4D"], "table_defaults": [{ "anchor": "1A2B3C4E", "columns": [{ "from": 2 }] }] }
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

## 可用工具（共 248 個）

### 文件管理 (6 個)

| 工具 | 說明 |
|------|------|
| `create_document` | 建立新的 Word 文件 |
| `open_document` | 開啟現有的 .docx 檔案（v3.0.0 起 track_changes 預設為 `false`） |
| `save_document` | 儲存文件為 .docx |
| `close_document` | 關閉文件（dirty 時需 `discard_changes: true` 才能丟棄變更） |
| `finalize_document` | 儲存並關閉（一步到位） |
| `list_open_documents` | 列出所有已開啟的文件 |

### 文件資訊與屬性 (4 個)

| 工具 | 說明 |
|------|------|
| `get_document_info` | 取得文件資訊（段落數、字數、圖片等） |
| `get_document_properties` | 取得文件屬性（標題、作者、建立日期等）（支援 Direct Mode） |
| `set_document_properties` | 設定文件屬性（標題、作者、主旨、關鍵字等） |
| `get_word_count_by_section` | 按區段統計字數，可自訂分隔標記（如 References）並排除特定區段（支援 Direct Mode） |

### Session State API (7 個)

| 工具 | 說明 |
|------|------|
| `get_session_state` | 回傳 `{ source_path, disk_hash_hex, disk_mtime_iso8601, is_dirty, track_changes_enabled }` |
| `get_document_session_state` | 舊版 session 快照（保留以維持向下相容） |
| `revert_to_disk` | 重新讀取來源檔案，丟棄記憶體中的編輯（destructive by design） |
| `reload_from_disk` | 協作式重載；dirty 文件需帶 `force: true` |
| `check_disk_drift` | 僅回報狀態：`{ drifted, disk_mtime, stored_mtime, disk_hash_matches }` |
| `checkpoint` | 把目前的 session 寫到 `<source>.autosave.docx`（或指定的 `path`），不清除 dirty 狀態 |
| `recover_from_autosave` | 從 `<source>.autosave.docx` 還原 session（dirty session 要帶 `discard_changes: true`） |

### 內容操作 (12 個)

| 工具 | 說明 |
|------|------|
| `get_text` | 取得純文字內容 |
| `get_paragraphs` | 取得所有段落（含格式資訊） |
| `get_document_text` | 取得 .docx 檔案的完整純文字內容（get_text 的別名，Direct Mode, Tier 1） |
| `get_paragraph_runs` | 取得指定段落的所有 runs（文字片段）及其格式資訊，包含顏色、粗體、斜體等 |
| `get_text_with_formatting` | 取得文件文字，格式以 Markdown 記號標出（粗體、斜體、`{{color:red}}`） |
| `estimate_paragraph_for_page` | 估算 Word UI 第 N 頁大約落在哪些 get_paragraphs 段落索引 |
| `insert_paragraph` | 插入新段落 |
| `insert_text` | 在指定段落的指定位置插入文字 |
| `update_paragraph` | 更新段落內容 |
| `delete_paragraph` | 刪除段落 |
| `replace_text` | 跨 run 安全的搜尋取代，支援 `scope`（body\|all）+ `regex` + `$1..$N` 回溯引用 |
| `replace_text_batch` | **v2.2.0** — 依序執行 N 次取代、結尾單次儲存、`dry_run` / `stop_on_first_failure` |

### 搜尋 (5 個)

| 工具 | 說明 |
|------|------|
| `search_text` | 在文件中搜尋指定文字，返回所有符合的位置（支援 Direct Mode） |
| `search_text_batch` | **v2.2.0** — 多 query 聚合搜尋，支援 Direct + Session Mode |
| `search_text_with_formatting` | 搜尋文字並返回匹配位置及其格式標記（粗體、斜體、顏色等） |
| `search_by_formatting` | 搜尋具有特定格式的文字（如紅色、粗體） |
| `list_all_formatted_text` | 列出所有具有特定格式的文字 |

### 格式化 (4 個)

| 工具 | 說明 |
|------|------|
| `format_text` | 設定文字格式（粗體、斜體、顏色、字型） |
| `set_paragraph_format` | 設定段落格式（對齊、間距） |
| `apply_style` | 套用內建或自訂樣式 |
| `set_language` | 設定文字的校訂語言（用於拼字檢查） |

### 段落版面 (6 個)

| 工具 | 說明 |
|------|------|
| `set_keep_with_next` | 設定段落與下一段同頁（避免分頁時分離） |
| `set_keep_lines` | 設定段落不分頁（整個段落保持在同一頁） |
| `set_page_break_before` | 設定段落前分頁（段落從新頁開始） |
| `set_widow_orphan` | 設定段落避頭尾（孤行/寡行控制） |
| `insert_tab_stop` | 在段落中設定定位點 |
| `clear_tab_stops` | 清除段落的所有定位點 |

### 表格 (21 個)

| 工具 | 說明 |
|------|------|
| `insert_table` | 插入表格（可含資料） |
| `get_tables` | 取得所有表格資訊 |
| `update_cell` | 更新儲存格內容 |
| `delete_table` | 刪除表格 |
| `merge_cells` | 合併儲存格（水平或垂直） |
| `set_table_style` | 設定表格邊框和底色 |
| `add_row_to_table` | 在表格中新增一列 |
| `delete_row_from_table` | 從表格中刪除一列 |
| `add_column_to_table` | 在表格中新增一欄 |
| `delete_column_from_table` | 從表格中刪除一欄 |
| `set_cell_width` | 設定表格儲存格寬度 |
| `set_cell_vertical_alignment` | 設定表格儲存格的垂直對齊方式 |
| `set_row_height` | 設定表格列高 |
| `set_table_alignment` | 設定表格在頁面上的對齊方式 |
| `get_cell_paragraphs` | 列出表格儲存格內的段落與 `paragraph_index`（支援 Direct Mode），供 `update_cell_paragraph` 定址 |
| `update_cell_paragraph` | 只改寫儲存格內第 `paragraph_index` 個段落的文字，同格其他段落不動 |
| `set_table_conditional_style` | 套用條件式格式（firstRow / lastRow / bandedRows 等 10 種區域）到表格的 tblStylePr |
| `insert_nested_table` | 在指定 cell 內插入新表格（深度上限 5 層，超過會 throw nested_too_deep） |
| `set_table_layout` | 切換表格版面配置（fixed = 固定欄寬 / autofit = 自動） |
| `set_header_row` | 標記表格標題列（emit `<w:tblHeader/>`），跨頁分割時自動重複 |
| `set_table_indent` | 設定表格左縮排（twips 單位，emit `<w:tblInd>`） |

### 樣式管理 (8 個)

| 工具 | 說明 |
|------|------|
| `list_styles` | 列出所有可用樣式 |
| `create_style` | 建立自訂樣式 |
| `update_style` | 更新樣式定義 |
| `delete_style` | 刪除自訂樣式 |
| `get_style_inheritance_chain` | 回傳樣式繼承鏈（從查詢樣式向上沿 basedOn 至根） |
| `link_styles` | 雙向連結 paragraph 與 character 樣式（emit `<w:link>`） |
| `set_latent_styles` | 設定 `<w:latentStyles>` block — 控制 Quick Style Gallery 中內建樣式的可見性 |
| `add_style_name_alias` | 為樣式加入本地化名稱別名（同 lang 已存在則替換） |

### 編號與清單 (12 個)

| 工具 | 說明 |
|------|------|
| `insert_bullet_list` | 插入項目符號清單 |
| `insert_numbered_list` | 插入編號清單 |
| `set_list_level` | 設定清單縮排層級 |
| `set_outline_level` | 設定段落的大綱層級（用於生成目錄和導覽） |
| `list_numbering_definitions` | 列出 numbering.xml 所有 abstractNum + num 定義 |
| `get_numbering_definition` | 依 numId 取得單一 numbering 定義（含 abstractNumId 與 levels） |
| `create_numbering_definition` | 建立新的 abstractNum + 配對 num（最多 9 層），回傳新 numId |
| `override_numbering_level` | 為 num 加 lvlOverride，覆寫指定 level 的起始值 |
| `assign_numbering_to_paragraph` | 將 numId+level 指派到段落（emit `<w:numPr>`） |
| `continue_list` | 延續既有 list — 將同一 num_id 指派給新段落 |
| `start_new_list` | 從既有 abstractNum 建立新 num 並指派到段落，回傳新 numId |
| `gc_orphan_numbering` | 刪除無段落引用的 num 定義（abstractNum 不會刪除），回傳被刪 num_id 陣列 |

### 分節與頁面設定 (19 個)

| 工具 | 說明 |
|------|------|
| `set_page_size` | 設定頁面大小（A4、Letter 等） |
| `set_page_margins` | 設定頁邊距 |
| `set_page_orientation` | 設定直向或橫向 |
| `insert_page_break` | 插入分頁符號 |
| `insert_section_break` | 插入分節符號 |
| `get_section_properties` | 取得文件的節屬性（頁面設定等）（支援 Direct Mode） |
| `insert_continuous_section_break` | 插入連續分節符（不換頁的分節） |
| `insert_column_break` | 在指定段落插入分欄符號 |
| `set_columns` | 設定文件多欄排版（預設整份文件，或指定段落後插入分節符） |
| `set_line_numbers` | 設定文件行號顯示 |
| `set_page_borders` | 設定頁面邊框（四邊可獨立顯示/隱藏，樣式/顏色/粗細/起算位置四邊共用） |
| `set_text_direction` | 設定段落或文件的文字方向（支援直書） |
| `get_all_sections` | 回傳每個 section 的完整屬性摘要（page_size / margins / orientation / line_numbers / vertical_alignment / page_number_format / break_type / titlePg / header+footer refs） |
| `set_section_break_type` | 切換分節符類型（emit `<w:type>`） |
| `set_section_vertical_alignment` | 設定 section 內容垂直對齊（emit `<w:vAlign>`） |
| `set_page_number_format` | 設定頁碼格式與起始值（emit `<w:pgNumType>`） |
| `set_line_numbers_for_section` | 啟用 section 行號標記（emit `<w:lnNumType>`） |
| `set_title_page_distinct` | 切換首頁獨立頁首頁尾（emit/移除 `<w:titlePg/>`） |
| `set_section_header_footer_references` | 為 section 指派 default/first/even 類型的 header/footer rId |

### 頁首、頁尾與浮水印 (20 個)

| 工具 | 說明 |
|------|------|
| `add_header` | 新增頁首內容（v3.3.0+ 用 `RelationshipIdAllocator` — overlay mode 不會 rId 衝突） |
| `update_header` | 更新頁首內容（保留檔名 + rId；in-place 覆寫 archiveTempDir） |
| `add_footer` | 新增頁尾內容 |
| `update_footer` | 更新頁尾內容 |
| `insert_page_number` | 插入頁碼欄位 |
| `insert_watermark` | 插入斜向文字浮水印，寫進每個 header part（沒有 header 時自動建立） |
| `insert_image_watermark` | 插入置中的圖片浮水印（png、jpg、jpeg、gif），寫進每個 header part |
| `remove_watermark` | 移除每個 header part 的文字與圖片浮水印（沒有浮水印時也回成功） |
| `list_headers` | 列舉所有 header parts，含 type（default/first/even）+ section_id + has_watermark |
| `get_header` | 讀取文字 + 完整 XML + watermark 結構 |
| `delete_header` | 移除 typed model entry + tempDir 檔案 + Relationship + Content_Types Override |
| `list_watermarks` | 掃描所有 header 中的 VML `PowerPlusWaterMarkObject` shapes（text 或 image） |
| `get_watermark` | 單一 header 的 watermark 詳細資訊（無 watermark 回 `null`） |
| `list_footers` | 列舉所有 footer parts，含 type + section_id + has_page_number |
| `get_footer` | 讀取文字 + XML + 解析後的 fields（PAGE / NUMPAGES / REF / STYLEREF） |
| `delete_footer` | 與 delete_header 對稱 |
| `enable_even_odd_headers` | 切換文件級 `<w:evenAndOddHeaders/>` flag（settings.xml） |
| `link_section_header_to_previous` | 讓 section 共用前一 section 的 header XML part（共用 rId） |
| `unlink_section_header_from_previous` | 為 section 建立獨立 header XML part（複製當前共用的 part） |
| `get_section_header_map` | 回傳每個 section 的 header / footer 檔案對應（哪個 section 用哪個 headerN.xml） |

### Theme 編輯 (4 個)

| 工具 | 說明 |
|------|------|
| `get_theme` | 讀取 `word/theme/theme1.xml` 的 major/minor 字體 slot（latin/ea/cs）+ 色盤（accent1-6, hyperlink, followedHyperlink） |
| `update_theme_fonts` | 部分更新字體 slot — 例：`{ minor: { ea: "DFKai-SB" } }` 修復 document中文字體 |
| `update_theme_color` | 按 slot 名稱 hex color 更新（拒絕無效 slot + 非 6 字元 hex） |
| `set_theme` | 低階 escape hatch — 完整覆寫 theme1.xml（驗證 `<a:theme>` 根 + well-formed XML） |

### 圖片 (9 個)

| 工具 | 說明 |
|------|------|
| `insert_image` | 插入內嵌圖片（PNG、JPEG） |
| `insert_image_from_path` | **v2.0.0+** — width/height 可省略（`ImageDimensions.detect` 自動長寬比），支援 `into_table_cell` + `after_text` / `before_text` anchor |
| `insert_floating_image` | 插入浮動圖片（文繞圖） |
| `update_image` | 更新圖片屬性 |
| `delete_image` | 刪除圖片 |
| `list_images` | 列出所有圖片 |
| `set_image_style` | 設定圖片邊框和效果 |
| `export_image` | 匯出單一圖片到檔案（會在內文、頁首頁尾與圖表的圖片中查找） |
| `export_all_images` | 匯出所有圖片（內文、頁首頁尾、圖表）到目錄；同名檔案加上 `_2`、`_3` 等後綴 |

### 圖表標題 (6 個)

| 工具 | 說明 |
|------|------|
| `insert_caption` | **v2.0.0+** — 輸出真正的 OOXML SEQ 欄位（原本是寫死的字串）。支援中英標籤（`Figure`/`Table`/`Equation`/`圖`/`表`/`公式`）、5 種 anchor（`paragraph_index` / `after_image_id` / `after_table_index` / `after_text` / `before_text`）、可選 `STYLEREF` 章節編號前綴 |
| `list_captions` | **v3.1.0** — 列出所有 caption 段落，含 label / sequence_number / caption_text / paragraph_index |
| `get_caption` | **v3.1.0** — 單一 caption 詳細資訊（含 STYLEREF 抽出的 `chapter_number`） |
| `update_caption` | **v3.1.0** — 修改 caption 文字或 label，不破壞 SEQ 欄位結構 |
| `delete_caption` | **v3.1.0** — 移除 caption 段落 |
| `wrap_caption_seq` | 把內文中符合 `pattern` 的圖表標號數字包成 SEQ 欄位 |

### 公式 (8 個)

| 工具 | 說明 |
|------|------|
| `insert_equation` | **v2.0.0+** — 透過 `MathComponent` AST（9 種型別）輸出結構正確的 OMML。主要路徑：`components:` tree；備援：`latex:` 子集（`\frac`、`\sqrt`、`x^{y}`、希臘字母、∑/∫/∏） |
| `list_equations` | **v3.1.0** — 列出所有 `<m:oMath>` run，含 display_mode 旗標 |
| `get_equation` | **v3.1.0** — 單一公式詳細資訊，含 component 概要 |
| `update_equation` | **v3.1.0** — 置換指定公式的 components tree |
| `delete_equation` | **v3.1.0** — 移除公式 run 或空段落 |
| `find_inline_math_gaps` | 掃描段落中疑似遺失 inline math symbol 的連續空白 gap，回傳位置與前後文（支援 Direct Mode） |
| `splice_omath_from_source` | 從另一份文件的段落逐字拷貝一個 `<m:oMath>` 區塊 |
| `splice_paragraph_omath_from_source` | 把來源段落的所有 `<m:oMath>` 區塊依序拷貝到目標段落的對應位置 |

### 匯出與比對 (6 個)

| 工具 | 說明 |
|------|------|
| `export_text` | 匯出為純文字 |
| `export_markdown` | 匯出為 Markdown（內嵌 `word-to-md-swift`） |
| `export_revision_summary_markdown` | **v1.19.0** — 單一文件的修訂時間軸（論文審閱） |
| `compare_documents_markdown` | **v1.19.0** — 多文件累積修訂時間軸 |
| `compare_documents` | 比對兩個 Word 文件的差異（段落層級），只回傳差異部分 |
| `export_comment_threads_markdown` | **v1.19.0** — 註解對話串，含 author 別名正規化 |

### 腳本管線 (3 個)

| 工具 | 說明 |
|------|------|
| `export_script` | docx → full-fidelity .mdocx.swift 重建腳本（與 macdoc word reverse 同一條 transcoder code path：raw byte-equal floor + typed DSL 升級） |
| `get_script_coverage` | docx 的 dual-track 覆蓋率報告（與 macdoc word reverse --coverage 同數字）：每個 XML part 的 DSL/raw channel、位元組數、DSL ratio，加 aggregate |
| `execute_script` | .mdocx.swift 重建腳本 → docx（ScriptImporter 同一條 code path） |

### 超連結與書籤 (12 個)

| 工具 | 說明 |
|------|------|
| `insert_hyperlink` | 插入外部超連結 |
| `insert_internal_link` | 插入連結至書籤 |
| `insert_cross_reference` | 插入交互參照（連結到書籤、標題、圖表標號等） |
| `update_hyperlink` | 更新超連結 |
| `delete_hyperlink` | 刪除超連結 |
| `list_hyperlinks` | 列出文件中所有的超連結（支援 Direct Mode） |
| `insert_bookmark` | 插入書籤 |
| `delete_bookmark` | 刪除書籤 |
| `list_bookmarks` | 列出文件中所有的書籤（支援 Direct Mode） |
| `insert_url_hyperlink` | 插入外部 URL 連結（自動建立 Hyperlink character style 若不存在） |
| `insert_bookmark_hyperlink` | 插入內部書籤連結（emit w:anchor，無 r:id） |
| `insert_email_hyperlink` | 插入 mailto: 連結（自動 URL-encode subject） |

### 註解與修訂 (22 個)

| 工具 | 說明 |
|------|------|
| `insert_comment` | 插入註解 |
| `update_comment` | 更新註解文字 |
| `delete_comment` | 刪除註解 |
| `list_comments` | 列出所有註解 |
| `reply_to_comment` | 回覆現有註解 |
| `resolve_comment` | 標記註解為已解決 |
| `add_comment_reply` | 回覆 thread root 註解，可用 template/vars，並可在同一次呼叫標記 resolved |
| `bulk_resolve_comments` | 批次標記多個註解為 resolved |
| `find_unresolved_comments` | 列出尚未 resolved 的頂層註解（支援 Direct Mode，可包含 anchor context） |
| `list_comment_threads` | **v3.4.0** — 列舉 thread 結構（root_comment_id + replies + resolved + durable_id），用 typed `Comment.parentId`（從 `commentsExtended.xml` 解析） |
| `get_comment_thread` | 讀取 root + 走遍 children 建構完整 reply tree |
| `sync_extended_comments` | 回報 typed comment count，用於 triplet sync 規劃 |
| `enable_track_changes` | 啟用追蹤修訂 |
| `disable_track_changes` | 停用追蹤修訂 |
| `get_revisions` | 取得文件中所有的修訂追蹤記錄 |
| `accept_revision` | 接受修訂 |
| `reject_revision` | 拒絕修訂 |
| `accept_all_revisions` | 接受文件中所有的修訂 |
| `reject_all_revisions` | 拒絕文件中所有的修訂 |
| `insert_text_as_revision` | 在指定段落位置插入文字並包覆 `<w:ins>` 修訂標記（需先 enable_track_changes） |
| `delete_text_as_revision` | 刪除指定段落 [start, end) 範圍的文字並包覆 `<w:del>` 修訂標記（需先 enable_track_changes） |
| `move_text_as_revision` | 將文字從來源段落 [from_start, from_end) 移到目標段落 to_position，產生成對的 `<w:moveFrom>`/`<w:moveTo>` 修訂（需先 enable_track_changes） |

### People — 註解作者 (4 個)

| 工具 | 說明 |
|------|------|
| `list_people` | 解析 `word/people.xml` 的 `<w15:person>` 紀錄 |
| `add_person` | 新增 entry；不存在則 auto-create `people.xml` part；重名加 `_2` 後綴 |
| `update_person` | 更新 display_name（author 屬性 swap） |
| `delete_person` | 移除 entry；回報 `comments_orphaned` 數 |

### 腳註與尾註 (10 個)

| 工具 | 說明 |
|------|------|
| `insert_footnote` | 插入腳註 |
| `delete_footnote` | 刪除腳註 |
| `insert_endnote` | 插入尾註 |
| `delete_endnote` | 刪除尾註 |
| `list_footnotes` | 支援 Direct Mode |
| `list_endnotes` | 支援 Direct Mode |
| `get_footnote` | 按整數 ID 讀取文字 + runs |
| `update_footnote` | In-place 替換文字，保留 footnote_id（cross-references 仍有效） |
| `get_endnote` | 按整數 ID 讀取文字 + runs |
| `update_endnote` | In-place 替換文字，保留 endnote_id |

### Web Settings (2 個)

| 工具 | 說明 |
|------|------|
| `get_web_settings` | 解析 `word/webSettings.xml` 旗標元素（`relyOnVML` / `optimizeForBrowser` / `allowPNG` / `doNotSaveAsSingleFile`）；無 part 時回 `{ error: "no webSettings part" }` |
| `update_web_settings` | 按 key 部分更新；不存在則 auto-create part |

### 欄位代碼 (7 個)

| 工具 | 說明 |
|------|------|
| `insert_if_field` | 插入 IF 條件欄位 |
| `insert_calculation_field` | 插入計算欄位（SUM、AVERAGE 等） |
| `insert_date_field` | 插入日期時間欄位 |
| `insert_page_field` | 插入頁碼欄位 |
| `insert_merge_field` | 插入合併列印欄位 |
| `insert_sequence_field` | 插入自動編號序列 |
| `update_all_fields` | **v3.1.0** — F9 等效的 SEQ 重編號，涵蓋 body + headers + footers + footnotes + endnotes。當 `pStyle=="Heading N"` 匹配 SEQ `resetLevel` 時支援章節重置 |

### 內容控制項（SDT） (13 個)

| 工具 | 說明 |
|------|------|
| `insert_content_control` | 插入 SDT 內容控制項 |
| `insert_repeating_section` | 插入重複區段（Word 2012+） |
| `insert_checkbox` | 插入表單核取方塊 |
| `insert_dropdown` | 插入表單下拉選單 |
| `insert_text_field` | 插入表單文字欄位 |
| `list_content_controls` | 列出文件中所有的內容控制項（SDT），支援巢狀展開 |
| `get_content_control` | 依 id / tag / alias 取得單一內容控制項，含完整 metadata 與內容 XML |
| `list_repeating_section_items` | 列出指定重複區段 SDT 內所有項目（順序、id、文字內容） |
| `list_custom_xml_parts` | 列出文件的 CustomXml parts——尚未實作，目前一律回傳空陣列 |
| `update_content_control_text` | 修改純文字 SDT 的文字內容（保留 sdtPr） |
| `replace_content_control_content` | 替換 SDT 的完整 sdtContent XML（白名單：禁止 w:sdt / w:body / w:sectPr / XML 宣告） |
| `delete_content_control` | 刪除指定 SDT，可選擇是否保留內容 |
| `update_repeating_section_item` | 修改重複區段內單一項目的文字內容 |

### 表單整理 (2 個)

| 工具 | 說明 |
|------|------|
| `classify_form` | 列出 .docx 表單裡帶 `w14:paraId` 的段落（paraId、類型、全文），供 `apply_form` 點名（讀磁碟上的檔案） |
| `apply_form` | 整理已填寫的 .docx 表單（與 `macdoc word form apply` 同一個函式庫），結果寫到 `output_path` |

### 文件保護 (5 個)

| 工具 | 說明 |
|------|------|
| `restrict_editing_region` | 在 `[start_paragraph, end_paragraph]` 前後寫入 `<w:permStart>`／`<w:permEnd>`，標出可編輯區域（`start_paragraph` 須 ≥ 1） |
| `protect_document` | 設定文件保護（限制編輯、唯讀）——尚未實作，呼叫會回 isError（#172） |
| `unprotect_document` | 移除文件保護——尚未實作，呼叫會回 isError（#172） |
| `set_document_password` | 設定文件開啟密碼——尚未實作，呼叫會回 isError（開啟密碼是容器層級的加密，不在 OOXML 範圍內，#172） |
| `remove_document_password` | 移除文件開啟密碼——尚未實作，呼叫會回 isError（#172） |

### 進階功能 (11 個)

| 工具 | 說明 |
|------|------|
| `insert_toc` | 插入目錄 |
| `insert_table_of_figures` | 插入圖表目錄 |
| `insert_index` | 插入索引（根據已標記的索引項目） |
| `insert_index_entry` | 標記文字為索引項目（用於生成索引） |
| `set_paragraph_border` | 設定段落邊框 |
| `set_paragraph_shading` | 設定段落背景色 |
| `set_character_spacing` | 設定字元間距 |
| `set_text_effect` | 設定文字動畫效果 |
| `insert_horizontal_line` | 在指定段落插入水平線（段落邊框方式） |
| `insert_drop_cap` | 將段落首字放大（首字下沉效果） |
| `insert_symbol` | 在指定段落插入特殊符號（使用字型符號或 Unicode） |

> **備註**：上面的表列出 server 註冊的全部工具；新增或移除工具卻沒有更新這些表時，`Issue306ToolCountDocsTests` 會讓 `swift test` 失敗。每個工具完整的說明與參數，執行 server 後呼叫 `tools/list` 查看。

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
