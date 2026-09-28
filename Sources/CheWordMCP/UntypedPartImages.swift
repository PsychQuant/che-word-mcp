import Foundation
import MCP
import OOXMLSwift

extension WordMCPServer {
    /// #219 — bytes suitable for enumerating package parts the typed model
    /// does not manage at all (charts). Direct Mode (`source_path` given)
    /// reads the source file verbatim — already correct, no serialization
    /// involved. Session Mode (`doc_id` only) MUST go through the same
    /// overlay-aware `DocxWriter.write(_:to:)` entry point the save gate
    /// uses (`persistableBytes(for:)`) rather than `DocxWriter.writeData
    /// (doc)` (always scratch mode): #220 found scratch mode silently drops
    /// parts the typed model doesn't manage when a document was opened from
    /// an existing file — exactly the class of part (charts) this function
    /// exists to read.
    func packageBytesForPartEnumeration(doc: WordDocument, args: [String: Value]) -> Data? {
        if let sourcePath = args["source_path"]?.stringValue {
            return FileManager.default.contents(atPath: sourcePath)
        }
        return try? Self.persistableBytes(for: doc)
    }
}

/// #219 — images living in parts `ooxml-swift`'s typed model does not parse
/// at all: chart parts (`word/charts/chartN.xml` + their own
/// `_rels/chartN.xml.rels`). Header/footer image *relationships* ARE typed
/// (`HeaderFooter.relationships.imageRelationships`, already used by
/// `collectImageRows` since 4.7.0) but their *bytes* are not — only
/// `document.images` (the document part) carries `ImageReference.data` in
/// memory. Both gaps need the raw package bytes, which this file reads
/// directly from an already-unzipped archive rather than teaching
/// `ooxml-swift` a new part type — the same "read the bytes directly, don't
/// grow the typed model for one reader" choice `PackageInspector` itself
/// documents making for the exact same class of part.
///
/// **Security (path traversal, found in post-commit review of the first
/// version of this file)**: a relationship's `Target` is attacker-controlled
/// — it comes from inside a `.docx` someone else authored. The first version
/// of this file did `baseDir.appendingPathComponent(rel.target)
/// .standardizedFileURL` with no check that the result stayed inside the
/// unzipped package: a header/footer/chart rels entry with
/// `Target="../../../../etc/hosts"` (or an absolute filesystem path, or a
/// `TargetMode="External"` URL) would resolve to, and then actually be
/// read from, a real path on the machine running this server — a local
/// file disclosure via `export_all_images`/`export_image`/`list_images`.
/// `resolvePackageRelativeTarget` below is the fix: every candidate path is
/// required to still be inside the unzipped package root after resolving
/// BOTH lexical `..` (`standardizedFileURL`) AND real symlinks
/// (`resolvingSymlinksInPath`, which also catches an in-archive symlink
/// that itself points outside) — a candidate that fails this check is
/// refused, not silently dropped: it comes back as a `RefusedEntry` so
/// callers can say so instead of pretending the relationship never existed.
enum UntypedPartImages {

    /// One image relationship this reader found outside `document.images`,
    /// resolved to its actual media file inside an unzipped package.
    struct Entry {
        /// Part-qualified, matching the `part:` column `list_images` /
        /// `collectImageRows` already emit for header/footer rows (e.g.
        /// `"word/charts/chart1.xml"`, `"word/header1.xml"`).
        let part: String
        let id: String
        /// Absolute path inside the unzipped package, already verified by
        /// `resolvePackageRelativeTarget` to be contained in the package
        /// root. The file may still not physically exist (a dangling
        /// relationship) — callers read it with `FileManager
        /// .contents(atPath:)` and get `nil`, same as any other
        /// missing-file case.
        let mediaURL: URL
        var fileName: String { mediaURL.lastPathComponent }
    }

    /// An image relationship whose `Target` was refused rather than
    /// resolved: either it declared `TargetMode="External"` (not a package
    /// member at all), or resolving it would have left the unzipped
    /// package root. Never silently dropped — surfaced so a caller can
    /// name it.
    struct RefusedEntry {
        let part: String
        let id: String
        let target: String
        let reason: String
    }

