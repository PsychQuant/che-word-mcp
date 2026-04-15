import Foundation
import MarkdownSwift
import OOXMLSwift

// MARK: - Truncation helper (per Spectra change manuscript-review-markdown-export)

/// Apply the unified summarize/elision policy.
///
/// - When `summarize == false` (default), return `text` unchanged.
/// - When `summarize == true`, return `text` unchanged if `text.count <= threshold`,
///   otherwise emit `<first 30 chars> [...] <last 30 chars>`.
func applySummarize(_ text: String, summarize: Bool, threshold: Int = 5000, contextChars: Int = 30) -> String {
    guard summarize, text.count > threshold else { return text }
    let start = text.prefix(contextChars)
    let end = text.suffix(contextChars)
    return "\(start) [...] \(end)"
}

// MARK: - export_revision_summary_markdown

public enum RevisionGroupBy: String {
    case author, section, type, none
}

public typealias RevisionTuple = (id: Int, type: String, author: String, paragraphIndex: Int, originalText: String?, newText: String?)
public typealias CommentTuple = (id: Int, author: String, text: String, paragraphIndex: Int, date: Date)

public func formatRevisionSummaryMarkdown(
    fileName: String,
    revisions: [RevisionTuple],
    comments: [CommentTuple],
    includeRevisions: Bool = true,
    includeComments: Bool = true,
    groupBy: RevisionGroupBy = .author,
    summarize: Bool = false
) -> String {
    var md = MarkdownBuilder().heading(level: 1, text: "\(fileName) — Revision Summary")

    md = md.heading(level: 2, text: "Stats")

    let revAuthorCounts = Dictionary(grouping: revisions, by: { $0.author }).mapValues { $0.count }
    let commentAuthorCounts = Dictionary(grouping: comments, by: { $0.author }).mapValues { $0.count }
    let allAuthors = Set(revAuthorCounts.keys).union(Set(commentAuthorCounts.keys)).sorted()

    var statLines = ["Revisions: \(revisions.count)", "Comments: \(comments.count)"]
    if !allAuthors.isEmpty {
        let authorSummary = allAuthors.map { author in
            "\(author) (\(revAuthorCounts[author] ?? 0) rev / \(commentAuthorCounts[author] ?? 0) cmt)"
        }.joined(separator: ", ")
        statLines.append("Authors: \(authorSummary)")
    }
    md = md.bulletList(statLines)

    if includeRevisions, !revisions.isEmpty {
        md = md.heading(level: 2, text: "Revisions")
        switch groupBy {
        case .author:
            let grouped = Dictionary(grouping: revisions, by: { $0.author })
            for author in grouped.keys.sorted() {
                let group = grouped[author]!
                md = md.heading(level: 3, text: author)
                let rows = group.enumerated().map { (i, rev) in
                    [
                        String(i + 1),
                        String(rev.paragraphIndex),
                        rev.type,
                        applySummarize(rev.originalText ?? "", summarize: summarize),
                        applySummarize(rev.newText ?? "", summarize: summarize),
                    ]
                }
                md = md.table(headers: ["#", "Para", "Type", "Original", "New"], rows: rows)
            }
        case .type:
            let grouped = Dictionary(grouping: revisions, by: { $0.type })
            for type in grouped.keys.sorted() {
                let group = grouped[type]!
                md = md.heading(level: 3, text: type)
                let rows = group.enumerated().map { (i, rev) in
                    [
                        String(i + 1),
                        String(rev.paragraphIndex),
                        rev.author,
                        applySummarize(rev.originalText ?? "", summarize: summarize),
                        applySummarize(rev.newText ?? "", summarize: summarize),
                    ]
                }
                md = md.table(headers: ["#", "Para", "Author", "Original", "New"], rows: rows)
            }
        case .section, .none:
            let rows = revisions.enumerated().map { (i, rev) in
                [
                    String(i + 1),
                    String(rev.paragraphIndex),
                    rev.author,
                    rev.type,
                    applySummarize(rev.originalText ?? "", summarize: summarize),
                    applySummarize(rev.newText ?? "", summarize: summarize),
                ]
            }
            md = md.table(headers: ["#", "Para", "Author", "Type", "Original", "New"], rows: rows)
        }
    }

    if includeComments, !comments.isEmpty {
        md = md.heading(level: 2, text: "Comments")
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        let rows = comments.enumerated().map { (i, c) in
            [
                String(i + 1),
                String(c.paragraphIndex),
                c.author,
                applySummarize(c.text, summarize: summarize),
                dateFormatter.string(from: c.date),
            ]
        }
        md = md.table(headers: ["#", "Para", "Author", "Text", "Date"], rows: rows)
    }

    return md.build()
}

