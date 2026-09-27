import XCTest
@testable import CheWordMCP

/// che-word-mcp#211 — three blind spots in how the version string is
/// tracked: `server.json` had no checklist item or gate at all, the MCP
/// handshake's `Implementation(version:)` sat stale on an old release for
/// two major versions because nothing compared it to anything, and behavior
/// changes from "always succeeds" to "always fails" shipped as a patch bump
/// with no note.
///
/// The second blind spot is closed structurally (`WordMCPServer.serverVersion`
/// is now the single source the `Server(...)` handshake call reads — see
/// that constant's doc comment) rather than by a test; this file locks it
/// against `mcpb/manifest.json` so the two can never independently drift
/// again. `server.json`'s version/URL/sha256 triple is a release-time-only
/// concern (the sha256 is only known after the binary is built and
/// notarized, which this repo's `swift test` cannot reproduce) — that gate
/// lives in `scripts/release.sh` instead; see its "script-pipeline parity
/// gate" comment block for the fail-fast check.
final class Issue211VersionConsistencyTests: XCTestCase {

    /// Walk up from this file to the directory holding `Package.swift` — the
    /// same technique `FuzzExtremeParamsGateTests` uses, robust regardless
    /// of `swift test`'s working directory.
    private static var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
        }
        return URL(fileURLWithPath: #filePath)
    }

    func testMCPHandshakeVersionMatchesManifestVersion() throws {
        let manifestURL = Self.repoRoot.appendingPathComponent("mcpb/manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let manifestVersion = try XCTUnwrap(json["version"] as? String,
                                            "mcpb/manifest.json must have a string 'version' field")
        XCTAssertEqual(
            WordMCPServer.serverVersion, manifestVersion,
            "Server.swift's serverVersion (the MCP initialize handshake's reported version) "
                + "must match mcpb/manifest.json's version — #211's checklist blind spot. "
                + "Bump both in the same change."
        )
    }

    /// `scripts/tests/release-source-stability.sh` greps for exactly this
    /// declaration shape and silently falls back to a dummy version if it
    /// finds nothing (see its `TEST_VERSION` fallback) — pin the shape so a
    /// future rename/refactor cannot quietly resurrect that fallback.
    func testServerVersionDeclarationMatchesTheShapeReleaseTestingGreps() throws {
        let serverSwiftURL = Self.repoRoot.appendingPathComponent("Sources/CheWordMCP/Server.swift")
        let source = try String(contentsOf: serverSwiftURL, encoding: .utf8)
        XCTAssertTrue(
            source.contains("static let serverVersion = \"\(WordMCPServer.serverVersion)\""),
            "Server.swift must declare `static let serverVersion = \"X.Y.Z\"` literally — "
                + "scripts/tests/release-source-stability.sh greps this exact shape."
        )
    }
}
