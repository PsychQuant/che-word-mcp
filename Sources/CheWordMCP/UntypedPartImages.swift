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
enum UntypedPartImages {

    /// One image relationship this reader found outside `document.images`,
    /// resolved to its actual media file inside an unzipped package.
    struct Entry {
        /// Part-qualified, matching the `part:` column `list_images` /
        /// `collectImageRows` already emit for header/footer rows (e.g.
        /// `"word/charts/chart1.xml"`, `"word/header1.xml"`).
        let part: String
        let id: String
        /// Absolute path inside the unzipped package. The file may not
        /// actually exist (a dangling relationship) — callers read it with
        /// `FileManager.contents(atPath:)` and get `nil`, same as any other
        /// missing-file case; this type does not pre-check existence so it
        /// never silently drops a row a caller might want to know about.
        let mediaURL: URL
        var fileName: String { mediaURL.lastPathComponent }
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
    static func entries(doc: WordDocument, tempDir: URL) -> [Entry] {
        var entries: [Entry] = []
        let wordDir = tempDir.appendingPathComponent("word")

        for header in doc.headers {
            for rel in header.relationships.imageRelationships {
                entries.append(Entry(
                    part: "word/\(header.fileName)", id: rel.id,
                    mediaURL: wordDir.appendingPathComponent(rel.target).standardizedFileURL))
            }
        }
        for footer in doc.footers {
            for rel in footer.relationships.imageRelationships {
                entries.append(Entry(
                    part: "word/\(footer.fileName)", id: rel.id,
                    mediaURL: wordDir.appendingPathComponent(rel.target).standardizedFileURL))
            }
        }

        let chartsDir = wordDir.appendingPathComponent("charts")
        if let chartFiles = try? FileManager.default.contentsOfDirectory(atPath: chartsDir.path) {
            for chartFile in chartFiles.sorted() where chartFile.hasSuffix(".xml") {
                let relsPath = chartsDir.appendingPathComponent("_rels").appendingPathComponent("\(chartFile).rels")
                guard let relsData = FileManager.default.contents(atPath: relsPath.path) else { continue }
                for rel in imageRelationships(fromRelsData: relsData) {
                    entries.append(Entry(
                        part: "word/charts/\(chartFile)", id: rel.id,
                        mediaURL: chartsDir.appendingPathComponent(rel.target).standardizedFileURL))
                }
            }
        }
        return entries
    }

    /// Just the chart subset of `entries(doc:tempDir:)`, as `list_images`
    /// row tuples — header/footer rows already come from `collectImageRows`
    /// (the typed-model path), so this does not duplicate those.
    static func chartImageRows(doc: WordDocument, tempDir: URL) -> [(part: String, id: String, fileName: String, widthPx: Int?, heightPx: Int?)] {
        entries(doc: doc, tempDir: tempDir)
            .filter { $0.part.hasPrefix("word/charts/") }
            .map { (part: $0.part, id: $0.id, fileName: $0.fileName, widthPx: nil, heightPx: nil) }
    }

    /// `<Relationship Id="..." Type="...(/relationships/)image" Target="..."/>`
    /// entries from a `.rels` part, attribute-order-independent (via
    /// `XMLParser`, not a hand-rolled regex — rels files are small and this
    /// runs at most a few times per call).
    static func imageRelationships(fromRelsData data: Data) -> [(id: String, target: String)] {
        let delegate = RelationshipImageDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.found
    }

    private final class RelationshipImageDelegate: NSObject, XMLParserDelegate {
        var found: [(id: String, target: String)] = []
        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
        ) {
            guard elementName == "Relationship",
                  let type = attributeDict["Type"], type.hasSuffix("/image"),
                  let id = attributeDict["Id"], let target = attributeDict["Target"]
            else { return }
            found.append((id: id, target: target))
        }
    }
}
