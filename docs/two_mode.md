# Two Modes: Direct Mode vs Memory Mode

che-word-mcp 提供兩種操作模式，根據使用情境選擇最有效率的方式。

## Direct Mode（直接檔案模式）

直接傳入 `.docx` 檔案路徑，一次呼叫完成。不需要先 `open_document`。

```
export_markdown(source_path="/path/to/file.docx", path="/path/to/output.md")
```

### 特性

- **單次呼叫**：一步完成 parse + 轉換 + 輸出
- **無狀態**：不佔用伺服器記憶體，處理完即釋放
- **適合唯讀**：讀取、轉換、比較等不修改文件的操作

### 支援的 Tools

| Tool | 說明 | 參數 |
|------|------|------|
| `export_markdown` | .docx → Markdown + 圖片（Tier 2） | `source_path`, `path` |
| `compare_documents` | 兩份文件差異比較 | `path_a`, `path_b` |

### 效能

```
source_path → DocxReader.read() → WordConverter → 寫入 .md
              ~~~~~~~~0.64s~~~~~~~~  ~~~~<1ms~~~~
              一次 round-trip，總計 ~0.65s
```

### 適用情境

- AI 閱讀 .docx 內容（轉 Markdown 比純文字更有結構）
- 批次轉換多份文件
- 比較兩份文件差異
- 不需要修改文件的場景

---

## Memory Mode（記憶體模式）

先用 `open_document` 將文件載入記憶體，再透過 `doc_id` 執行多次操作。

```
open_document(path="/path/to/file.docx", doc_id="report")
get_text(doc_id="report")
insert_paragraph(doc_id="report", text="New paragraph")
format_text(doc_id="report", ...)
save_document(doc_id="report", path="/path/to/output.docx")
close_document(doc_id="report")
```

### 特性

- **有狀態**：文件常駐記憶體，後續操作免重複 parse
- **多次操作**：開啟一次，可執行任意多次讀寫操作
- **適合編輯**：插入、刪除、格式化、表格操作等

### 支援的 Tools

全部 145 個 tools（含 `export_markdown` 透過 `doc_id`）。

### 效能

```
open_document → DocxReader.read()   → 存入記憶體（~0.64s，只做一次）
get_text      → doc.getText()       → <1ms（從記憶體讀取）
insert_paragraph → 修改記憶體      → <1ms
format_text      → 修改記憶體      → <1ms
save_document → DocxWriter.write()  → ~20ms
```

### 適用情境

- 修改文件（插入段落、格式化、加表格等）
- 多步驟操作（讀取 → 修改 → 存檔）
- 建立新文件（`create_document` → 組裝內容 → `save_document`）
- 需要反覆查詢同一份文件

---

## 選擇指引

```
需要修改文件？
  ├─ 是 → Memory Mode（open → edit → save）
  └─ 否 → 需要什麼格式？
            ├─ Markdown（推薦）→ Direct Mode: export_markdown(source_path=...)
            └─ 純文字 → Memory Mode: open → get_text
                         或 Direct Mode: export_markdown（Markdown 對 AI 更有用）
```

| 需求 | 推薦模式 | 原因 |
|------|----------|------|
| AI 閱讀文件 | Direct | 一次呼叫，Markdown 格式保留結構 |
| 修改文件 | Memory | 需要多步驟操作 |
| 批次轉換 | Direct | 無狀態，不佔記憶體 |
| 建立新文件 | Memory | create_document → 組裝 → save |
| 比較兩份文件 | Direct | compare_documents 直接吃檔案 |

## 混合使用

`export_markdown` 同時支援兩種模式：

```
# Direct Mode：直接從檔案轉換
export_markdown(source_path="report.docx", path="report.md")

# Memory Mode：轉換已開啟的文件
open_document(path="report.docx", doc_id="report")
insert_paragraph(doc_id="report", text="New section")
export_markdown(doc_id="report", path="report.md")
```