    /// Header/footer/chart image relationships, resolved against `tempDir`
    /// (the root of an already-unzipped `.docx` package — same shape
    /// `ZipHelper.unzip(data:)` returns).
    ///
    /// Header/footer relationship targets are read from the TYPED model
    /// (`doc.headers` / `doc.footers`) — that part of the model is already
    /// correct and tested (#199/#219 4.7.0). Chart relationships are read
    /// directly off disk because nothing in the typed model represents
    /// charts at all.
    static func entries(doc: WordDocument, tempDir: URL) -> (entries: [Entry], refused: [RefusedEntry]) {
        var entries: [Entry] = []
        var refused: [RefusedEntry] = []
        let packageRoot = tempDir
        let wordDir = tempDir.appendingPathComponent("word")

        func consider(part: String, id: String, target: String, targetMode: String?, baseDir: URL) {
            guard targetMode != "External" else {
                refused.append(RefusedEntry(part: part, id: id, target: target, reason: "TargetMode=\"External\" — not a package member"))
                return
            }
            guard let resolved = resolvePackageRelativeTarget(target, baseDir: baseDir, packageRoot: packageRoot) else {
                refused.append(RefusedEntry(part: part, id: id, target: target, reason: "Target resolves outside the package"))
                return
            }
            entries.append(Entry(part: part, id: id, mediaURL: resolved))
        }

        for header in doc.headers {
            let part = "word/\(header.fileName)"
            for rel in header.relationships.imageRelationships {
                consider(part: part, id: rel.id, target: rel.target, targetMode: rel.targetMode, baseDir: wordDir)
            }
        }
        for footer in doc.footers {
            let part = "word/\(footer.fileName)"
            for rel in footer.relationships.imageRelationships {
                consider(part: part, id: rel.id, target: rel.target, targetMode: rel.targetMode, baseDir: wordDir)
            }
        }

        let chartsDir = wordDir.appendingPathComponent("charts")
        if let chartFiles = try? FileManager.default.contentsOfDirectory(atPath: chartsDir.path) {
            for chartFile in chartFiles.sorted() where chartFile.hasSuffix(".xml") {
                let relsPath = chartsDir.appendingPathComponent("_rels").appendingPathComponent("\(chartFile).rels")
                guard let relsData = FileManager.default.contents(atPath: relsPath.path) else { continue }
                let part = "word/charts/\(chartFile)"
                for rel in imageRelationships(fromRelsData: relsData) {
                    consider(part: part, id: rel.id, target: rel.target, targetMode: rel.targetMode, baseDir: chartsDir)
                }
            }
        }
        return (entries, refused)
    }

    /// Just the chart subset of `entries(doc:tempDir:)`, as `list_images`
    /// row tuples plus its own refused subset — header/footer rows already
    /// come from `collectImageRows` (the typed-model path), so this does
    /// not duplicate those.
    static func chartImageRows(
        doc: WordDocument, tempDir: URL
    ) -> (rows: [(part: String, id: String, fileName: String, widthPx: Int?, heightPx: Int?)], refused: [RefusedEntry]) {
        let (all, refused) = entries(doc: doc, tempDir: tempDir)
        let rows: [(part: String, id: String, fileName: String, widthPx: Int?, heightPx: Int?)] = all
            .filter { $0.part.hasPrefix("word/charts/") }
            .map { (part: $0.part, id: $0.id, fileName: $0.fileName, widthPx: nil, heightPx: nil) }
        return (rows, refused.filter { $0.part.hasPrefix("word/charts/") })
    }

    /// Resolves a relationship `Target` against `baseDir` (the directory
    /// containing the part that declared it — `word/` for headers/footers,
    /// `word/charts/` for charts), honoring OPC's own path rule for
    /// absolute targets, and refuses — returns `nil` — under any
    /// interpretation that would leave `packageRoot` (the unzipped archive
    /// root).
    ///
    /// - A `Target` beginning with `/` is package-root-relative per OPC
    ///   (ECMA-376 Part 2 §9.2 — an "absolute" part reference is relative to
    ///   the PACKAGE root, never the filesystem root), so it resolves
    ///   against `packageRoot`, not `baseDir`.
    /// - Everything else (the common case: `"media/image1.png"`,
    ///   `"../media/image1.png"`) resolves against `baseDir`.
    /// - Either way, the candidate is standardized (collapses lexical `..`)
    ///   AND has its symlinks resolved (catches an in-archive symlink that
    ///   itself points outside the package) before the containment check —
    ///   a candidate whose resolved path is not `packageRoot` itself or
    ///   under it is refused.
    static func resolvePackageRelativeTarget(_ target: String, baseDir: URL, packageRoot: URL) -> URL? {
        guard !target.isEmpty else { return nil }

        let candidate: URL
        if target.hasPrefix("/") {
            candidate = packageRoot.appendingPathComponent(String(target.dropFirst()))
        } else {
            candidate = baseDir.appendingPathComponent(target)
        }

        let resolvedRoot = packageRoot.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedCandidate = candidate.standardizedFileURL.resolvingSymlinksInPath()

        let rootPath = resolvedRoot.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard resolvedCandidate.path == rootPath || resolvedCandidate.path.hasPrefix(rootPrefix) else {
            return nil
        }
        return resolvedCandidate
    }

    /// `<Relationship Id="..." Type="...(/relationships/)image" Target="..."
    /// TargetMode="..."/>` entries from a `.rels` part, attribute-order-
    /// independent (via `XMLParser`, not a hand-rolled regex — rels files
    /// are small and this runs at most a few times per call). `targetMode`
    /// is `nil` when the attribute is absent (the overwhelmingly common
    /// case — internal package relationships don't declare it).
    static func imageRelationships(fromRelsData data: Data) -> [(id: String, target: String, targetMode: String?)] {
        let delegate = RelationshipImageDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.found
    }

    private final class RelationshipImageDelegate: NSObject, XMLParserDelegate {
        var found: [(id: String, target: String, targetMode: String?)] = []
        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
        ) {
            guard elementName == "Relationship",
                  let type = attributeDict["Type"], type.hasSuffix("/image"),
                  let id = attributeDict["Id"], let target = attributeDict["Target"]
            else { return }
            found.append((id: id, target: target, targetMode: attributeDict["TargetMode"]))
        }
    }
}
