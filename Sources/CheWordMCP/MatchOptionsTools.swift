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
/// R2 fix (independent review MEDIUM-1): the first version of this
/// description claimed "常用下標／上標字母 U+2090–U+209C（如 ᵢ ⱼ ₓ）" — but `ᵢ`
/// is U+1D62 (Phonetic Extensions) and `ⱼ` is U+2C7C (Latin Extended-C),
/// NEITHER inside U+2090–U+209C; only `ₓ` (U+2093) actually is. Verified by
/// mechanically extracting every `(glyph, replacement)` pair straight out of
/// ooxml-swift's `InsertLocation.swift` source (not retyped by hand) and
/// checking each glyph's actual `ord()` — all 97 mapped characters are
/// enumerated below by the SAME extraction, grouped only where they truly
/// share one contiguous Unicode block. The 44 superscript letters do NOT
/// reduce to any single range (they span at least 5 disjoint blocks), so
/// this description does not claim one — see that bullet's own note.
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
                            + "支援範圍是 ooxml-swift AnchorLookupOptions.mathScriptVariantMap 逐字元列舉的封閉集合"
                            + "（共 97 個字元，逐一核對碼位如下，不是任意 Unicode 數學符號變體）：\n"
                            + "- 下標數字 ₀₁₂₃₄₅₆₇₈₉：U+2080–U+2089 ↔ 0–9\n"
                            + "- 上標數字 ⁰¹²³⁴⁵⁶⁷⁸⁹：U+2070（⁰）、U+2074–U+2079（⁴–⁹），"
                            + "以及 Latin-1 歷史上標 U+00B9（¹）、U+00B2（²）、U+00B3（³）↔ 0–9\n"
                            + "- 下標／上標運算符號 ₊⁺₋⁻₌⁼₍⁽₎⁾：U+208A–U+208E（下標）與 U+207A–U+207E（上標）↔ + - = ( )\n"
                            + "- 下標字母 ₐₑₕₖₗₘₙₒₚₛₜₓₔ（13 個，含 U+2094 schwa ↔ ə）：U+2090–U+209C 整段連續區塊 ↔ a e h k l m n o p s t x ə；"
                            + "另有 5 個下標字母不落在此區塊內：ᵢᵣᵤᵥ（i r u v，U+1D62–U+1D65，Phonetic Extensions 區塊）、"
                            + "ⱼ（j，U+2C7C，Latin Extended-C 孤立碼位）\n"
                            + "- Greek 下標 ᵦᵧᵨᵩᵪ：U+1D66–U+1D6A ↔ β γ ρ φ χ\n"
                            + "- 上標字母（44 個：a–z 除 q 共 25 個小寫；A–Z 僅 A B D E G H I J K L M N O P R T U V W 共 19 個大寫）："
                            + "**不對應任何單一連續碼位範圍**——分散在 Spacing Modifier Letters（如 ʰ U+02B0、ʷ U+02B7）、"
                            + "Phonetic Extensions（如 ᵃ U+1D43、ᴬ U+1D2C）、Phonetic Extensions Supplement（如 ᶜ U+1D9C、ᶠ U+1DA0）、"
                            + "Superscripts and Subscripts（ⁱ U+2071、ⁿ U+207F）、Latin Extended-C（ⱽ U+2C7D）等至少 5 個不相連區塊；"
                            + "逐字元清單以 ooxml-swift 原始碼為準，不在此重複列舉全部 44 個碼位\n"
                            + "- 數學重音符號（如 X̄ 的 combining macron U+0304、ŷ 的 circumflex）：比對前先做 NFD 分解，"
                            + "任何 nonspacing combining mark（Unicode general category Mn，不限數學重音）都會被去除\n"
                            + "其他 Unicode 變體（vulgar fraction、mathematical alphanumeric symbols 等）不在支援範圍，仍需精確比對。"
                            + "完整逐字元 mapping 見 ooxml-swift Sources/OOXMLSwift/Models/InsertLocation.swift 的 "
                            + "AnchorLookupOptions.mathScriptVariantMap（本描述的分類與碼位已逐一核對，如有出入以該原始碼為準）。"
                            + "預設 false（維持既有精確比對，向後相容）。"
                    )
                ])
            ])
        ])
    }
}
