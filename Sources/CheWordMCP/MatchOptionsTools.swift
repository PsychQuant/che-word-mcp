import Foundation
import MCP
import OOXMLSwift

/// #90 / #115 follow-ups (#150-#154): the `match_options` JSON Schema
/// fragment shared by every tool whose text-anchor lookup supports
/// `math_script_insensitive`. A single `static var` (mirroring
/// `documentProfileSchema` in `DocumentProfileTools.swift`) so the schema's
/// enumerated Unicode-range claim (#150 — "schema description 過度承諾"
/// found by the PR #115 verify) and `parseAnchorLookupOptions`'s actual
/// runtime behavior (`Server.swift`) can never drift apart from each other:
/// there is exactly one place this text is written.
///
/// #152's own strategy write-up proposed schema `additionalProperties:
/// false` alongside the runtime rejection. That key is deliberately OMITTED
/// here: `Issue236ToolSchemaOpenAPISubsetTests
/// .testNoSchemaDeclaresAdditionalProperties` (repo policy from #236, a
/// closed, tested decision — "`additionalProperties`：OpenAPI 3.0 合法，但不在
/// Gemini `Schema` 的欄位清單內...改在描述裡說明") already guards every tool
/// schema in this repo against declaring `additionalProperties` at all, for
/// cross-client compatibility with transports that convert MCP tool schemas
/// to Gemini function declarations. Adding it here would violate that
/// existing, deliberate invariant and fail that guard test. The functional
/// requirement — reject unknown/typo'd keys — is fully met by the RUNTIME
/// check in `parseAnchorLookupOptions` (`Server.swift`) plus documenting the
/// closed key set in this schema's own `description` text, exactly as #236
/// already prescribes doing for `export_comment_threads_markdown
/// .author_aliases`.
extension WordMCPServer {
    static var matchOptionsSchema: Value {
        .object([
            "type": .string("object"),
            "description": .string(
                "文字 anchor 比對的額外選項，只有 anchor 涉及數學符號時才需要。"
                    + "目前只有一個 key：math_script_insensitive；其他 key（含拼字錯誤，如 math_script_insensitve 缺一個 i）"
                    + "一律回 isError，不會靜默忽略。"
            ),
            "properties": .object([
                "math_script_insensitive": .object([
                    "type": .string("boolean"),
                    "description": .string(
                        "true 時，anchor 比對忽略 Unicode 數學上下標／重音差異（例如 H₀ 與 H0 視為相同）。"
                            + "支援範圍（隨 ooxml-swift AnchorLookupOptions.mathScriptVariantMap 而定，非任意 Unicode 變體）：\n"
                            + "- 數字下標 U+2080–U+2089（₀–₉）↔ 0–9\n"
                            + "- 數字上標 U+2070、U+2074–U+2079（⁰ ⁴–⁹）與 Latin-1 歷史上標 U+00B2/U+00B3/U+00B9（² ³ ¹）↔ 0–9\n"
                            + "- 常用下標／上標字母 U+2090–U+209C（如 ᵢ ⱼ ₓ）與 U+1D2C 區塊上標字母 ↔ 對應 ASCII 字母\n"
                            + "- Greek 下標 U+1D66–U+1D6A（ᵦᵧᵨᵩᵪ）↔ βγρφχ\n"
                            + "- 數學重音符號（如 X̄ 的 combining macron U+0304、ŷ 的 circumflex）：比對時經 NFD 分解後去除\n"
                            + "其他 Unicode 變體（vulgar fraction、mathematical alphanumeric symbols 等）不在支援範圍，"
                            + "仍需精確比對。完整 mapping 見 ooxml-swift Sources/OOXMLSwift/Models/InsertLocation.swift 的 "
                            + "AnchorLookupOptions.mathScriptVariantMap。預設 false（維持既有精確比對，向後相容）。"
                    )
                ])
            ])
        ])
    }
}
