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
///
/// **R2 — relationship to ooxml-swift 3.18.1's own containment gate**: the
/// SAME vulnerability class also existed one layer down, in
/// `DocxReader.extractImages` (the document-part image loader) — reported
/// by the same review round as CRITICAL, fixed upstream by bumping this
/// repo's `ooxml-swift` pin to 3.18.1, which added
/// `resolveContainedOOXMLTarget` (`Sources/OOXMLSwift/IO/PathValidator.swift`).
/// That function is `internal` to the `OOXMLSwift` module — not `public` —
/// so it cannot be called from here, and per this round's own instructions
/// this file's own `resolvePackageRelativeTarget` is kept rather than
/// deleted. The two are NOT drop-in equivalents even setting access level
/// aside:
/// - **Percent-encoding.** ooxml-swift's version resolves Targets through
///   `ProfileXML.normalizedRelationshipTarget`, which — per RFC 3986
///   §6.2.2.2 — decodes ONLY unreserved-character escapes (`%2E` → `.`,
///   since `.` is unreserved) and leaves reserved-character escapes
///   (`%2F`, `%5C`) encoded. A `%2e%2e%2f`-shaped Target therefore still
///   cannot escape there EITHER (decoding `%2e%2e` to `..` while `%2f`
///   stays literal text means the `..` never lines up with a real `/` to
///   pop a segment against), but it also is not distinguished from an
///   ordinary nonexistent file. This file's `resolvePackageRelativeTarget`
///   instead does a blanket substring refuse (see
///   `containsSuspiciousPercentEncoding`) — simpler than replicating the
///   selective-decode algorithm, and it lets `RefusedEntry` name the
///   refusal instead of the caller only ever seeing "not found".
/// - **Reason reporting.** `resolveContainedOOXMLTarget` returns a bare
///   `URL?` — sufficient for `DocxReader`, which only needs to decide
///   whether to add an `ImageReference`, not to explain itself to a human.
///   This file's callers (`list_images`/`export_all_images`/`export_image`)
///   need to NAME a refusal per #219's own requirement, so
///   `resolvePackageRelativeTarget` is paired with a separate
///   `diagnoseRefusal` for that presentation-only purpose.
/// - **Consumers.** ooxml-swift 3.18.1's fix covers exactly one reader
///   (document-part images, at parse time). This file covers three this
///   repo owns and the library fix does not touch at all: header/footer
///   image relationships, chart image relationships (untyped in
///   `ooxml-swift` altogether), and the DELETE-side consumer
///   (`cleanupOrphanedWatermarkMedia`, in `Server.swift`).
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
                refused.append(RefusedEntry(
                    part: part, id: id, target: target,
                    reason: diagnoseRefusal(target, baseDir: baseDir, packageRoot: packageRoot)))
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
        // R2 (independent review LOW-1): a percent-encoded traversal
        // sequence (`%2e%2e%2f...`) contains no LITERAL `/`, so the whole
        // string is one opaque path segment to `appendingPathComponent` —
        // it cannot escape the package (there is nothing for the encoded
        // ".."/".."-adjacent "/" to lexically pop), but it also almost
        // never names a real file, so it silently vanished as an ordinary
        // "doesn't exist" case with no way to tell it apart from a
        // genuinely absent media file. Refused up front, by the same
        // blanket substring check `isSafeRelativeOOXMLPath` (ooxml-swift)
        // already uses for header/footer filenames — chosen over
        // replicating that function's fuller RFC 3986 selective-decode
        // algorithm (unreserved-only) because this call site's job is to
        // NAME the refusal for `RefusedEntry`, not to recover a
        // legitimately-encoded filename.
        guard !containsSuspiciousPercentEncoding(target) else { return nil }

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

        // R2 (independent review LOW-2): a Target that resolves to an
        // EXISTING directory is contained (no traversal), so it used to be
        // accepted and listed as an ordinary image row — `list_images`
        // then showed something nobody could ever export
        // (`FileManager.contents(atPath:)` on a directory is `nil`,
        // `export_all_images` silently skipped it). Refused here instead,
        // same as ooxml-swift 3.18.1's `resolveContainedOOXMLTarget` does
        // for the document-part path. Deliberately does NOT reject a path
        // that simply does not exist yet — a dangling relationship (Target
        // names a file the package never included) is a pre-existing,
        // separately-handled case (see `Entry`'s doc comment) and must
        // keep resolving to a URL so callers treat it the same way they
        // always have, not as a NEW security refusal.
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolvedCandidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return nil
        }
        return resolvedCandidate
    }

    /// Case-insensitive substring check for the percent-encoded forms of
    /// `..`, `/`, and `\` — mirrors `isSafeRelativeOOXMLPath`
    /// (ooxml-swift)'s own check, reproduced here rather than called
    /// because that function is `public` but validates a DIFFERENT thing
    /// (a bare relative filename with no legitimate `..`, used for header/
    /// footer `originalFileName`) — this call site's Targets legitimately
    /// contain literal `..` (`../media/image1.png` from a chart), so the
    /// blanket-reject-every-`..` policy that function encodes would refuse
    /// ordinary, safe chart images.
    private static func containsSuspiciousPercentEncoding(_ target: String) -> Bool {
        let lowercased = target.lowercased()
        return lowercased.contains("%2e%2e") || lowercased.contains("%2f") || lowercased.contains("%5c")
    }

    /// Best-effort explanation of WHY `resolvePackageRelativeTarget`
    /// refused a Target, for `RefusedEntry.reason`. Presentation only —
    /// re-derives the same candidate the gate above already computed
    /// (accepting the small duplication) rather than having the gate
    /// return a reason itself, so the actual security decision in
    /// `resolvePackageRelativeTarget` stays a single, simple `URL?` with no
    /// pressure to keep a reason string in sync with it. Only ever called
    /// after that function has already returned `nil`.
    private static func diagnoseRefusal(_ target: String, baseDir: URL, packageRoot: URL) -> String {
        if containsSuspiciousPercentEncoding(target) {
            return "Target contains a percent-encoded \"..\"/\"/\"/\"\\\" sequence (%2e/%2f/%5c) — refused without decoding"
        }

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
            return "Target resolves outside the package"
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolvedCandidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return "Target resolves to a directory, not a file"
        }
        return "Target could not be safely resolved"
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
