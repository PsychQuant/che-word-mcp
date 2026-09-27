import XCTest

/// PsychQuant/che-word-mcp#234 — `swift test`-gated entry point for
/// `scripts/fuzz-extreme-params.py`.
///
/// The fuzzer spawns ~1300 fresh `CheWordMCP` subprocesses (one per probe)
/// against a REAL compiled debug binary and saves the document after each
/// probe, which takes on the order of tens of seconds and needs the binary to
/// be built already — not something every `swift test` invocation should pay
/// for. This test is therefore SKIPPED unless `RUN_FUZZ=1` is set:
///
/// ```bash
/// swift build   # the gate refuses a binary older than Sources/
/// RUN_FUZZ=1 swift test --filter FuzzExtremeParamsGateTests
/// ```
///
/// The script's exit code is the completion condition: no crash or hang
/// (including the save after each probe), every "(must reject)" probe
/// rejected, the largest legal table under the memory ceiling (measured at
/// its PEAK, not just when the sequence finishes — #239), and at least
/// `FUZZ_MIN_COVERAGE` (default 0.80 as of #239 — see that variable's own
/// comment in `scripts/fuzz-extreme-params.py` for why it moved down from
/// 0.97) of the schema's integer/number parameters actually reached (see the
/// script's docstring).
///
/// When to run this: before any release that touches integer/number
/// parameter handling in `Server.swift`, and whenever a tool or an
/// integer/number parameter is added.
///
/// R9 (review `rev232c` LOW-5): once `RUN_FUZZ=1` is set, a missing script or
/// binary — or a binary older than the sources — FAILS instead of skipping: a
/// release gate that quietly skips is not a gate. The script's output is
/// drained before waiting for it to exit; R8 waited first, so a run with a
/// few hundred failures could fill the pipe buffer and deadlock instead of
/// reporting.
final class FuzzExtremeParamsGateTests: XCTestCase {
    func testFuzzExtremeParamsFindsZeroCrashes() throws {
        guard ProcessInfo.processInfo.environment["RUN_FUZZ"] == "1" else {
            throw XCTSkip("RUN_FUZZ=1 not set — see this file's doc comment for how/when to run the fuzzer.")
        }

        // Walk up from this file to the directory holding Package.swift.
        var repoRoot = URL(fileURLWithPath: #filePath)
        while repoRoot.pathComponents.count > 1 {
            repoRoot = repoRoot.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("Package.swift").path) {
                break
            }
        }
        let script = repoRoot.appendingPathComponent("scripts/fuzz-extreme-params.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            XCTFail("RUN_FUZZ=1 but scripts/fuzz-extreme-params.py is missing under \(repoRoot.path).")
            return
        }
        let binary = repoRoot.appendingPathComponent(".build/debug/CheWordMCP")
        guard let binaryDate = modificationDate(binary) else {
            XCTFail("RUN_FUZZ=1 but .build/debug/CheWordMCP does not exist — run `swift build` first.")
            return
        }
        if let newestSource = newestModificationDate(under: repoRoot.appendingPathComponent("Sources")),
           newestSource > binaryDate {
            XCTFail("RUN_FUZZ=1 but .build/debug/CheWordMCP is older than Sources/ — run `swift build` so the fuzzer tests the current code.")
            return
        }
        // #239: the pre-fix version only compared against Sources/, so a
        // dependency bump (e.g. ooxml-swift) that changed behavior without
        // touching a single file under Sources/ left a stale binary passing
        // this gate silently — the fuzzer would then probe old dependency
        // code while reporting "zero crashes" against what looks like the
        // current tree. `Package.resolved` changes on every `swift package
        // update` / dependency version bump, `Package.swift` on every
        // dependency declaration change; both are cheap to stat and belong
        // in the same freshness check as Sources/.
        for manifest in ["Package.resolved", "Package.swift"] {
            let manifestURL = repoRoot.appendingPathComponent(manifest)
            if let manifestDate = modificationDate(manifestURL), manifestDate > binaryDate {
                XCTFail("RUN_FUZZ=1 but .build/debug/CheWordMCP is older than \(manifest) — run `swift build` so the fuzzer tests the current dependency graph, not a stale one.")
                return
            }
        }

        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("fuzz-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workDir) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path, binary.path, workDir.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output   // one pipe, drained below before waiting
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(
            process.terminationStatus, 0,
            "fuzz-extreme-params.py failed (exit \(process.terminationStatus)):\n\(text)"
        )
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func newestModificationDate(under directory: URL) -> Date? {
        guard let files = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        var newest: Date?
        for case let file as URL in files where file.pathExtension == "swift" {
            if let date = modificationDate(file), newest.map({ date > $0 }) ?? true {
                newest = date
            }
        }
        return newest
    }
}