// MARK: - compare_documents_markdown

public struct DocumentRef {
    public let path: String
    public let label: String
    public init(path: String, label: String) {
        self.path = path
        self.label = label
    }
}

public enum DiffFormat: String {
    case narrative, table, raw
}

public struct DocStats {
    public let label: String
    public let revisionCount: Int
    public let commentCount: Int
    public let wordCount: Int
}

public func formatCompareDocumentsMarkdown(
    documents: [DocumentRef],
    docStats: [DocStats],
    pairwiseDiffs: [(fromLabel: String, toLabel: String, diff: String)],
    includeSummaryTable: Bool = true,
    includePerPairDiff: Bool = true,
    diffFormat: DiffFormat = .narrative
) -> String {
    var md = MarkdownBuilder().heading(level: 1, text: "Manuscript Change Timeline")

    if includeSummaryTable, !docStats.isEmpty {
        md = md.heading(level: 2, text: "Versions")
        let rows = docStats.enumerated().map { (i, s) in
            [
                String(i + 1),
                s.label,
                String(s.revisionCount),
                String(s.commentCount),
                String(s.wordCount),
            ]
        }
        md = md.table(headers: ["#", "Label", "Revisions", "Comments", "Words"], rows: rows)
    }

    if includePerPairDiff {
        md = md.heading(level: 2, text: "Pairwise transitions")
        for pair in pairwiseDiffs {
            md = md.heading(level: 3, text: "\(pair.fromLabel) → \(pair.toLabel)")
            switch diffFormat {
            case .narrative, .table, .raw:
                // For initial release, all three formats route the underlying
                // compare_documents text output verbatim. Formatting variants
                // can be expanded in a follow-up change.
                md = md.codeBlock(pair.diff, language: "diff")
            }
        }
    }

    return md.build()
}

// MARK: - export_comment_threads_markdown

public enum CommentThreadFormat: String {
    case table, threaded, narrative
}

public struct CommentThread {
    public let parent: Comment
    public let replies: [Comment]
    public let resolved: Bool
}

public func buildCommentThreads(comments: [Comment], aliases: AuthorAliasMap) -> [CommentThread] {
    let parents = comments.filter { !$0.isReply }
    return parents.map { parent in
        var canonicalParent = parent
        canonicalParent.author = aliases.canonicalize(parent.author)
        let directReplies = comments
            .filter { $0.parentId == parent.id }
            .map { reply -> Comment in
                var copy = reply
                copy.author = aliases.canonicalize(reply.author)
                return copy
            }
        return CommentThread(parent: canonicalParent, replies: directReplies, resolved: parent.done)
    }
}

