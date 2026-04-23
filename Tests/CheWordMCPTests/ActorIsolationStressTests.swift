import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// Phase 2 of `che-word-mcp-save-durability-stack` (closes #39).
///
/// Spec: `openspec/changes/che-word-mcp-save-durability-stack/specs/che-word-mcp-session-state-api/spec.md`
/// Requirement: "WordMCPServer is an actor for concurrent-safe session state".
///
/// The 2026-04-23 incident reproduced 12 parallel `insert_image_from_path` +
/// `save_document` against a `class WordMCPServer` → MCP crash → 0-byte docx.
/// Root cause: 8 unsynchronized `var` dictionaries (`openDocuments`, etc.)
/// mutated concurrently by parallel async tasks → Dictionary hash table corruption.
///
/// This test scales the incident pattern up (50 concurrent inserts × 5
/// iterations = 250 mutations) to surface any remaining race in the actor
/// refactor.
///
/// **TSan note**: `swift test -Xswiftc -sanitize=thread` on macOS hits a
/// known Xcode/SwiftPM limitation — the swiftpm-xctest-helper spawns the
/// test bundle in a way that loads TSan too late, producing
/// `Interceptors are not working` regardless of `DYLD_INSERT_LIBRARIES`.
/// The actor model itself provides compile-time race-freedom; this test
/// verifies behavior + state integrity. The original crash reproduces in
/// pre-v3.5.4 (`class WordMCPServer`) at as few as 12 concurrent inserts
/// without any sanitizer; v3.5.4 (`actor`) handles 50 cleanly.
final class ActorIsolationStressTests: XCTestCase {

    private var tempDir: URL!
    private var imagePath: String!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActorStress-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Minimal 1×1 PNG — sufficient for ImageDimensions.detect + insertImage.
        let png1x1: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,                          // signature
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,                          // IHDR length+type
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,                          // 1×1
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89,                    // 8-bit RGBA + CRC
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54,                          // IDAT
            0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01,
            0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00,
            0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82                           // IEND
        ]
        let imageURL = tempDir.appendingPathComponent("dot.png")
        try? Data(png1x1).write(to: imageURL)
        imagePath = imageURL.path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func tempDocx() throws -> String {
        let url = tempDir.appendingPathComponent("stress-\(UUID().uuidString).docx")
        var doc = WordDocument()
        doc.appendParagraph(Paragraph(text: "stress baseline"))
        try DocxWriter.write(doc, to: url)
        return url.path
    }

    /// 50 concurrent insert_image_from_path tasks against the same doc_id.
    /// Asserts no crash + final image count == 50 (no lost updates).
    /// Iteration count kept low (5 iterations × 50 inserts) so the suite
    /// stays under a few seconds; bump locally to 100 iterations under TSan
    /// for the full incident-pattern coverage.
    func testParallelInsertImageDoesNotCrash() async throws {
        let iterations = 5
        for iter in 0..<iterations {
            let docPath = try tempDocx()
            let server = await WordMCPServer()

            _ = await server.invokeToolForTesting(
                name: "open_document",
                arguments: ["path": .string(docPath), "doc_id": .string("d1")]
            )

            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<50 {
                    group.addTask { [imagePath = self.imagePath!] in
                        _ = await server.invokeToolForTesting(
                            name: "insert_image_from_path",
                            arguments: [
                                "doc_id": .string("d1"),
                                "path": .string(imagePath)
                            ]
                        )
                    }
                }
            }

            let count = await server.imageCountForTesting("d1")
            XCTAssertEqual(
                count, 50,
                "iter \(iter): SHALL have exactly 50 images after 50 concurrent inserts; got \(count ?? -1)"
            )
        }
    }
}
