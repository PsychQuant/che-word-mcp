import XCTest
import MCP
import OOXMLSwift
import CoreGraphics
import ImageIO
@testable import CheWordMCP

/// R9 — responses to the independent R8 review (`rev232c`) of #232/#234.
/// Each test pins one finding; every one of them was run RED against
/// 0cd5651 before the fix (see the R9 section of the implementation report).
final class Issue234R9ReviewTests: XCTestCase {

    private func resultText(_ result: CallTool.Result) -> String {
        guard let first = result.content.first else { return "" }
        if case .text(let text, _, _) = first { return text }
        return ""
    }

    private func newDocument(_ server: WordMCPServer, id: String) async throws {
        let create = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string(id)])
        XCTAssertNotEqual(create.isError, true, resultText(create))
        let para = await server.invokeToolForTesting(
            name: "insert_paragraph", arguments: ["doc_id": .string(id), "text": .string("Anchor")]
        )
        XCTAssertNotEqual(para.isError, true, resultText(para))
    }

    private func savedDocumentXML(_ server: WordMCPServer, docId: String) async throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("r9-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("out.docx").path
        let save = await server.invokeToolForTesting(name: "save_document", arguments: ["doc_id": .string(docId), "path": .string(path)])
        XCTAssertNotEqual(save.isError, true, resultText(save))
        let unzipped = try ZipHelper.unzip(URL(fileURLWithPath: path))
        defer { ZipHelper.cleanup(unzipped) }
        return try String(contentsOf: unzipped.appendingPathComponent("word/document.xml"), encoding: .utf8)
    }

    private func tempPNGPath(width: Int, height: Int) throws -> String {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let image = { () -> CGImage? in
                ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
                return ctx.makeImage()
            }()
        else { throw XCTSkip("CGContext unavailable") }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else {
            throw XCTSkip("PNG encoder unavailable")
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("r9-\(UUID().uuidString).png")
        try (out as Data).write(to: url)
        return url.path
    }

    private var floatingFixturePath: String?
    /// A real 1×1 PNG for `insert_floating_image` (which reads the file's bytes).
    private func floatingImageFixture() throws -> String {
        if let p = floatingFixturePath { return p }
        let p = try tempPNGPath(width: 1, height: 1)
        floatingFixturePath = p
        return p
    }

    override func tearDown() {
        if let p = floatingFixturePath { try? FileManager.default.removeItem(atPath: p) }
        floatingFixturePath = nil
        super.tearDown()
    }

    // MARK: - H-1: the table budget is a total CELL count, not two independent axis bounds

    /// 65,536 rows × 63 columns measured 9.0 GB resident (14.2 GB peak on
    /// save, 33 s) in release — "one parameter takes the host down" by
    /// memory, the exact failure the R8 bound claimed to prevent.
    func testInsertTableRejectsCellCountAboveBudget() async throws {
        let server = await WordMCPServer()
        let id = "r9-table-cells"
        try await newDocument(server, id: id)
        for (rows, cols) in [(2_000, 63), (65_536, 2), (65_536, 63)] {
            let result = await server.invokeToolForTesting(
                name: "insert_table", arguments: ["doc_id": .string(id), "rows": .int(rows), "cols": .int(cols)]
            )
            XCTAssertEqual(result.isError, true, "\(rows)×\(cols): \(resultText(result))")
            XCTAssertTrue(resultText(result).contains("\(WordMCPServer.tableCellCountLimit)"), "\(rows)×\(cols): \(resultText(result))")
        }
        let ok = await server.invokeToolForTesting(
            name: "insert_table", arguments: ["doc_id": .string(id), "rows": .int(1_040), "cols": .int(63)]
        )
        XCTAssertNotEqual(ok.isError, true, "1040×63 = 65,520 cells is within budget: \(resultText(ok))")
    }

    /// The R8 mutation run showed removing `insert_nested_table`'s `cols`
    /// guard SURVIVED — nothing exercised it. Pin it, plus the cell budget.
    func testInsertNestedTableRejectsBadColsAndCellCount() async throws {
        let server = await WordMCPServer()
        let id = "r9-nested"
        try await newDocument(server, id: id)
        let parent = await server.invokeToolForTesting(
            name: "insert_table", arguments: ["doc_id": .string(id), "rows": .int(2), "cols": .int(2)]
        )
        XCTAssertNotEqual(parent.isError, true, resultText(parent))
        func nested(_ rows: Int, _ cols: Int) async -> CallTool.Result {
            await server.invokeToolForTesting(name: "insert_nested_table", arguments: [
                "doc_id": .string(id), "parent_table_index": .int(0), "row_index": .int(0), "col_index": .int(0),
                "rows": .int(rows), "cols": .int(cols),
            ])
        }
        for badCols in [-1, 0, 64] {
            let r = await nested(1, badCols)
            XCTAssertEqual(r.isError, true, "cols=\(badCols): \(resultText(r))")
            XCTAssertTrue(resultText(r).contains("cols"), "cols=\(badCols): \(resultText(r))")
        }
        let tooMany = await nested(2_000, 63)
        XCTAssertEqual(tooMany.isError, true, resultText(tooMany))
        XCTAssertTrue(resultText(tooMany).contains("\(WordMCPServer.tableCellCountLimit)"), resultText(tooMany))
    }

    // MARK: - M-2: the new string alignment parameters are strictly typed

    func testFloatingImageAlignRejectsNonStringValues() async throws {
        let server = await WordMCPServer()
        let id = "r9-align-type"
        try await newDocument(server, id: id)
        let cases: [(String, Value)] = [
            ("horizontal_align", .int(5)), ("horizontal_align", .bool(true)),
            ("vertical_align", .array([.string("top")])), ("vertical_align", .object(["a": .int(1)])),
        ]
        for (key, value) in cases {
            let result = await server.invokeToolForTesting(name: "insert_floating_image", arguments: [
                "doc_id": .string(id), "path": .string(try floatingImageFixture()), key: value,
            ])
            XCTAssertEqual(result.isError, true, "\(key)=\(value): \(resultText(result))")
            XCTAssertTrue(resultText(result).contains(key), "\(key)=\(value): \(resultText(result))")
        }
        // An integer offset plus a mistyped align must not slip past the
        // conflict check by the align being silently dropped.
        let both = await server.invokeToolForTesting(name: "insert_floating_image", arguments: [
            "doc_id": .string(id), "path": .string(try floatingImageFixture()),
            "horizontal_position": .int(5), "horizontal_align": .int(5),
        ])
        XCTAssertEqual(both.isError, true, resultText(both))
    }

    // MARK: - LOW-4 / LOW-6: position offsets

    /// A v4.3.x caller following the old schema sends `"center"` to
    /// `horizontal_position`; the error must point at `horizontal_align`.
    func testFloatingImagePositionStringPointsAtAlignParameter() async throws {
        let server = await WordMCPServer()
        let id = "r9-pos-hint"
        try await newDocument(server, id: id)
        for (posKey, alignKey) in [("horizontal_position", "horizontal_align"), ("vertical_position", "vertical_align")] {
            let result = await server.invokeToolForTesting(name: "insert_floating_image", arguments: [
                "doc_id": .string(id), "path": .string(try floatingImageFixture()), posKey: .string("center"),
            ])
            XCTAssertEqual(result.isError, true, resultText(result))
            XCTAssertTrue(resultText(result).contains(posKey), resultText(result))
            XCTAssertTrue(resultText(result).contains(alignKey), resultText(result))
        }
    }

    /// `wp:posOffset` is `ST_PositionOffset` = `xsd:int`.
    func testFloatingImagePositionOffsetOutsideInt32IsRejected() async throws {
        let server = await WordMCPServer()
        let id = "r9-pos-int32"
        try await newDocument(server, id: id)
        for bad in [40_000_000_000_000_000, Int(Int32.max) + 1, Int(Int32.min) - 1] {
            let result = await server.invokeToolForTesting(name: "insert_floating_image", arguments: [
                "doc_id": .string(id), "path": .string(try floatingImageFixture()), "vertical_position": .int(bad),
            ])
            XCTAssertEqual(result.isError, true, "\(bad): \(resultText(result))")
            XCTAssertTrue(resultText(result).contains("vertical_position"), "\(bad): \(resultText(result))")
        }
        let edge = await server.invokeToolForTesting(name: "insert_floating_image", arguments: [
            "doc_id": .string(id), "path": .string(try floatingImageFixture()), "vertical_position": .int(Int(Int32.min)),
        ])
        XCTAssertNotEqual(edge.isError, true, resultText(edge))
    }

    /// Values below 1/480 used to round (or truncate) to `w:line="0"`.
    func testLineSpacingThatWouldWriteZeroIsRejected() async throws {
        XCTAssertThrowsError(try WordMCPServer.twipsLine(fromLineSpacingMultiplier: 0.002))
        XCTAssertThrowsError(try WordMCPServer.twipsLine(fromLineSpacingMultiplier: 1e-10))
        XCTAssertEqual(try WordMCPServer.twipsLine(fromLineSpacingMultiplier: 1.0 / 240), 1)
    }

    // MARK: - M-3 / LOW-2: insert_text position

    func testInsertTextRejectsNegativePosition() async throws {
        let server = await WordMCPServer()
        let id = "r9-inserttext-neg"
        try await newDocument(server, id: id)
        for bad in [-1, Int.min] {
            let result = await server.invokeToolForTesting(name: "insert_text", arguments: [
                "doc_id": .string(id), "paragraph_index": .int(0), "text": .string("X"), "position": .int(bad),
            ])
            XCTAssertEqual(result.isError, true, "\(bad): \(resultText(result))")
            XCTAssertTrue(resultText(result).contains("position"), "\(bad): \(resultText(result))")
        }
    }

    /// A position past the end still lands at the end (documented default),
    /// and the reply reports where the text actually went.
    func testInsertTextReportsActualPositionWhenClampedToEnd() async throws {
        let server = await WordMCPServer()
        let id = "r9-inserttext-end"
        try await newDocument(server, id: id)   // paragraph 0 = "Anchor" (6 characters)
        let result = await server.invokeToolForTesting(name: "insert_text", arguments: [
            "doc_id": .string(id), "paragraph_index": .int(0), "text": .string("X"), "position": .int(1_000),
        ])
        XCTAssertNotEqual(result.isError, true, resultText(result))
        XCTAssertTrue(resultText(result).contains("position 6"), resultText(result))
        XCTAssertFalse(resultText(result).contains("position 1000"), resultText(result))
        let xml = try await savedDocumentXML(server, docId: id)
        XCTAssertTrue(xml.contains("AnchorX"), xml)
    }

    // MARK: - M-4: aspect-derived image dimension rounds, and never blames the absent parameter

    func testImageFromPathAspectDerivedDimensionRounds() async throws {
        let server = await WordMCPServer()
        let id = "r9-aspect"
        try await newDocument(server, id: id)
        // 1×49 image, height 49 (its native size): 49 × (1/49) = 0.9999999999999999.
        let tall = try tempPNGPath(width: 1, height: 49)
        defer { try? FileManager.default.removeItem(atPath: tall) }
        let native = await server.invokeToolForTesting(name: "insert_image_from_path", arguments: [
            "doc_id": .string(id), "path": .string(tall), "height": .int(49),
        ])
        XCTAssertNotEqual(native.isError, true, resultText(native))
        // 3×17 image, width 21: 21 / (3/17) = 118.99999999999999 → 119.
        let odd = try tempPNGPath(width: 3, height: 17)
        defer { try? FileManager.default.removeItem(atPath: odd) }
        let rounded = await server.invokeToolForTesting(name: "insert_image_from_path", arguments: [
            "doc_id": .string(id), "path": .string(odd), "width": .int(21),
        ])
        XCTAssertNotEqual(rounded.isError, true, resultText(rounded))
        let xml = try await savedDocumentXML(server, docId: id)
        XCTAssertTrue(xml.contains("cx=\"\(1 * 9525)\" cy=\"\(49 * 9525)\""), "1×49 expected: \(xml.prefix(3000))")
        XCTAssertTrue(xml.contains("cx=\"\(21 * 9525)\" cy=\"\(119 * 9525)\""), "21×119 expected: \(xml.prefix(3000))")
    }

    /// When the derived side is out of range, the error names the parameter
    /// the caller actually supplied.
    func testImageFromPathDerivedOverflowNamesTheSuppliedParameter() async throws {
        let server = await WordMCPServer()
        let id = "r9-aspect-name"
        try await newDocument(server, id: id)
        let wide = try tempPNGPath(width: 1_000, height: 1)
        defer { try? FileManager.default.removeItem(atPath: wide) }
        // 1000×1 image, height 3,000,000 (in range) → derived width 3×10^9,
        // above the 2,863,311,529-pixel bound.
        let result = await server.invokeToolForTesting(name: "insert_image_from_path", arguments: [
            "doc_id": .string(id), "path": .string(wide), "height": .int(3_000_000),
        ])
        XCTAssertEqual(result.isError, true, resultText(result))
        XCTAssertTrue(resultText(result).contains("height"), resultText(result))
        XCTAssertFalse(resultText(result).contains("Invalid parameter 'width'"), resultText(result))
    }

    // MARK: - LOW-1: insert_toc names the parameter that is actually wrong

    func testInsertTocNamesTheOutOfRangeParameter() async throws {
        let server = await WordMCPServer()
        let id = "r9-toc"
        try await newDocument(server, id: id)
        func toc(_ args: [String: Value]) async -> CallTool.Result {
            var a = args; a["doc_id"] = .string(id)
            return await server.invokeToolForTesting(name: "insert_toc", arguments: a)
        }
        let maxHigh = await toc(["min_level": .int(1), "max_level": .int(10)])
        XCTAssertEqual(maxHigh.isError, true, resultText(maxHigh))
        XCTAssertTrue(resultText(maxHigh).contains("max_level"), resultText(maxHigh))
        XCTAssertFalse(resultText(maxHigh).contains("Invalid parameter 'min_level'"), resultText(maxHigh))
        let maxZero = await toc(["max_level": .int(0)])
        XCTAssertTrue(resultText(maxZero).contains("max_level"), resultText(maxZero))
        let minHigh = await toc(["min_level": .int(10)])
        XCTAssertTrue(resultText(minHigh).contains("min_level"), resultText(minHigh))
        // Only min_level given, above the default max_level 3: the message
        // must say where the 3 came from.
        let inverted = await toc(["min_level": .int(4)])
        XCTAssertEqual(inverted.isError, true, resultText(inverted))
        XCTAssertTrue(resultText(inverted).contains("預設"), resultText(inverted))
    }
}
