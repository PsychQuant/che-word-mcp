import XCTest
import MCP
import CoreGraphics
import ImageIO
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/macdoc#175 verify round 2 — the save gate's side doors and
/// baseline design (R1 logic H1, security S2/S6, codex F3/F6, DA N2, #14).
final class Issue175R2SaveGateTests: XCTestCase {

    private func textOf(_ r: CallTool.Result) -> String {
        guard let content = r.content.first else { return "" }
        if case .text(let t) = content { return t.text }
        return ""
    }

    private func docxWithText(_ text: String) throws -> URL {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: text)])))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("i175r2-\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    private func pngPath() throws -> String {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw XCTSkip("CGContext unavailable") }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        guard let image = ctx.makeImage() else { throw XCTSkip("no image") }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { throw XCTSkip("no encoder") }
        CGImageDestinationAddImage(dest, image, nil); CGImageDestinationFinalize(dest)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("i175r2-\(UUID().uuidString).png")
        try (out as Data).write(to: url)
        return url.path
    }

    private func report(_ url: URL) throws -> ImageConsistencyReport {
        try PackageInspector.imageConsistencyReport(of: Data(contentsOf: url))
    }

    /// Open → insert image (appended) → delete its paragraph → session-new orphan.
    private func orphanSession(_ server: WordMCPServer, url: URL, id: String, extraOpenArgs: [String: Value] = [:]) async throws {
        var open: [String: Value] = ["path": .string(url.path), "doc_id": .string(id)]
        for (k, v) in extraOpenArgs { open[k] = v }
        _ = await server.invokeToolForTesting(name: "open_document", arguments: open)
        let png = try pngPath(); defer { try? FileManager.default.removeItem(atPath: png) }
        let ins = await server.invokeToolForTesting(name: "insert_image_from_path", arguments: ["doc_id": .string(id), "path": .string(png)])
        XCTAssertFalse(textOf(ins).hasPrefix("Error"), textOf(ins))
        let del = await server.invokeToolForTesting(name: "delete_paragraph", arguments: ["doc_id": .string(id), "index": .int(1)])
        XCTAssertFalse(textOf(del).hasPrefix("Error"), textOf(del))
    }

    // MARK: - Pure helpers

    func testInspectionRefusalIsFailClosedAndNamed() {
        let m = WordMCPServer.imageConsistencyInspectionRefusal(reason: "boom")
        XCTAssertTrue(m.contains("E_IMAGE_CONSISTENCY_INSPECTION"))
        XCTAssertTrue(m.contains("boom"))
        XCTAssertTrue(m.contains("No file was written"))
    }

    func testAllowOrphanImagesFlagRejectsNonBoolean() throws {
        XCTAssertFalse(try WordMCPServer.allowOrphanImagesFlag([:]))
        XCTAssertFalse(try WordMCPServer.allowOrphanImagesFlag(["allow_orphan_images": .null]))
        XCTAssertTrue(try WordMCPServer.allowOrphanImagesFlag(["allow_orphan_images": .bool(true)]))
        XCTAssertThrowsError(try WordMCPServer.allowOrphanImagesFlag(["allow_orphan_images": .string("true")]))
    }

    func testRefusalMessageNoLongerInvitesRouteAround() throws {
        let m = try XCTUnwrap(WordMCPServer.imageConsistencyRefusalMessage(
            orphanIds: ["word/document.xml:rId7"], baselineOrphanIds: [], bodyDrawingCount: 0, imageRelationshipCount: 1, mediaEntryCount: 1))
        XCTAssertTrue(m.contains("Two possible causes"))
        XCTAssertTrue(m.contains("deliberately deleted"))
        XCTAssertTrue(m.contains("checkpoint"), "must warn against the checkpoint bypass (DA N2)")
    }

    // MARK: - Baseline is an open-time snapshot

    func testAllowedSaveRefreshesBaselineSoNextSavePasses() async throws {
        let url = try docxWithText("seed"); defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        try await orphanSession(server, url: url, id: "r2a")
        let refused = await server.invokeToolForTesting(name: "save_document", arguments: ["doc_id": .string("r2a")])
        XCTAssertTrue(textOf(refused).contains("E_IMAGE_CONSISTENCY"), textOf(refused))
        XCTAssertEqual(refused.isError, true, "the image-consistency refusal must be isError on the wire (#202)")
        let allowed = await server.invokeToolForTesting(name: "save_document", arguments: ["doc_id": .string("r2a"), "allow_orphan_images": .bool(true)])
        XCTAssertFalse(textOf(allowed).hasPrefix("Error"), textOf(allowed))
        _ = await server.invokeToolForTesting(name: "insert_paragraph", arguments: ["doc_id": .string("r2a"), "text": .string("later edit")])
        let again = await server.invokeToolForTesting(name: "save_document", arguments: ["doc_id": .string("r2a")])
        XCTAssertFalse(textOf(again).contains("E_IMAGE_CONSISTENCY"), "acknowledged orphan must not be re-refused: \(textOf(again))")
    }

    func testCheckpointToSourcePathIsGatedAndDoesNotUnlockGate() async throws {
        let url = try docxWithText("seed"); defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        try await orphanSession(server, url: url, id: "r2c")
        let cp = await server.invokeToolForTesting(name: "checkpoint", arguments: ["doc_id": .string("r2c"), "path": .string(url.path)])
        XCTAssertTrue(textOf(cp).contains("E_IMAGE_CONSISTENCY"), "checkpoint aimed at the source must be gated: \(textOf(cp))")
        XCTAssertEqual(try report(url).imageRelationshipCount, 0, "source file must be untouched")
        let sidecar = url.path + ".autosave.docx"
        let cp2 = await server.invokeToolForTesting(name: "checkpoint", arguments: ["doc_id": .string("r2c")])
        XCTAssertFalse(textOf(cp2).hasPrefix("Error"), "sidecar checkpoint stays allowed: \(textOf(cp2))")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar)); try? FileManager.default.removeItem(atPath: sidecar)
        let save = await server.invokeToolForTesting(name: "save_document", arguments: ["doc_id": .string("r2c")])
        XCTAssertTrue(textOf(save).contains("E_IMAGE_CONSISTENCY"), "baseline must not be laundered by checkpoint: \(textOf(save))")
    }

    func testFinalizeRefusalKeepsSessionAlive() async throws {
        let url = try docxWithText("seed"); defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        try await orphanSession(server, url: url, id: "r2f")
        let fin = await server.invokeToolForTesting(name: "finalize_document", arguments: ["doc_id": .string("r2f")])
        XCTAssertTrue(textOf(fin).contains("E_IMAGE_CONSISTENCY"), textOf(fin))
        let info = await server.invokeToolForTesting(name: "get_document_info", arguments: ["doc_id": .string("r2f")])
        XCTAssertFalse(textOf(info).contains("not found") || textOf(info).lowercased().contains("documentnotfound"), "session must survive: \(textOf(info))")
    }

    func testAutosaveRefusalWritesSidecarNotSource() async throws {
        let url = try docxWithText("seed"); defer { try? FileManager.default.removeItem(at: url) }
        let sidecar = url.path + ".unsaved.docx"; defer { try? FileManager.default.removeItem(atPath: sidecar) }
        let server = await WordMCPServer()
        try await orphanSession(server, url: url, id: "r2s", extraOpenArgs: ["autosave": .bool(true)])
        // delete_paragraph triggered autosave; the gate must have diverted it.
        XCTAssertEqual(try report(url).imageRelationshipCount, 1, "autosave after insert wrote the (consistent) image")
        XCTAssertTrue(try report(url).isConsistent, "source must never receive the orphan via autosave")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar), "refused autosave state preserved in sidecar")
        let save = await server.invokeToolForTesting(name: "save_document", arguments: ["doc_id": .string("r2s")])
        XCTAssertTrue(textOf(save).contains("E_IMAGE_CONSISTENCY"), "autosave must not launder the baseline: \(textOf(save))")
    }

    func testNonBooleanAllowFlagIsAnErrorNotSilentFalse() async throws {
        let url = try docxWithText("seed"); defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: ["path": .string(url.path), "doc_id": .string("r2b")])
        let r = await server.invokeToolForTesting(name: "save_document", arguments: ["doc_id": .string("r2b"), "allow_orphan_images": .string("true")])
        XCTAssertTrue(textOf(r).contains("boolean"), textOf(r))
    }
}