/// Detect the informal `Old: <prior wording>\n<new wording>` reply convention used
/// during academic peer review (per design.md `Old:` pattern).
///
/// Returns `(quoted, newWording)` if the pattern matches at the start of `text`,
/// `nil` otherwise.
public func detectOldPattern(in text: String) -> (quoted: String, newWording: String)? {
    let pattern = #"^Old:\s*(?<quoted>.+?)\n+(?<new>.+)$"#
    guard
        let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
    else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
    guard
        let quotedRange = Range(match.range(withName: "quoted"), in: text),
        let newRange = Range(match.range(withName: "new"), in: text)
    else { return nil }
    return (
        quoted: String(text[quotedRange]).trimmingCharacters(in: .whitespacesAndNewlines),
        newWording: String(text[newRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    )
}

public func formatCommentThreadsMarkdown(
    threads: [CommentThread],
    format: CommentThreadFormat = .table,
    includeResolved: Bool = true,
    detectOldPatternFlag: Bool = false,
    summarize: Bool = false
) -> String {
    let visibleThreads = includeResolved ? threads : threads.filter { !$0.resolved }
    var md = MarkdownBuilder().heading(level: 1, text: "Comment Threads")

    if visibleThreads.isEmpty {
        return md.paragraph("No comment threads in document.").build()
    }

    switch format {
    case .table:
        let rows = visibleThreads.enumerated().map { (i, thread) -> [String] in
            let excerpt = applySummarize(thread.parent.text, summarize: summarize)
            let repliesSummary = thread.replies.map { reply -> String in
                let replyExcerpt = applySummarize(reply.text, summarize: summarize)
                if detectOldPatternFlag, let pattern = detectOldPattern(in: reply.text) {
                    return "\(reply.author): [Old: \(applySummarize(pattern.quoted, summarize: summarize))] -> \(applySummarize(pattern.newWording, summarize: summarize))"
                }
                return "\(reply.author): \(replyExcerpt)"
            }.joined(separator: " | ")
            return [
                String(i + 1),
                String(thread.parent.paragraphIndex),
                thread.parent.author,
                excerpt,
                String(thread.replies.count),
                repliesSummary,
                thread.resolved ? "yes" : "no",
            ]
        }
        md = md.table(
            headers: ["#", "Para", "Parent author", "Parent excerpt", "Replies", "Reply summary", "Resolved"],
            rows: rows
        )
    case .threaded:
        for (i, thread) in visibleThreads.enumerated() {
            let excerpt = applySummarize(thread.parent.text, summarize: summarize)
            md = md.heading(level: 2, text: "Thread #\(i + 1) — \(thread.parent.author) @ para \(thread.parent.paragraphIndex)\(thread.resolved ? " (resolved)" : "")")
            let parentItems = ["Parent (\(thread.parent.author)): \(excerpt)"]
            let replyItems = thread.replies.map { reply -> String in
                let replyExcerpt = applySummarize(reply.text, summarize: summarize)
                if detectOldPatternFlag, let pattern = detectOldPattern(in: reply.text) {
                    return "  Reply (\(reply.author)) [Old: \(applySummarize(pattern.quoted, summarize: summarize))] -> \(applySummarize(pattern.newWording, summarize: summarize))"
                }
                return "  Reply (\(reply.author)): \(replyExcerpt)"
            }
            md = md.bulletList(parentItems + replyItems)
        }
    case .narrative:
        for (i, thread) in visibleThreads.enumerated() {
            let excerpt = applySummarize(thread.parent.text, summarize: summarize)
            var paragraph = "Thread #\(i + 1) (paragraph \(thread.parent.paragraphIndex)): "
            paragraph += "\(thread.parent.author) wrote: \"\(excerpt)\". "
            if thread.replies.isEmpty {
                paragraph += "No replies."
            } else {
                paragraph += "\(thread.replies.count) repl\(thread.replies.count == 1 ? "y" : "ies"): "
                let parts = thread.replies.map { reply -> String in
                    let replyExcerpt = applySummarize(reply.text, summarize: summarize)
                    if detectOldPatternFlag, let pattern = detectOldPattern(in: reply.text) {
                        return "\(reply.author) replied [Old: \(applySummarize(pattern.quoted, summarize: summarize))] with \"\(applySummarize(pattern.newWording, summarize: summarize))\""
                    }
                    return "\(reply.author) replied \"\(replyExcerpt)\""
                }
                paragraph += parts.joined(separator: "; ")
                paragraph += "."
            }
            paragraph += thread.resolved ? " (Thread resolved.)" : " (Thread open.)"
            md = md.paragraph(paragraph)
        }
    }

    return md.build()
}
