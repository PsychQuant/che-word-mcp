import XCTest
import OOXMLSwift
import CryptoKit
@testable import CheWordMCP

/// Real-world docx round-trip smoke test for the
/// `che-word-mcp-document-xml-lossless-roundtrip` Spectra change
/// (PsychQuant/che-word-mcp#56) Phase 5 task 5.3.
///
/// Iterates `mcp/che-word-mcp/test-files/*.docx` (gitignored — populated by
/// developers locally with document-class fixtures). For each file:
///   1. Open via DocxReader.
///   2. Force `word/document.xml` to regenerate (`markPartDirty`) so the
///      v3.12.0 Writer regression is exercised end-to-end.
///   3. Save via DocxWriter to a temp .docx.
///   4. Reload the saved file.
///   5. Assert xmllint --noout reports no errors.
///   6. Assert bookmark / `<w:hyperlink>` / `<w:fldSimple>` /
///      `<mc:AlternateContent>` counts match.
///   7. Assert SHA256 of concatenated `<w:t>` text content matches.
///
/// XCTSkip when the directory is absent or contains no `.docx` files
/// (mirrors the existing `.note` smoke test pattern from PsychQuant/macdoc#81).
/// This means CI on a clean clone passes silently while local developers can
/// drop a confidential document fixture in and exercise the full Reader / Writer
/// pair against real-world Word output.
final class RealWorldDocxRoundTripSmokeTests: XCTestCase {

    /// Locate the `test-files/` directory relative to this test source file.
    /// Returns nil when the directory is absent (clean clone scenario).
    private func testFilesDir() -> URL? {
        let thisFile = URL(fileURLWithPath: #filePath)
        // .../che-word-mcp/Tests/CheWordMCPTests/RealWorldDocxRoundTripSmokeTests.swift
        // → .../che-word-mcp/test-files/
        let pkgRoot = thisFile
            .deletingLastPathComponent()  // CheWordMCPTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // che-word-mcp
        let dir = pkgRoot.appendingPathComponent("test-files", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
              isDir.boolValue else {
            return nil
        }
        return dir
    }

    /// List `.docx` fixtures under `test-files/`. Skips dotfiles and
    /// non-`.docx` extensions so a `.gitkeep` marker plus stray notes do not
    /// trip the test.
    private func listFixtures(in dir: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        return entries
            .filter { $0.pathExtension.lowercased() == "docx" }
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func testEveryFixtureRoundTripsLossless() throws {
        guard let dir = testFilesDir() else {
            throw XCTSkip("mcp/che-word-mcp/test-files/ not present (clean clone). Drop real-world .docx fixtures here to exercise this test.")
        }
        let fixtures = listFixtures(in: dir)
        guard !fixtures.isEmpty else {
            throw XCTSkip("mcp/che-word-mcp/test-files/ is empty (no .docx fixtures present).")
        }

        var failures: [String] = []
        for fixture in fixtures {
            do {
                try assertRoundTripLossless(fixture: fixture)
            } catch {
                failures.append("\(fixture.lastPathComponent): \(error)")
            }
        }
        XCTAssertTrue(failures.isEmpty, "Round-trip failures:\n\(failures.joined(separator: "\n"))")
    }

    /// Per-file round-trip + 6 assertions.
    private func assertRoundTripLossless(fixture: URL) throws {
        // Source ground-truth: counts + <w:t> hash.
        var sourceDoc = try DocxReader.read(from: fixture)
        let sourceCounts = paragraphCounts(in: sourceDoc)
        let sourceTextHash = textContentHash(in: sourceDoc)
        sourceDoc.close()

        // Round-trip: load, force regeneration, save, reload.
        var doc = try DocxReader.read(from: fixture)
        doc.markPartDirty("word/document.xml")
        let saved = FileManager.default.temporaryDirectory
            .appendingPathComponent("rwsmoke-\(UUID().uuidString).docx")
        defer {
            doc.close()
            try? FileManager.default.removeItem(at: saved)
        }
        try DocxWriter.write(doc, to: saved)

        // Assertion 1: xmllint --noout (when available).
        if let result = runXmllintNoOut(on: saved) {
            XCTAssertEqual(result.exitCode, 0,
                           "xmllint --noout failed on saved \(fixture.lastPathComponent). stderr: \(result.stderr)")
        }

        var savedDoc = try DocxReader.read(from: saved)
        defer { savedDoc.close() }
        let savedCounts = paragraphCounts(in: savedDoc)
        let savedTextHash = textContentHash(in: savedDoc)

        // Assertion 2-5: 4 wrapper count parities.
        XCTAssertEqual(savedCounts.bookmarks, sourceCounts.bookmarks,
                       "[\(fixture.lastPathComponent)] bookmark count diverged")
        XCTAssertEqual(savedCounts.hyperlinks, sourceCounts.hyperlinks,
                       "[\(fixture.lastPathComponent)] hyperlink count diverged")
        XCTAssertEqual(savedCounts.fieldSimples, sourceCounts.fieldSimples,
                       "[\(fixture.lastPathComponent)] fldSimple count diverged")
        XCTAssertEqual(savedCounts.alternateContents, sourceCounts.alternateContents,
                       "[\(fixture.lastPathComponent)] AlternateContent count diverged")

        // Assertion 6: <w:t> SHA256 parity.
        XCTAssertEqual(savedTextHash, sourceTextHash,
                       "[\(fixture.lastPathComponent)] concatenated <w:t> SHA256 diverged — text content lost")
    }

    // MARK: - Helpers

    private struct Counts {
        var bookmarks: Int
        var hyperlinks: Int
        var fieldSimples: Int
        var alternateContents: Int
    }

    private func paragraphCounts(in doc: WordDocument) -> Counts {
        var c = Counts(bookmarks: 0, hyperlinks: 0, fieldSimples: 0, alternateContents: 0)
        for para in doc.getParagraphs() {
            c.bookmarks += para.bookmarks.count
            c.hyperlinks += para.hyperlinks.count
            c.fieldSimples += para.fieldSimples.count
            c.alternateContents += para.alternateContents.count
        }
        return c
    }

    /// SHA256 of every `<w:t>` content concatenated in document order.
    /// Catches text loss / reordering even when wrapper counts match.
    private func textContentHash(in doc: WordDocument) -> String {
        var concat = ""
        for para in doc.getParagraphs() {
            for run in para.runs { concat += run.text }
            for hl in para.hyperlinks { for run in hl.runs { concat += run.text } }
            for field in para.fieldSimples { for run in field.runs { concat += run.text } }
            for ac in para.alternateContents { for run in ac.fallbackRuns { concat += run.text } }
        }
        let digest = SHA256.hash(data: Data(concat.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Run `xmllint --noout` on the saved file's `word/document.xml`. Returns
    /// nil when xmllint is not available on the host.
    private func runXmllintNoOut(on docxURL: URL) -> (exitCode: Int32, stderr: String)? {
        let unzipped: URL
        do {
            unzipped = try ZipHelper.unzip(docxURL)
        } catch {
            return nil
        }
        defer { ZipHelper.cleanup(unzipped) }
        let documentPath = unzipped.appendingPathComponent("word/document.xml").path
        let xmllintPath = "/usr/bin/xmllint"
        guard FileManager.default.isExecutableFile(atPath: xmllintPath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: xmllintPath)
        process.arguments = ["--noout", documentPath]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stderr)
    }
}
