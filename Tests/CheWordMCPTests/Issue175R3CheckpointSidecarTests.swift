import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/macdoc#175 verify round 3 — checkpoint gating by intent
/// (R2 security S2/S3, logic N3), non-clobbering `.unsaved` sidecars with
/// cleanup (R2 security S4), and an image short-circuit that sees
/// header/footer images (R2 requirements R2-2).
final class Issue175R3CheckpointSidecarTests: XCTestCase {

    private func textOf(_ r: CallTool.Result) -> String {
        guard let c = r.content.first, case .text(let t) = c else { return "" }
        return t.text
    }

    private func docxWithText(_ text: String, name: String = "Doc") throws -> URL {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: text)])))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("i175r3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    private let onePixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

    private func report(_ url: URL) throws -> ImageConsistencyReport {
        try PackageInspector.imageConsistencyReport(of: Data(contentsOf: url))
    }

    /// open → append image → delete its paragraph → session-new orphan.
    private func orphanSession(_ server: WordMCPServer, url: URL, id: String, extraOpenArgs: [String: Value] = [:]) async throws {
        var open: [String: Value] = ["path": .string(url.path), "doc_id": .string(id)]
        for (k, v) in extraOpenArgs { open[k] = v }
        _ = await server.invokeToolForTesting(name: "open_document", arguments: open)
        let png = url.deletingLastPathComponent().appendingPathComponent("px.png"); try onePixelPNG.write(to: png)
        let ins = await server.invokeToolForTesting(name: "insert_image_from_path", arguments: ["doc_id": .string(id), "path": .string(png.path)])
        XCTAssertFalse(textOf(ins).hasPrefix("Error"), textOf(ins))
        let del = await server.invokeToolForTesting(name: "delete_paragraph", arguments: ["doc_id": .string(id), "index": .int(1)])
        XCTAssertFalse(textOf(del).hasPrefix("Error"), textOf(del))
    }

    func testCheckpointCaseVariantOfSourceIsGated() async throws {
        let url = try docxWithText("seed", name: "Doc"); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let server = await WordMCPServer()
        try await orphanSession(server, url: url, id: "r3case")
        let variant = url.deletingLastPathComponent().appendingPathComponent("doc.docx").path   // APFS case-insensitive alias
        let cp = await server.invokeToolForTesting(name: "checkpoint", arguments: ["doc_id": .string("r3case"), "path": .string(variant)])
        XCTAssertTrue(textOf(cp).contains("E_IMAGE_CONSISTENCY"), "case variant must be gated: \(textOf(cp))")
        XCTAssertEqual(try report(url).imageRelationshipCount, 0, "source must be untouched")
    }

    func testCheckpointArbitraryPathIsGatedAndAllowFlagPasses() async throws {
        let url = try docxWithText("seed"); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let server = await WordMCPServer()
        try await orphanSession(server, url: url, id: "r3any")
        let out = url.deletingLastPathComponent().appendingPathComponent("final_deliverable.docx").path
        let refused = await server.invokeToolForTesting(name: "checkpoint", arguments: ["doc_id": .string("r3any"), "path": .string(out)])
        XCTAssertTrue(textOf(refused).contains("E_IMAGE_CONSISTENCY"), textOf(refused))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out))
        let allowed = await server.invokeToolForTesting(name: "checkpoint", arguments: ["doc_id": .string("r3any"), "path": .string(out), "allow_orphan_images": .bool(true)])
        XCTAssertFalse(textOf(allowed).hasPrefix("Error"), textOf(allowed))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out))
    }

    func testDefaultRecoveryCheckpointStaysUngated() async throws {
        let url = try docxWithText("seed"); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let server = await WordMCPServer()
        try await orphanSession(server, url: url, id: "r3def")
        let cp = await server.invokeToolForTesting(name: "checkpoint", arguments: ["doc_id": .string("r3def")])
        XCTAssertFalse(textOf(cp).hasPrefix("Error"), textOf(cp))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".autosave.docx"))
        XCTAssertEqual(try report(url).imageRelationshipCount, 0, "source untouched")
    }

    func testRefusedAutosaveNeverClobbersAnExistingSidecar() async throws {
        let url = try docxWithText("seed"); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let existing = url.path + ".unsaved.docx"
        try Data("USER DATA — not ours".utf8).write(to: URL(fileURLWithPath: existing))
        let server = await WordMCPServer()
        try await orphanSession(server, url: url, id: "r3clob", extraOpenArgs: ["autosave": .bool(true)])
        XCTAssertEqual(String(decoding: try Data(contentsOf: URL(fileURLWithPath: existing)), as: UTF8.self), "USER DATA — not ours", "pre-existing file must not be overwritten (R2 security S4)")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertTrue(siblings.contains { $0.contains(".unsaved-") }, "refused state must land in a timestamped variant: \(siblings)")
        XCTAssertTrue(try report(url).isConsistent, "source never receives the orphan")
    }

    func testSuccessfulSaveCleansUpOurSidecars() async throws {
        let url = try docxWithText("seed"); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let server = await WordMCPServer()
        try await orphanSession(server, url: url, id: "r3clean", extraOpenArgs: ["autosave": .bool(true)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".unsaved.docx"), "refused autosave wrote our sidecar")
        let allowed = await server.invokeToolForTesting(name: "save_document", arguments: ["doc_id": .string("r3clean"), "allow_orphan_images": .bool(true)])
        XCTAssertFalse(textOf(allowed).hasPrefix("Error"), textOf(allowed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".unsaved.docx"), "acknowledged save removes the sidecar we wrote")
    }

    func testShortCircuitSeesHeaderImages() {
        var doc = WordDocument()
        XCTAssertFalse(WordMCPServer.documentMayCarryImages(doc))
        var header = Header(id: "h1")
        header.relationships.relationships.append(Relationship(id: "rId1", type: .image, target: "media/logo.png"))
        doc.headers.append(header)
        XCTAssertTrue(WordMCPServer.documentMayCarryImages(doc), "header-only images must not skip the gate (R2 requirements R2-2)")
    }
}
