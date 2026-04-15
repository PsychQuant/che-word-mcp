import Foundation

/// Canonicalizes raw author names from docx XML to a per-call canonical name.
///
/// Used by `compare_documents_markdown` and `export_comment_threads_markdown` to
/// merge "the same reviewer using two computers" into a single label
/// (e.g., `kllay's PC` → `Lay`).
///
/// Per the `manuscript-review-markdown-export` design — Decision: Author Alias
/// Normalization is Shared Helper.
///
/// Lookup is exact-match (case-sensitive, no whitespace normalization). When a
/// raw author is not in the map, `canonicalize(_:)` returns the raw author
/// unchanged.
public struct AuthorAliasMap {
    private let map: [String: String]

    public init(_ map: [String: String]) {
        self.map = map
    }

    /// Returns the canonical name for `rawAuthor`, or `rawAuthor` itself when
    /// no mapping exists.
    public func canonicalize(_ rawAuthor: String) -> String {
        return map[rawAuthor] ?? rawAuthor
    }
}
