import Foundation
import CryptoKit

/// Read-only snapshot of a document's session state, used for MCP tool
/// response serialization (`get_session_state`, `check_disk_drift` responses).
///
/// Server.swift stores the live state across parallel dictionaries keyed by
/// `doc_id` (`openDocuments`, `documentOriginalPaths`, `documentDirtyState`,
/// `documentDiskHash`, `documentDiskMtime`, `documentTrackChangesEnforced`).
/// This struct exists to serialize that state into a single response object
/// without requiring callers to read 6 dicts.
public struct SessionStateView: Equatable {
    public let sourcePath: String
    public let diskHash: Data?
    public let diskMtime: Date?
    public let isDirty: Bool
    public let trackChangesEnabled: Bool
    /// v3.6.0+ (closes #37): true when `<sourcePath>.autosave.docx` exists at
    /// `open_document` time (or any subsequent `get_session_state` call).
    public let autosaveDetected: Bool
    /// v3.6.0+: path to the detected autosave file (`<sourcePath>.autosave.docx`),
    /// nil when `autosaveDetected == false`.
    public let autosavePath: String?

    public init(
        sourcePath: String,
        diskHash: Data?,
        diskMtime: Date?,
        isDirty: Bool,
        trackChangesEnabled: Bool,
        autosaveDetected: Bool = false,
        autosavePath: String? = nil
    ) {
        self.sourcePath = sourcePath
        self.diskHash = diskHash
        self.diskMtime = diskMtime
        self.isDirty = isDirty
        self.trackChangesEnabled = trackChangesEnabled
        self.autosaveDetected = autosaveDetected
        self.autosavePath = autosavePath
    }
}

/// Disk-drift detection status. Returned by `SessionState.checkDriftStatus`.
public enum DriftStatus: Equatable {
    /// On-disk file matches the known hash and mtime. No drift.
    case inSync
    /// On-disk mtime differs from known mtime but hash matches (e.g., `touch`
    /// without content change, or filesystem granularity). Rare but possible.
    case driftedMtime
    /// On-disk hash differs from known hash — content has changed externally.
    case driftedHash
}

/// Namespace for disk-metadata helpers that back `documentDiskHash` /
/// `documentDiskMtime` tracking in Server.swift.
public enum SessionState {

    /// Read file bytes and return the SHA256 digest as `Data`. Throws standard
    /// `Error` on unreadable path.
    ///
    /// Chosen over CRC32 for collision resistance (MCP writes are not
    /// adversarial but SHA256 has zero meaningful perf cost on typical .docx
    /// sizes — ~10ms on a 2 MB file on M1) and over mtime-only comparison
    /// because mtime can be fragile across sync tools (Dropbox, rsync).
    public static func computeSHA256(path: String) throws -> Data {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return Data(digest)
    }

    /// Read file modification date. Throws standard `Error` on missing file.
    public static func readMtime(path: String) throws -> Date {
        let url = URL(fileURLWithPath: path)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let date = attrs[.modificationDate] as? Date else {
            throw NSError(
                domain: "CheWordMCP.SessionState",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "File attributes missing modificationDate: \(path)"]
            )
        }
        return date
    }

    /// Classify the drift between on-disk state and the caller's known hash+mtime.
    ///
    /// - Returns: `.inSync` when both hash and mtime match the known values.
    ///   `.driftedHash` when the hash differs (content changed). `.driftedMtime`
    ///   when only mtime differs (touch-without-change or filesystem artifact).
    /// - Note: If the file is unreadable, returns `.driftedHash` (conservative:
    ///   treat unreadable as drifted, caller decides next action).
    public static func checkDriftStatus(
        path: String,
        knownHash: Data?,
        knownMtime: Date?
    ) -> DriftStatus {
        let currentHash: Data
        let currentMtime: Date
        do {
            currentHash = try computeSHA256(path: path)
            currentMtime = try readMtime(path: path)
        } catch {
            return .driftedHash
        }

        let hashMatches = (knownHash == currentHash)
        let mtimeMatches = (knownMtime == currentMtime)

        if !hashMatches {
            return .driftedHash
        }
        if !mtimeMatches {
            return .driftedMtime
        }
        return .inSync
    }
}
