import Foundation
import MCP
import OOXMLSwift

extension WordMCPServer {
    static var documentProfileSchema: Value {
        .object([
            "type": .string("string"),
            "enum": .array([.string("inherit"), .string("official")]),
            "description": .string("文件格式：inherit 或 official。新建時優先於共用設定；既有文件與腳本只在明示時套用。official 需要先用 macdoc config document import-official 匯入快照。")
        ])
    }

    func resolveDocumentProfile(
        args: [String: Value], context: DocumentFormattingContext
    ) throws -> DocumentFormattingProfile? {
        var kind: DocumentFormattingProfile.Kind?
        if let raw = args["profile"] {
            guard case .string(let value) = raw, let parsed = DocumentFormattingProfile.Kind(rawValue: value) else {
                throw WordError.invalidParameter("profile", "必須是 inherit 或 official 字串；不接受 null 或其他型別。")
            }
            kind = parsed
        }
        return try documentProfileStore.resolve(explicit: kind, context: context)
    }
}
