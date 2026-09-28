import XCTest
import MCP
import ZIPFoundation
@testable import CheWordMCP

/// A malicious .docx whose image relationship `Target` climbs out of the
/// package (`../../…/sentinel`) used to make `open_document` read that file
/// into memory, and `export_all_images` then wrote it into the caller's output
/// directory. Fixed in ooxml-swift 3.18.1 (targets must resolve inside the
/// package). This drives the real tool path so a dependency downgrade or a new
/// read path that bypasses the containment check fails here.
final class ImageTargetTraversalRegressionTests: XCTestCase {

    private var scratch: URL!
    private let sentinelText = "SENTINEL-OUTSIDE-THE-PACKAGE"

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-target-traversal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testExportAllImagesNeverWritesAFileFromOutsideThePackage() async throws {
        let sentinel = scratch.appendingPathComponent("sentinel.txt")
        try Data(sentinelText.utf8).write(to: sentinel)
        // Enough `../` to reach the filesystem root from any extraction
        // directory, then back down to the sentinel.
        let escapingTarget = String(repeating: "../", count: 30)
            + sentinel.standardizedFileURL.path.dropFirst()
        let source = scratch.appendingPathComponent("evil.docx")
        try Self.writePackage(escapingTarget: escapingTarget, to: source)

        let server = await WordMCPServer()
        let docId = "traversal-\(UUID().uuidString)"
        let opened = await server.invokeToolForTesting(name: "open_document", arguments: [
            "doc_id": .string(docId), "path": .string(source.path),
        ])
        XCTAssertNotEqual(opened.isError, true, text(of: opened))

        let outputDir = scratch.appendingPathComponent("exported")
        let exported = await server.invokeToolForTesting(name: "export_all_images", arguments: [
            "doc_id": .string(docId), "output_dir": .string(outputDir.path),
        ])
        XCTAssertNotEqual(exported.isError, true, text(of: exported))
        _ = await server.invokeToolForTesting(name: "close_document", arguments: [
            "doc_id": .string(docId),
        ])

        let files = (try? FileManager.default.contentsOfDirectory(atPath: outputDir.path)) ?? []
        XCTAssertEqual(files, ["image1.png"], "only the in-package image may be exported: \(files)")
        for name in files {
            let bytes = try Data(contentsOf: outputDir.appendingPathComponent(name))
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(sentinelText),
                           "\(name) carries the content of a file outside the package")
        }
    }

    // MARK: - Helpers

    private func text(of result: CallTool.Result) -> String {
        guard case .text(let value, _, _)? = result.content.first else { return "" }
        return value
    }

    private static func writePackage(escapingTarget: String, to destination: URL) throws {
        let ns = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture""#
        func drawing(_ rid: String, _ id: Int) -> String {
            #"<w:r><w:drawing><wp:inline><wp:extent cx="9525" cy="9525"/><wp:docPr id="\#(id)" name="p\#(id)"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="\#(id)" name="p\#(id)"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="\#(rid)"/></pic:blipFill><pic:spPr/></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>"#
        }
        let parts: [(String, Data)] = [
            ("[Content_Types].xml", Data(#"<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Default Extension="txt" ContentType="image/png"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>"#.utf8)),
            ("_rels/.rels", Data(#"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>"#.utf8)),
            ("word/_rels/document.xml.rels", Data(#"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rIdOk" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image1.png"/><Relationship Id="rIdEvil" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="\#(escapingTarget)"/></Relationships>"#.utf8)),
            ("word/document.xml", Data(#"<?xml version="1.0" encoding="UTF-8"?><w:document \#(ns)><w:body><w:p>\#(drawing("rIdOk", 1))\#(drawing("rIdEvil", 2))</w:p><w:sectPr/></w:body></w:document>"#.utf8)),
            ("word/media/image1.png", onePixelPNG),
        ]
        let archive = try Archive(url: destination, accessMode: .create)
        for (path, data) in parts {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                                 compressionMethod: .deflate) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
    }

    private static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
}
