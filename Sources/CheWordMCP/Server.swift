import Foundation
import MCP
import OOXMLSwift

/// Word MCP Server - Swift OOXML Word 文件處理
class WordMCPServer {
    private let server: Server
    private let transport: StdioTransport

    /// 目前開啟的文件 (doc_id -> WordDocument)
    private var openDocuments: [String: WordDocument] = [:]

    init() async {
        self.server = Server(
            name: "che-word-mcp",
            version: "1.7.0",
            capabilities: .init(tools: .init())
        )
        self.transport = StdioTransport()

        // 註冊 Tool handlers
        await registerToolHandlers()
    }

    func run() async throws {
        // 啟動 server
        try await server.start(transport: transport)

        // 等待完成
        await server.waitUntilCompleted()
    }

    private func registerToolHandlers() async {
        let tools = allTools

        // 列出所有工具
        await server.withMethodHandler(ListTools.self) { [tools] _ in
            ListTools.Result(tools: tools)
        }

        // 處理工具呼叫
        await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self = self else {
                return CallTool.Result(content: [.text("Server unavailable")], isError: true)
            }
            return try await self.handleToolCall(params)
        }
    }

    // MARK: - Tools Definition

    private var allTools: [Tool] {
        [
            // 文件管理
            Tool(
                name: "create_document",
                description: "建立新的 Word 文件 (.docx)",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼，用於後續操作")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "open_document",
                description: "開啟現有的 Word 文件 (.docx)",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("文件路徑")
                        ]),
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼，用於後續操作")
                        ])
                    ]),
                    "required": .array([.string("path"), .string("doc_id")])
                ])
            ),
            Tool(
                name: "save_document",
                description: "儲存 Word 文件 (.docx)",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("儲存路徑")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("path")])
                ])
            ),
            Tool(
                name: "close_document",
                description: "關閉已開啟的文件",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "list_open_documents",
                description: "列出所有已開啟的文件",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:])
                ])
            ),
            Tool(
                name: "get_document_info",
                description: "取得文件資訊（段落數、字數等）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),

            // 內容操作
            Tool(
                name: "get_text",
                description: "取得文件的純文字內容",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "get_paragraphs",
                description: "取得所有段落（含格式資訊）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "insert_paragraph",
                description: "插入新段落",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("段落文字內容")
                        ]),
                        "index": .object([
                            "type": .string("integer"),
                            "description": .string("插入位置（從 0 開始），不指定則加到最後")
                        ]),
                        "style": .object([
                            "type": .string("string"),
                            "description": .string("段落樣式（如 Heading1, Normal）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("text")])
                ])
            ),
            Tool(
                name: "update_paragraph",
                description: "更新現有段落的內容",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("新的段落文字")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("index"), .string("text")])
                ])
            ),
            Tool(
                name: "delete_paragraph",
                description: "刪除段落",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("index")])
                ])
            ),
            Tool(
                name: "replace_text",
                description: "搜尋並取代文字",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "find": .object([
                            "type": .string("string"),
                            "description": .string("要搜尋的文字")
                        ]),
                        "replace": .object([
                            "type": .string("string"),
                            "description": .string("取代後的文字")
                        ]),
                        "all": .object([
                            "type": .string("boolean"),
                            "description": .string("是否取代所有符合項目（預設 true）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("find"), .string("replace")])
                ])
            ),

            // 格式化
            Tool(
                name: "format_text",
                description: "格式化指定段落的文字（粗體、斜體、顏色等）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引")
                        ]),
                        "bold": .object([
                            "type": .string("boolean"),
                            "description": .string("粗體")
                        ]),
                        "italic": .object([
                            "type": .string("boolean"),
                            "description": .string("斜體")
                        ]),
                        "underline": .object([
                            "type": .string("boolean"),
                            "description": .string("底線")
                        ]),
                        "font_size": .object([
                            "type": .string("integer"),
                            "description": .string("字型大小（點數，如 12）")
                        ]),
                        "font_name": .object([
                            "type": .string("string"),
                            "description": .string("字型名稱（如 Arial, Times New Roman）")
                        ]),
                        "color": .object([
                            "type": .string("string"),
                            "description": .string("文字顏色（RGB 十六進位，如 FF0000 表示紅色）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index")])
                ])
            ),
            Tool(
                name: "set_paragraph_format",
                description: "設定段落格式（對齊、間距等）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引")
                        ]),
                        "alignment": .object([
                            "type": .string("string"),
                            "description": .string("對齊方式：left, center, right, both")
                        ]),
                        "line_spacing": .object([
                            "type": .string("number"),
                            "description": .string("行距（倍數，如 1.5）")
                        ]),
                        "space_before": .object([
                            "type": .string("integer"),
                            "description": .string("段前間距（點數）")
                        ]),
                        "space_after": .object([
                            "type": .string("integer"),
                            "description": .string("段後間距（點數）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index")])
                ])
            ),
            Tool(
                name: "apply_style",
                description: "套用內建樣式到段落",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引")
                        ]),
                        "style": .object([
                            "type": .string("string"),
                            "description": .string("樣式名稱（如 Heading1, Heading2, Normal, Title）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("style")])
                ])
            ),

            // 表格
            Tool(
                name: "insert_table",
                description: "插入表格",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "rows": .object([
                            "type": .string("integer"),
                            "description": .string("列數")
                        ]),
                        "cols": .object([
                            "type": .string("integer"),
                            "description": .string("欄數")
                        ]),
                        "data": .object([
                            "type": .string("array"),
                            "description": .string("表格資料（二維陣列）")
                        ]),
                        "index": .object([
                            "type": .string("integer"),
                            "description": .string("插入位置")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("rows"), .string("cols")])
                ])
            ),
            Tool(
                name: "get_tables",
                description: "取得文件中所有表格的資訊",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "update_cell",
                description: "更新表格儲存格內容",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "table_index": .object([
                            "type": .string("integer"),
                            "description": .string("表格索引（從 0 開始）")
                        ]),
                        "row": .object([
                            "type": .string("integer"),
                            "description": .string("列索引（從 0 開始）")
                        ]),
                        "col": .object([
                            "type": .string("integer"),
                            "description": .string("欄索引（從 0 開始）")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("新的儲存格內容")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("table_index"), .string("row"), .string("col"), .string("text")])
                ])
            ),
            Tool(
                name: "delete_table",
                description: "刪除指定的表格",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "table_index": .object([
                            "type": .string("integer"),
                            "description": .string("表格索引（從 0 開始）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("table_index")])
                ])
            ),
            Tool(
                name: "merge_cells",
                description: "合併表格儲存格（支援水平或垂直合併）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "table_index": .object([
                            "type": .string("integer"),
                            "description": .string("表格索引（從 0 開始）")
                        ]),
                        "direction": .object([
                            "type": .string("string"),
                            "description": .string("合併方向：horizontal（水平）或 vertical（垂直）")
                        ]),
                        "row": .object([
                            "type": .string("integer"),
                            "description": .string("水平合併時：目標列索引；垂直合併時：起始列")
                        ]),
                        "col": .object([
                            "type": .string("integer"),
                            "description": .string("水平合併時：起始欄；垂直合併時：目標欄索引")
                        ]),
                        "end_row": .object([
                            "type": .string("integer"),
                            "description": .string("垂直合併時的結束列索引")
                        ]),
                        "end_col": .object([
                            "type": .string("integer"),
                            "description": .string("水平合併時的結束欄索引")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("table_index"), .string("direction")])
                ])
            ),
            Tool(
                name: "set_table_style",
                description: "設定表格樣式（邊框、儲存格底色）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "table_index": .object([
                            "type": .string("integer"),
                            "description": .string("表格索引（從 0 開始）")
                        ]),
                        "border_style": .object([
                            "type": .string("string"),
                            "description": .string("邊框樣式：single, double, dashed, dotted, none")
                        ]),
                        "border_color": .object([
                            "type": .string("string"),
                            "description": .string("邊框顏色（RGB 十六進位，如 000000）")
                        ]),
                        "border_size": .object([
                            "type": .string("integer"),
                            "description": .string("邊框寬度（1/8 點，預設 4 = 0.5pt）")
                        ]),
                        "cell_row": .object([
                            "type": .string("integer"),
                            "description": .string("設定底色的儲存格列索引（可選）")
                        ]),
                        "cell_col": .object([
                            "type": .string("integer"),
                            "description": .string("設定底色的儲存格欄索引（可選）")
                        ]),
                        "shading_color": .object([
                            "type": .string("string"),
                            "description": .string("儲存格底色（RGB 十六進位，如 FFFF00）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("table_index")])
                ])
            ),

            // 樣式管理
            Tool(
                name: "list_styles",
                description: "列出文件中所有可用的樣式",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "create_style",
                description: "建立自訂樣式",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "style_id": .object([
                            "type": .string("string"),
                            "description": .string("樣式 ID（唯一識別碼）")
                        ]),
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("樣式顯示名稱")
                        ]),
                        "type": .object([
                            "type": .string("string"),
                            "description": .string("樣式類型：paragraph, character, table, numbering")
                        ]),
                        "based_on": .object([
                            "type": .string("string"),
                            "description": .string("基於的樣式 ID（可選）")
                        ]),
                        "next_style": .object([
                            "type": .string("string"),
                            "description": .string("下一段使用的樣式 ID（可選）")
                        ]),
                        "font_name": .object([
                            "type": .string("string"),
                            "description": .string("字型名稱")
                        ]),
                        "font_size": .object([
                            "type": .string("integer"),
                            "description": .string("字型大小（點數）")
                        ]),
                        "bold": .object([
                            "type": .string("boolean"),
                            "description": .string("粗體")
                        ]),
                        "italic": .object([
                            "type": .string("boolean"),
                            "description": .string("斜體")
                        ]),
                        "color": .object([
                            "type": .string("string"),
                            "description": .string("文字顏色（RGB 十六進位）")
                        ]),
                        "alignment": .object([
                            "type": .string("string"),
                            "description": .string("對齊方式：left, center, right, both")
                        ]),
                        "space_before": .object([
                            "type": .string("integer"),
                            "description": .string("段前間距（點數）")
                        ]),
                        "space_after": .object([
                            "type": .string("integer"),
                            "description": .string("段後間距（點數）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("style_id"), .string("name")])
                ])
            ),
            Tool(
                name: "update_style",
                description: "修改現有樣式的定義",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "style_id": .object([
                            "type": .string("string"),
                            "description": .string("要修改的樣式 ID")
                        ]),
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("新的顯示名稱")
                        ]),
                        "font_name": .object([
                            "type": .string("string"),
                            "description": .string("字型名稱")
                        ]),
                        "font_size": .object([
                            "type": .string("integer"),
                            "description": .string("字型大小（點數）")
                        ]),
                        "bold": .object([
                            "type": .string("boolean"),
                            "description": .string("粗體")
                        ]),
                        "italic": .object([
                            "type": .string("boolean"),
                            "description": .string("斜體")
                        ]),
                        "color": .object([
                            "type": .string("string"),
                            "description": .string("文字顏色（RGB 十六進位）")
                        ]),
                        "alignment": .object([
                            "type": .string("string"),
                            "description": .string("對齊方式")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("style_id")])
                ])
            ),
            Tool(
                name: "delete_style",
                description: "刪除自訂樣式（不能刪除內建樣式）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "style_id": .object([
                            "type": .string("string"),
                            "description": .string("要刪除的樣式 ID")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("style_id")])
                ])
            ),

            // 清單/編號
            Tool(
                name: "insert_bullet_list",
                description: "插入項目符號清單",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "items": .object([
                            "type": .string("array"),
                            "description": .string("清單項目（字串陣列）")
                        ]),
                        "index": .object([
                            "type": .string("integer"),
                            "description": .string("插入位置（可選，不指定則加到最後）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("items")])
                ])
            ),
            Tool(
                name: "insert_numbered_list",
                description: "插入編號清單",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "items": .object([
                            "type": .string("array"),
                            "description": .string("清單項目（字串陣列）")
                        ]),
                        "index": .object([
                            "type": .string("integer"),
                            "description": .string("插入位置（可選，不指定則加到最後）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("items")])
                ])
            ),
            Tool(
                name: "set_list_level",
                description: "設定清單項目的層級（0-8）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引")
                        ]),
                        "level": .object([
                            "type": .string("integer"),
                            "description": .string("層級（0-8，0 為最外層）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("level")])
                ])
            ),

            // 頁面設定
            Tool(
                name: "set_page_size",
                description: "設定頁面大小（letter, a4, legal, a3, a5, b5, executive）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "size": .object([
                            "type": .string("string"),
                            "description": .string("頁面大小：letter, a4, legal, a3, a5, b5, executive")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("size")])
                ])
            ),
            Tool(
                name: "set_page_margins",
                description: "設定頁邊距",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "preset": .object([
                            "type": .string("string"),
                            "description": .string("預設邊距：normal, narrow, moderate, wide（可選）")
                        ]),
                        "top": .object([
                            "type": .string("integer"),
                            "description": .string("上邊距（twips，1440 = 1 英寸）")
                        ]),
                        "right": .object([
                            "type": .string("integer"),
                            "description": .string("右邊距（twips）")
                        ]),
                        "bottom": .object([
                            "type": .string("integer"),
                            "description": .string("下邊距（twips）")
                        ]),
                        "left": .object([
                            "type": .string("integer"),
                            "description": .string("左邊距（twips）")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "set_page_orientation",
                description: "設定頁面方向（直向/橫向）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "orientation": .object([
                            "type": .string("string"),
                            "description": .string("頁面方向：portrait（直向）, landscape（橫向）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("orientation")])
                ])
            ),
            Tool(
                name: "insert_page_break",
                description: "插入分頁符",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "at_index": .object([
                            "type": .string("integer"),
                            "description": .string("插入位置（段落索引，可選，預設插在文件最後）")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "insert_section_break",
                description: "插入分節符（可設定不同的分節類型）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "type": .object([
                            "type": .string("string"),
                            "description": .string("分節類型：nextPage（下一頁）, continuous（連續）, evenPage（偶數頁）, oddPage（奇數頁）")
                        ]),
                        "at_index": .object([
                            "type": .string("integer"),
                            "description": .string("插入位置（段落索引，可選）")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),

            // 頁首/頁尾
            Tool(
                name: "add_header",
                description: "新增頁首",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("頁首文字")
                        ]),
                        "type": .object([
                            "type": .string("string"),
                            "description": .string("頁首類型：default（預設）, first（首頁）, even（偶數頁）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("text")])
                ])
            ),
            Tool(
                name: "update_header",
                description: "更新頁首內容",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "header_id": .object([
                            "type": .string("string"),
                            "description": .string("頁首 ID（從 add_header 返回）")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("新的頁首文字")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("header_id"), .string("text")])
                ])
            ),
            Tool(
                name: "add_footer",
                description: "新增頁尾",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("頁尾文字（可選，若不提供則使用頁碼）")
                        ]),
                        "type": .object([
                            "type": .string("string"),
                            "description": .string("頁尾類型：default（預設）, first（首頁）, even（偶數頁）")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "update_footer",
                description: "更新頁尾內容",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "footer_id": .object([
                            "type": .string("string"),
                            "description": .string("頁尾 ID（從 add_footer 返回）")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("新的頁尾文字")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("footer_id"), .string("text")])
                ])
            ),
            Tool(
                name: "insert_page_number",
                description: "在頁尾插入頁碼",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "format": .object([
                            "type": .string("string"),
                            "description": .string("頁碼格式：simple（1）, pageOfTotal（Page 1 of 10）, withDash（- 1 -）, 或自訂格式如 '第#頁'（# 代表頁碼）")
                        ]),
                        "alignment": .object([
                            "type": .string("string"),
                            "description": .string("對齊方式：left, center, right（預設 center）")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),

            // 圖片
            Tool(
                name: "insert_image",
                description: "插入圖片到文件中",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "base64": .object([
                            "type": .string("string"),
                            "description": .string("圖片的 Base64 編碼資料")
                        ]),
                        "file_name": .object([
                            "type": .string("string"),
                            "description": .string("圖片檔名（包含副檔名，如 image.png）")
                        ]),
                        "width": .object([
                            "type": .string("integer"),
                            "description": .string("圖片寬度（像素）")
                        ]),
                        "height": .object([
                            "type": .string("integer"),
                            "description": .string("圖片高度（像素）")
                        ]),
                        "index": .object([
                            "type": .string("integer"),
                            "description": .string("插入位置（段落索引，可選）")
                        ]),
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("圖片名稱（可選，用於替代文字）")
                        ]),
                        "description": .object([
                            "type": .string("string"),
                            "description": .string("圖片描述（可選，用於無障礙）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("base64"), .string("file_name"), .string("width"), .string("height")])
                ])
            ),
            Tool(
                name: "insert_image_from_path",
                description: "從檔案路徑插入圖片（推薦用於大型圖片，避免 base64 傳輸）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("圖片檔案的完整路徑")
                        ]),
                        "width": .object([
                            "type": .string("integer"),
                            "description": .string("圖片寬度（像素）")
                        ]),
                        "height": .object([
                            "type": .string("integer"),
                            "description": .string("圖片高度（像素）")
                        ]),
                        "index": .object([
                            "type": .string("integer"),
                            "description": .string("插入位置（段落索引，可選）")
                        ]),
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("圖片名稱（可選，用於替代文字）")
                        ]),
                        "description": .object([
                            "type": .string("string"),
                            "description": .string("圖片描述（可選，用於無障礙）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("path"), .string("width"), .string("height")])
                ])
            ),
            Tool(
                name: "update_image",
                description: "更新圖片尺寸",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "image_id": .object([
                            "type": .string("string"),
                            "description": .string("圖片 ID（從 insert_image 返回）")
                        ]),
                        "width": .object([
                            "type": .string("integer"),
                            "description": .string("新的寬度（像素，可選）")
                        ]),
                        "height": .object([
                            "type": .string("integer"),
                            "description": .string("新的高度（像素，可選）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("image_id")])
                ])
            ),
            Tool(
                name: "delete_image",
                description: "刪除圖片",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "image_id": .object([
                            "type": .string("string"),
                            "description": .string("圖片 ID（從 insert_image 返回）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("image_id")])
                ])
            ),
            Tool(
                name: "list_images",
                description: "列出文件中所有圖片",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "export_image",
                description: "匯出單一圖片到檔案",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "image_id": .object([
                            "type": .string("string"),
                            "description": .string("圖片 ID（從 list_images 取得）")
                        ]),
                        "save_path": .object([
                            "type": .string("string"),
                            "description": .string("完整存檔路徑（含檔名，如 /tmp/output.png）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("image_id"), .string("save_path")])
                ])
            ),
            Tool(
                name: "export_all_images",
                description: "匯出所有圖片到目錄",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "output_dir": .object([
                            "type": .string("string"),
                            "description": .string("輸出目錄路徑（自動建立）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("output_dir")])
                ])
            ),
            Tool(
                name: "set_image_style",
                description: "設定圖片樣式（邊框、陰影等）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "image_id": .object([
                            "type": .string("string"),
                            "description": .string("圖片 ID（從 insert_image 返回）")
                        ]),
                        "has_border": .object([
                            "type": .string("boolean"),
                            "description": .string("是否顯示邊框")
                        ]),
                        "border_color": .object([
                            "type": .string("string"),
                            "description": .string("邊框顏色（RGB hex，如 '000000'）")
                        ]),
                        "border_width": .object([
                            "type": .string("integer"),
                            "description": .string("邊框寬度（EMU，9525 ≈ 0.75pt）")
                        ]),
                        "has_shadow": .object([
                            "type": .string("boolean"),
                            "description": .string("是否顯示陰影")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("image_id")])
                ])
            ),

            // 匯出
            Tool(
                name: "export_text",
                description: "匯出文件為純文字",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("匯出路徑")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("path")])
                ])
            ),
            Tool(
                name: "export_markdown",
                description: "匯出文件為 Markdown 格式",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("匯出路徑")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("path")])
                ])
            ),

            // 超連結和書籤
            Tool(
                name: "insert_hyperlink",
                description: "插入外部超連結（URL）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "url": .object([
                            "type": .string("string"),
                            "description": .string("目標 URL（如 https://example.com）")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("連結顯示文字")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("插入到哪個段落（可選，預設最後一個段落）")
                        ]),
                        "tooltip": .object([
                            "type": .string("string"),
                            "description": .string("滑鼠懸停提示文字（可選）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("url"), .string("text")])
                ])
            ),
            Tool(
                name: "insert_internal_link",
                description: "插入內部連結（連到書籤）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "bookmark_name": .object([
                            "type": .string("string"),
                            "description": .string("目標書籤名稱")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("連結顯示文字")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("插入到哪個段落（可選，預設最後一個段落）")
                        ]),
                        "tooltip": .object([
                            "type": .string("string"),
                            "description": .string("滑鼠懸停提示文字（可選）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("bookmark_name"), .string("text")])
                ])
            ),
            Tool(
                name: "update_hyperlink",
                description: "更新超連結的文字或 URL",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "hyperlink_id": .object([
                            "type": .string("string"),
                            "description": .string("超連結 ID（從 insert_hyperlink 返回）")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("新的顯示文字（可選）")
                        ]),
                        "url": .object([
                            "type": .string("string"),
                            "description": .string("新的 URL（可選，僅外部連結）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("hyperlink_id")])
                ])
            ),
            Tool(
                name: "delete_hyperlink",
                description: "刪除超連結（保留文字但移除連結）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "hyperlink_id": .object([
                            "type": .string("string"),
                            "description": .string("超連結 ID（從 insert_hyperlink 返回）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("hyperlink_id")])
                ])
            ),
            Tool(
                name: "insert_bookmark",
                description: "插入書籤標記（用於文件內部導航）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("書籤名稱（不能包含空格，不能以數字開頭，最多 40 字元）")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("插入到哪個段落（可選，預設最後一個段落）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("name")])
                ])
            ),
            Tool(
                name: "delete_bookmark",
                description: "刪除書籤",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("要刪除的書籤名稱")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("name")])
                ])
            ),

            // 註解和修訂
            Tool(
                name: "insert_comment",
                description: "在指定段落插入註解",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("註解文字")
                        ]),
                        "author": .object([
                            "type": .string("string"),
                            "description": .string("作者名稱")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("要附加註解的段落索引")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("text"), .string("author"), .string("paragraph_index")])
                ])
            ),
            Tool(
                name: "update_comment",
                description: "更新註解內容",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "comment_id": .object([
                            "type": .string("integer"),
                            "description": .string("註解 ID")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("新的註解文字")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("comment_id"), .string("text")])
                ])
            ),
            Tool(
                name: "delete_comment",
                description: "刪除註解",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "comment_id": .object([
                            "type": .string("integer"),
                            "description": .string("要刪除的註解 ID")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("comment_id")])
                ])
            ),
            Tool(
                name: "list_comments",
                description: "列出文件中所有註解",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "enable_track_changes",
                description: "啟用修訂追蹤",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "author": .object([
                            "type": .string("string"),
                            "description": .string("修訂作者名稱（可選）")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "disable_track_changes",
                description: "停用修訂追蹤",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "accept_revision",
                description: "接受指定的修訂",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "revision_id": .object([
                            "type": .string("integer"),
                            "description": .string("修訂 ID（使用 'all' 接受所有修訂）")
                        ]),
                        "all": .object([
                            "type": .string("boolean"),
                            "description": .string("是否接受所有修訂")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "reject_revision",
                description: "拒絕指定的修訂",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "revision_id": .object([
                            "type": .string("integer"),
                            "description": .string("修訂 ID")
                        ]),
                        "all": .object([
                            "type": .string("boolean"),
                            "description": .string("是否拒絕所有修訂")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),

            // 腳註/尾註
            Tool(
                name: "insert_footnote",
                description: "在指定段落插入腳註（出現在頁面底部）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("腳註內容")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("text")])
                ])
            ),
            Tool(
                name: "delete_footnote",
                description: "刪除指定的腳註",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "footnote_id": .object([
                            "type": .string("integer"),
                            "description": .string("腳註 ID")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("footnote_id")])
                ])
            ),
            Tool(
                name: "insert_endnote",
                description: "在指定段落插入尾註（出現在文件結尾）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("尾註內容")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("text")])
                ])
            ),
            Tool(
                name: "delete_endnote",
                description: "刪除指定的尾註",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "endnote_id": .object([
                            "type": .string("integer"),
                            "description": .string("尾註 ID")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("endnote_id")])
                ])
            ),

            // P7 進階功能

            // 7.1 目錄
            Tool(
                name: "insert_toc",
                description: "插入目錄（Table of Contents）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "title": .object([
                            "type": .string("string"),
                            "description": .string("目錄標題")
                        ]),
                        "heading_levels": .object([
                            "type": .string("string"),
                            "description": .string("包含的標題層級範圍，如 1-3")
                        ]),
                        "index": .object([
                            "type": .string("integer"),
                            "description": .string("插入位置（從 0 開始），不指定則插入到開頭")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),

            // 7.2 表單控制項
            Tool(
                name: "insert_text_field",
                description: "插入表單文字欄位",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("欄位名稱")
                        ]),
                        "default_value": .object([
                            "type": .string("string"),
                            "description": .string("預設值")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("name")])
                ])
            ),
            Tool(
                name: "insert_checkbox",
                description: "插入核取方塊",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("欄位名稱")
                        ]),
                        "checked": .object([
                            "type": .string("boolean"),
                            "description": .string("是否預設勾選")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("name")])
                ])
            ),
            Tool(
                name: "insert_dropdown",
                description: "插入下拉選單",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("欄位名稱")
                        ]),
                        "options": .object([
                            "type": .string("array"),
                            "description": .string("選項列表（JSON 陣列格式）")
                        ]),
                        "selected_index": .object([
                            "type": .string("integer"),
                            "description": .string("預設選中的索引（從 0 開始）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("name"), .string("options")])
                ])
            ),

            // 7.3 數學公式
            Tool(
                name: "insert_equation",
                description: "插入數學公式（支援簡化 LaTeX 語法）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "latex": .object([
                            "type": .string("string"),
                            "description": .string("LaTeX 格式的公式")
                        ]),
                        "display_mode": .object([
                            "type": .string("boolean"),
                            "description": .string("是否為獨立區塊（true）或行內（false）")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（行內模式時指定插入位置）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("latex")])
                ])
            ),

            // 7.4 進階格式
            Tool(
                name: "set_paragraph_border",
                description: "設定段落邊框",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "border_type": .object([
                            "type": .string("string"),
                            "description": .string("邊框類型：single, double, dotted, dashed, thick, wave")
                        ]),
                        "color": .object([
                            "type": .string("string"),
                            "description": .string("邊框顏色（十六進位 RGB）")
                        ]),
                        "size": .object([
                            "type": .string("integer"),
                            "description": .string("邊框寬度（1/8 點）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index")])
                ])
            ),
            Tool(
                name: "set_paragraph_shading",
                description: "設定段落底色",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "fill": .object([
                            "type": .string("string"),
                            "description": .string("填充顏色（十六進位 RGB，如 FFFF00）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("fill")])
                ])
            ),
            Tool(
                name: "set_character_spacing",
                description: "設定字元間距",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "spacing": .object([
                            "type": .string("integer"),
                            "description": .string("字元間距（1/20 點，正值增加，負值減少）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index")])
                ])
            ),
            Tool(
                name: "set_text_effect",
                description: "設定文字效果",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "effect": .object([
                            "type": .string("string"),
                            "description": .string("效果類型：blinkBackground, lights, antsBlack, antsRed, shimmer, sparkle, none")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("effect")])
                ])
            ),

            // P8 新功能：註解回覆、浮動圖片、欄位代碼、重複區段

            // 8.1 註解回覆
            Tool(
                name: "reply_to_comment",
                description: "回覆現有的註解",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "parent_comment_id": .object([
                            "type": .string("integer"),
                            "description": .string("要回覆的註解 ID")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("回覆內容")
                        ]),
                        "author": .object([
                            "type": .string("string"),
                            "description": .string("回覆者名稱（預設 'Author'）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("parent_comment_id"), .string("text")])
                ])
            ),
            Tool(
                name: "resolve_comment",
                description: "將註解標記為已解決或未解決",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "comment_id": .object([
                            "type": .string("integer"),
                            "description": .string("註解 ID")
                        ]),
                        "resolved": .object([
                            "type": .string("boolean"),
                            "description": .string("是否已解決（true/false）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("comment_id")])
                ])
            ),

            // 8.2 浮動圖片
            Tool(
                name: "insert_floating_image",
                description: "插入浮動圖片（可設定位置和文繞方式）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "base64": .object([
                            "type": .string("string"),
                            "description": .string("圖片的 Base64 編碼資料")
                        ]),
                        "file_name": .object([
                            "type": .string("string"),
                            "description": .string("圖片檔名（包含副檔名）")
                        ]),
                        "width": .object([
                            "type": .string("integer"),
                            "description": .string("圖片寬度（像素）")
                        ]),
                        "height": .object([
                            "type": .string("integer"),
                            "description": .string("圖片高度（像素）")
                        ]),
                        "wrap_type": .object([
                            "type": .string("string"),
                            "description": .string("文繞方式：square（四邊型）, tight（緊密）, through（穿透）, topAndBottom（上下）, behindText（文字下方）, inFrontOfText（文字上方）")
                        ]),
                        "horizontal_position": .object([
                            "type": .string("string"),
                            "description": .string("水平位置：left, center, right, 或具體偏移像素")
                        ]),
                        "vertical_position": .object([
                            "type": .string("string"),
                            "description": .string("垂直位置：top, center, bottom, 或具體偏移像素")
                        ]),
                        "relative_to_h": .object([
                            "type": .string("string"),
                            "description": .string("水平相對於：margin, page, column, character")
                        ]),
                        "relative_to_v": .object([
                            "type": .string("string"),
                            "description": .string("垂直相對於：margin, page, paragraph, line")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("base64"), .string("file_name"), .string("width"), .string("height")])
                ])
            ),

            // 8.3 欄位代碼
            Tool(
                name: "insert_if_field",
                description: "插入 IF 條件判斷欄位",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "left_operand": .object([
                            "type": .string("string"),
                            "description": .string("左運算元（可以是欄位名稱或值）")
                        ]),
                        "operator": .object([
                            "type": .string("string"),
                            "description": .string("比較運算子：=, <>, <, >, <=, >=")
                        ]),
                        "right_operand": .object([
                            "type": .string("string"),
                            "description": .string("右運算元")
                        ]),
                        "true_text": .object([
                            "type": .string("string"),
                            "description": .string("條件為真時顯示的文字")
                        ]),
                        "false_text": .object([
                            "type": .string("string"),
                            "description": .string("條件為假時顯示的文字")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("left_operand"), .string("operator"), .string("right_operand"), .string("true_text"), .string("false_text")])
                ])
            ),
            Tool(
                name: "insert_calculation_field",
                description: "插入計算欄位（支援 SUM, AVERAGE, MAX, MIN 等）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "expression": .object([
                            "type": .string("string"),
                            "description": .string("計算表達式，如 'SUM(ABOVE)', 'AVERAGE(LEFT)', '=bookmark1*bookmark2'")
                        ]),
                        "format": .object([
                            "type": .string("string"),
                            "description": .string("數字格式，如 '#,##0.00'（可選）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("expression")])
                ])
            ),
            Tool(
                name: "insert_date_field",
                description: "插入日期時間欄位",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "type": .object([
                            "type": .string("string"),
                            "description": .string("日期類型：date（目前日期）, time（目前時間）, createDate（建立日期）, saveDate（儲存日期）")
                        ]),
                        "format": .object([
                            "type": .string("string"),
                            "description": .string("日期格式，如 'yyyy/M/d', 'yyyy年M月d日'（可選）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index")])
                ])
            ),
            Tool(
                name: "insert_page_field",
                description: "插入頁碼或文件資訊欄位",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "type": .object([
                            "type": .string("string"),
                            "description": .string("欄位類型：page（頁碼）, numPages（總頁數）, fileName（檔名）, author（作者）, numWords（字數）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("type")])
                ])
            ),
            Tool(
                name: "insert_merge_field",
                description: "插入合併列印欄位",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "field_name": .object([
                            "type": .string("string"),
                            "description": .string("欄位名稱（對應資料來源的欄位）")
                        ]),
                        "text_before": .object([
                            "type": .string("string"),
                            "description": .string("前置文字（僅當欄位非空時顯示）")
                        ]),
                        "text_after": .object([
                            "type": .string("string"),
                            "description": .string("後置文字（僅當欄位非空時顯示）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("field_name")])
                ])
            ),
            Tool(
                name: "insert_sequence_field",
                description: "插入序列欄位（自動編號，用於圖表編號等）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "identifier": .object([
                            "type": .string("string"),
                            "description": .string("序列識別符，如 'Figure', 'Table', 'Equation'")
                        ]),
                        "format": .object([
                            "type": .string("string"),
                            "description": .string("編號格式：arabic（1,2,3）, alphabetic（A,B,C）, roman（I,II,III）")
                        ]),
                        "reset_level": .object([
                            "type": .string("integer"),
                            "description": .string("重設層級（對應標題層級，如設為 1 則每遇到 Heading1 就重設）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("identifier")])
                ])
            ),

            // 8.4 重複區段控制項
            Tool(
                name: "insert_content_control",
                description: "插入內容控制項（SDT）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "type": .object([
                            "type": .string("string"),
                            "description": .string("控制項類型：richText, plainText, picture, date, dropDownList, comboBox, checkbox")
                        ]),
                        "tag": .object([
                            "type": .string("string"),
                            "description": .string("控制項標籤（用於識別）")
                        ]),
                        "alias": .object([
                            "type": .string("string"),
                            "description": .string("控制項顯示名稱")
                        ]),
                        "placeholder": .object([
                            "type": .string("string"),
                            "description": .string("佔位符提示文字")
                        ]),
                        "content": .object([
                            "type": .string("string"),
                            "description": .string("預設內容")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("type"), .string("tag")])
                ])
            ),
            Tool(
                name: "insert_repeating_section",
                description: "插入重複區段（可新增/刪除項目的區塊）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "index": .object([
                            "type": .string("integer"),
                            "description": .string("插入位置（段落索引）")
                        ]),
                        "tag": .object([
                            "type": .string("string"),
                            "description": .string("區段標籤（用於識別）")
                        ]),
                        "section_title": .object([
                            "type": .string("string"),
                            "description": .string("區段標題（顯示在 UI）")
                        ]),
                        "items": .object([
                            "type": .string("array"),
                            "description": .string("初始項目內容（字串陣列）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("tag")])
                ])
            ),

            // P9 新增功能：列表查詢、文件屬性、搜尋文字、批次修訂

            // 9.1 insert_text - 在指定位置插入文字
            Tool(
                name: "insert_text",
                description: "在指定段落的指定位置插入文字",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("要插入的文字")
                        ]),
                        "position": .object([
                            "type": .string("integer"),
                            "description": .string("字元位置（從 0 開始，不指定則插入到段落末尾）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("text")])
                ])
            ),

            // 9.2 get_document_text - get_text 的增強版別名
            Tool(
                name: "get_document_text",
                description: "取得文件的完整純文字內容（get_text 的別名，更直覺的命名）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),

            // 9.3 search_text - 搜尋文字並返回位置
            Tool(
                name: "search_text",
                description: "在文件中搜尋指定文字，返回所有符合的位置",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("要搜尋的文字")
                        ]),
                        "case_sensitive": .object([
                            "type": .string("boolean"),
                            "description": .string("是否區分大小寫（預設 false）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("query")])
                ])
            ),

            // 9.4 list_hyperlinks - 列出所有超連結
            Tool(
                name: "list_hyperlinks",
                description: "列出文件中所有的超連結",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),

            // 9.5 list_bookmarks - 列出所有書籤
            Tool(
                name: "list_bookmarks",
                description: "列出文件中所有的書籤",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),

            // 9.6 list_footnotes - 列出所有腳註
            Tool(
                name: "list_footnotes",
                description: "列出文件中所有的腳註",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),

            // 9.7 list_endnotes - 列出所有尾註
            Tool(
                name: "list_endnotes",
                description: "列出文件中所有的尾註",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),

            // 9.8 get_revisions - 取得所有修訂記錄
            Tool(
                name: "get_revisions",
                description: "取得文件中所有的修訂追蹤記錄",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),

            // 9.9 accept_all_revisions - 接受所有修訂
            Tool(
                name: "accept_all_revisions",
                description: "接受文件中所有的修訂",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),

            // 9.10 reject_all_revisions - 拒絕所有修訂
            Tool(
                name: "reject_all_revisions",
                description: "拒絕文件中所有的修訂",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),

            // 9.11 set_document_properties - 設定文件屬性
            Tool(
                name: "set_document_properties",
                description: "設定文件屬性（標題、作者、主旨、關鍵字等）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "title": .object([
                            "type": .string("string"),
                            "description": .string("文件標題")
                        ]),
                        "subject": .object([
                            "type": .string("string"),
                            "description": .string("主旨")
                        ]),
                        "creator": .object([
                            "type": .string("string"),
                            "description": .string("作者")
                        ]),
                        "keywords": .object([
                            "type": .string("string"),
                            "description": .string("關鍵字（以逗號分隔）")
                        ]),
                        "description": .object([
                            "type": .string("string"),
                            "description": .string("描述/備註")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),

            // 9.12 get_paragraph_runs - 取得段落的 runs 及其格式
            Tool(
                name: "get_paragraph_runs",
                description: "取得指定段落的所有 runs（文字片段）及其格式資訊，包含顏色、粗體、斜體等",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index")])
                ])
            ),

            // 9.13 get_text_with_formatting - 取得帶格式標記的文字
            Tool(
                name: "get_text_with_formatting",
                description: "取得文件文字，並以 Markdown 標記格式（粗體用 **、斜體用 *、紅色用 {{color:red}}）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("指定段落索引（可選，不指定則取得全部）")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),

            // 9.14 search_by_formatting - 搜尋特定格式的文字
            Tool(
                name: "search_by_formatting",
                description: "搜尋具有特定格式的文字（如紅色、粗體）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "color": .object([
                            "type": .string("string"),
                            "description": .string("顏色 RGB hex（如 FF0000 代表紅色）")
                        ]),
                        "bold": .object([
                            "type": .string("boolean"),
                            "description": .string("是否為粗體")
                        ]),
                        "italic": .object([
                            "type": .string("boolean"),
                            "description": .string("是否為斜體")
                        ]),
                        "highlight": .object([
                            "type": .string("string"),
                            "description": .string("螢光標記顏色（yellow, green, cyan 等）")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),

            // 9.15 get_document_properties - 取得文件屬性
            Tool(
                name: "get_document_properties",
                description: "取得文件屬性（標題、作者、建立日期等）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),

            // 9.16 search_text_with_formatting - 搜尋文字並顯示格式
            Tool(
                name: "search_text_with_formatting",
                description: "搜尋文字並返回匹配位置及其格式標記（粗體、斜體、顏色等）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("要搜尋的文字")
                        ]),
                        "case_sensitive": .object([
                            "type": .string("boolean"),
                            "description": .string("是否區分大小寫（預設 false）")
                        ]),
                        "context_chars": .object([
                            "type": .string("integer"),
                            "description": .string("顯示匹配位置前後多少字元（預設 20）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("query")])
                ])
            ),

            // 9.17 list_all_formatted_text - 列出特定格式的所有文字
            Tool(
                name: "list_all_formatted_text",
                description: "列出所有具有特定格式的文字（如所有斜體、所有粗體、特定顏色文字）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "format_type": .object([
                            "type": .string("string"),
                            "description": .string("格式類型：italic, bold, underline, color, highlight, strikethrough")
                        ]),
                        "color_filter": .object([
                            "type": .string("string"),
                            "description": .string("當 format_type=color 時，可指定顏色（如 FF0000 代表紅色）")
                        ]),
                        "paragraph_start": .object([
                            "type": .string("integer"),
                            "description": .string("起始段落索引（可選）")
                        ]),
                        "paragraph_end": .object([
                            "type": .string("integer"),
                            "description": .string("結束段落索引（可選）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("format_type")])
                ])
            ),

            // 9.18 get_word_count_by_section - 按區段統計字數
            Tool(
                name: "get_word_count_by_section",
                description: "按區段統計字數，可自訂分隔標記（如 References）並排除特定區段",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "section_markers": .object([
                            "type": .string("array"),
                            "description": .string("區段分隔標記文字陣列（如 [\"Abstract\", \"Introduction\", \"References\"]）")
                        ]),
                        "exclude_sections": .object([
                            "type": .string("array"),
                            "description": .string("不計入總字數的區段名稱（如 [\"References\", \"Appendix\"]）")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "compare_documents",
                description: "比對兩個 Word 文件的差異（段落層級），只回傳差異部分。支援文字、格式、結構比對模式",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id_a": .object([
                            "type": .string("string"),
                            "description": .string("基準文件（舊版本）的識別碼")
                        ]),
                        "doc_id_b": .object([
                            "type": .string("string"),
                            "description": .string("比較文件（新版本）的識別碼")
                        ]),
                        "mode": .object([
                            "type": .string("string"),
                            "description": .string("比對模式：text（預設，純文字差異）、formatting（含格式差異）、structure（結構摘要）、full（完整比對）"),
                            "enum": .array([.string("text"), .string("formatting"), .string("structure"), .string("full")])
                        ]),
                        "context_lines": .object([
                            "type": .string("integer"),
                            "description": .string("差異前後顯示的未變更段落數（0-3，預設 0）"),
                            "minimum": .int(0),
                            "maximum": .int(3)
                        ])
                    ]),
                    "required": .array([.string("doc_id_a"), .string("doc_id_b")])
                ])
            )
        ]
    }

    // MARK: - Tool Handler

    private func handleToolCall(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let name = params.name
        let args = params.arguments ?? [:]

        do {
            let result = try await executeToolTask(name: name, args: args)
            return CallTool.Result(content: [.text(result)])
        } catch {
            return CallTool.Result(
                content: [.text("Error: \(error.localizedDescription)")],
                isError: true
            )
        }
    }

    private func executeToolTask(name: String, args: [String: Value]) async throws -> String {
        switch name {
        // 文件管理
        case "create_document":
            return try await createDocument(args: args)
        case "open_document":
            return try await openDocument(args: args)
        case "save_document":
            return try await saveDocument(args: args)
        case "close_document":
            return try await closeDocument(args: args)
        case "list_open_documents":
            return await listOpenDocuments()
        case "get_document_info":
            return try await getDocumentInfo(args: args)

        // 內容操作
        case "get_text":
            return try await getText(args: args)
        case "get_paragraphs":
            return try await getParagraphs(args: args)
        case "insert_paragraph":
            return try await insertParagraph(args: args)
        case "update_paragraph":
            return try await updateParagraph(args: args)
        case "delete_paragraph":
            return try await deleteParagraph(args: args)
        case "replace_text":
            return try await replaceText(args: args)

        // 格式化
        case "format_text":
            return try await formatText(args: args)
        case "set_paragraph_format":
            return try await setParagraphFormat(args: args)
        case "apply_style":
            return try await applyStyle(args: args)

        // 表格
        case "insert_table":
            return try await insertTable(args: args)
        case "get_tables":
            return try await getTables(args: args)
        case "update_cell":
            return try await updateCell(args: args)
        case "delete_table":
            return try await deleteTable(args: args)
        case "merge_cells":
            return try await mergeCells(args: args)
        case "set_table_style":
            return try await setTableStyle(args: args)

        // 樣式管理
        case "list_styles":
            return try await listStyles(args: args)
        case "create_style":
            return try await createStyle(args: args)
        case "update_style":
            return try await updateStyle(args: args)
        case "delete_style":
            return try await deleteStyle(args: args)

        // 清單/編號
        case "insert_bullet_list":
            return try await insertBulletList(args: args)
        case "insert_numbered_list":
            return try await insertNumberedList(args: args)
        case "set_list_level":
            return try await setListLevel(args: args)

        // 頁面設定
        case "set_page_size":
            return try await setPageSize(args: args)
        case "set_page_margins":
            return try await setPageMargins(args: args)
        case "set_page_orientation":
            return try await setPageOrientation(args: args)
        case "insert_page_break":
            return try await insertPageBreak(args: args)
        case "insert_section_break":
            return try await insertSectionBreak(args: args)

        // 頁首/頁尾
        case "add_header":
            return try await addHeader(args: args)
        case "update_header":
            return try await updateHeader(args: args)
        case "add_footer":
            return try await addFooter(args: args)
        case "update_footer":
            return try await updateFooter(args: args)
        case "insert_page_number":
            return try await insertPageNumber(args: args)

        // 圖片
        case "insert_image":
            return try await insertImage(args: args)
        case "insert_image_from_path":
            return try await insertImageFromPath(args: args)
        case "update_image":
            return try await updateImage(args: args)
        case "delete_image":
            return try await deleteImage(args: args)
        case "list_images":
            return try await listImages(args: args)
        case "export_image":
            return try await exportImage(args: args)
        case "export_all_images":
            return try await exportAllImages(args: args)
        case "set_image_style":
            return try await setImageStyle(args: args)

        // 匯出
        case "export_text":
            return try await exportText(args: args)
        case "export_markdown":
            return try await exportMarkdown(args: args)

        // 超連結和書籤
        case "insert_hyperlink":
            return try await insertHyperlink(args: args)
        case "insert_internal_link":
            return try await insertInternalLink(args: args)
        case "update_hyperlink":
            return try await updateHyperlink(args: args)
        case "delete_hyperlink":
            return try await deleteHyperlink(args: args)
        case "insert_bookmark":
            return try await insertBookmark(args: args)
        case "delete_bookmark":
            return try await deleteBookmark(args: args)

        // 註解和修訂
        case "insert_comment":
            return try await insertComment(args: args)
        case "update_comment":
            return try await updateComment(args: args)
        case "delete_comment":
            return try await deleteComment(args: args)
        case "list_comments":
            return try await listComments(args: args)
        case "enable_track_changes":
            return try await enableTrackChanges(args: args)
        case "disable_track_changes":
            return try await disableTrackChanges(args: args)
        case "accept_revision":
            return try await acceptRevision(args: args)
        case "reject_revision":
            return try await rejectRevision(args: args)

        // 腳註/尾註
        case "insert_footnote":
            return try await insertFootnote(args: args)
        case "delete_footnote":
            return try await deleteFootnote(args: args)
        case "insert_endnote":
            return try await insertEndnote(args: args)
        case "delete_endnote":
            return try await deleteEndnote(args: args)

        // 進階功能 (P7)
        case "insert_toc":
            return try await insertTOC(args: args)
        case "insert_text_field":
            return try await insertTextField(args: args)
        case "insert_checkbox":
            return try await insertCheckbox(args: args)
        case "insert_dropdown":
            return try await insertDropdown(args: args)
        case "insert_equation":
            return try await insertEquation(args: args)
        case "set_paragraph_border":
            return try await setParagraphBorder(args: args)
        case "set_paragraph_shading":
            return try await setParagraphShading(args: args)
        case "set_character_spacing":
            return try await setCharacterSpacing(args: args)
        case "set_text_effect":
            return try await setTextEffect(args: args)

        // 8.1 註解回覆與解析
        case "reply_to_comment":
            return try await replyToComment(args: args)
        case "resolve_comment":
            return try await resolveComment(args: args)

        // 8.2 浮動圖片
        case "insert_floating_image":
            return try await insertFloatingImage(args: args)

        // 8.3 欄位代碼
        case "insert_if_field":
            return try await insertIfField(args: args)
        case "insert_calculation_field":
            return try await insertCalculationField(args: args)
        case "insert_date_field":
            return try await insertDateField(args: args)
        case "insert_page_field":
            return try await insertPageField(args: args)
        case "insert_merge_field":
            return try await insertMergeField(args: args)
        case "insert_sequence_field":
            return try await insertSequenceField(args: args)

        // 8.4 內容控制項（SDT）
        case "insert_content_control":
            return try await insertContentControl(args: args)
        case "insert_repeating_section":
            return try await insertRepeatingSection(args: args)

        // 9. 新增功能 (P9)
        case "insert_text":
            return try await insertText(args: args)
        case "get_document_text":
            return try await getDocumentText(args: args)
        case "search_text":
            return try await searchText(args: args)
        case "list_hyperlinks":
            return try await listHyperlinks(args: args)
        case "list_bookmarks":
            return try await listBookmarks(args: args)
        case "list_footnotes":
            return try await listFootnotes(args: args)
        case "list_endnotes":
            return try await listEndnotes(args: args)
        case "get_revisions":
            return try await getRevisions(args: args)
        case "accept_all_revisions":
            return try await acceptAllRevisions(args: args)
        case "reject_all_revisions":
            return try await rejectAllRevisions(args: args)
        case "set_document_properties":
            return try await setDocumentProperties(args: args)
        case "get_document_properties":
            return try await getDocumentProperties(args: args)
        case "get_paragraph_runs":
            return try await getParagraphRuns(args: args)
        case "get_text_with_formatting":
            return try await getTextWithFormatting(args: args)
        case "search_by_formatting":
            return try await searchByFormatting(args: args)
        case "search_text_with_formatting":
            return try await searchTextWithFormatting(args: args)
        case "list_all_formatted_text":
            return try await listAllFormattedText(args: args)
        case "get_word_count_by_section":
            return try await getWordCountBySection(args: args)
        case "compare_documents":
            return try await compareDocuments(args: args)

        default:
            throw WordError.unknownTool(name)
        }
    }

    // MARK: - Document Management

    private func createDocument(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }

        let doc = WordDocument()
        openDocuments[docId] = doc

        return "Created new document with id: \(docId)"
    }

    private func openDocument(args: [String: Value]) async throws -> String {
        guard let path = args["path"]?.stringValue else {
            throw WordError.missingParameter("path")
        }
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }

        let url = URL(fileURLWithPath: path)
        let doc = try DocxReader.read(from: url)
        openDocuments[docId] = doc

        return "Opened document '\(path)' with id: \(docId)"
    }

    private func saveDocument(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let path = args["path"]?.stringValue else {
            throw WordError.missingParameter("path")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let url = URL(fileURLWithPath: path)
        try DocxWriter.write(doc, to: url)

        return "Saved document to: \(path)"
    }

    private func closeDocument(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }

        openDocuments.removeValue(forKey: docId)
        return "Closed document: \(docId)"
    }

    private func listOpenDocuments() async -> String {
        if openDocuments.isEmpty {
            return "No documents currently open"
        }

        let ids = openDocuments.keys.sorted()
        return "Open documents:\n" + ids.map { "- \($0)" }.joined(separator: "\n")
    }

    private func getDocumentInfo(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let info = doc.getInfo()
        return """
        Document Info (\(docId)):
        - Paragraphs: \(info.paragraphCount)
        - Characters: \(info.characterCount)
        - Words: \(info.wordCount)
        - Tables: \(info.tableCount)
        """
    }

    // MARK: - Content Operations

    private func getText(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        return doc.getText()
    }

    private func getParagraphs(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let paragraphs = doc.getParagraphs()
        if paragraphs.isEmpty {
            return "No paragraphs in document"
        }

        var result = "Paragraphs:\n"
        for (index, para) in paragraphs.enumerated() {
            let style = para.properties.style ?? "Normal"
            let preview = String(para.getText().prefix(50))
            result += "[\(index)] (\(style)) \(preview)...\n"
        }
        return result
    }

    private func insertParagraph(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let text = args["text"]?.stringValue else {
            throw WordError.missingParameter("text")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let index = args["index"]?.intValue
        let style = args["style"]?.stringValue

        var para = Paragraph(text: text)
        if let style = style {
            para.properties.style = style
        }

        if let index = index {
            doc.insertParagraph(para, at: index)
        } else {
            doc.appendParagraph(para)
        }

        openDocuments[docId] = doc

        return "Inserted paragraph at index \(index ?? doc.getParagraphs().count - 1)"
    }

    private func updateParagraph(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let index = args["index"]?.intValue else {
            throw WordError.missingParameter("index")
        }
        guard let text = args["text"]?.stringValue else {
            throw WordError.missingParameter("text")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        try doc.updateParagraph(at: index, text: text)
        openDocuments[docId] = doc

        return "Updated paragraph at index \(index)"
    }

    private func deleteParagraph(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let index = args["index"]?.intValue else {
            throw WordError.missingParameter("index")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        try doc.deleteParagraph(at: index)
        openDocuments[docId] = doc

        return "Deleted paragraph at index \(index)"
    }

    private func replaceText(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let find = args["find"]?.stringValue else {
            throw WordError.missingParameter("find")
        }
        guard let replace = args["replace"]?.stringValue else {
            throw WordError.missingParameter("replace")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let replaceAll = args["all"]?.boolValue ?? true
        let count = doc.replaceText(find: find, with: replace, all: replaceAll)
        openDocuments[docId] = doc

        return "Replaced \(count) occurrence(s) of '\(find)' with '\(replace)'"
    }

    // MARK: - Formatting

    private func formatText(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        var format = RunProperties()
        if let bold = args["bold"]?.boolValue { format.bold = bold }
        if let italic = args["italic"]?.boolValue { format.italic = italic }
        if let underline = args["underline"]?.boolValue { format.underline = underline ? .single : nil }
        if let fontSize = args["font_size"]?.intValue { format.fontSize = fontSize * 2 } // 轉換為半點
        if let fontName = args["font_name"]?.stringValue { format.fontName = fontName }
        if let color = args["color"]?.stringValue { format.color = color }

        try doc.formatParagraph(at: paragraphIndex, with: format)
        openDocuments[docId] = doc

        return "Applied formatting to paragraph \(paragraphIndex)"
    }

    private func setParagraphFormat(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        var props = ParagraphProperties()
        if let alignment = args["alignment"]?.stringValue {
            props.alignment = Alignment(rawValue: alignment)
        }
        if let lineSpacing = args["line_spacing"]?.doubleValue {
            props.spacing = Spacing(line: Int(lineSpacing * 240)) // 轉換為 1/240 點
        }
        if let spaceBefore = args["space_before"]?.intValue {
            if props.spacing == nil { props.spacing = Spacing() }
            props.spacing?.before = spaceBefore * 20 // 轉換為 1/20 點
        }
        if let spaceAfter = args["space_after"]?.intValue {
            if props.spacing == nil { props.spacing = Spacing() }
            props.spacing?.after = spaceAfter * 20
        }

        try doc.setParagraphFormat(at: paragraphIndex, properties: props)
        openDocuments[docId] = doc

        return "Applied paragraph format to index \(paragraphIndex)"
    }

    private func applyStyle(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let style = args["style"]?.stringValue else {
            throw WordError.missingParameter("style")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        try doc.applyStyle(at: paragraphIndex, style: style)
        openDocuments[docId] = doc

        return "Applied style '\(style)' to paragraph \(paragraphIndex)"
    }

    // MARK: - Table

    private func insertTable(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let rows = args["rows"]?.intValue else {
            throw WordError.missingParameter("rows")
        }
        guard let cols = args["cols"]?.intValue else {
            throw WordError.missingParameter("cols")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        var table = Table(rowCount: rows, columnCount: cols)

        // 如果有提供資料，填入表格
        if let dataArray = args["data"]?.arrayValue {
            for (rowIndex, rowData) in dataArray.enumerated() {
                if let rowArray = rowData.arrayValue {
                    for (colIndex, cellData) in rowArray.enumerated() {
                        if let text = cellData.stringValue,
                           rowIndex < table.rows.count && colIndex < table.rows[rowIndex].cells.count {
                            table.rows[rowIndex].cells[colIndex] = TableCell(text: text)
                        }
                    }
                }
            }
        }

        let index = args["index"]?.intValue
        if let index = index {
            doc.insertTable(table, at: index)
        } else {
            doc.appendTable(table)
        }

        openDocuments[docId] = doc

        return "Inserted \(rows)x\(cols) table"
    }

    private func getTables(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let tables = doc.getTables()
        if tables.isEmpty {
            return "No tables in document"
        }

        var result = "Tables in document:\n"
        for (index, table) in tables.enumerated() {
            let rows = table.rows.count
            let cols = table.rows.first?.cells.count ?? 0
            result += "[\(index)] \(rows)x\(cols) table\n"

            // 顯示表格內容預覽
            for (rowIdx, row) in table.rows.prefix(3).enumerated() {
                let cellPreviews = row.cells.prefix(3).map { cell -> String in
                    let preview = String(cell.getText().prefix(15))
                    return preview.isEmpty ? "(empty)" : preview
                }
                result += "  Row \(rowIdx): \(cellPreviews.joined(separator: " | "))\n"
            }
            if table.rows.count > 3 {
                result += "  ... (\(table.rows.count - 3) more rows)\n"
            }
        }
        return result
    }

    private func updateCell(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let tableIndex = args["table_index"]?.intValue else {
            throw WordError.missingParameter("table_index")
        }
        guard let row = args["row"]?.intValue else {
            throw WordError.missingParameter("row")
        }
        guard let col = args["col"]?.intValue else {
            throw WordError.missingParameter("col")
        }
        guard let text = args["text"]?.stringValue else {
            throw WordError.missingParameter("text")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        try doc.updateCell(tableIndex: tableIndex, row: row, col: col, text: text)
        openDocuments[docId] = doc

        return "Updated cell at table[\(tableIndex)][\(row)][\(col)]"
    }

    private func deleteTable(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let tableIndex = args["table_index"]?.intValue else {
            throw WordError.missingParameter("table_index")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        try doc.deleteTable(at: tableIndex)
        openDocuments[docId] = doc

        return "Deleted table at index \(tableIndex)"
    }

    private func mergeCells(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let tableIndex = args["table_index"]?.intValue else {
            throw WordError.missingParameter("table_index")
        }
        guard let direction = args["direction"]?.stringValue else {
            throw WordError.missingParameter("direction")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        switch direction.lowercased() {
        case "horizontal":
            guard let row = args["row"]?.intValue else {
                throw WordError.missingParameter("row")
            }
            guard let col = args["col"]?.intValue else {
                throw WordError.missingParameter("col")
            }
            guard let endCol = args["end_col"]?.intValue else {
                throw WordError.missingParameter("end_col")
            }
            try doc.mergeCellsHorizontal(tableIndex: tableIndex, row: row, startCol: col, endCol: endCol)
            openDocuments[docId] = doc
            return "Merged cells horizontally: row \(row), columns \(col) to \(endCol)"

        case "vertical":
            guard let row = args["row"]?.intValue else {
                throw WordError.missingParameter("row")
            }
            guard let col = args["col"]?.intValue else {
                throw WordError.missingParameter("col")
            }
            guard let endRow = args["end_row"]?.intValue else {
                throw WordError.missingParameter("end_row")
            }
            try doc.mergeCellsVertical(tableIndex: tableIndex, col: col, startRow: row, endRow: endRow)
            openDocuments[docId] = doc
            return "Merged cells vertically: column \(col), rows \(row) to \(endRow)"

        default:
            throw WordError.invalidParameter("direction", "Must be 'horizontal' or 'vertical'")
        }
    }

    private func setTableStyle(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let tableIndex = args["table_index"]?.intValue else {
            throw WordError.missingParameter("table_index")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        var results: [String] = []

        // 設定邊框
        if let borderStyle = args["border_style"]?.stringValue {
            let style = BorderStyle(rawValue: borderStyle) ?? .single
            let size = args["border_size"]?.intValue ?? 4
            let color = args["border_color"]?.stringValue ?? "000000"

            let border = Border(style: style, size: size, color: color)
            let borders = TableBorders.all(border)

            try doc.setTableBorders(tableIndex: tableIndex, borders: borders)
            results.append("Set border style: \(borderStyle)")
        }

        // 設定儲存格底色
        if let cellRow = args["cell_row"]?.intValue,
           let cellCol = args["cell_col"]?.intValue,
           let shadingColor = args["shading_color"]?.stringValue {
            let shading = CellShading(fill: shadingColor)
            try doc.setCellShading(tableIndex: tableIndex, row: cellRow, col: cellCol, shading: shading)
            results.append("Set cell shading at [\(cellRow)][\(cellCol)]: \(shadingColor)")
        }

        openDocuments[docId] = doc

        if results.isEmpty {
            return "No style changes applied"
        }
        return results.joined(separator: "\n")
    }

    // MARK: - Style Management

    private func listStyles(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let styles = doc.getStyles()
        if styles.isEmpty {
            return "No styles defined"
        }

        var result = "Available Styles:\n"
        for style in styles {
            let defaultMark = style.isDefault ? " (default)" : ""
            let basedOnInfo = style.basedOn.map { " [based on: \($0)]" } ?? ""
            result += "- \(style.id) (\(style.name)) - \(style.type.rawValue)\(defaultMark)\(basedOnInfo)\n"

            // 顯示格式資訊
            if let runProps = style.runProperties {
                var formats: [String] = []
                if let fontName = runProps.fontName { formats.append("font: \(fontName)") }
                if let fontSize = runProps.fontSize { formats.append("size: \(fontSize / 2)pt") }
                if runProps.bold == true { formats.append("bold") }
                if runProps.italic == true { formats.append("italic") }
                if let color = runProps.color { formats.append("color: #\(color)") }
                if !formats.isEmpty {
                    result += "    Text: \(formats.joined(separator: ", "))\n"
                }
            }
        }
        return result
    }

    private func createStyle(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let styleId = args["style_id"]?.stringValue else {
            throw WordError.missingParameter("style_id")
        }
        guard let name = args["name"]?.stringValue else {
            throw WordError.missingParameter("name")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        // 解析樣式類型
        let typeStr = args["type"]?.stringValue ?? "paragraph"
        let styleType = StyleType(rawValue: typeStr) ?? .paragraph

        // 解析段落屬性
        var paraProps = ParagraphProperties()
        if let alignment = args["alignment"]?.stringValue {
            paraProps.alignment = Alignment(rawValue: alignment)
        }
        if let spaceBefore = args["space_before"]?.intValue {
            if paraProps.spacing == nil { paraProps.spacing = Spacing() }
            paraProps.spacing?.before = spaceBefore * 20
        }
        if let spaceAfter = args["space_after"]?.intValue {
            if paraProps.spacing == nil { paraProps.spacing = Spacing() }
            paraProps.spacing?.after = spaceAfter * 20
        }

        // 解析 Run 屬性
        var runProps = RunProperties()
        if let fontName = args["font_name"]?.stringValue { runProps.fontName = fontName }
        if let fontSize = args["font_size"]?.intValue { runProps.fontSize = fontSize * 2 }
        if let bold = args["bold"]?.boolValue { runProps.bold = bold }
        if let italic = args["italic"]?.boolValue { runProps.italic = italic }
        if let color = args["color"]?.stringValue { runProps.color = color }

        let style = Style(
            id: styleId,
            name: name,
            type: styleType,
            basedOn: args["based_on"]?.stringValue,
            nextStyle: args["next_style"]?.stringValue,
            isDefault: false,
            isQuickStyle: true,
            paragraphProperties: paraProps,
            runProperties: runProps
        )

        try doc.addStyle(style)
        openDocuments[docId] = doc

        return "Created style '\(styleId)' (\(name))"
    }

    private func updateStyle(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let styleId = args["style_id"]?.stringValue else {
            throw WordError.missingParameter("style_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        // 建立更新資料
        var paraProps: ParagraphProperties? = nil
        if let alignment = args["alignment"]?.stringValue {
            paraProps = ParagraphProperties()
            paraProps?.alignment = Alignment(rawValue: alignment)
        }

        var runProps: RunProperties? = nil
        if args["font_name"] != nil || args["font_size"] != nil ||
           args["bold"] != nil || args["italic"] != nil || args["color"] != nil {
            runProps = RunProperties()
            if let fontName = args["font_name"]?.stringValue { runProps?.fontName = fontName }
            if let fontSize = args["font_size"]?.intValue { runProps?.fontSize = fontSize * 2 }
            if let bold = args["bold"]?.boolValue { runProps?.bold = bold }
            if let italic = args["italic"]?.boolValue { runProps?.italic = italic }
            if let color = args["color"]?.stringValue { runProps?.color = color }
        }

        let updates = StyleUpdate(
            name: args["name"]?.stringValue,
            paragraphProperties: paraProps,
            runProperties: runProps
        )

        try doc.updateStyle(id: styleId, with: updates)
        openDocuments[docId] = doc

        return "Updated style '\(styleId)'"
    }

    private func deleteStyle(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let styleId = args["style_id"]?.stringValue else {
            throw WordError.missingParameter("style_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        try doc.deleteStyle(id: styleId)
        openDocuments[docId] = doc

        return "Deleted style '\(styleId)'"
    }

    // MARK: - List Operations

    private func insertBulletList(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let itemsArray = args["items"]?.arrayValue else {
            throw WordError.missingParameter("items")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let items = itemsArray.compactMap { $0.stringValue }
        if items.isEmpty {
            throw WordError.invalidParameter("items", "Must contain at least one item")
        }

        let index = args["index"]?.intValue
        let numId = doc.insertBulletList(items: items, at: index)
        openDocuments[docId] = doc

        return "Inserted bullet list with \(items.count) items (numId: \(numId))"
    }

    private func insertNumberedList(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let itemsArray = args["items"]?.arrayValue else {
            throw WordError.missingParameter("items")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let items = itemsArray.compactMap { $0.stringValue }
        if items.isEmpty {
            throw WordError.invalidParameter("items", "Must contain at least one item")
        }

        let index = args["index"]?.intValue
        let numId = doc.insertNumberedList(items: items, at: index)
        openDocuments[docId] = doc

        return "Inserted numbered list with \(items.count) items (numId: \(numId))"
    }

    private func setListLevel(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let level = args["level"]?.intValue else {
            throw WordError.missingParameter("level")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        try doc.setListLevel(paragraphIndex: paragraphIndex, level: level)
        openDocuments[docId] = doc

        return "Set list level to \(level) for paragraph \(paragraphIndex)"
    }

    // MARK: - Page Settings

    private func setPageSize(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let sizeName = args["size"]?.stringValue else {
            throw WordError.missingParameter("size")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        try doc.setPageSize(name: sizeName)
        openDocuments[docId] = doc

        let size = doc.sectionProperties.pageSize
        return "Set page size to \(size.name) (\(size.widthInInches)\" x \(size.heightInInches)\")"
    }

    private func setPageMargins(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        // 優先使用預設名稱
        if let preset = args["preset"]?.stringValue {
            try doc.setPageMargins(name: preset)
        } else {
            // 使用自訂值
            let top = args["top"]?.intValue
            let right = args["right"]?.intValue
            let bottom = args["bottom"]?.intValue
            let left = args["left"]?.intValue

            doc.setPageMargins(top: top, right: right, bottom: bottom, left: left)
        }

        openDocuments[docId] = doc

        let margins = doc.sectionProperties.pageMargins
        return "Set page margins to \(margins.name) (top: \(margins.top), right: \(margins.right), bottom: \(margins.bottom), left: \(margins.left) twips)"
    }

    private func setPageOrientation(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let orientationStr = args["orientation"]?.stringValue else {
            throw WordError.missingParameter("orientation")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        guard let orientation = PageOrientation(rawValue: orientationStr.lowercased()) else {
            throw WordError.invalidParameter("orientation", "Must be 'portrait' or 'landscape'")
        }

        doc.setPageOrientation(orientation)
        openDocuments[docId] = doc

        return "Set page orientation to \(orientation.rawValue)"
    }

    private func insertPageBreak(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let index = args["at_index"]?.intValue
        doc.insertPageBreak(at: index)
        openDocuments[docId] = doc

        if let index = index {
            return "Inserted page break at position \(index)"
        } else {
            return "Inserted page break at end of document"
        }
    }

    private func insertSectionBreak(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let typeStr = args["type"]?.stringValue ?? "nextPage"
        guard let breakType = SectionBreakType(rawValue: typeStr) else {
            throw WordError.invalidParameter("type", "Must be 'nextPage', 'continuous', 'evenPage', or 'oddPage'")
        }

        let index = args["at_index"]?.intValue
        doc.insertSectionBreak(type: breakType, at: index)
        openDocuments[docId] = doc

        if let index = index {
            return "Inserted \(breakType.rawValue) section break at position \(index)"
        } else {
            return "Inserted \(breakType.rawValue) section break at end of document"
        }
    }

    // MARK: - Header/Footer

    private func addHeader(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let text = args["text"]?.stringValue else {
            throw WordError.missingParameter("text")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let typeStr = args["type"]?.stringValue ?? "default"
        let headerType: HeaderFooterType
        switch typeStr.lowercased() {
        case "first": headerType = .first
        case "even": headerType = .even
        default: headerType = .default
        }

        let header = doc.addHeader(text: text, type: headerType)
        openDocuments[docId] = doc

        return "Added header with id '\(header.id)' (type: \(headerType.rawValue))"
    }

    private func updateHeader(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let headerId = args["header_id"]?.stringValue else {
            throw WordError.missingParameter("header_id")
        }
        guard let text = args["text"]?.stringValue else {
            throw WordError.missingParameter("text")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        try doc.updateHeader(id: headerId, text: text)
        openDocuments[docId] = doc

        return "Updated header '\(headerId)'"
    }

    private func addFooter(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let typeStr = args["type"]?.stringValue ?? "default"
        let footerType: HeaderFooterType
        switch typeStr.lowercased() {
        case "first": footerType = .first
        case "even": footerType = .even
        default: footerType = .default
        }

        let footer: Footer
        if let text = args["text"]?.stringValue {
            footer = doc.addFooter(text: text, type: footerType)
        } else {
            // 沒有提供文字，使用頁碼
            footer = doc.addFooterWithPageNumber(format: .simple, type: footerType)
        }

        openDocuments[docId] = doc

        return "Added footer with id '\(footer.id)' (type: \(footerType.rawValue))"
    }

    private func updateFooter(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let footerId = args["footer_id"]?.stringValue else {
            throw WordError.missingParameter("footer_id")
        }
        guard let text = args["text"]?.stringValue else {
            throw WordError.missingParameter("text")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        try doc.updateFooter(id: footerId, text: text)
        openDocuments[docId] = doc

        return "Updated footer '\(footerId)'"
    }

    private func insertPageNumber(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        // 解析頁碼格式
        let formatStr = args["format"]?.stringValue ?? "simple"
        let format: PageNumberFormat
        switch formatStr.lowercased() {
        case "simple": format = .simple
        case "pageoftotal": format = .pageOfTotal
        case "withdash": format = .withDash
        default:
            // 自訂格式（包含 # 的字串）
            if formatStr.contains("#") {
                format = .withText(formatStr)
            } else {
                format = .simple
            }
        }

        let footer = doc.addFooterWithPageNumber(format: format, type: .default)
        openDocuments[docId] = doc

        return "Inserted page number in footer '\(footer.id)' with format '\(formatStr)'"
    }

    // MARK: - Image Operations

    private func insertImage(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let base64 = args["base64"]?.stringValue else {
            throw WordError.missingParameter("base64")
        }
        guard let fileName = args["file_name"]?.stringValue else {
            throw WordError.missingParameter("file_name")
        }
        guard let width = args["width"]?.intValue else {
            throw WordError.missingParameter("width")
        }
        guard let height = args["height"]?.intValue else {
            throw WordError.missingParameter("height")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let index = args["index"]?.intValue
        let name = args["name"]?.stringValue ?? "Picture"
        let description = args["description"]?.stringValue ?? ""

        let imageId = try doc.insertImage(
            base64: base64,
            fileName: fileName,
            widthPx: width,
            heightPx: height,
            at: index,
            name: name,
            description: description
        )

        openDocuments[docId] = doc

        return "Inserted image '\(fileName)' with id '\(imageId)' (\(width)x\(height) pixels)"
    }

    private func insertImageFromPath(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let path = args["path"]?.stringValue else {
            throw WordError.missingParameter("path")
        }
        guard let width = args["width"]?.intValue else {
            throw WordError.missingParameter("width")
        }
        guard let height = args["height"]?.intValue else {
            throw WordError.missingParameter("height")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        // 檢查檔案是否存在
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else {
            throw WordError.fileNotFound(path)
        }

        let index = args["index"]?.intValue
        let name = args["name"]?.stringValue ?? "Picture"
        let description = args["description"]?.stringValue ?? ""

        let imageId = try doc.insertImage(
            path: path,
            widthPx: width,
            heightPx: height,
            at: index,
            name: name,
            description: description
        )

        openDocuments[docId] = doc

        let url = URL(fileURLWithPath: path)
        return "Inserted image '\(url.lastPathComponent)' from path with id '\(imageId)' (\(width)x\(height) pixels)"
    }

    private func updateImage(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let imageId = args["image_id"]?.stringValue else {
            throw WordError.missingParameter("image_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let width = args["width"]?.intValue
        let height = args["height"]?.intValue

        try doc.updateImage(imageId: imageId, widthPx: width, heightPx: height)
        openDocuments[docId] = doc

        var changes: [String] = []
        if let w = width { changes.append("width: \(w)px") }
        if let h = height { changes.append("height: \(h)px") }

        return "Updated image '\(imageId)': \(changes.joined(separator: ", "))"
    }

    private func deleteImage(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let imageId = args["image_id"]?.stringValue else {
            throw WordError.missingParameter("image_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        try doc.deleteImage(imageId: imageId)
        openDocuments[docId] = doc

        return "Deleted image '\(imageId)'"
    }

    private func listImages(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let images = doc.getImages()

        if images.isEmpty {
            return "No images in document"
        }

        var result = "Found \(images.count) image(s):\n"
        for img in images {
            result += "- id: \(img.id), file: \(img.fileName), size: \(img.widthPx)x\(img.heightPx)px\n"
        }

        return result
    }

    // MARK: - 9.17 export_image - 匯出單一圖片
    private func exportImage(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let imageId = args["image_id"]?.stringValue else {
            throw WordError.missingParameter("image_id")
        }
        guard let savePath = args["save_path"]?.stringValue else {
            throw WordError.missingParameter("save_path")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        // 找到對應的圖片
        guard let imageRef = doc.images.first(where: { $0.id == imageId }) else {
            throw WordError.parseError("找不到圖片 ID: \(imageId)")
        }

        // 確保目錄存在
        let url = URL(fileURLWithPath: savePath)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // 寫入檔案
        try imageRef.data.write(to: url)

        let sizeKB = imageRef.data.count / 1024
        return "Saved image \(imageId) to \(savePath) (\(sizeKB)KB)"
    }

    // MARK: - 9.18 export_all_images - 匯出所有圖片
    private func exportAllImages(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let outputDir = args["output_dir"]?.stringValue else {
            throw WordError.missingParameter("output_dir")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let images = doc.images
        if images.isEmpty {
            return "No images to export"
        }

        // 建立輸出目錄
        let dirURL = URL(fileURLWithPath: outputDir)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        var result = "Exported \(images.count) image(s) to \(outputDir):\n"
        for imageRef in images {
            let fileURL = dirURL.appendingPathComponent(imageRef.fileName)
            try imageRef.data.write(to: fileURL)
            let sizeKB = imageRef.data.count / 1024
            result += "  - \(imageRef.fileName) (\(sizeKB)KB)\n"
        }

        return result
    }

    private func setImageStyle(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let imageId = args["image_id"]?.stringValue else {
            throw WordError.missingParameter("image_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let hasBorder = args["has_border"]?.boolValue
        let borderColor = args["border_color"]?.stringValue
        let borderWidth = args["border_width"]?.intValue
        let hasShadow = args["has_shadow"]?.boolValue

        try doc.setImageStyle(
            imageId: imageId,
            hasBorder: hasBorder,
            borderColor: borderColor,
            borderWidth: borderWidth,
            hasShadow: hasShadow
        )

        openDocuments[docId] = doc

        var changes: [String] = []
        if let border = hasBorder { changes.append("border: \(border)") }
        if let color = borderColor { changes.append("color: \(color)") }
        if let width = borderWidth { changes.append("width: \(width)") }
        if let shadow = hasShadow { changes.append("shadow: \(shadow)") }

        return "Updated image style for '\(imageId)': \(changes.joined(separator: ", "))"
    }

    // MARK: - Export

    private func exportText(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let path = args["path"]?.stringValue else {
            throw WordError.missingParameter("path")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let text = doc.getText()
        try text.write(toFile: path, atomically: true, encoding: .utf8)

        return "Exported text to: \(path)"
    }

    private func exportMarkdown(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let path = args["path"]?.stringValue else {
            throw WordError.missingParameter("path")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let markdown = doc.toMarkdown()
        try markdown.write(toFile: path, atomically: true, encoding: .utf8)

        return "Exported Markdown to: \(path)"
    }

    // MARK: - Hyperlink and Bookmark Operations

    private func insertHyperlink(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let url = args["url"]?.stringValue else {
            throw WordError.missingParameter("url")
        }
        guard let text = args["text"]?.stringValue else {
            throw WordError.missingParameter("text")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let paragraphIndex = args["paragraph_index"]?.intValue
        let tooltip = args["tooltip"]?.stringValue

        let hyperlinkId = doc.insertHyperlink(
            url: url,
            text: text,
            at: paragraphIndex,
            tooltip: tooltip
        )

        openDocuments[docId] = doc

        return "Inserted hyperlink '\(text)' -> \(url) with id '\(hyperlinkId)'"
    }

    private func insertInternalLink(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let bookmarkName = args["bookmark_name"]?.stringValue else {
            throw WordError.missingParameter("bookmark_name")
        }
        guard let text = args["text"]?.stringValue else {
            throw WordError.missingParameter("text")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let paragraphIndex = args["paragraph_index"]?.intValue
        let tooltip = args["tooltip"]?.stringValue

        let hyperlinkId = doc.insertInternalLink(
            bookmarkName: bookmarkName,
            text: text,
            at: paragraphIndex,
            tooltip: tooltip
        )

        openDocuments[docId] = doc

        return "Inserted internal link '\(text)' -> bookmark '\(bookmarkName)' with id '\(hyperlinkId)'"
    }

    private func updateHyperlink(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let hyperlinkId = args["hyperlink_id"]?.stringValue else {
            throw WordError.missingParameter("hyperlink_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let text = args["text"]?.stringValue
        let url = args["url"]?.stringValue

        try doc.updateHyperlink(hyperlinkId: hyperlinkId, text: text, url: url)
        openDocuments[docId] = doc

        var changes: [String] = []
        if let text = text { changes.append("text: '\(text)'") }
        if let url = url { changes.append("url: '\(url)'") }

        return "Updated hyperlink '\(hyperlinkId)': \(changes.joined(separator: ", "))"
    }

    private func deleteHyperlink(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let hyperlinkId = args["hyperlink_id"]?.stringValue else {
            throw WordError.missingParameter("hyperlink_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        try doc.deleteHyperlink(hyperlinkId: hyperlinkId)
        openDocuments[docId] = doc

        return "Deleted hyperlink '\(hyperlinkId)'"
    }

    private func insertBookmark(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let name = args["name"]?.stringValue else {
            throw WordError.missingParameter("name")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let paragraphIndex = args["paragraph_index"]?.intValue

        let bookmarkId = try doc.insertBookmark(name: name, at: paragraphIndex)
        openDocuments[docId] = doc

        return "Inserted bookmark '\(name)' with id \(bookmarkId)"
    }

    private func deleteBookmark(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let name = args["name"]?.stringValue else {
            throw WordError.missingParameter("name")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        try doc.deleteBookmark(name: name)
        openDocuments[docId] = doc

        return "Deleted bookmark '\(name)'"
    }

    // MARK: - Comment and Revision Operations

    private func insertComment(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let text = args["text"]?.stringValue else {
            throw WordError.missingParameter("text")
        }
        guard let author = args["author"]?.stringValue else {
            throw WordError.missingParameter("author")
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let commentId = try doc.insertComment(text: text, author: author, paragraphIndex: paragraphIndex)
        openDocuments[docId] = doc

        return "Inserted comment with id \(commentId) by '\(author)'"
    }

    private func updateComment(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let commentId = args["comment_id"]?.intValue else {
            throw WordError.missingParameter("comment_id")
        }
        guard let text = args["text"]?.stringValue else {
            throw WordError.missingParameter("text")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        try doc.updateComment(commentId: commentId, text: text)
        openDocuments[docId] = doc

        return "Updated comment \(commentId)"
    }

    private func deleteComment(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let commentId = args["comment_id"]?.intValue else {
            throw WordError.missingParameter("comment_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        try doc.deleteComment(commentId: commentId)
        openDocuments[docId] = doc

        return "Deleted comment \(commentId)"
    }

    private func listComments(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let comments = doc.getComments()
        if comments.isEmpty {
            return "No comments in document"
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"

        var result = "Comments (\(comments.count)):\n"
        for comment in comments {
            result += "- [ID: \(comment.id)] \(comment.author) (\(dateFormatter.string(from: comment.date))): \"\(comment.text)\" (para \(comment.paragraphIndex))\n"
        }

        return result
    }

    private func enableTrackChanges(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let author = args["author"]?.stringValue ?? "Unknown"
        doc.enableTrackChanges(author: author)
        openDocuments[docId] = doc

        return "Track changes enabled for '\(author)'"
    }

    private func disableTrackChanges(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        doc.disableTrackChanges()
        openDocuments[docId] = doc

        return "Track changes disabled"
    }

    private func acceptRevision(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let acceptAll = args["all"]?.boolValue ?? false

        if acceptAll {
            doc.acceptAllRevisions()
            openDocuments[docId] = doc
            return "Accepted all revisions"
        } else {
            guard let revisionId = args["revision_id"]?.intValue else {
                throw WordError.missingParameter("revision_id")
            }
            try doc.acceptRevision(revisionId: revisionId)
            openDocuments[docId] = doc
            return "Accepted revision \(revisionId)"
        }
    }

    private func rejectRevision(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let rejectAll = args["all"]?.boolValue ?? false

        if rejectAll {
            doc.rejectAllRevisions()
            openDocuments[docId] = doc
            return "Rejected all revisions"
        } else {
            guard let revisionId = args["revision_id"]?.intValue else {
                throw WordError.missingParameter("revision_id")
            }
            try doc.rejectRevision(revisionId: revisionId)
            openDocuments[docId] = doc
            return "Rejected revision \(revisionId)"
        }
    }

    // MARK: - Footnotes/Endnotes

    private func insertFootnote(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let text = args["text"]?.stringValue else {
            throw WordError.missingParameter("text")
        }

        let footnoteId = try doc.insertFootnote(text: text, paragraphIndex: paragraphIndex)
        openDocuments[docId] = doc
        return "Inserted footnote \(footnoteId) at paragraph \(paragraphIndex)"
    }

    private func deleteFootnote(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let footnoteId = args["footnote_id"]?.intValue else {
            throw WordError.missingParameter("footnote_id")
        }

        try doc.deleteFootnote(footnoteId: footnoteId)
        openDocuments[docId] = doc
        return "Deleted footnote \(footnoteId)"
    }

    private func insertEndnote(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let text = args["text"]?.stringValue else {
            throw WordError.missingParameter("text")
        }

        let endnoteId = try doc.insertEndnote(text: text, paragraphIndex: paragraphIndex)
        openDocuments[docId] = doc
        return "Inserted endnote \(endnoteId) at paragraph \(paragraphIndex)"
    }

    private func deleteEndnote(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let endnoteId = args["endnote_id"]?.intValue else {
            throw WordError.missingParameter("endnote_id")
        }

        try doc.deleteEndnote(endnoteId: endnoteId)
        openDocuments[docId] = doc
        return "Deleted endnote \(endnoteId)"
    }

    // MARK: - Advanced Features (P7)

    private func insertTOC(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let index = args["index"]?.intValue
        let title = args["title"]?.stringValue
        let minLevel = args["min_level"]?.intValue ?? 1
        let maxLevel = args["max_level"]?.intValue ?? 3
        let includePageNumbers = args["include_page_numbers"]?.boolValue ?? true
        let useHyperlinks = args["use_hyperlinks"]?.boolValue ?? true

        doc.insertTableOfContents(
            at: index,
            title: title,
            headingLevels: minLevel...maxLevel,
            includePageNumbers: includePageNumbers,
            useHyperlinks: useHyperlinks
        )
        openDocuments[docId] = doc

        return "Inserted table of contents (heading levels \(minLevel)-\(maxLevel))"
    }

    private func insertTextField(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let name = args["name"]?.stringValue else {
            throw WordError.missingParameter("name")
        }

        let defaultValue = args["default_value"]?.stringValue
        let maxLength = args["max_length"]?.intValue

        try doc.insertTextField(at: paragraphIndex, name: name, defaultValue: defaultValue, maxLength: maxLength)
        openDocuments[docId] = doc

        return "Inserted text field '\(name)' at paragraph \(paragraphIndex)"
    }

    private func insertCheckbox(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let name = args["name"]?.stringValue else {
            throw WordError.missingParameter("name")
        }

        let isChecked = args["is_checked"]?.boolValue ?? false

        try doc.insertCheckbox(at: paragraphIndex, name: name, isChecked: isChecked)
        openDocuments[docId] = doc

        return "Inserted checkbox '\(name)' (checked: \(isChecked)) at paragraph \(paragraphIndex)"
    }

    private func insertDropdown(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let name = args["name"]?.stringValue else {
            throw WordError.missingParameter("name")
        }
        guard let optionsValue = args["options"] else {
            throw WordError.missingParameter("options")
        }

        // 解析 options array
        var options: [String] = []
        if case .array(let arr) = optionsValue {
            for item in arr {
                if let str = item.stringValue {
                    options.append(str)
                }
            }
        }

        if options.isEmpty {
            throw WordError.missingParameter("options (array of strings)")
        }

        let selectedIndex = args["selected_index"]?.intValue ?? 0

        try doc.insertDropdown(at: paragraphIndex, name: name, options: options, selectedIndex: selectedIndex)
        openDocuments[docId] = doc

        return "Inserted dropdown '\(name)' with \(options.count) options at paragraph \(paragraphIndex)"
    }

    private func insertEquation(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let latex = args["latex"]?.stringValue else {
            throw WordError.missingParameter("latex")
        }

        let paragraphIndex = args["paragraph_index"]?.intValue
        let displayMode = args["display_mode"]?.boolValue ?? false

        doc.insertEquation(at: paragraphIndex, latex: latex, displayMode: displayMode)
        openDocuments[docId] = doc

        return "Inserted equation (display mode: \(displayMode))"
    }

    private func setParagraphBorder(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }

        let typeStr = args["type"]?.stringValue ?? "single"
        let size = args["size"]?.intValue ?? 4
        let color = args["color"]?.stringValue ?? "000000"
        let space = args["space"]?.intValue ?? 1

        // 解析邊框類型
        let borderType = ParagraphBorderType(rawValue: typeStr) ?? .single
        let borderStyle = ParagraphBorderStyle(type: borderType, color: color, size: size, space: space)

        // 解析要套用的邊
        var topStyle: ParagraphBorderStyle? = borderStyle
        var bottomStyle: ParagraphBorderStyle? = borderStyle
        var leftStyle: ParagraphBorderStyle? = borderStyle
        var rightStyle: ParagraphBorderStyle? = borderStyle

        if let sidesValue = args["sides"] {
            if case .array(let arr) = sidesValue {
                topStyle = nil; bottomStyle = nil; leftStyle = nil; rightStyle = nil
                for item in arr {
                    if let side = item.stringValue {
                        switch side.lowercased() {
                        case "top": topStyle = borderStyle
                        case "bottom": bottomStyle = borderStyle
                        case "left": leftStyle = borderStyle
                        case "right": rightStyle = borderStyle
                        default: break
                        }
                    }
                }
            }
        }

        let border = ParagraphBorder(
            top: topStyle,
            bottom: bottomStyle,
            left: leftStyle,
            right: rightStyle
        )

        try doc.setParagraphBorder(at: paragraphIndex, border: border)
        openDocuments[docId] = doc

        return "Set border on paragraph \(paragraphIndex)"
    }

    private func setParagraphShading(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let fill = args["fill"]?.stringValue else {
            throw WordError.missingParameter("fill")
        }

        var pattern: ShadingPattern? = nil
        if let patternStr = args["pattern"]?.stringValue {
            pattern = ShadingPattern(rawValue: patternStr)
        }

        try doc.setParagraphShading(at: paragraphIndex, fill: fill, pattern: pattern)
        openDocuments[docId] = doc

        return "Set shading on paragraph \(paragraphIndex) (fill: #\(fill))"
    }

    private func setCharacterSpacing(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }

        let spacing = args["spacing"]?.intValue
        let position = args["position"]?.intValue
        let kern = args["kern"]?.intValue

        try doc.setCharacterSpacing(at: paragraphIndex, spacing: spacing, position: position, kern: kern)
        openDocuments[docId] = doc

        var changes: [String] = []
        if let spacing = spacing { changes.append("spacing: \(spacing)") }
        if let position = position { changes.append("position: \(position)") }
        if let kern = kern { changes.append("kern: \(kern)") }

        return "Set character spacing on paragraph \(paragraphIndex): \(changes.joined(separator: ", "))"
    }

    private func setTextEffect(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let effectType = args["effect"]?.stringValue else {
            throw WordError.missingParameter("effect")
        }

        // TextEffect 是 enum：blinkBackground, lights, antsBlack, antsRed, shimmer, sparkle, none
        guard let effect = TextEffect(rawValue: effectType) else {
            throw WordError.invalidParameter("effect", "Unknown effect type: \(effectType). Valid: blinkBackground, lights, antsBlack, antsRed, shimmer, sparkle, none")
        }

        try doc.setTextEffect(at: paragraphIndex, effect: effect)
        openDocuments[docId] = doc

        return "Applied '\(effectType)' effect to paragraph \(paragraphIndex)"
    }

    // MARK: - 8.1 Comment Replies and Resolution

    private func replyToComment(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let commentId = args["comment_id"]?.intValue else {
            throw WordError.missingParameter("comment_id")
        }
        guard let replyText = args["reply_text"]?.stringValue else {
            throw WordError.missingParameter("reply_text")
        }
        let author = args["author"]?.stringValue ?? "User"

        // 使用 CommentsCollection.addReply 方法
        guard let reply = doc.comments.addReply(to: commentId, author: author, text: replyText) else {
            throw WordError.invalidParameter("comment_id", "Comment with ID \(commentId) not found")
        }

        openDocuments[docId] = doc
        return "Added reply to comment \(commentId) by \(author) (reply ID: \(reply.id))"
    }

    private func resolveComment(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let commentId = args["comment_id"]?.intValue else {
            throw WordError.missingParameter("comment_id")
        }
        let resolved = args["resolved"]?.boolValue ?? true

        // 使用 CommentsCollection.markAsDone 方法
        doc.comments.markAsDone(commentId, done: resolved)
        openDocuments[docId] = doc

        return "Comment \(commentId) \(resolved ? "resolved" : "reopened")"
    }

    // MARK: - 8.2 Floating Images

    private func insertFloatingImage(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let path = args["path"]?.stringValue else {
            throw WordError.missingParameter("path")
        }

        let paragraphIndex = args["paragraph_index"]?.intValue ?? 0
        let widthEmu = args["width"]?.intValue ?? 2000000  // ~2 inches default
        let heightEmu = args["height"]?.intValue ?? 2000000
        let horizontalPos = args["horizontal_position"]?.intValue ?? 0
        let verticalPos = args["vertical_position"]?.intValue ?? 0
        let wrapTypeStr = args["wrap_type"]?.stringValue ?? "square"
        let horizontalRelative = args["horizontal_relative"]?.stringValue ?? "column"
        let allowOverlap = args["allow_overlap"]?.boolValue ?? true

        // 讀取圖片數據
        let url = URL(fileURLWithPath: path)
        let imageData = try Data(contentsOf: url)

        // 建立圖片參照
        let imageId = "rId\(doc.images.count + 10)"
        let imageRef = ImageReference(
            id: imageId,
            fileName: url.lastPathComponent,
            contentType: detectImageContentType(from: url),
            data: imageData
        )
        doc.images.append(imageRef)

        // 建立浮動圖片定位
        var anchorPosition = AnchorPosition()
        anchorPosition.horizontalOffset = horizontalPos
        anchorPosition.verticalOffset = verticalPos
        anchorPosition.allowOverlap = allowOverlap

        // 設定水平參照點
        if let hrel = HorizontalRelativeFrom(rawValue: horizontalRelative) {
            anchorPosition.horizontalRelativeFrom = hrel
        }

        // 設定文繞圖類型
        switch wrapTypeStr.lowercased() {
        case "none": anchorPosition.wrapType = .none
        case "square": anchorPosition.wrapType = .square
        case "tight": anchorPosition.wrapType = .tight
        case "through": anchorPosition.wrapType = .through
        case "topandbottom": anchorPosition.wrapType = .topAndBottom
        case "behindtext": anchorPosition.wrapType = .behindText
        case "infrontoftext": anchorPosition.wrapType = .inFrontOfText
        default: anchorPosition.wrapType = .square
        }

        // 建立浮動繪圖
        let drawing = Drawing.anchor(
            width: widthEmu,
            height: heightEmu,
            imageId: imageId,
            position: anchorPosition,
            name: url.lastPathComponent
        )

        // 插入到段落
        try doc.insertDrawing(drawing, at: paragraphIndex)
        openDocuments[docId] = doc

        return "Inserted floating image '\(url.lastPathComponent)' at paragraph \(paragraphIndex)"
    }

    private func detectImageContentType(from url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "bmp": return "image/bmp"
        case "tiff", "tif": return "image/tiff"
        default: return "image/png"
        }
    }

    // MARK: - 8.3 Field Codes

    private func insertIfField(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let leftOperand = args["left_operand"]?.stringValue else {
            throw WordError.missingParameter("left_operand")
        }
        guard let operatorStr = args["operator"]?.stringValue else {
            throw WordError.missingParameter("operator")
        }
        guard let rightOperand = args["right_operand"]?.stringValue else {
            throw WordError.missingParameter("right_operand")
        }
        guard let trueText = args["true_text"]?.stringValue else {
            throw WordError.missingParameter("true_text")
        }
        guard let falseText = args["false_text"]?.stringValue else {
            throw WordError.missingParameter("false_text")
        }

        // 轉換運算符字串為 enum
        let compOp: IFField.ComparisonOperator
        switch operatorStr {
        case "=", "==": compOp = .equal
        case "<>", "!=": compOp = .notEqual
        case "<": compOp = .lessThan
        case ">": compOp = .greaterThan
        case "<=": compOp = .lessThanOrEqual
        case ">=": compOp = .greaterThanOrEqual
        default: compOp = .equal
        }

        let ifField = IFField(
            leftOperand: leftOperand,
            comparisonOperator: compOp,
            rightOperand: rightOperand,
            trueText: trueText,
            falseText: falseText
        )

        try doc.insertFieldCode(ifField, at: paragraphIndex)
        openDocuments[docId] = doc

        return "Inserted IF field at paragraph \(paragraphIndex): IF \(leftOperand) \(operatorStr) \(rightOperand)"
    }

    private func insertCalculationField(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let expression = args["expression"]?.stringValue else {
            throw WordError.missingParameter("expression")
        }
        let format = args["format"]?.stringValue

        // 表達式可以是完整的如 "=SUM(ABOVE)" 或 "SUM(ABOVE)"
        let calcField = CalculationField(
            expression: expression,
            numberFormat: format
        )

        try doc.insertFieldCode(calcField, at: paragraphIndex)
        openDocuments[docId] = doc

        return "Inserted calculation field '\(expression)' at paragraph \(paragraphIndex)"
    }

    private func insertDateField(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        let format = args["format"]?.stringValue ?? "yyyy-MM-dd"
        let typeStr = args["type"]?.stringValue ?? "DATE"

        let fieldType: DateTimeFieldType
        switch typeStr.uppercased() {
        case "DATE": fieldType = .date
        case "TIME": fieldType = .time
        case "PRINTDATE": fieldType = .printDate
        case "SAVEDATE": fieldType = .saveDate
        case "CREATEDATE": fieldType = .createDate
        case "EDITTIME": fieldType = .editTime
        default: fieldType = .date
        }

        let dateField = DateTimeField(type: fieldType, dateFormat: format)

        try doc.insertFieldCode(dateField, at: paragraphIndex)
        openDocuments[docId] = doc

        return "Inserted \(typeStr) field with format '\(format)' at paragraph \(paragraphIndex)"
    }

    private func insertPageField(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        let typeStr = args["type"]?.stringValue ?? "PAGE"

        let infoType: DocumentInfoFieldType
        switch typeStr.uppercased() {
        case "PAGE": infoType = .page
        case "NUMPAGES": infoType = .numPages
        case "NUMWORDS": infoType = .numWords
        case "NUMCHARS": infoType = .numChars
        case "FILENAME": infoType = .fileName
        case "AUTHOR": infoType = .author
        case "TITLE": infoType = .title
        case "SECTIONPAGES": infoType = .sectionPages
        default: infoType = .page
        }

        let infoField = DocumentInfoField(type: infoType)

        try doc.insertFieldCode(infoField, at: paragraphIndex)
        openDocuments[docId] = doc

        return "Inserted \(typeStr) field at paragraph \(paragraphIndex)"
    }

    private func insertMergeField(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let fieldName = args["field_name"]?.stringValue else {
            throw WordError.missingParameter("field_name")
        }
        let textBefore = args["text_before"]?.stringValue
        let textAfter = args["text_after"]?.stringValue

        let mergeField = MergeField(
            fieldName: fieldName,
            textBefore: textBefore,
            textAfter: textAfter
        )

        try doc.insertFieldCode(mergeField, at: paragraphIndex)
        openDocuments[docId] = doc

        return "Inserted MERGEFIELD '\(fieldName)' at paragraph \(paragraphIndex)"
    }

    private func insertSequenceField(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let identifier = args["identifier"]?.stringValue else {
            throw WordError.missingParameter("identifier")
        }
        let resetOnHeading = args["reset_on_heading"]?.intValue

        let seqField = SequenceField(
            identifier: identifier,
            resetLevel: resetOnHeading
        )

        try doc.insertFieldCode(seqField, at: paragraphIndex)
        openDocuments[docId] = doc

        return "Inserted SEQ '\(identifier)' field at paragraph \(paragraphIndex)"
    }

    // MARK: - 8.4 Content Controls (SDT)

    private func insertContentControl(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let typeStr = args["type"]?.stringValue else {
            throw WordError.missingParameter("type")
        }
        guard let tag = args["tag"]?.stringValue else {
            throw WordError.missingParameter("tag")
        }

        let alias = args["alias"]?.stringValue
        let placeholder = args["placeholder"]?.stringValue
        let contentText = args["content"]?.stringValue ?? ""

        guard let sdtType = SDTType(rawValue: typeStr) else {
            throw WordError.invalidParameter("type", "Unknown SDT type: \(typeStr). Valid: richText, text, picture, date, dropDownList, comboBox, checkbox")
        }

        // 使用正確的初始化順序
        let sdt = StructuredDocumentTag(
            id: Int.random(in: 100000...999999),
            tag: tag,
            alias: alias,
            type: sdtType,
            placeholder: placeholder
        )

        // 使用 ContentControl 包裝
        let contentControl = ContentControl(sdt: sdt, content: contentText)

        try doc.insertContentControl(contentControl, at: paragraphIndex)
        openDocuments[docId] = doc

        return "Inserted \(typeStr) content control '\(tag)' at paragraph \(paragraphIndex)"
    }

    private func insertRepeatingSection(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let tag = args["tag"]?.stringValue else {
            throw WordError.missingParameter("tag")
        }

        let index = args["index"]?.intValue ?? 0
        let sectionTitle = args["section_title"]?.stringValue
        let itemsArray = args["items"]?.arrayValue ?? []

        // 解析初始項目
        var items: [RepeatingSectionItem] = []
        for item in itemsArray {
            if let content = item.stringValue {
                let rsItem = RepeatingSectionItem(
                    tag: nil,
                    content: content
                )
                items.append(rsItem)
            }
        }

        // 如果沒有初始項目，創建一個空的
        if items.isEmpty {
            items.append(RepeatingSectionItem(content: ""))
        }

        // 使用正確的初始化方式
        let repeatingSection = RepeatingSection(
            tag: tag,
            alias: sectionTitle,
            items: items,
            allowInsertDeleteSections: true,
            sectionTitle: sectionTitle
        )

        try doc.insertRepeatingSection(repeatingSection, at: index)
        openDocuments[docId] = doc

        return "Inserted repeating section '\(tag)' with \(items.count) item(s) at index \(index)"
    }

    // MARK: - P9 新增功能

    // 9.1 insert_text - 在指定位置插入文字
    private func insertText(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let text = args["text"]?.stringValue else {
            throw WordError.missingParameter("text")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let position = args["position"]?.intValue

        // 取得段落並插入文字
        let paragraphs = doc.getParagraphs()
        guard paragraphIndex >= 0 && paragraphIndex < paragraphs.count else {
            throw WordError.invalidIndex(paragraphIndex)
        }

        // 取得現有文字並在指定位置插入
        let currentText = paragraphs[paragraphIndex].getText()
        let insertPosition = position ?? currentText.count

        let startIndex = currentText.startIndex
        let insertIndex = currentText.index(startIndex, offsetBy: min(insertPosition, currentText.count))
        let newText = String(currentText[..<insertIndex]) + text + String(currentText[insertIndex...])

        try doc.updateParagraph(at: paragraphIndex, text: newText)
        openDocuments[docId] = doc

        return "Inserted text at paragraph \(paragraphIndex)\(position.map { ", position \($0)" } ?? " (at end)")"
    }

    // 9.2 get_document_text - get_text 的別名
    private func getDocumentText(args: [String: Value]) async throws -> String {
        // 直接呼叫 getText，這是一個更直覺的別名
        return try await getText(args: args)
    }

    // 9.3 search_text - 搜尋文字
    private func searchText(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let query = args["query"]?.stringValue else {
            throw WordError.missingParameter("query")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let caseSensitive = args["case_sensitive"]?.boolValue ?? false

        // 搜尋每個段落中的文字
        let paragraphs = doc.getParagraphs()
        var results: [(paragraphIndex: Int, startPosition: Int, text: String)] = []

        for (index, para) in paragraphs.enumerated() {
            let paraText = para.getText()
            let searchText = caseSensitive ? paraText : paraText.lowercased()
            let searchQuery = caseSensitive ? query : query.lowercased()

            var searchStart = searchText.startIndex
            while let range = searchText.range(of: searchQuery, range: searchStart..<searchText.endIndex) {
                let position = searchText.distance(from: searchText.startIndex, to: range.lowerBound)
                let matchedText = String(paraText[range])
                results.append((index, position, matchedText))
                searchStart = range.upperBound
            }
        }

        if results.isEmpty {
            return "No matches found for '\(query)'"
        }

        var output = "Found \(results.count) match(es) for '\(query)':\n"
        for result in results {
            output += "- Paragraph \(result.paragraphIndex), position \(result.startPosition): \"\(result.text)\"\n"
        }
        return output
    }

    // 9.4 list_hyperlinks - 列出所有超連結
    private func listHyperlinks(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let hyperlinks = doc.getHyperlinks()
        if hyperlinks.isEmpty {
            return "No hyperlinks in document"
        }

        var output = "Hyperlinks in document (\(hyperlinks.count)):\n"
        for (index, link) in hyperlinks.enumerated() {
            let displayText = link.text
            let target = link.url ?? link.anchor ?? "(unknown target)"
            output += "[\(index)] (\(link.type)) \(displayText) -> \(target)\n"
        }
        return output
    }

    // 9.5 list_bookmarks - 列出所有書籤
    private func listBookmarks(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let bookmarks = doc.getBookmarks()
        if bookmarks.isEmpty {
            return "No bookmarks in document"
        }

        var output = "Bookmarks in document (\(bookmarks.count)):\n"
        for (index, bookmark) in bookmarks.enumerated() {
            output += "[\(index)] \(bookmark.name)\n"
        }
        return output
    }

    // 9.6 list_footnotes - 列出所有腳註
    private func listFootnotes(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let footnotes = doc.getFootnotes()
        if footnotes.isEmpty {
            return "No footnotes in document"
        }

        var output = "Footnotes in document (\(footnotes.count)):\n"
        for footnote in footnotes {
            let preview = String(footnote.text.prefix(50))
            output += "[\(footnote.id)] \(preview)...\n"
        }
        return output
    }

    // 9.7 list_endnotes - 列出所有尾註
    private func listEndnotes(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let endnotes = doc.getEndnotes()
        if endnotes.isEmpty {
            return "No endnotes in document"
        }

        var output = "Endnotes in document (\(endnotes.count)):\n"
        for endnote in endnotes {
            let preview = String(endnote.text.prefix(50))
            output += "[\(endnote.id)] \(preview)...\n"
        }
        return output
    }

    // 9.8 get_revisions - 取得所有修訂記錄
    private func getRevisions(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let revisions = doc.getRevisions()
        if revisions.isEmpty {
            return "No revisions in document"
        }

        var output = "Revisions in document (\(revisions.count)):\n"
        for revision in revisions {
            // revision.type 是 String (rawValue)
            let typeStr = revision.type.uppercased()
            let author = revision.author
            output += "[\(revision.id)] \(typeStr) by \(author) at paragraph \(revision.paragraphIndex)\n"
            if let original = revision.originalText {
                output += "    Original: \(original.prefix(30))...\n"
            }
            if let newText = revision.newText {
                output += "    New: \(newText.prefix(30))...\n"
            }
        }
        return output
    }

    // 9.9 accept_all_revisions - 接受所有修訂
    private func acceptAllRevisions(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let count = doc.getRevisions().count
        doc.acceptAllRevisions()
        openDocuments[docId] = doc

        return "Accepted \(count) revision(s)"
    }

    // 9.10 reject_all_revisions - 拒絕所有修訂
    private func rejectAllRevisions(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let count = doc.getRevisions().count
        doc.rejectAllRevisions()
        openDocuments[docId] = doc

        return "Rejected \(count) revision(s)"
    }

    // 9.11 set_document_properties - 設定文件屬性
    private func setDocumentProperties(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        var props = doc.properties

        if let title = args["title"]?.stringValue {
            props.title = title
        }
        if let subject = args["subject"]?.stringValue {
            props.subject = subject
        }
        if let creator = args["creator"]?.stringValue {
            props.creator = creator
        }
        if let keywords = args["keywords"]?.stringValue {
            props.keywords = keywords
        }
        if let description = args["description"]?.stringValue {
            props.description = description
        }

        doc.properties = props
        openDocuments[docId] = doc

        return "Updated document properties"
    }

    // 9.12 get_document_properties - 取得文件屬性
    private func getDocumentProperties(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let props = doc.properties

        var output = "Document Properties:\n"
        if let title = props.title { output += "- Title: \(title)\n" }
        if let subject = props.subject { output += "- Subject: \(subject)\n" }
        if let creator = props.creator { output += "- Creator: \(creator)\n" }
        if let keywords = props.keywords { output += "- Keywords: \(keywords)\n" }
        if let description = props.description { output += "- Description: \(description)\n" }
        if let lastModifiedBy = props.lastModifiedBy { output += "- Last Modified By: \(lastModifiedBy)\n" }
        if let revision = props.revision { output += "- Revision: \(revision)\n" }
        if let created = props.created { output += "- Created: \(created)\n" }
        if let modified = props.modified { output += "- Modified: \(modified)\n" }

        if output == "Document Properties:\n" {
            return "No document properties set"
        }

        return output
    }

    // 9.13 get_paragraph_runs - 取得段落的 runs 及格式
    private func getParagraphRuns(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let paragraphs = doc.getParagraphs()
        guard paragraphIndex >= 0 && paragraphIndex < paragraphs.count else {
            throw WordError.invalidIndex(paragraphIndex)
        }

        let para = paragraphs[paragraphIndex]
        var output = "Paragraph [\(paragraphIndex)] Runs:\n"

        for (runIndex, run) in para.runs.enumerated() {
            output += "  Run [\(runIndex)]:\n"
            output += "    Text: \"\(run.text)\"\n"

            // 格式資訊
            let props = run.properties
            var formatParts: [String] = []

            if props.bold { formatParts.append("bold") }
            if props.italic { formatParts.append("italic") }
            if props.strikethrough { formatParts.append("strikethrough") }
            if let underline = props.underline { formatParts.append("underline:\(underline.rawValue)") }
            if let color = props.color { formatParts.append("color:#\(color)") }
            if let highlight = props.highlight { formatParts.append("highlight:\(highlight.rawValue)") }
            if let fontSize = props.fontSize { formatParts.append("size:\(fontSize / 2)pt") }
            if let fontName = props.fontName { formatParts.append("font:\(fontName)") }
            if let verticalAlign = props.verticalAlign { formatParts.append("vertAlign:\(verticalAlign.rawValue)") }

            if formatParts.isEmpty {
                output += "    Format: (none)\n"
            } else {
                output += "    Format: \(formatParts.joined(separator: ", "))\n"
            }
        }

        // 也顯示超連結
        if !para.hyperlinks.isEmpty {
            output += "  Hyperlinks:\n"
            for hyperlink in para.hyperlinks {
                output += "    - \"\(hyperlink.text)\" -> \(hyperlink.url ?? hyperlink.anchor ?? "unknown")\n"
            }
        }

        return output
    }

    // 9.14 get_text_with_formatting - 取得帶格式標記的文字
    private func getTextWithFormatting(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let paragraphs = doc.getParagraphs()

        // 如果指定了段落索引，只處理該段落
        if let paragraphIndex = args["paragraph_index"]?.intValue {
            guard paragraphIndex >= 0 && paragraphIndex < paragraphs.count else {
                throw WordError.invalidIndex(paragraphIndex)
            }
            return formatParagraphWithMarkup(paragraphs[paragraphIndex], index: paragraphIndex)
        }

        // 處理所有段落
        var output = ""
        for (index, para) in paragraphs.enumerated() {
            output += formatParagraphWithMarkup(para, index: index) + "\n"
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Helper: 將段落轉換為帶格式標記的文字
    private func formatParagraphWithMarkup(_ para: Paragraph, index: Int) -> String {
        var result = "[\(index)] "

        for run in para.runs {
            var text = run.text
            let props = run.properties

            // 加入格式標記
            if props.bold {
                text = "**\(text)**"
            }
            if props.italic {
                text = "*\(text)*"
            }
            if props.strikethrough {
                text = "~~\(text)~~"
            }
            if let color = props.color {
                // 常見顏色轉換為名稱
                let colorName = colorHexToName(color)
                text = "{{color:\(colorName)}}\(text){{/color}}"
            }
            if let highlight = props.highlight {
                text = "{{highlight:\(highlight.rawValue)}}\(text){{/highlight}}"
            }
            if let underline = props.underline {
                text = "{{underline:\(underline.rawValue)}}\(text){{/underline}}"
            }

            result += text
        }

        // 加入超連結
        for hyperlink in para.hyperlinks {
            result += " [\(hyperlink.text)](\(hyperlink.url ?? "#\(hyperlink.anchor ?? "")"))"
        }

        return result
    }

    // Helper: 顏色 hex 轉名稱
    private func colorHexToName(_ hex: String) -> String {
        let upperHex = hex.uppercased()
        switch upperHex {
        case "FF0000": return "red"
        case "00FF00": return "green"
        case "0000FF": return "blue"
        case "FFFF00": return "yellow"
        case "00FFFF": return "cyan"
        case "FF00FF": return "magenta"
        case "000000": return "black"
        case "FFFFFF": return "white"
        case "808080": return "gray"
        case "FFA500": return "orange"
        case "800080": return "purple"
        default: return "#\(hex)"
        }
    }

    // 9.15 search_by_formatting - 搜尋特定格式的文字
    private func searchByFormatting(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        // 取得搜尋條件
        let searchColor = args["color"]?.stringValue?.uppercased()
        let searchBold = args["bold"]?.boolValue
        let searchItalic = args["italic"]?.boolValue
        let searchHighlight = args["highlight"]?.stringValue

        let paragraphs = doc.getParagraphs()
        var results: [(paragraphIndex: Int, runIndex: Int, text: String, format: String)] = []

        for (paraIndex, para) in paragraphs.enumerated() {
            for (runIndex, run) in para.runs.enumerated() {
                let props = run.properties
                var matches = true

                // 檢查顏色
                if let color = searchColor {
                    if props.color?.uppercased() != color {
                        matches = false
                    }
                }

                // 檢查粗體
                if let bold = searchBold {
                    if props.bold != bold {
                        matches = false
                    }
                }

                // 檢查斜體
                if let italic = searchItalic {
                    if props.italic != italic {
                        matches = false
                    }
                }

                // 檢查螢光標記
                if let highlight = searchHighlight {
                    if props.highlight?.rawValue != highlight {
                        matches = false
                    }
                }

                // 如果符合且文字不為空，加入結果
                if matches && !run.text.isEmpty {
                    var formatParts: [String] = []
                    if props.bold { formatParts.append("bold") }
                    if props.italic { formatParts.append("italic") }
                    if let color = props.color { formatParts.append("color:#\(color)") }
                    if let highlight = props.highlight { formatParts.append("highlight:\(highlight.rawValue)") }

                    results.append((
                        paragraphIndex: paraIndex,
                        runIndex: runIndex,
                        text: run.text,
                        format: formatParts.isEmpty ? "(none)" : formatParts.joined(separator: ", ")
                    ))
                }
            }
        }

        if results.isEmpty {
            return "No text found matching the specified formatting"
        }

        var output = "Found \(results.count) match(es):\n"
        for result in results {
            output += "  [Para \(result.paragraphIndex), Run \(result.runIndex)]: \"\(result.text)\"\n"
            output += "    Format: \(result.format)\n"
        }

        return output
    }

    // 9.16 search_text_with_formatting - 搜尋文字並顯示格式
    private func searchTextWithFormatting(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let query = args["query"]?.stringValue else {
            throw WordError.missingParameter("query")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let caseSensitive = args["case_sensitive"]?.boolValue ?? false
        let contextChars = args["context_chars"]?.intValue ?? 20

        let paragraphs = doc.getParagraphs()
        var results: [(paraIndex: Int, position: Int, matchedText: String, context: String, formats: [String])] = []

        for (paraIndex, para) in paragraphs.enumerated() {
            let paraText = para.getText()
            let searchText = caseSensitive ? paraText : paraText.lowercased()
            let searchQuery = caseSensitive ? query : query.lowercased()

            var searchStart = searchText.startIndex
            while let range = searchText.range(of: searchQuery, range: searchStart..<searchText.endIndex) {
                let position = searchText.distance(from: searchText.startIndex, to: range.lowerBound)
                let matchedText = String(paraText[range])

                // 取得上下文
                let contextStart = max(0, position - contextChars)
                let contextEnd = min(paraText.count, position + matchedText.count + contextChars)
                let startIndex = paraText.index(paraText.startIndex, offsetBy: contextStart)
                let endIndex = paraText.index(paraText.startIndex, offsetBy: contextEnd)
                var context = String(paraText[startIndex..<endIndex])
                if contextStart > 0 { context = "..." + context }
                if contextEnd < paraText.count { context = context + "..." }

                // 找出該位置的格式
                var formats: [String] = []
                var currentPos = 0
                for run in para.runs {
                    let runEnd = currentPos + run.text.count
                    // 檢查這個 run 是否包含搜尋結果
                    if currentPos <= position && position < runEnd {
                        let props = run.properties
                        if props.bold { formats.append("bold") }
                        if props.italic { formats.append("italic") }
                        if props.strikethrough { formats.append("strikethrough") }
                        if let color = props.color {
                            formats.append("color:\(colorHexToName(color))")
                        }
                        if let highlight = props.highlight {
                            formats.append("highlight:\(highlight.rawValue)")
                        }
                        if let underline = props.underline {
                            formats.append("underline:\(underline.rawValue)")
                        }
                        break
                    }
                    currentPos = runEnd
                }

                results.append((paraIndex, position, matchedText, context, formats))
                searchStart = range.upperBound
            }
        }

        if results.isEmpty {
            return "No matches found for '\(query)'"
        }

        var output = "Found \(results.count) match(es) for '\(query)':\n"
        for result in results {
            output += "[Para \(result.paraIndex)] \(result.context)\n"
            if result.formats.isEmpty {
                output += "  Format: (none)\n"
            } else {
                output += "  Format: \(result.formats.joined(separator: ", "))\n"
            }
        }
        return output
    }

    // 9.17 list_all_formatted_text - 列出特定格式的所有文字
    private func listAllFormattedText(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let formatType = args["format_type"]?.stringValue?.lowercased() else {
            throw WordError.missingParameter("format_type")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let colorFilter = args["color_filter"]?.stringValue?.uppercased()
        let paragraphStart = args["paragraph_start"]?.intValue ?? 0
        let paragraphEnd = args["paragraph_end"]?.intValue

        let paragraphs = doc.getParagraphs()
        let endIndex = paragraphEnd ?? paragraphs.count - 1

        guard paragraphStart >= 0 && paragraphStart < paragraphs.count else {
            throw WordError.invalidIndex(paragraphStart)
        }
        guard endIndex >= paragraphStart && endIndex < paragraphs.count else {
            throw WordError.invalidIndex(endIndex)
        }

        var results: [(paraIndex: Int, text: String)] = []

        for paraIndex in paragraphStart...endIndex {
            let para = paragraphs[paraIndex]
            for run in para.runs {
                let props = run.properties
                var matches = false

                switch formatType {
                case "italic":
                    matches = props.italic
                case "bold":
                    matches = props.bold
                case "underline":
                    matches = props.underline != nil
                case "strikethrough":
                    matches = props.strikethrough
                case "highlight":
                    matches = props.highlight != nil
                case "color":
                    if let colorFilter = colorFilter {
                        matches = props.color?.uppercased() == colorFilter
                    } else {
                        matches = props.color != nil
                    }
                default:
                    break
                }

                if matches && !run.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    results.append((paraIndex, run.text))
                }
            }
        }

        if results.isEmpty {
            let rangeInfo = paragraphEnd != nil ? " in paragraphs \(paragraphStart)-\(endIndex)" : ""
            return "No \(formatType) text found\(rangeInfo)"
        }

        var output = "Found \(results.count) \(formatType) text segment(s):\n"
        for result in results {
            // 截斷過長的文字
            let displayText = result.text.count > 60 ? String(result.text.prefix(57)) + "..." : result.text
            output += "[Para \(result.paraIndex)] \"\(displayText)\"\n"
        }
        return output
    }

    // 9.18 get_word_count_by_section - 按區段統計字數
    private func getWordCountBySection(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        // 解析區段標記
        var sectionMarkers: [String] = []
        if let markersValue = args["section_markers"] {
            if let markersArray = markersValue.arrayValue {
                sectionMarkers = markersArray.compactMap { $0.stringValue }
            }
        }

        // 解析排除區段
        var excludeSections: Set<String> = []
        if let excludeValue = args["exclude_sections"] {
            if let excludeArray = excludeValue.arrayValue {
                excludeSections = Set(excludeArray.compactMap { $0.stringValue })
            }
        }

        let paragraphs = doc.getParagraphs()

        // 如果沒有指定區段標記，直接計算總字數
        if sectionMarkers.isEmpty {
            var totalWords = 0
            var totalChars = 0
            for para in paragraphs {
                let text = para.getText()
                totalWords += countWords(text)
                totalChars += text.filter { !$0.isWhitespace }.count
            }
            return """
            Word Count Summary:
              Total words: \(formatNumber(totalWords))
              Total characters (no spaces): \(formatNumber(totalChars))
              Total paragraphs: \(paragraphs.count)
            """
        }

        // 找出每個區段的起始段落
        var sectionStarts: [(name: String, startIndex: Int)] = []
        for (index, para) in paragraphs.enumerated() {
            let paraText = para.getText().trimmingCharacters(in: .whitespacesAndNewlines)
            for marker in sectionMarkers {
                // 檢查段落是否以標記開頭（支援各種格式如 "1. Introduction", "Introduction:", "INTRODUCTION" 等）
                let lowerParaText = paraText.lowercased()
                let lowerMarker = marker.lowercased()
                if lowerParaText == lowerMarker ||
                   lowerParaText.hasPrefix(lowerMarker + ":") ||
                   lowerParaText.hasPrefix(lowerMarker + " ") ||
                   lowerParaText.hasSuffix(" " + lowerMarker) ||
                   lowerParaText.contains(". " + lowerMarker) {
                    sectionStarts.append((marker, index))
                    break
                }
            }
        }

        // 如果沒有找到任何區段，返回總字數
        if sectionStarts.isEmpty {
            var totalWords = 0
            for para in paragraphs {
                totalWords += countWords(para.getText())
            }
            return """
            No section markers found in document.
            Total words: \(formatNumber(totalWords))

            Tip: Section markers should match paragraph text (e.g., "Abstract", "Introduction", "References")
            """
        }

        // 計算每個區段的字數
        var sectionCounts: [(name: String, words: Int, excluded: Bool)] = []
        var totalWords = 0
        var excludedWords = 0

        // 處理第一個區段之前的內容
        if sectionStarts[0].startIndex > 0 {
            var preWords = 0
            for i in 0..<sectionStarts[0].startIndex {
                preWords += countWords(paragraphs[i].getText())
            }
            if preWords > 0 {
                sectionCounts.append(("(Before first section)", preWords, false))
                totalWords += preWords
            }
        }

        // 計算各區段
        for (i, section) in sectionStarts.enumerated() {
            let startIndex = section.startIndex
            let endIndex = (i + 1 < sectionStarts.count) ? sectionStarts[i + 1].startIndex : paragraphs.count

            var sectionWords = 0
            for j in startIndex..<endIndex {
                sectionWords += countWords(paragraphs[j].getText())
            }

            let isExcluded = excludeSections.contains(section.name)
            sectionCounts.append((section.name, sectionWords, isExcluded))
            totalWords += sectionWords
            if isExcluded {
                excludedWords += sectionWords
            }
        }

        // 生成輸出
        var output = "Word Count by Section:\n"
        for section in sectionCounts {
            let excludeTag = section.excluded ? " (excluded)" : ""
            output += "  \(section.name): \(formatNumber(section.words)) words\(excludeTag)\n"
        }
        output += "  ─────────────────────────────\n"
        if excludedWords > 0 {
            output += "  Main Text: \(formatNumber(totalWords - excludedWords)) words\n"
        }
        output += "  Total: \(formatNumber(totalWords)) words\n"

        return output
    }

    // Helper: 計算字數（支援中英文混合）
    private func countWords(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }

        // 分離中文和英文
        var englishWords = 0
        var chineseChars = 0

        // 用正規表達式分割
        let englishPattern = try? NSRegularExpression(pattern: "[a-zA-Z]+", options: [])
        let chinesePattern = try? NSRegularExpression(pattern: "[\\u4e00-\\u9fff]", options: [])

        let range = NSRange(trimmed.startIndex..., in: trimmed)

        if let matches = englishPattern?.matches(in: trimmed, options: [], range: range) {
            englishWords = matches.count
        }

        if let matches = chinesePattern?.matches(in: trimmed, options: [], range: range) {
            chineseChars = matches.count
        }

        // 中文每個字算一個詞
        return englishWords + chineseChars
    }

    // Helper: 格式化數字（加入千分位）
    private func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    // MARK: - Document Comparison

    private struct ParagraphSnapshot {
        let index: Int
        let text: String
        let textHash: Int
        let style: String?
        let formattedText: String
    }

    private enum DiffType {
        case unchanged, modified, deleted, added, formatOnly
    }

    private struct DiffEntry {
        let type: DiffType
        let indexA: Int?
        let indexB: Int?
        let style: String?
        let textA: String?
        let textB: String?
        let formattedA: String?
        let formattedB: String?
    }

    private func snapshotParagraphs(_ doc: WordDocument) -> [ParagraphSnapshot] {
        let paragraphs = doc.getParagraphs()
        return paragraphs.enumerated().map { (index, para) in
            let text = para.getText().trimmingCharacters(in: .whitespacesAndNewlines)
            return ParagraphSnapshot(
                index: index,
                text: text,
                textHash: text.hashValue,
                style: para.properties.style,
                formattedText: formatParagraphWithMarkup(para, index: index)
            )
        }
    }

    private func computeLCS(_ a: [ParagraphSnapshot], _ b: [ParagraphSnapshot]) -> [[Int]] {
        let n = a.count
        let m = b.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 1...max(n, 1) {
            guard i <= n else { break }
            for j in 1...max(m, 1) {
                guard j <= m else { break }
                if a[i - 1].textHash == b[j - 1].textHash && a[i - 1].text == b[j - 1].text {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }
        return dp
    }

    private func textSimilarity(_ a: String, _ b: String) -> Double {
        let wordsA = Set(a.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }))
        let wordsB = Set(b.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }))
        guard !wordsA.isEmpty || !wordsB.isEmpty else { return 1.0 }
        let intersection = wordsA.intersection(wordsB).count
        let union = wordsA.union(wordsB).count
        guard union > 0 else { return 0.0 }
        return Double(intersection) / Double(union)
    }

    private func buildDiffEntries(
        _ a: [ParagraphSnapshot],
        _ b: [ParagraphSnapshot],
        _ dp: [[Int]],
        mode: String
    ) -> [DiffEntry] {
        // Backtrack LCS to get aligned sequence
        var aligned: [(aIdx: Int?, bIdx: Int?)] = []
        var i = a.count
        var j = b.count
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && a[i - 1].textHash == b[j - 1].textHash && a[i - 1].text == b[j - 1].text {
                aligned.append((i - 1, j - 1))
                i -= 1
                j -= 1
            } else if j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j]) {
                aligned.append((nil, j - 1))
                j -= 1
            } else {
                aligned.append((i - 1, nil))
                i -= 1
            }
        }
        aligned.reverse()

        // Post-process: merge adjacent DELETED+ADDED into MODIFIED if similar
        var entries: [DiffEntry] = []
        var idx = 0
        while idx < aligned.count {
            let (aIdx, bIdx) = aligned[idx]
            if let ai = aIdx, let bi = bIdx {
                // Matched pair
                let checkFormatting = (mode == "formatting" || mode == "full")
                if checkFormatting && a[ai].formattedText != b[bi].formattedText {
                    entries.append(DiffEntry(
                        type: .formatOnly,
                        indexA: ai, indexB: bi,
                        style: a[ai].style ?? b[bi].style,
                        textA: a[ai].text, textB: b[bi].text,
                        formattedA: a[ai].formattedText, formattedB: b[bi].formattedText
                    ))
                } else {
                    entries.append(DiffEntry(
                        type: .unchanged,
                        indexA: ai, indexB: bi,
                        style: a[ai].style,
                        textA: a[ai].text, textB: nil,
                        formattedA: nil, formattedB: nil
                    ))
                }
                idx += 1
            } else if aIdx != nil && bIdx == nil {
                // Check if next is ADDED and they are similar → MODIFIED
                if idx + 1 < aligned.count,
                   aligned[idx + 1].aIdx == nil,
                   let bi = aligned[idx + 1].bIdx,
                   let ai = aIdx,
                   textSimilarity(a[ai].text, b[bi].text) > 0.5 {
                    entries.append(DiffEntry(
                        type: .modified,
                        indexA: ai, indexB: bi,
                        style: a[ai].style ?? b[bi].style,
                        textA: a[ai].text, textB: b[bi].text,
                        formattedA: a[ai].formattedText, formattedB: b[bi].formattedText
                    ))
                    idx += 2
                } else {
                    entries.append(DiffEntry(
                        type: .deleted,
                        indexA: aIdx, indexB: nil,
                        style: a[aIdx!].style,
                        textA: a[aIdx!].text, textB: nil,
                        formattedA: a[aIdx!].formattedText, formattedB: nil
                    ))
                    idx += 1
                }
            } else {
                // ADDED - check if next is DELETED and they are similar → MODIFIED
                if idx + 1 < aligned.count,
                   aligned[idx + 1].bIdx == nil,
                   let ai = aligned[idx + 1].aIdx,
                   let bi = bIdx,
                   textSimilarity(a[ai].text, b[bi].text) > 0.5 {
                    entries.append(DiffEntry(
                        type: .modified,
                        indexA: ai, indexB: bi,
                        style: a[ai].style ?? b[bi].style,
                        textA: a[ai].text, textB: b[bi].text,
                        formattedA: a[ai].formattedText, formattedB: b[bi].formattedText
                    ))
                    idx += 2
                } else {
                    entries.append(DiffEntry(
                        type: .added,
                        indexA: nil, indexB: bIdx,
                        style: b[bIdx!].style,
                        textA: nil, textB: b[bIdx!].text,
                        formattedA: nil, formattedB: b[bIdx!].formattedText
                    ))
                    idx += 1
                }
            }
        }
        return entries
    }

    private func truncateText(_ text: String, maxLength: Int = 200, contextChars: Int = 30) -> String {
        guard text.count > maxLength else { return text }
        let start = text.prefix(contextChars)
        let end = text.suffix(contextChars)
        return "\(start) [...] \(end)"
    }

    private func formatStructureComparison(
        docIdA: String, docIdB: String,
        snapshotsA: [ParagraphSnapshot], snapshotsB: [ParagraphSnapshot],
        infoA: (paragraphs: Int, words: Int), infoB: (paragraphs: Int, words: Int)
    ) -> String {
        var output = """
        === Document Comparison (Structure) ===
        Base: \(docIdA) (\(infoA.paragraphs) paragraphs, \(formatNumber(infoA.words)) words)
        Compare: \(docIdB) (\(infoB.paragraphs) paragraphs, \(formatNumber(infoB.words)) words)

        --- Statistics ---
        Paragraph count: \(infoA.paragraphs) → \(infoB.paragraphs) (\(infoB.paragraphs >= infoA.paragraphs ? "+" : "")\(infoB.paragraphs - infoA.paragraphs))
        Word count: \(formatNumber(infoA.words)) → \(formatNumber(infoB.words)) (\(infoB.words >= infoA.words ? "+" : "")\(formatNumber(infoB.words - infoA.words)))

        --- Heading Outline: Base (\(docIdA)) ---

        """
        let headingStyles = Set(["Heading1", "Heading2", "Heading3", "Heading 1", "Heading 2", "Heading 3", "heading 1", "heading 2", "heading 3", "Title"])
        for s in snapshotsA {
            if let style = s.style, headingStyles.contains(style) {
                let indent = style.contains("2") ? "  " : (style.contains("3") ? "    " : "")
                output += "\(indent)[\(s.index)] (\(style)) \(truncateText(s.text, maxLength: 80))\n"
            }
        }
        output += "\n--- Heading Outline: Compare (\(docIdB)) ---\n"
        for s in snapshotsB {
            if let style = s.style, headingStyles.contains(style) {
                let indent = style.contains("2") ? "  " : (style.contains("3") ? "    " : "")
                output += "\(indent)[\(s.index)] (\(style)) \(truncateText(s.text, maxLength: 80))\n"
            }
        }
        return output
    }

    private func formatComparisonResult(
        docIdA: String, docIdB: String,
        infoA: (paragraphs: Int, words: Int), infoB: (paragraphs: Int, words: Int),
        entries: [DiffEntry], mode: String, contextLines: Int
    ) -> String {
        let unchanged = entries.filter { $0.type == .unchanged }.count
        let modified = entries.filter { $0.type == .modified }.count
        let added = entries.filter { $0.type == .added }.count
        let deleted = entries.filter { $0.type == .deleted }.count
        let formatOnly = entries.filter { $0.type == .formatOnly }.count

        if modified == 0 && added == 0 && deleted == 0 && formatOnly == 0 {
            return """
            === Document Comparison ===
            Base: \(docIdA) (\(infoA.paragraphs) paragraphs, \(formatNumber(infoA.words)) words)
            Compare: \(docIdB) (\(infoB.paragraphs) paragraphs, \(formatNumber(infoB.words)) words)
            Mode: \(mode)

            Documents are identical.
            """
        }

        var output = """
        === Document Comparison ===
        Base: \(docIdA) (\(infoA.paragraphs) paragraphs, \(formatNumber(infoA.words)) words)
        Compare: \(docIdB) (\(infoB.paragraphs) paragraphs, \(formatNumber(infoB.words)) words)
        Mode: \(mode)

        --- Summary ---
        Unchanged: \(unchanged)  Modified: \(modified)  Added: \(added)  Deleted: \(deleted)
        """
        if formatOnly > 0 {
            output += "  Format-only: \(formatOnly)"
        }
        output += "\n\n--- Differences ---\n"

        var diffCount = 0
        let maxDiffs = 50
        for (entryIdx, entry) in entries.enumerated() {
            if entry.type == .unchanged { continue }
            diffCount += 1
            if diffCount > maxDiffs {
                let remaining = entries.filter { $0.type != .unchanged }.count - maxDiffs
                output += "\n... and \(remaining) more differences (truncated)\n"
                break
            }

            // Context: show preceding unchanged paragraphs
            if contextLines > 0 {
                var contextEntries: [DiffEntry] = []
                var lookBack = entryIdx - 1
                while lookBack >= 0 && contextEntries.count < contextLines {
                    if entries[lookBack].type == .unchanged {
                        contextEntries.insert(entries[lookBack], at: 0)
                    } else {
                        break
                    }
                    lookBack -= 1
                }
                for ctx in contextEntries {
                    output += "\n  . A[\(ctx.indexA ?? 0)] \(truncateText(ctx.textA ?? "", maxLength: 80))"
                }
            }

            let style = entry.style ?? "Normal"
            switch entry.type {
            case .modified:
                output += "\n[MODIFIED] A[\(entry.indexA!)] → B[\(entry.indexB!)] (\(style))"
                output += "\n  - \(truncateText(entry.textA ?? "", maxLength: 200))"
                output += "\n  + \(truncateText(entry.textB ?? "", maxLength: 200))"
            case .deleted:
                output += "\n[DELETED] A[\(entry.indexA!)] (\(style))"
                output += "\n  \(truncateText(entry.textA ?? "", maxLength: 200))"
            case .added:
                output += "\n[ADDED] B[\(entry.indexB!)] (\(style))"
                output += "\n  \(truncateText(entry.textB ?? "", maxLength: 200))"
            case .formatOnly:
                output += "\n[FORMAT_ONLY] A[\(entry.indexA!)] → B[\(entry.indexB!)] (\(style))"
                output += "\n  Text: \(truncateText(entry.textA ?? "", maxLength: 120))"
                // Show formatting diff
                let fmtA = entry.formattedA ?? ""
                let fmtB = entry.formattedB ?? ""
                output += "\n  Base fmt: \(truncateText(fmtA, maxLength: 200))"
                output += "\n  Comp fmt: \(truncateText(fmtB, maxLength: 200))"
            case .unchanged:
                break
            }
            output += "\n"
        }
        return output
    }

    private func compareDocuments(args: [String: Value]) async throws -> String {
        guard let docIdA = args["doc_id_a"]?.stringValue else {
            throw WordError.missingParameter("doc_id_a")
        }
        guard let docIdB = args["doc_id_b"]?.stringValue else {
            throw WordError.missingParameter("doc_id_b")
        }
        if docIdA == docIdB {
            return "Error: doc_id_a and doc_id_b must be different documents."
        }
        guard let docA = openDocuments[docIdA] else {
            throw WordError.documentNotFound(docIdA)
        }
        guard let docB = openDocuments[docIdB] else {
            throw WordError.documentNotFound(docIdB)
        }

        let mode = args["mode"]?.stringValue ?? "text"
        let contextLines = min(max(args["context_lines"]?.intValue ?? 0, 0), 3)

        let snapshotsA = snapshotParagraphs(docA)
        let snapshotsB = snapshotParagraphs(docB)

        if snapshotsA.isEmpty && snapshotsB.isEmpty {
            return "Both documents have no paragraphs."
        }
        if snapshotsA.isEmpty {
            return "Base document (\(docIdA)) has no paragraphs."
        }
        if snapshotsB.isEmpty {
            return "Compare document (\(docIdB)) has no paragraphs."
        }

        let wordsA = snapshotsA.reduce(0) { $0 + countWords($1.text) }
        let wordsB = snapshotsB.reduce(0) { $0 + countWords($1.text) }
        let infoA = (paragraphs: snapshotsA.count, words: wordsA)
        let infoB = (paragraphs: snapshotsB.count, words: wordsB)

        // Structure mode: only statistics + heading outline
        if mode == "structure" {
            return formatStructureComparison(
                docIdA: docIdA, docIdB: docIdB,
                snapshotsA: snapshotsA, snapshotsB: snapshotsB,
                infoA: infoA, infoB: infoB
            )
        }

        let dp = computeLCS(snapshotsA, snapshotsB)
        let entries = buildDiffEntries(snapshotsA, snapshotsB, dp, mode: mode)

        return formatComparisonResult(
            docIdA: docIdA, docIdB: docIdB,
            infoA: infoA, infoB: infoB,
            entries: entries, mode: mode, contextLines: contextLines
        )
    }
}
