# Two Modes: Direct Mode vs Memory Mode

che-word-mcp 提供兩種操作模式。每個 tool 只屬於一種模式，不混用（見 [消歧義原則](../../docs/DISAMBIGUATION.md)）。

## Direct Mode（`source_path`）

直接傳入 `.docx` 檔案路徑，一次呼叫完成。不需要先 `open_document`。

```
get_text(source_path="/path/to/file.docx")
export_markdown(source_path="/path/to/file.docx", path="/path/to/output.md")
```

### 特性

- **單次呼叫**：parse → 處理 → 回傳/寫檔
- **無狀態**：不佔用伺服器記憶體，處理完即釋放
- **唯讀**：不修改原始文件

### Tools 與 Fidelity Tier

| Tool | Tier | 輸出 | 必要參數 |
|------|------|------|----------|
| `get_text` | 1 | 純文字（回傳內容） | `source_path` |
| `get_document_text` | 1 | 純文字（get_text 別名） | `source_path` |
| `export_markdown` | 2 | Markdown + 圖片（寫檔） | `source_path`, `path` |
| `compare_documents` | — | 差異比較 | `path_a`, `path_b` |

### 效能

```
get_text:        source_path → DocxReader.read(~0.64s) → getText(<1ms) → 回傳文字
export_markdown: source_path → DocxReader.read(~0.64s) → WordConverter(<1ms) → 寫 .md + figures/
```

---

## Memory Mode（`doc_id`）

先用 `open_document` 將文件載入記憶體，再透過 `doc_id` 執行多次操作。

```
open_document(path="/path/to/file.docx", doc_id="report")
get_paragraphs(doc_id="report")
insert_paragraph(doc_id="report", text="New paragraph")
format_text(doc_id="report", ...)
save_document(doc_id="report", path="/path/to/output.docx")
close_document(doc_id="report")
```

### 特性

- **有狀態**：文件常駐記憶體，後續操作免重複 parse
- **多次操作**：開啟一次，可執行任意多次讀寫操作
- **適合編輯**：插入、刪除、格式化、表格操作等

### Tools

所有需要 `doc_id` 的 tools：`get_paragraphs`, `insert_paragraph`, `format_text`, `insert_table`, `save_document` 等。

### 效能

```
open_document    → DocxReader.read()   → 存入記憶體（~0.64s，只做一次）
get_paragraphs   → 讀取記憶體         → <1ms
insert_paragraph → 修改記憶體         → <1ms
save_document    → DocxWriter.write()  → ~20ms
```

---

## 選擇指引

```
需要修改文件？
  ├─ 是 → Memory Mode（open → edit → save）
  └─ 否 → 需要什麼輸出？
            ├─ 純文字 → get_text(source_path=...)           Tier 1
            ├─ Markdown + 圖片 → export_markdown(...)       Tier 2
            └─ 比較差異 → compare_documents(...)
```

| 需求 | 模式 | Tool | 原因 |
|------|------|------|------|
| AI 快速閱讀 | Direct | `get_text` | 一次呼叫，純文字 |
| AI 結構化閱讀 | Direct | `export_markdown` | Markdown 格式 + 圖片 |
| 修改文件 | Memory | `open` → edit → `save` | 需要多步驟 |
| 建立新文件 | Memory | `create` → 組裝 → `save` | 需要多步驟 |
| 比較兩份文件 | Direct | `compare_documents` | 直接吃檔案 |
