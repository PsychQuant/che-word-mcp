import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// che-word-mcp#220 — the save gate inspected `DocxWriter.writeData`'s
/// ALWAYS-scratch serialization, never the overlay-mode bytes a real save
/// through an opened document actually writes. Overlay mode preserves parts
/// the typed model does not manage at all (charts, and any image
/// relationship declared inside them) verbatim; scratch mode never emits
/// them, so a chart's orphan image relationship was invisible to the gate
/// even though it reaches the real output file unchanged. `#199`'s own
/// diagnosis technique (Direct Mode vs Session Mode `list_images`) is
/// reproduced here at the `PackageInspector` level: build a document whose
/// ONLY inconsistency lives in a chart part, and show the two byte sources
/// disagree — then show the fix (`WordMCPServer.persistableBytes`) resolves
/// the disagreement in the correct direction.
final class Issue220SaveGateOverlayBytesTests: XCTestCase {

    // MARK: - Fixture: a minimal, self-produced docx with a chart-only orphan
    //
    // No third-party document — built from a fresh ooxml-swift authoring
    // package, then a synthetic `word/charts/chart1.xml` + its own `.rels`
    // (declaring an image relationship the chart body never references) is
    // appended as extra ZIP entries, the same technique
    // `ScriptPipelineParityTests.testExecuteMissingPartBreaksVerification`
    // uses to grow a package beyond what the typed model can write.

    private func textOf(_ r: CallTool.Result) -> String {
        guard let content = r.content.first else { return "" }
        if case .text(let t) = content { return t.text }
        return ""
    }

    private func makeScratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("i220-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// A minimal, valid docx (one paragraph, no images) with an appended
    /// `word/charts/chart1.xml` + `word/charts/_rels/chart1.xml.rels`
    /// declaring ONE image relationship that `chart1.xml`'s own body never
    /// references — an orphan that lives ENTIRELY outside the typed model.
    private func makeDocxWithChartOnlyOrphan(in dir: URL) throws -> URL {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "seed")])))
        let url = dir.appendingPathComponent("chart-orphan.docx")
        try DocxWriter.write(doc, to: url)

        let chartsDir = dir.appendingPathComponent("word/charts", isDirectory: true)
        let chartsRelsDir = chartsDir.appendingPathComponent("_rels", isDirectory: true)
        let mediaDir = dir.appendingPathComponent("word/media", isDirectory: true)
        try FileManager.default.createDirectory(at: chartsRelsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        // The chart body never mentions rId1 — no `r:embed`/`r:link`/`r:id`
        // reference anywhere — so PackageInspector must call it an orphan.
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart"><c:chart/></c:chartSpace>
        """.write(to: chartsDir.appendingPathComponent("chart1.xml"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/chartimg.png"/>
        </Relationships>
        """.write(to: chartsRelsDir.appendingPathComponent("chart1.xml.rels"), atomically: true, encoding: .utf8)
        try Data("not a real png, PackageInspector only counts the entry".utf8)
            .write(to: mediaDir.appendingPathComponent("chartimg.png"))

        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = dir
        zip.arguments = ["-q", url.lastPathComponent,
                          "word/charts/chart1.xml", "word/charts/_rels/chart1.xml.rels",
                          "word/media/chartimg.png"]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        return url
    }

    // MARK: - Premise + fix, at the PackageInspector level

    /// Premise check (mirrors #199's own finding): a document carrying a
    /// chart-only orphan reports CONSISTENT via `writeData` (scratch —
    /// the chart never reaches those bytes at all) but INCONSISTENT via the
    /// real disk file. If this fails, `DocxWriter` changed shape and the rest
    /// of this file is testing nothing.
    func testWriteDataScratchBytesMissTheChartOrphan() throws {
        let dir = try makeScratch()
        let url = try makeDocxWithChartOnlyOrphan(in: dir)

        let onDisk = try PackageInspector.imageConsistencyReport(of: Data(contentsOf: url))
        XCTAssertFalse(onDisk.isConsistent, "premise: the real file must carry the chart orphan")
        XCTAssertTrue(onDisk.orphanImageRelationshipRefs.contains { $0.part.contains("chart1") },
                      "premise: orphan must be attributed to the chart part; got \(onDisk.orphanImageRelationshipRefs)")

        let doc = try DocxReader.read(from: url)
        let scratchReport = try PackageInspector.imageConsistencyReport(of: try DocxWriter.writeData(doc))
        XCTAssertTrue(scratchReport.isConsistent,
                      "premise: scratch-mode writeData must NOT see the chart part at all — " +
                      "got orphans \(scratchReport.orphanImageRelationshipRefs)")
        XCTAssertEqual(scratchReport.imageRelationshipCount, 0,
                       "premise: scratch mode declares zero image relationships for this document")
    }

    /// The fix: `WordMCPServer.persistableBytes` (overlay mode, the SAME
    /// branch `persistDocumentToDisk` takes) sees exactly what the real
    /// saved file sees.
    func testPersistableBytesSeesTheSameOrphanAsTheRealFile() throws {
        let dir = try makeScratch()
        let url = try makeDocxWithChartOnlyOrphan(in: dir)
        let doc = try DocxReader.read(from: url)

        let onDisk = try PackageInspector.imageConsistencyReport(of: Data(contentsOf: url))
        let gateInput = try PackageInspector.imageConsistencyReport(
            of: try WordMCPServer.persistableBytes(for: doc))

        XCTAssertFalse(gateInput.isConsistent, "the gate's bytes must see the chart orphan")
        XCTAssertEqual(gateInput.orphanImageRelationshipRefs, onDisk.orphanImageRelationshipRefs,
                       "the gate must inspect exactly the bytes the real save would write")
        XCTAssertEqual(gateInput.imageRelationshipCount, onDisk.imageRelationshipCount)
    }

    // MARK: - Integration: the fix does not turn a legitimate pre-existing
    // chart orphan into a spurious save refusal

    /// A document whose ONLY inconsistency is a pre-existing, overlay-only
    /// chart orphan must keep saving normally (it is captured at open-time
    /// baseline — see `recordImageBaseline`, which already reads the real
    /// disk file) — and the saved file must still carry the chart part
    /// byte-for-byte (overlay preservation untouched by the fix).
    func testPreexistingChartOnlyOrphanDoesNotBlockSave() async throws {
        let dir = try makeScratch()
        let url = try makeDocxWithChartOnlyOrphan(in: dir)

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("i220")])
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("i220"), "text": .string("edit")])
        let save = await server.invokeToolForTesting(
            name: "save_document", arguments: ["doc_id": .string("i220")])
        XCTAssertFalse(textOf(save).contains("E_IMAGE_CONSISTENCY"),
                       "a pre-existing, baseline-captured chart orphan must not block ordinary saves: \(textOf(save))")
        XCTAssertFalse(textOf(save).hasPrefix("Error"), "save failed: \(textOf(save))")

        let after = try PackageInspector.imageConsistencyReport(of: Data(contentsOf: url))
        XCTAssertEqual(after.orphanImageRelationshipRefs.count, 1,
                       "the chart part must survive the save (overlay preservation)")
        XCTAssertTrue(after.orphanImageRelationshipRefs.contains { $0.part.contains("chart1") })
    }
}
