# che-word-mcp

以 Swift 原生開發的 MCP (Model Context Protocol) 伺服器，用於操作 Microsoft Word 文件 (.docx)。這是**首個 Swift OOXML 函式庫**，直接操作 Office Open XML 而不依賴任何第三方 Word 函式庫。

[English](README.md)

## 特色

- **純 Swift 實作**：不需要 Node.js、Python 或其他執行環境
- **直接操作 OOXML**：直接處理 XML，不需要安裝 Microsoft Word
- **單一執行檔**：只有一個 binary 檔案
- **83 個 MCP 工具**：完整的文件操作功能
- **完整 OOXML 支援**：完整支援表格、樣式、圖片、頁首/頁尾、註解、腳註等
- **跨平台**：支援 macOS（以及其他支援 Swift 的平台）

## 安裝

### 系統需求

- macOS 13.0+ (Ventura 或更新版本)
- Swift 5.9+

### 從原始碼編譯

```bash
git clone https://github.com/kiki830621/che-word-mcp.git
cd che-word-mcp
swift build -c release
```

執行檔位於 `.build/release/CheWordMCP`

### 加入 Claude Code

```bash
claude mcp add che-word-mcp /path/to/che-word-mcp/.build/release/CheWordMCP
```

### 加入 Claude Desktop

編輯 `~/Library/Application Support/Claude/claude_desktop_config.json`：

```json
{
  "mcpServers": {
    "che-word-mcp": {
      "command": "/path/to/che-word-mcp/.build/release/CheWordMCP"
    }
  }
}
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
  https://raw.githubusercontent.com/kiki830621/che-word-mcp/main/skills/che-word-mcp/SKILL.md
```

或從專案複製：

```bash
cp -r /path/to/che-word-mcp/skills/che-word-mcp .claude/skills/
```

## 可用工具（共 83 個）

### 文件管理 (6 個)

| 工具 | 說明 |
|------|------|
| `create_document` | 建立新的 Word 文件 |
| `open_document` | 開啟現有的 .docx 檔案 |
| `save_document` | 儲存文件為 .docx |
| `close_document` | 關閉已開啟的文件 |
| `list_open_documents` | 列出所有已開啟的文件 |
| `get_document_info` | 取得文件統計資訊 |

### 內容操作 (6 個)

| 工具 | 說明 |
|------|------|
| `get_text` | 取得純文字內容 |
| `get_paragraphs` | 取得所有段落（含格式資訊）|
| `insert_paragraph` | 插入新段落 |
| `update_paragraph` | 更新段落內容 |
| `delete_paragraph` | 刪除段落 |
| `replace_text` | 搜尋並取代文字 |

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

### 頁首與頁尾 (5 個)

| 工具 | 說明 |
|------|------|
| `add_header` | 新增頁首內容 |
| `update_header` | 更新頁首內容 |
| `add_footer` | 新增頁尾內容 |
| `update_footer` | 更新頁尾內容 |
| `insert_page_number` | 插入頁碼欄位 |

### 圖片 (6 個)

| 工具 | 說明 |
|------|------|
| `insert_image` | 插入內嵌圖片（PNG、JPEG）|
| `insert_floating_image` | 插入浮動圖片（文繞圖）|
| `update_image` | 更新圖片屬性 |
| `delete_image` | 刪除圖片 |
| `list_images` | 列出所有圖片 |
| `set_image_style` | 設定圖片邊框和效果 |

### 匯出 (2 個)

| 工具 | 說明 |
|------|------|
| `export_text` | 匯出為純文字 |
| `export_markdown` | 匯出為 Markdown |

### 超連結與書籤 (6 個)

| 工具 | 說明 |
|------|------|
| `insert_hyperlink` | 插入外部超連結 |
| `insert_internal_link` | 插入連結至書籤 |
| `update_hyperlink` | 更新超連結 |
| `delete_hyperlink` | 刪除超連結 |
| `insert_bookmark` | 插入書籤 |
| `delete_bookmark` | 刪除書籤 |

### 註解與修訂 (10 個)

| 工具 | 說明 |
|------|------|
| `insert_comment` | 插入註解 |
| `update_comment` | 更新註解文字 |
| `delete_comment` | 刪除註解 |
| `list_comments` | 列出所有註解 |
| `reply_to_comment` | 回覆現有註解 |
| `resolve_comment` | 標記註解為已解決 |
| `enable_track_changes` | 啟用追蹤修訂 |
| `disable_track_changes` | 停用追蹤修訂 |
| `accept_revision` | 接受修訂 |
| `reject_revision` | 拒絕修訂 |

### 腳註與尾註 (4 個)

| 工具 | 說明 |
|------|------|
| `insert_footnote` | 插入腳註 |
| `delete_footnote` | 刪除腳註 |
| `insert_endnote` | 插入尾註 |
| `delete_endnote` | 刪除尾註 |

### 欄位代碼 (7 個)

| 工具 | 說明 |
|------|------|
| `insert_if_field` | 插入 IF 條件欄位 |
| `insert_calculation_field` | 插入計算欄位（SUM、AVERAGE 等）|
| `insert_date_field` | 插入日期時間欄位 |
| `insert_page_field` | 插入頁碼欄位 |
| `insert_merge_field` | 插入合併列印欄位 |
| `insert_sequence_field` | 插入自動編號序列 |
| `insert_content_control` | 插入 SDT 內容控制項 |

### 重複區段 (1 個)

| 工具 | 說明 |
|------|------|
| `insert_repeating_section` | 插入重複區段（Word 2012+）|

### 進階功能 (9 個)

| 工具 | 說明 |
|------|------|
| `insert_toc` | 插入目錄 |
| `insert_text_field` | 插入表單文字欄位 |
| `insert_checkbox` | 插入表單核取方塊 |
| `insert_dropdown` | 插入表單下拉選單 |
| `insert_equation` | 插入數學公式 |
| `set_paragraph_border` | 設定段落邊框 |
| `set_paragraph_shading` | 設定段落背景色 |
| `set_character_spacing` | 設定字元間距 |
| `set_text_effect` | 設定文字動畫效果 |

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

- [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) (v0.10.0+) - Model Context Protocol 實作
- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) (v0.9.0+) - ZIP 壓縮/解壓縮

## 與其他方案比較

| 功能 | Anthropic Word MCP | python-docx | docx npm | **che-word-mcp** |
|------|-------------------|-------------|----------|------------------|
| 語言 | Node.js | Python | Node.js | **Swift** |
| 後端 | AppleScript | OOXML | OOXML | **OOXML** |
| 需要 Word | 是 | 否 | 否 | **否** |
| 執行環境 | Node.js | Python | Node.js | **無** |
| 單一執行檔 | 否 | 否 | 否 | **是** |
| 工具數量 | ~10 | N/A | N/A | **83** |
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

鄭澈 ([@kiki830621](https://github.com/kiki830621))

## 相關專案

- [che-apple-mail-mcp](https://github.com/kiki830621/che-apple-mail-mcp) - Apple Mail MCP 伺服器
- [che-ical-mcp](https://github.com/kiki830621/che-ical-mcp) - macOS 行事曆 MCP 伺服器
