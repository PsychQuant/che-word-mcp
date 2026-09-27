# `estimate_paragraph_for_page`

OOXML 沒有頁面邊界的概念——`.docx` 只有段落／表格的 XML 序列，實際分頁完全由渲染引擎
（Word／LibreOffice／…）在顯示時決定，跟字型、行距、DPI、印表機設定都有關。這個工具用
**字元密度啟發式**在沒有渲染引擎的情況下，把使用者說的「第 N 頁」對應到 `get_paragraphs`
可用的段落索引範圍——永遠是估計值，不是精確頁面邊界（見回傳的 `warning` 欄位）。

## `chars_per_page` 預設推導公式

沒有 caller 提供 `chars_per_page` 時，工具用文件自己的 section page size／margins 推算
（見 `estimateCharsPerPage`）：

```
usable_width_twips  = max(1440, pageSize.width  - margins.left - margins.right - margins.gutter)
usable_height_twips = max(1440, pageSize.height - margins.top  - margins.bottom)

chars_per_line = max(20, usable_width_twips  / 220)   # ≈ 11pt 平均字元寬度
lines_per_page = max(10, usable_height_twips / 480)   # ≈ 24pt 行高

default_chars_per_page = max(400, chars_per_line × lines_per_page)
```

這組除數（220 / 480）是針對 **12pt 單欄中英文混排論文排版**校準的保守估計，刻意寧可低估
（見 `estimateCharsPerPage` 的原始碼註解）。實測結果：

| 紙張 | 邊距 | `default_chars_per_page` |
|---|---|---|
| US Letter（12240×15840 twips） | normal（四邊 1440 twips） | 1134 |
| A4（11906×16838 twips） | normal（四邊 1440 twips） | 1178 |

英文 IEEE／ACM 雙欄排版、非 12pt 字級、或任何跟這組假設差很多的版面，caller 應該用
`chars_per_page` 覆寫這個預設值，不要依賴推導公式。

## `confidence` 分級（#143）

| 值 | 條件 | `confidence_reason` |
|---|---|---|
| `high` | caller 提供了 `chars_per_page` | `caller_provided_chars_per_page` |
| `medium` | 用預設推導、文件不含表格／圖片／顯示公式、且 `paragraph_count >= 10` | `default_heuristic_simple_layout` |
| `low` | 目標頁超出估計總頁數（`requested_page_beyond_estimated_document == true`） | `beyond_estimated_document` |
| `low` | 用預設推導，且文件含表格／圖片／顯示公式（見下「結構權重」） | `complex_layout_default_heuristic` |
| `low` | 用預設推導、簡單版面，但 `paragraph_count < 10`（樣本太短，字元計數噪訊沒機會被平均掉） | `short_doc_or_fallback_layout` |

判斷順序（由上到下，命中即停）：

1. **超出估計文件範圍優先於一切**——外推到已知內容之外，跟 `chars_per_page` 怎麼來的
   無關，一律低信心，即使 caller 有提供校準值。
2. **caller 校準永遠不會比預設啟發式低**——這是 #143 修正的語意反轉：舊邏輯把「caller
   提供了自己量測過的 `chars_per_page`」歸類成跟預設啟發式互斥的分支，結果 caller 校準
   永遠拿到 `"low"`，比什麼都不給還差。calibration 越明確，confidence 應該越高，不是
   越低。
3. 其餘情況都是使用預設推導，再依版面複雜度／文件長度細分。

## `assumed_chars_per_page` 這個名字（#146）

`assumed_chars_per_page` 這個回傳欄位名稱，在 caller 提供了 `chars_per_page` 時語意上
有點奇怪——那不是「假設」的值，是 caller 給的值。目前的決定是**不改名**（避免破壞既有
呼叫端與既有測試），改用已存在的 `layout_basis` 欄位區分兩種情況：

- `layout_basis == "caller_chars_per_page"` → `assumed_chars_per_page` 就是 caller 給的
  原始值。
- `layout_basis == "section_properties"` → `assumed_chars_per_page` 是從文件版面推導出
  的預設值。

呼叫端要知道這個數字的來源，看 `layout_basis`，不是看欄位名稱本身。

## 結構權重（#142）

表格／圖片／顯示公式不是純文字段落，字元密度假設對它們不成立，所以個別給定權重
（回傳的 `structural_breakdown` 有逐項細目）：

- 表格：`tableRows × avgCellChars`（空表格 fallback 每列 200 字）
- 圖片段落（run 帶 `w:drawing`）：文字內容之外，每張圖 +200 字
- 顯示公式段落（`unrecognizedChildren` 帶 `<m:oMathPara>` 且所有 run 皆空文字）：固定
  +120 字

這些常數是針對 12pt 論文排版校準的粗估，不是量測結果——見下一節。

## 已知限制：尚未對真實文件做校準測量（#146）

目前沒有拿真實 thesis／paper `.docx`（Word 實際分頁結果）跟這個工具的估計值做系統性
比對，所以「±N 段落準確度」這類數字目前**沒有**，不應該假裝有。這是刻意標記的缺口，
需要之後：

1. 至少 3 份不同排版的真實文件（CJK／英文／混合）
2. 用 Word 開啟後實際看每頁在哪一段結束
3. 跑 `estimate_paragraph_for_page` 逐頁比對
4. 把結果（含差距分布）寫回這份文件

在有這組量測之前，`confidence` 分級反映的是「啟發式用了多少可用資訊」，不是「跟真實
Word 分頁的距離」。

## Option A（本工具）vs Option B（raw per-paragraph breakdown）（#147）

`estimate_paragraph_for_page` 是 **Option A**：伺服器端算好一個估計值＋confidence 標籤，
heuristic 的細節（220/480 除數、200/120 常數）鎖在伺服器裡，caller 拿到的是成品。

**Option B**（新增一個 raw 工具，例如 `get_paragraph_char_breakdown`，讓 caller 自己拿
per-paragraph 字元數＋累計去算）目前**沒有實作**——這是刻意的取捨，不是遺漏：

- Option A 對一般呼叫端（多數只想知道「大概第 N 頁在哪」）更方便。
- Option B 對需要自訂校準（例如已經有自己 ground-truth 分頁資料的呼叫端）更靈活，但
  要做對需要一套獨立的 schema／權重揭露／測試，跟現有 `structural_breakdown` 有重疊但
  不完全相同的設計面，值得另開 issue 獨立評估，不在 #143–#147 這波修正範圍內。

當前的折衷：`structural_breakdown` 已經把 Option A 的黑箱打開一部分——
`tables_counted`／`tables_total_chars`／`image_only_paragraphs`／`image_chars_added`／
`display_equations`／`equation_chars_added` 這些細項讓 caller 至少看得到每個結構類別
貢獻了多少字元，即使還不能完全自訂權重。

## 錯誤處理（#145）

`page`／`chars_per_page`／`context_paragraphs` 超出範圍，或文件沒有任何段落
（`empty_document`），都會 `throw`，MCP 回應是 `isError: true` 加 `Error: ` 前綴——跟這
個 server 其他工具的錯誤慣例一致（見 #238 的先例：曾經有工具把錯誤包成看起來像成功的
JSON、`isError` 沒設，這個 class 的 bug 現在統一修成 throw）。正常回應
（`estimated_paragraph_range` 等欄位齊全）跟錯誤回應（只有 `Error: ...` 文字）不會混在
同一個 JSON 形狀裡，呼叫端不需要 fork 成兩套 parser。
