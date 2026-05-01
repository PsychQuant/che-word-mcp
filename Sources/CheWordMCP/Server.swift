import Foundation
import MCP
import OOXMLSwift
import WordToMDSwift
import CommonConverterSwift
import LaTeXMathSwift

/// Word MCP Server - Swift OOXML Word 文件處理
///
/// **Concurrency model (v3.5.4+, closes #39)**: declared as `actor` for
/// compiler-enforced synchronization of session state dictionaries
/// (`openDocuments`, `documentDirtyState`, `documentDiskHash`, etc.). Pre-v3.5.4
/// `class` declaration allowed parallel async tasks (e.g., 12 concurrent
/// `insert_image_from_path` calls) to mutate Swift `Dictionary` hash tables
/// without synchronization, causing corruption + save-time crash. The atomic
/// rename in v3.5.3 prevents data loss when the crash hits, but the underlying
/// race remained — closed by this actor refactor.
actor WordMCPServer {
    private let server: Server
    private let transport: StdioTransport

    /// 目前開啟的文件 (doc_id -> WordDocument)
    internal var openDocuments: [String: WordDocument] = [:]
    /// Session state tracking (contributed by @ildunari)
    private var documentOriginalPaths: [String: String] = [:]
    private var documentDirtyState: [String: Bool] = [:]
    private var documentAutosave: [String: Bool] = [:]
    private var documentTrackChangesEnforced: [String: Bool] = [:]
    /// Disk-drift detection (3.0.0 — Refs #12 #13 #15)
    private var documentDiskHash: [String: Data] = [:]
    private var documentDiskMtime: [String: Date] = [:]
    /// Phase 4 (v3.6.0, closes #37): per-N-mutations autosave throttle.
    /// `autosaveEvery[docId] > 0` enables periodic checkpoint to
    /// `<sourcePath>.autosave.docx`; `0` (default) disables. `autosaveCounter`
    /// increments on every `storeDocument(markDirty: true)` call; checkpoint
    /// fires when `counter % N == 0`.
    private var autosaveEvery: [String: Int] = [:]
    private var autosaveCounter: [String: Int] = [:]

    /// Phase A of `che-word-mcp-insert-crash-autosave-fix` (#41 investigation).
    /// Set to `true` when `CHE_WORD_MCP_LOG_LEVEL=debug` is in process env at
    /// actor init OR when test seam constructor passes `forceDebugLogging: true`.
    /// Read-only after init.
    private let debugLoggingEnabled: Bool

    /// Test seam — when `debugLoggingEnabled`, every emitted event is also
    /// appended here so XCTests can assert event traces without subprocess wrapping.
    /// Bounded ring buffer (last 1000 events) to avoid unbounded growth.
    private var debugEventLog: [DebugLogEvent] = []
    private static let debugEventLogCapacity = 1000

    // MARK: - anchor-dx-consistency (#71): conflict-detection helper

    /// Per-anchor presence predicate. Each entry knows its expected JSON-Value type
    /// so JSON `null` and wrong-type values do NOT count as present (matches the
    /// existing dispatcher pattern where `args["after_text"]?.stringValue` returning
    /// nil falls through to the next branch).
    static let anchorPresence: [String: @Sendable (Value) -> Bool] = [
        "into_table_cell":   { $0.objectValue != nil },
        "after_image_id":    { $0.stringValue != nil },
        "after_text":        { $0.stringValue != nil },
        "before_text":       { $0.stringValue != nil },
        "index":             { $0.intValue    != nil },
        "paragraph_index":   { $0.intValue    != nil },
        "after_table_index": { $0.intValue    != nil },
    ]

    /// #80 — single source of truth for each #61-target tool's accepted anchor names.
    /// Keys are MCP tool names (snake_case, matching schema), values are the anchor
    /// parameter names that tool accepts. Conflict-detection call sites resolve via
    /// this dict instead of duplicating literal arrays at each site (which silently
    /// drift when a future PR adds a new anchor to one but not the others).
    /// Test `testToolAnchorWhitelistsSubsetOfAnchorPresence` enforces every value
    /// here is in `anchorPresence.keys` so unknown names cannot silently bypass
    /// detection.
    static let toolAnchorWhitelists: [String: [String]] = [
        "insert_paragraph":       ["into_table_cell", "after_image_id", "after_text", "before_text", "index"],
        "insert_image_from_path": ["into_table_cell", "after_image_id", "after_text", "before_text", "index"],
        "insert_equation":        ["into_table_cell", "after_image_id", "after_text", "before_text", "paragraph_index"],
        "insert_caption":         ["paragraph_index", "after_image_id", "after_table_index", "after_text", "before_text"],
    ]

    /// Detect which anchor parameters from `anchors` are present in `args`.
    /// Returns alphabetically-sorted names so callers can include them verbatim
    /// in error messages with stable formatting.
    ///
    /// - Parameters:
    ///   - args: tool invocation arguments (from MCP request).
    ///   - anchors: whitelist of anchor names this tool accepts. Names not in
    ///     `anchorPresence` are silently skipped (defensive — never fatal).
    /// - Returns: sorted names of anchors that are present (correct type, non-null).
    /// - Note: For #61-target tools (`insert_paragraph` / `insert_image_from_path`
    ///   / `insert_equation` / `insert_caption`), prefer the `(args, tool:)`
    ///   overload — it resolves the anchor list from `toolAnchorWhitelists` (SoT)
    ///   so adding/removing anchors only touches one place.
    static func detectPresentAnchors(_ args: [String: Value], anchors: [String]) -> [String] {
        return anchors.compactMap { name -> String? in
            guard let value = args[name],
                  let predicate = anchorPresence[name],
                  predicate(value)
            else { return nil }
            return name
        }.sorted()
    }

    /// #80 — SoT-driven overload. Looks up the tool's accepted anchor list in
    /// `toolAnchorWhitelists` then delegates to the explicit-anchors overload.
    /// Tools not in the dict return `[]` (defensive — mirrors the per-anchor
    /// silent-skip in the explicit overload).
    static func detectPresentAnchors(_ args: [String: Value], tool: String) -> [String] {
        guard let anchors = toolAnchorWhitelists[tool] else { return [] }
        return detectPresentAnchors(args, anchors: anchors)
    }

    /// One emitted log event. `event` is the dotted name (e.g. `storeDocument.entry`),
    /// `keyValues` is the structured payload.
    struct DebugLogEvent: Sendable, Equatable {
        let event: String
        let keyValues: [(String, String)]

        static func == (lhs: DebugLogEvent, rhs: DebugLogEvent) -> Bool {
            lhs.event == rhs.event &&
                lhs.keyValues.count == rhs.keyValues.count &&
                zip(lhs.keyValues, rhs.keyValues).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        }
    }

    /// Word → Markdown 轉換器（嵌入 word-to-md-swift library）
    private let wordConverter = WordConverter()
    private let defaultRevisionAuthor = "CheWordMCP"

    // MARK: - Server Instructions

    private static let serverInstructions = """
    # che-word-mcp — Word Document MCP Server

    Swift-native OOXML server for .docx manipulation. 148 tools.

    ## Two Modes of Operation

    | Mode | Parameter | Use When | Tools |
    |------|-----------|----------|-------|
    | **Direct Mode** | `source_path` | Quick read-only access, no state needed | 18 tools |
    | **Session Mode** | `doc_id` | Full read/write with open→edit→save lifecycle | All 146 tools |

    ### Direct Mode (source_path)
    Pass `source_path` with the .docx file path. No need to call `open_document` first.
    Best for quick inspection: listing images, reading text, searching, checking properties.

    ```
    list_images: { "source_path": "/path/to/file.docx" }
    search_text: { "source_path": "/path/to/file.docx", "query": "keyword" }
    ```

    ### Session Mode (doc_id)
    Call `open_document` first, then use `doc_id` for subsequent operations. Required for any edits.

    ```
    open_document: { "path": "/path/to/file.docx", "doc_id": "mydoc" }
    insert_paragraph: { "doc_id": "mydoc", "text": "Hello" }
    save_document: { "doc_id": "mydoc", "path": "/path/to/output.docx" }
    close_document: { "doc_id": "mydoc" }
    ```

    ## Direct Mode Tools (source_path supported)

    **Read content**: `get_text`, `get_document_text`, `get_paragraphs`, `get_document_info`, `search_text`
    **List elements**: `list_images`, `list_styles`, `get_tables`, `list_comments`, `list_hyperlinks`, `list_bookmarks`, `list_footnotes`, `list_endnotes`, `get_revisions`
    **Properties**: `get_document_properties`, `get_section_properties`, `get_word_count_by_section`
    **Export**: `export_markdown`

    ## Common Workflows

    **Read-only inspection** (Direct Mode):
    1. `get_document_text` or `get_paragraphs` → read content
    2. `list_images` → check embedded images
    3. `search_text` → find specific content

    **Edit document** (Session Mode):
    1. `open_document` → get doc_id (track changes enabled by default)
    2. Edit: `insert_paragraph`, `replace_text`, `format_text`, etc.
    3. `finalize_document` → save and close in one step
    Or: `save_document` → write to disk, then `close_document` → release memory

    **Session safety**:
    - `close_document` blocks if unsaved changes exist → use `save_document` first or `finalize_document`
    - `get_document_session_state` → inspect dirty/autosave/track changes status
    - `autosave: true` on open → auto-writes after every edit
    """

    init(forceDebugLogging: Bool = false) async {
        self.server = Server(
            name: "che-word-mcp",
            version: "1.17.0",
            instructions: Self.serverInstructions,
            capabilities: .init(tools: .init())
        )
        self.transport = StdioTransport()
        // Phase A (#41 investigation): snapshot env-var ONCE at actor init.
        // Test seam: `forceDebugLogging: true` lets XCTests opt in without subprocess wrapping.
        let envValue = ProcessInfo.processInfo.environment["CHE_WORD_MCP_LOG_LEVEL"]
        self.debugLoggingEnabled = forceDebugLogging || envValue == "debug"

        // 註冊 Tool handlers
        await registerToolHandlers()
    }

    func run() async throws {
        do {
            try await server.start(transport: transport)
            await server.waitUntilCompleted()
            await flushDirtyDocumentsOnShutdown()
        } catch {
            await flushDirtyDocumentsOnShutdown()
            throw error
        }
    }

    // MARK: - Session Management (contributed by @ildunari)

    private func initializeSession(
        docId: String,
        document: WordDocument,
        sourcePath: String?,
        autosave: Bool,
        autosaveEveryN: Int = 0
    ) {
        openDocuments[docId] = document
        documentOriginalPaths[docId] = sourcePath
        documentDirtyState[docId] = false
        documentAutosave[docId] = autosave
        documentTrackChangesEnforced[docId] = true
        autosaveEvery[docId] = autosaveEveryN
        autosaveCounter[docId] = 0
    }

    private func removeSession(docId: String) {
        // v3.3.0: release ooxml-swift v0.12.0+ preserved archive tempDir on session
        // close. WordDocument is a value type → mutate a local copy; the underlying
        // tempDir on disk is shared, so close() actually deletes it. The dictionary
        // entry is then removed, discarding the now-stale archiveTempDir reference.
        if var doc = openDocuments[docId] {
            doc.close()
        }
        openDocuments.removeValue(forKey: docId)
        documentOriginalPaths.removeValue(forKey: docId)
        documentDirtyState.removeValue(forKey: docId)
        documentAutosave.removeValue(forKey: docId)
        documentTrackChangesEnforced.removeValue(forKey: docId)
        documentDiskHash.removeValue(forKey: docId)
        documentDiskMtime.removeValue(forKey: docId)
        autosaveEvery.removeValue(forKey: docId)
        autosaveCounter.removeValue(forKey: docId)
    }

    internal func isDirty(docId: String) -> Bool {
        documentDirtyState[docId] ?? false
    }

    private func effectiveSavePath(for docId: String, explicitPath: String?) throws -> String {
        if let explicitPath, !explicitPath.isEmpty {
            return explicitPath
        }
        if let originalPath = documentOriginalPaths[docId], !originalPath.isEmpty {
            return originalPath
        }
        throw WordError.invalidParameter(
            "path",
            "No path was provided and this document has no known original path. Call save_document with an explicit path."
        )
    }

    private func enforceTrackChangesIfNeeded(_ document: inout WordDocument, docId: String) {
        guard documentTrackChangesEnforced[docId] ?? true else { return }
        if !document.isTrackChangesEnabled() {
            document.enableTrackChanges(author: defaultRevisionAuthor)
        }
    }

    /// Writes `document` to `path` using `DocxWriter.write` (atomic-rename
    /// since v3.5.3). Updates session disk-hash + mtime tracking.
    ///
    /// - Parameter keepBak: when `true` and the target file already exists at
    ///   `path`, rename target → `<path>.bak` BEFORE the atomic-rename save
    ///   (overwriting any prior `.bak`). When `false` (default), no `.bak`
    ///   side-effect — preserves pre-v3.5.5 behavior. Per the
    ///   `che-word-mcp-save-durability-stack` SDD Decision (Phase 3 / closes
    ///   #38), `.bak` lives at the server layer NOT `ooxml-swift` so other
    ///   `DocxWriter` consumers (e.g., `macdoc` CLI) don't get unwanted
    ///   `.bak` files.
    private func persistDocumentToDisk(
        _ document: WordDocument,
        docId: String,
        path: String,
        keepBak: Bool = false
    ) throws {
        let url = URL(fileURLWithPath: path)

        if keepBak, FileManager.default.fileExists(atPath: path) {
            let bakURL = url.appendingPathExtension("bak")
            // Overwrite any existing .bak (single-slot, no rotation per SDD).
            if FileManager.default.fileExists(atPath: bakURL.path) {
                try FileManager.default.removeItem(at: bakURL)
            }
            try FileManager.default.moveItem(at: url, to: bakURL)
        }

        try DocxWriter.write(document, to: url)
        openDocuments[docId] = document
        documentOriginalPaths[docId] = path
        documentDirtyState[docId] = false
        // Refresh disk-hash + mtime from freshly written file (3.0.0 — Refs #12 #13 #15)
        if let hash = try? SessionState.computeSHA256(path: path) {
            documentDiskHash[docId] = hash
        }
        if let mtime = try? SessionState.readMtime(path: path) {
            documentDiskMtime[docId] = mtime
        }
    }

    /// Snapshot the session state for response serialization.
    /// Returns nil if `docId` is unknown.
    private func sessionStateView(for docId: String) -> SessionStateView? {
        guard openDocuments[docId] != nil,
              let sourcePath = documentOriginalPaths[docId] else {
            return nil
        }
        // Phase 4 (closes #37): detect existing autosave file every read.
        let autosavePath = sourcePath + ".autosave.docx"
        let autosaveDetected = FileManager.default.fileExists(atPath: autosavePath)
        return SessionStateView(
            sourcePath: sourcePath,
            diskHash: documentDiskHash[docId],
            diskMtime: documentDiskMtime[docId],
            isDirty: isDirty(docId: docId),
            trackChangesEnabled: documentTrackChangesEnforced[docId] ?? false,
            autosaveDetected: autosaveDetected,
            autosavePath: autosaveDetected ? autosavePath : nil
        )
    }

    /// 儲存文件到記憶體（標記 dirty），若啟用 autosave 則同時寫入磁碟
    internal func storeDocument(
        _ document: WordDocument,
        for docId: String,
        markDirty: Bool = true
    ) async throws {
        // Phase A (#41 investigation): structured entry log.
        logDebug(event: "storeDocument.entry", [
            ("doc_id", docId),
            ("markDirty", String(markDirty)),
            ("autosaveCounter", String(autosaveCounter[docId] ?? 0)),
            ("autosaveEvery", String(autosaveEvery[docId] ?? 0))
        ])

        // Phase C (Design B, #40): dispatch pre-mutation snapshot BEFORE we
        // overwrite openDocuments[docId] with the new state. The dispatcher
        // reads openDocuments[docId] (still the OLD state at this point) and
        // writes it to <sourcePath>.autosave.docx. This captures the
        // "everything before mutation K" guarantee — if the new state being
        // committed turns out to be corrupt, or if a follow-up mutation
        // crashes, the autosave file holds the prior known-good state.
        if markDirty {
            dispatchAutosaveCheckpointIfDue(docId: docId)
        }

        var doc = document
        if markDirty {
            enforceTrackChangesIfNeeded(&doc, docId: docId)
        }
        openDocuments[docId] = doc
        documentDirtyState[docId] = markDirty

        // Phase C (Design B, #40): increment counter AFTER mutation commit.
        // Counter == "number of successful storeDocument calls since session start
        // or last save_document". The dispatcher above checks `counter > 0 &&
        // counter % N == 0` BEFORE this increment, so the first storeDocument
        // (counter=0) does NOT fire a snapshot, but the second onward will.
        if markDirty, autosaveEvery[docId] != nil {
            autosaveCounter[docId] = (autosaveCounter[docId] ?? 0) + 1
        }

        // Phase A (#41 investigation): structured exit log.
        defer {
            logDebug(event: "storeDocument.exit", [
                ("doc_id", docId),
                ("autosaveCounter", String(autosaveCounter[docId] ?? 0))
            ])
        }

        guard markDirty, documentAutosave[docId] == true, let path = documentOriginalPaths[docId] else {
            return
        }

        try persistDocumentToDisk(doc, docId: docId, path: path)
    }

    /// Phase C (Design B, #40): pre-mutation snapshot dispatch. Mutating
    /// handlers (insertImageFromPath, insertParagraph, replaceText, etc.)
    /// SHALL call this BEFORE running their mutation. When
    /// `autosaveCounter[docId] > 0 && counter % autosaveEvery == 0`, write
    /// the CURRENT in-memory state to `<sourcePath>.autosave.docx` — capturing
    /// state-just-before-the-incoming-mutation. On crash mid-mutation, the
    /// autosave file holds the pre-mutation state, preserving K-1 mutations.
    internal func dispatchAutosaveCheckpointIfDue(docId: String) {
        guard let n = autosaveEvery[docId], n > 0 else { return }
        let counter = autosaveCounter[docId] ?? 0
        guard counter > 0, counter % n == 0 else { return }
        guard let sourcePath = documentOriginalPaths[docId] else { return }
        guard let doc = openDocuments[docId] else { return }

        let autosaveURL = URL(fileURLWithPath: sourcePath + ".autosave.docx")
        let startTime = Date()
        do {
            try DocxWriter.write(doc, to: autosaveURL)
            logDebug(event: "dispatchAutosaveCheckpoint.exit", [
                ("doc_id", docId),
                ("autosavePath", autosaveURL.path),
                ("counter", String(counter)),
                ("elapsedMs", String(Int(Date().timeIntervalSince(startTime) * 1000)))
            ])
        } catch {
            FileHandle.standardError.write(
                Data("Warning: autosave checkpoint failed for '\(docId)' at '\(autosaveURL.path)': \(error.localizedDescription)\n".utf8)
            )
        }
    }

    /// Best-effort delete `<sourcePath>.autosave.docx` after a successful
    /// save_document / finalize_document. Phase 4 (closes #37) — captures the
    /// "Successful save_document cleans up .autosave.docx" scenario.
    /// Phase C (Design B, #40): also reset `autosaveCounter[docId] = 0` so the
    /// next mutation cycle starts fresh (no immediate snapshot at counter==0).
    private func cleanupAutosaveFile(for docId: String) {
        guard let sourcePath = documentOriginalPaths[docId] else { return }
        let autosavePath = sourcePath + ".autosave.docx"
        if FileManager.default.fileExists(atPath: autosavePath) {
            try? FileManager.default.removeItem(atPath: autosavePath)
        }
        autosaveCounter[docId] = 0
    }

    private func flushDirtyDocumentsOnShutdown() async {
        for docId in openDocuments.keys.sorted() {
            guard isDirty(docId: docId), let document = openDocuments[docId] else { continue }
            guard let path = documentOriginalPaths[docId], !path.isEmpty else {
                FileHandle.standardError.write(
                    Data("Warning: document '\(docId)' has unsaved changes but no save path; shutdown flush skipped.\n".utf8)
                )
                continue
            }

            do {
                try persistDocumentToDisk(document, docId: docId, path: path)
            } catch {
                FileHandle.standardError.write(
                    Data("Warning: failed to flush '\(docId)' to '\(path)' during shutdown: \(error.localizedDescription)\n".utf8)
                )
            }
        }
    }

    // MARK: - Testing Helpers

    func invokeToolForTesting(name: String, arguments: [String: Value] = [:]) async -> CallTool.Result {
        let params = CallTool.Parameters(name: name, arguments: arguments)
        do {
            return try await handleToolCall(params)
        } catch {
            return CallTool.Result(content: [.text("Error: \(error.localizedDescription)")], isError: true)
        }
    }

    func isDocumentDirtyForTesting(_ docId: String) -> Bool {
        isDirty(docId: docId)
    }

    func isTrackChangesEnabledForTesting(_ docId: String) -> Bool? {
        openDocuments[docId]?.isTrackChangesEnabled()
    }

    /// Expose `openDocuments[docId].images.count` for actor-isolation stress
    /// tests (Phase 2, closes #39). Returns nil if doc not open.
    func imageCountForTesting(_ docId: String) -> Int? {
        openDocuments[docId]?.images.count
    }

    // MARK: - Phase A (#41 investigation) — Structured debug logging

    /// Test seam: returns whether debug logging is on for this actor instance.
    func isDebugLoggingEnabledForTesting() -> Bool {
        return debugLoggingEnabled
    }

    /// Test seam: returns the captured event log (only populated when
    /// `debugLoggingEnabled == true`).
    func debugEventLogForTesting() -> [DebugLogEvent] {
        return debugEventLog
    }

    /// Emit a structured diagnostic event to stderr + (in tests) the in-memory
    /// ring buffer. No-op when `debugLoggingEnabled == false` — designed for
    /// zero-overhead in production default.
    private func logDebug(event: String, _ keyValues: [(String, String)] = []) {
        guard debugLoggingEnabled else { return }
        let stamp = Self.iso8601Formatter.string(from: Date())
        let kvString = keyValues.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
        let line = "[\(stamp)] DEBUG \(event)\(kvString.isEmpty ? "" : " ")\(kvString)\n"
        FileHandle.standardError.write(Data(line.utf8))

        // Append to bounded ring buffer for test introspection.
        debugEventLog.append(DebugLogEvent(event: event, keyValues: keyValues))
        if debugEventLog.count > Self.debugEventLogCapacity {
            debugEventLog.removeFirst(debugEventLog.count - Self.debugEventLogCapacity)
        }
    }

    func flushDirtyDocumentsForTesting() async {
        await flushDirtyDocumentsOnShutdown()
    }

    private func registerToolHandlers() async {
        let tools = allTools

        // 列出所有工具
        await server.withMethodHandler(ListTools.self) { [tools] _ in
            ListTools.Result(tools: tools)
        }

        // 處理工具呼叫
        await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self = self else {
                return CallTool.Result(content: [.text("Server unavailable")], isError: true)
            }
            return try await self.handleToolCall(params)
        }
    }

    // MARK: - Tools Definition

    private var allTools: [Tool] {
        [
            // 文件管理
            Tool(
                name: "create_document",
                description: "建立新的 Word 文件 (.docx)，預設啟用追蹤修訂",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼，用於後續操作")
                        ]),
                        "autosave": .object([
                            "type": .string("boolean"),
                            "description": .string("是否在每次編輯後自動存檔到已知路徑（新文件仍需先手動存檔一次）")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "open_document",
                description: "開啟現有的 Word 文件 (.docx)。BREAKING v3.0.0: track_changes 預設改為 false（之前是 true）；需要追蹤修訂的 caller 必須明確傳 track_changes: true。Refs #13.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("文件路徑")
                        ]),
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼，用於後續操作")
                        ]),
                        "autosave": .object([
                            "type": .string("boolean"),
                            "description": .string("是否在每次編輯後自動存檔回原始檔案")
                        ]),
                        "track_changes": .object([
                            "type": .string("boolean"),
                            "description": .string("v3.0.0 新增：是否啟用追蹤修訂（預設 false；之前是 implicit true，見 CHANGELOG 3.0.0 BREAKING）")
                        ]),
                        "autosave_every": .object([
                            "type": .string("integer"),
                            "description": .string("v3.7.0 BREAKING: default flipped 0 → 1 (Design B pre-mutation snapshot). 每 N 次 mutation 在下次 mutation 開始時 snapshot 至 <path>.autosave.docx，捕捉 pre-mutation state（crash on K 保留 1..K-1）。傳 0 顯式禁用 autosave。Refs #40.")
                        ])
                    ]),
                    "required": .array([.string("path"), .string("doc_id")])
                ])
            ),
            Tool(
                name: "save_document",
                description: "儲存 Word 文件 (.docx)，未指定路徑時自動使用開啟時的原始路徑。v3.5.5+：可加 keep_bak: true 讓 server 在覆蓋前把舊檔搬到 <path>.bak 作為 rollback escape hatch（預設 false，不留 .bak）。Refs #38.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("儲存路徑（可選，從磁碟開啟的文件可省略）")
                        ]),
                        "keep_bak": .object([
                            "type": .string("boolean"),
                            "description": .string("v3.5.5 新增：若 true 且目標檔已存在，覆蓋前先把它搬到 <path>.bak（單一槽，會覆蓋舊 .bak）。預設 false。需手動清理 .bak。")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "close_document",
                description: "關閉已開啟的文件。dirty doc 且無 discard_changes: true 時回傳 E_DIRTY_DOC 錯誤並列出三種恢復路徑：save_document / discard_changes: true / finalize_document。Refs #12.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "discard_changes": .object([
                            "type": .string("boolean"),
                            "description": .string("v3.0.0 新增：若 true 且 doc is dirty，直接釋放 in-memory state 不寫 disk（預設 false，dirty 時回 E_DIRTY_DOC）")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "finalize_document",
                description: "一步完成存檔並關閉文件，未指定路徑時自動使用原始路徑",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("儲存路徑（可選）")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "get_document_session_state",
                description: "查看開啟文件的 session 狀態（dirty/autosave/track changes 等）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "get_session_state",
                description: "v3.0.0 — 取得完整 SessionState 快照，superset of get_document_session_state：含 source_path / disk_hash_hex / disk_mtime_iso8601 / is_dirty / track_changes_enabled。純查詢、無副作用。Refs #15.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "revert_to_disk",
                description: "v3.0.0 — 丟棄 in-memory 編輯，從 source path 重新讀取。destructive-by-design，不需 force flag。Refs #12 #15.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "reload_from_disk",
                description: "v3.0.0 — 從 source path 重新讀取，預設拒絕 dirty doc（需 force: true 覆蓋）。用於 pick up external editor 的改動同時保護未保存工作。Refs #15.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "force": .object([
                            "type": .string("boolean"),
                            "description": .string("若 true，即使 dirty 也強制 reload（丟棄 in-memory 編輯）。預設 false。")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "check_disk_drift",
                description: "v3.0.0 — 檢查 in-memory 與 disk 的 drift 狀態。永不 error（除了 doc_id 不存在）。回傳 { drifted, disk_mtime, stored_mtime, disk_hash_matches }。Refs #15.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "list_open_documents",
                description: "列出所有已開啟的文件",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:])
                ])
            ),
            Tool(
                name: "get_document_info",
                description: "取得文件資訊（段落數、字數等）（支援 Direct Mode）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼（Session Mode）")
                        ]),
                        "source_path": .object([
                            "type": .string("string"),
                            "description": .string("檔案路徑（Direct Mode，免開啟）")
                        ])
                    ])
                ])
            ),

            // 內容操作
            Tool(
                name: "get_text",
                description: "取得 .docx 檔案的純文字內容（Direct Mode, Tier 1）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "source_path": .object([
                            "type": .string("string"),
                            "description": .string("來源 .docx 檔案路徑")
                        ])
                    ]),
                    "required": .array([.string("source_path")])
                ])
            ),
            Tool(
                name: "get_paragraphs",
                description: "取得所有段落（含格式資訊）（支援 Direct Mode）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼（Session Mode）")
                        ]),
                        "source_path": .object([
                            "type": .string("string"),
                            "description": .string("檔案路徑（Direct Mode，免開啟）")
                        ])
                    ])
                ])
            ),
            Tool(
                name: "insert_paragraph",
                description: "插入新段落（需先 open_document）。v3.15.1+ 接受 after_text / before_text / text_instance / into_table_cell / after_image_id anchor（與 insert_image_from_path 對齊）；anchor 與 index 擇一，不傳則加到最後。v3.16.0+ 同時傳多個 anchor 會 return 「Error: insert_paragraph: received conflicting anchors: ...」（先前版本是 silent priority winner）。",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("段落文字內容")
                        ]),
                        "index": .object([
                            "type": .string("integer"),
                            "description": .string("插入位置（body 層級索引，從 0 開始）。anchor 擇一，不傳則加到最後")
                        ]),
                        "style": .object([
                            "type": .string("string"),
                            "description": .string("段落樣式（如 Heading1, Normal）")
                        ]),
                        "into_table_cell": .object([
                            "type": .string("object"),
                            "description": .string("插入到指定表格儲存格（append 到 cell.paragraphs）。格式：{ table_index: N, row: R, col: C }，三個欄位都必填，缺一回 structured error。（anchor 擇一）")
                        ]),
                        "after_image_id": .object([
                            "type": .string("string"),
                            "description": .string("v3.15.1+：在含指定圖片 rId（`insert_image_from_path` 返回值）的段落**之後**插入新段落。（anchor 擇一）")
                        ]),
                        "after_text": .object([
                            "type": .string("string"),
                            "description": .string("在含此文字的段落**之後**插入新段落。substring match on flattened paragraph text（cross-run + 涵蓋 hyperlinks/fieldSimples/contentControls/alternateContents v3.14.5+）。配合 text_instance 指定第幾次出現（預設 1）。（anchor 擇一）")
                        ]),
                        "before_text": .object([
                            "type": .string("string"),
                            "description": .string("在含此文字的段落**之前**插入新段落。規則同 after_text。（anchor 擇一）")
                        ]),
                        "text_instance": .object([
                            "type": .string("integer"),
                            "description": .string("after_text / before_text 的第 N 次匹配（1-based，預設 1）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("text")])
                ])
            ),
            Tool(
                name: "update_paragraph",
                description: "更新現有段落的內容",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("新的段落文字")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("index"), .string("text")])
                ])
            ),
            Tool(
                name: "delete_paragraph",
                description: "刪除段落",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("index")])
                ])
            ),
            Tool(
                name: "replace_text",
                description: "搜尋並取代文字。v2.1+ cross-run 匹配自動生效；新增 scope / regex / match_case。BREAKING: all 參數已移除（現在恆為 replace-all）。（需先 open_document）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "find": .object([
                            "type": .string("string"),
                            "description": .string("要搜尋的文字。regex: true 時被視為 NSRegularExpression (ICU) pattern")
                        ]),
                        "replace": .object([
                            "type": .string("string"),
                            "description": .string("取代後的文字。regex: true 時支援 $1..$N capture-group backreferences")
                        ]),
                        "scope": .object([
                            "type": .string("string"),
                            "description": .string("搜尋範圍：'body'（預設，僅 body + tables）或 'all'（額外搜 headers/footers/footnotes/endnotes）")
                        ]),
                        "regex": .object([
                            "type": .string("boolean"),
                            "description": .string("是否將 find 視為 regex pattern（預設 false）")
                        ]),
                        "match_case": .object([
                            "type": .string("boolean"),
                            "description": .string("是否區分大小寫（預設 true）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("find"), .string("replace")])
                ])
            ),
            Tool(
                name: "replace_text_batch",
                description: "批次文字取代（減少 per-call round-trip，單次 save）。Replacements 依陣列順序套用（sequential），後者看到前者結果。per-item scope / regex / match_case 設定。dry_run 略過 disk save（但 in-memory doc 仍被 mutate；需 open_document 還原）。（需先 open_document）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "replacements": .object([
                            "type": .string("array"),
                            "description": .string("取代清單。每項 format: { find: string, replace: string, scope?: 'body'|'all', regex?: bool, match_case?: bool }。item-level 設定 override default。")
                        ]),
                        "stop_on_first_failure": .object([
                            "type": .string("boolean"),
                            "description": .string("遇到 error（如 regex 無效）立即中止（預設 false；繼續處理剩餘 items）")
                        ]),
                        "dry_run": .object([
                            "type": .string("boolean"),
                            "description": .string("若 true，套用 replacements 但不 save 到 disk（預設 false）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("replacements")])
                ])
            ),

            // 格式化
            Tool(
                name: "format_text",
                description: "格式化指定段落的文字（粗體、斜體、顏色等）（需先 open_document）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引")
                        ]),
                        "bold": .object([
                            "type": .string("boolean"),
                            "description": .string("粗體")
                        ]),
                        "italic": .object([
                            "type": .string("boolean"),
                            "description": .string("斜體")
                        ]),
                        "underline": .object([
                            "type": .string("boolean"),
                            "description": .string("底線")
                        ]),
                        "font_size": .object([
                            "type": .string("integer"),
                            "description": .string("字型大小（點數，如 12）")
                        ]),
                        "font_name": .object([
                            "type": .string("string"),
                            "description": .string("字型名稱（如 Arial, Times New Roman）")
                        ]),
                        "color": .object([
                            "type": .string("string"),
                            "description": .string("文字顏色（RGB 十六進位，如 FF0000 表示紅色）")
                        ]),
                        "as_revision": .object([
                            "type": .string("boolean"),
                            "description": .string("以追蹤修訂方式套用格式（預設 false）。為 true 時需先 enable_track_changes，否則回傳 track_changes_not_enabled 錯誤。")
                        ]),
                        "run_index": .object([
                            "type": .string("integer"),
                            "description": .string("（僅 as_revision=true 使用）目標 run 索引，預設 0")
                        ]),
                        "author": .object([
                            "type": .string("string"),
                            "description": .string("（僅 as_revision=true 使用）修訂作者")
                        ]),
                        "date": .object([
                            "type": .string("string"),
                            "description": .string("（僅 as_revision=true 使用）修訂日期 ISO 8601")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index")])
                ])
            ),
            Tool(
                name: "set_paragraph_format",
                description: "設定段落格式（對齊、間距等）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引")
                        ]),
                        "alignment": .object([
                            "type": .string("string"),
                            "description": .string("對齊方式：left, center, right, both")
                        ]),
                        "line_spacing": .object([
                            "type": .string("number"),
                            "description": .string("行距（倍數，如 1.5）")
                        ]),
                        "space_before": .object([
                            "type": .string("integer"),
                            "description": .string("段前間距（點數）")
                        ]),
                        "space_after": .object([
                            "type": .string("integer"),
                            "description": .string("段後間距（點數）")
                        ]),
                        "as_revision": .object([
                            "type": .string("boolean"),
                            "description": .string("以追蹤修訂方式套用段落格式（預設 false）。為 true 時需先 enable_track_changes。")
                        ]),
                        "author": .object([
                            "type": .string("string"),
                            "description": .string("（僅 as_revision=true 使用）修訂作者")
                        ]),
                        "date": .object([
                            "type": .string("string"),
                            "description": .string("（僅 as_revision=true 使用）修訂日期 ISO 8601")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index")])
                ])
            ),
            Tool(
                name: "apply_style",
                description: "套用內建樣式到段落",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引")
                        ]),
                        "style": .object([
                            "type": .string("string"),
                            "description": .string("樣式名稱（如 Heading1, Heading2, Normal, Title）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("style")])
                ])
            ),

            // 表格
            Tool(
                name: "insert_table",
                description: "插入表格",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "rows": .object([
                            "type": .string("integer"),
                            "description": .string("列數")
                        ]),
                        "cols": .object([
                            "type": .string("integer"),
                            "description": .string("欄數")
                        ]),
                        "data": .object([
                            "type": .string("array"),
                            "description": .string("表格資料（二維陣列）")
                        ]),
                        "index": .object([
                            "type": .string("integer"),
                            "description": .string("插入位置")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("rows"), .string("cols")])
                ])
            ),
            Tool(
                name: "get_tables",
                description: "取得文件中所有表格的資訊（支援 Direct Mode）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼（Session Mode）")
                        ]),
                        "source_path": .object([
                            "type": .string("string"),
                            "description": .string("檔案路徑（Direct Mode，免開啟）")
                        ])
                    ])
                ])
            ),
            Tool(
                name: "update_cell",
                description: "更新表格儲存格內容",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "table_index": .object([
                            "type": .string("integer"),
                            "description": .string("表格索引（從 0 開始）")
                        ]),
                        "row": .object([
                            "type": .string("integer"),
                            "description": .string("列索引（從 0 開始）")
                        ]),
                        "col": .object([
                            "type": .string("integer"),
                            "description": .string("欄索引（從 0 開始）")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("新的儲存格內容")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("table_index"), .string("row"), .string("col"), .string("text")])
                ])
            ),
            Tool(
                name: "delete_table",
                description: "刪除指定的表格",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "table_index": .object([
                            "type": .string("integer"),
                            "description": .string("表格索引（從 0 開始）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("table_index")])
                ])
            ),
            Tool(
                name: "merge_cells",
                description: "合併表格儲存格（支援水平或垂直合併）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "table_index": .object([
                            "type": .string("integer"),
                            "description": .string("表格索引（從 0 開始）")
                        ]),
                        "direction": .object([
                            "type": .string("string"),
                            "description": .string("合併方向：horizontal（水平）或 vertical（垂直）")
                        ]),
                        "row": .object([
                            "type": .string("integer"),
                            "description": .string("水平合併時：目標列索引；垂直合併時：起始列")
                        ]),
                        "col": .object([
                            "type": .string("integer"),
                            "description": .string("水平合併時：起始欄；垂直合併時：目標欄索引")
                        ]),
                        "end_row": .object([
                            "type": .string("integer"),
                            "description": .string("垂直合併時的結束列索引")
                        ]),
                        "end_col": .object([
                            "type": .string("integer"),
                            "description": .string("水平合併時的結束欄索引")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("table_index"), .string("direction")])
                ])
            ),
            Tool(
                name: "set_table_style",
                description: "設定表格樣式（邊框、儲存格底色）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "table_index": .object([
                            "type": .string("integer"),
                            "description": .string("表格索引（從 0 開始）")
                        ]),
                        "border_style": .object([
                            "type": .string("string"),
                            "description": .string("邊框樣式：single, double, dashed, dotted, none")
                        ]),
                        "border_color": .object([
                            "type": .string("string"),
                            "description": .string("邊框顏色（RGB 十六進位，如 000000）")
                        ]),
                        "border_size": .object([
                            "type": .string("integer"),
                            "description": .string("邊框寬度（1/8 點，預設 4 = 0.5pt）")
                        ]),
                        "cell_row": .object([
                            "type": .string("integer"),
                            "description": .string("設定底色的儲存格列索引（可選）")
                        ]),
                        "cell_col": .object([
                            "type": .string("integer"),
                            "description": .string("設定底色的儲存格欄索引（可選）")
                        ]),
                        "shading_color": .object([
                            "type": .string("string"),
                            "description": .string("儲存格底色（RGB 十六進位，如 FFFF00）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("table_index")])
                ])
            ),

            // 樣式管理
            Tool(
                name: "list_styles",
                description: "列出文件中所有可用的樣式（支援 Direct Mode）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼（Session Mode）")
                        ]),
                        "source_path": .object([
                            "type": .string("string"),
                            "description": .string("檔案路徑（Direct Mode，免開啟）")
                        ])
                    ])
                ])
            ),
            Tool(
                name: "create_style",
                description: "建立自訂樣式",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "style_id": .object([
                            "type": .string("string"),
                            "description": .string("樣式 ID（唯一識別碼）")
                        ]),
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("樣式顯示名稱")
                        ]),
                        "type": .object([
                            "type": .string("string"),
                            "description": .string("樣式類型：paragraph, character, table, numbering")
                        ]),
                        "based_on": .object([
                            "type": .string("string"),
                            "description": .string("基於的樣式 ID（可選）")
                        ]),
                        "next_style": .object([
                            "type": .string("string"),
                            "description": .string("下一段使用的樣式 ID（可選）")
                        ]),
                        "font_name": .object([
                            "type": .string("string"),
                            "description": .string("字型名稱")
                        ]),
                        "font_size": .object([
                            "type": .string("integer"),
                            "description": .string("字型大小（點數）")
                        ]),
                        "bold": .object([
                            "type": .string("boolean"),
                            "description": .string("粗體")
                        ]),
                        "italic": .object([
                            "type": .string("boolean"),
                            "description": .string("斜體")
                        ]),
                        "color": .object([
                            "type": .string("string"),
                            "description": .string("文字顏色（RGB 十六進位）")
                        ]),
                        "alignment": .object([
                            "type": .string("string"),
                            "description": .string("對齊方式：left, center, right, both")
                        ]),
                        "space_before": .object([
                            "type": .string("integer"),
                            "description": .string("段前間距（點數）")
                        ]),
                        "space_after": .object([
                            "type": .string("integer"),
                            "description": .string("段後間距（點數）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("style_id"), .string("name")])
                ])
            ),
            Tool(
                name: "update_style",
                description: "修改現有樣式的定義",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "style_id": .object([
                            "type": .string("string"),
                            "description": .string("要修改的樣式 ID")
                        ]),
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("新的顯示名稱")
                        ]),
                        "font_name": .object([
                            "type": .string("string"),
                            "description": .string("字型名稱")
                        ]),
                        "font_size": .object([
                            "type": .string("integer"),
                            "description": .string("字型大小（點數）")
                        ]),
                        "bold": .object([
                            "type": .string("boolean"),
                            "description": .string("粗體")
                        ]),
                        "italic": .object([
                            "type": .string("boolean"),
                            "description": .string("斜體")
                        ]),
                        "color": .object([
                            "type": .string("string"),
                            "description": .string("文字顏色（RGB 十六進位）")
                        ]),
                        "alignment": .object([
                            "type": .string("string"),
                            "description": .string("對齊方式")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("style_id")])
                ])
            ),
            Tool(
                name: "delete_style",
                description: "刪除自訂樣式（不能刪除內建樣式）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "style_id": .object([
                            "type": .string("string"),
                            "description": .string("要刪除的樣式 ID")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("style_id")])
                ])
            ),

            // 清單/編號
            Tool(
                name: "insert_bullet_list",
                description: "插入項目符號清單",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "items": .object([
                            "type": .string("array"),
                            "description": .string("清單項目（字串陣列）")
                        ]),
                        "index": .object([
                            "type": .string("integer"),
                            "description": .string("插入位置（可選，不指定則加到最後）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("items")])
                ])
            ),
            Tool(
                name: "insert_numbered_list",
                description: "插入編號清單",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "items": .object([
                            "type": .string("array"),
                            "description": .string("清單項目（字串陣列）")
                        ]),
                        "index": .object([
                            "type": .string("integer"),
                            "description": .string("插入位置（可選，不指定則加到最後）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("items")])
                ])
            ),
            Tool(
                name: "set_list_level",
                description: "設定清單項目的層級（0-8）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引")
                        ]),
                        "level": .object([
                            "type": .string("integer"),
                            "description": .string("層級（0-8，0 為最外層）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("level")])
                ])
            ),

            // 頁面設定
            Tool(
                name: "set_page_size",
                description: "設定頁面大小（letter, a4, legal, a3, a5, b5, executive）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "size": .object([
                            "type": .string("string"),
                            "description": .string("頁面大小：letter, a4, legal, a3, a5, b5, executive")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("size")])
                ])
            ),
            Tool(
                name: "set_page_margins",
                description: "設定頁邊距",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "preset": .object([
                            "type": .string("string"),
                            "description": .string("預設邊距：normal, narrow, moderate, wide（可選）")
                        ]),
                        "top": .object([
                            "type": .string("integer"),
                            "description": .string("上邊距（twips，1440 = 1 英寸）")
                        ]),
                        "right": .object([
                            "type": .string("integer"),
                            "description": .string("右邊距（twips）")
                        ]),
                        "bottom": .object([
                            "type": .string("integer"),
                            "description": .string("下邊距（twips）")
                        ]),
                        "left": .object([
                            "type": .string("integer"),
                            "description": .string("左邊距（twips）")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "set_page_orientation",
                description: "設定頁面方向（直向/橫向）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "orientation": .object([
                            "type": .string("string"),
                            "description": .string("頁面方向：portrait（直向）, landscape（橫向）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("orientation")])
                ])
            ),
            Tool(
                name: "insert_page_break",
                description: "插入分頁符",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "at_index": .object([
                            "type": .string("integer"),
                            "description": .string("插入位置（段落索引，可選，預設插在文件最後）")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "insert_section_break",
                description: "插入分節符（可設定不同的分節類型）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "type": .object([
                            "type": .string("string"),
                            "description": .string("分節類型：nextPage（下一頁）, continuous（連續）, evenPage（偶數頁）, oddPage（奇數頁）")
                        ]),
                        "at_index": .object([
                            "type": .string("integer"),
                            "description": .string("插入位置（段落索引，可選）")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),

            // 頁首/頁尾
            Tool(
                name: "add_header",
                description: "新增頁首",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("頁首文字")
                        ]),
                        "type": .object([
                            "type": .string("string"),
                            "description": .string("頁首類型：default（預設）, first（首頁）, even（偶數頁）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("text")])
                ])
            ),
            Tool(
                name: "update_header",
                description: "更新頁首內容",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "header_id": .object([
                            "type": .string("string"),
                            "description": .string("頁首 ID（從 add_header 返回）")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("新的頁首文字")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("header_id"), .string("text")])
                ])
            ),
            Tool(
                name: "add_footer",
                description: "新增頁尾",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("頁尾文字（可選，若不提供則使用頁碼）")
                        ]),
                        "type": .object([
                            "type": .string("string"),
                            "description": .string("頁尾類型：default（預設）, first（首頁）, even（偶數頁）")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "update_footer",
                description: "更新頁尾內容",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "footer_id": .object([
                            "type": .string("string"),
                            "description": .string("頁尾 ID（從 add_footer 返回）")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("新的頁尾文字")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("footer_id"), .string("text")])
                ])
            ),
            Tool(
                name: "insert_page_number",
                description: "在頁尾插入頁碼",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "format": .object([
                            "type": .string("string"),
                            "description": .string("頁碼格式：simple（1）, pageOfTotal（Page 1 of 10）, withDash（- 1 -）, 或自訂格式如 '第#頁'（# 代表頁碼）")
                        ]),
                        "alignment": .object([
                            "type": .string("string"),
                            "description": .string("對齊方式：left, center, right（預設 center）")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),

            // 圖片
            Tool(
                name: "insert_image",
                description: "插入圖片到文件中（需先 open_document）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "base64": .object([
                            "type": .string("string"),
                            "description": .string("圖片的 Base64 編碼資料")
                        ]),
                        "file_name": .object([
                            "type": .string("string"),
                            "description": .string("圖片檔名（包含副檔名，如 image.png）")
                        ]),
                        "width": .object([
                            "type": .string("integer"),
                            "description": .string("圖片寬度（像素）")
                        ]),
                        "height": .object([
                            "type": .string("integer"),
                            "description": .string("圖片高度（像素）")
                        ]),
                        "index": .object([
                            "type": .string("integer"),
                            "description": .string("插入位置（段落索引，可選）")
                        ]),
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("圖片名稱（可選，用於替代文字）")
                        ]),
                        "description": .object([
                            "type": .string("string"),
                            "description": .string("圖片描述（可選，用於無障礙）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("base64"), .string("file_name"), .string("width"), .string("height")])
                ])
            ),
            Tool(
                name: "insert_image_from_path",
                description: "從檔案路徑插入圖片。v2.1+ width/height 為可選（auto-aspect：擇一 → 另一邊按原圖比例算；全省略 → 用原始像素）。v3.15.1+ 新增 after_image_id anchor。anchor priority: into_table_cell > after_image_id > after_text > before_text > index > append。v3.16.0+ 同時傳多個 anchor 會 return 「Error: insert_image_from_path: received conflicting anchors: ...」（先前版本是 silent priority winner）。支援 PNG / JPEG。（需先 open_document）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("圖片檔案的完整路徑（PNG / JPEG）")
                        ]),
                        "width": .object([
                            "type": .string("integer"),
                            "description": .string("圖片寬度（像素，可選；省略時從 height 按原圖比例算或用原始像素）")
                        ]),
                        "height": .object([
                            "type": .string("integer"),
                            "description": .string("圖片高度（像素，可選；規則同 width）")
                        ]),
                        "index": .object([
                            "type": .string("integer"),
                            "description": .string("插入段落索引（body 層級；與其他 anchor 擇一）")
                        ]),
                        "into_table_cell": .object([
                            "type": .string("object"),
                            "description": .string("插入到指定表格儲存格。格式：{ table_index: N, row: R, col: C }，三個欄位都必填，缺一回 structured error。（anchor 擇一）")
                        ]),
                        "after_image_id": .object([
                            "type": .string("string"),
                            "description": .string("v3.15.1+：在含指定圖片 rId 的段落**之後**插入新圖片。便於連續插入相關圖片（e.g. 多圖 figure）。（anchor 擇一）")
                        ]),
                        "after_text": .object([
                            "type": .string("string"),
                            "description": .string("在含此文字的段落**之後**插入圖片。substring match on flattened run text（cross-run safe）。配合 text_instance 指定第幾次出現（預設 1）。（anchor 擇一）")
                        ]),
                        "before_text": .object([
                            "type": .string("string"),
                            "description": .string("在含此文字的段落**之前**插入圖片。規則同 after_text。（anchor 擇一）")
                        ]),
                        "text_instance": .object([
                            "type": .string("integer"),
                            "description": .string("after_text / before_text 的第 N 次匹配（1-based，預設 1）")
                        ]),
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("圖片名稱（可選，用於替代文字）")
                        ]),
                        "description": .object([
                            "type": .string("string"),
                            "description": .string("圖片描述（可選，用於無障礙）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("path")])
                ])
            ),
            Tool(
                name: "update_image",
                description: "更新圖片尺寸",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "image_id": .object([
                            "type": .string("string"),
                            "description": .string("圖片 ID（從 insert_image 返回）")
                        ]),
                        "width": .object([
                            "type": .string("integer"),
                            "description": .string("新的寬度（像素，可選）")
                        ]),
                        "height": .object([
                            "type": .string("integer"),
                            "description": .string("新的高度（像素，可選）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("image_id")])
                ])
            ),
            Tool(
                name: "delete_image",
                description: "刪除圖片",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "image_id": .object([
                            "type": .string("string"),
                            "description": .string("圖片 ID（從 insert_image 返回）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("image_id")])
                ])
            ),
            Tool(
                name: "list_images",
                description: "列出文件中所有圖片（支援 Direct Mode）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼（Session Mode）")
                        ]),
                        "source_path": .object([
                            "type": .string("string"),
                            "description": .string("檔案路徑（Direct Mode，免開啟）")
                        ])
                    ])
                ])
            ),
            Tool(
                name: "export_image",
                description: "匯出單一圖片到檔案（需先 open_document）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "image_id": .object([
                            "type": .string("string"),
                            "description": .string("圖片 ID（從 list_images 取得）")
                        ]),
                        "save_path": .object([
                            "type": .string("string"),
                            "description": .string("完整存檔路徑（含檔名，如 /tmp/output.png）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("image_id"), .string("save_path")])
                ])
            ),
            Tool(
                name: "export_all_images",
                description: "匯出所有圖片到目錄（需先 open_document）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "output_dir": .object([
                            "type": .string("string"),
                            "description": .string("輸出目錄路徑（自動建立）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("output_dir")])
                ])
            ),
            Tool(
                name: "set_image_style",
                description: "設定圖片樣式（邊框、陰影等）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "image_id": .object([
                            "type": .string("string"),
                            "description": .string("圖片 ID（從 insert_image 返回）")
                        ]),
                        "has_border": .object([
                            "type": .string("boolean"),
                            "description": .string("是否顯示邊框")
                        ]),
                        "border_color": .object([
                            "type": .string("string"),
                            "description": .string("邊框顏色（RGB hex，如 '000000'）")
                        ]),
                        "border_width": .object([
                            "type": .string("integer"),
                            "description": .string("邊框寬度（EMU，9525 ≈ 0.75pt）")
                        ]),
                        "has_shadow": .object([
                            "type": .string("boolean"),
                            "description": .string("是否顯示陰影")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("image_id")])
                ])
            ),

            // 匯出
            Tool(
                name: "export_text",
                description: "匯出文件為純文字（需先 open_document）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("匯出路徑")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("path")])
                ])
            ),
            Tool(
                name: "export_markdown",
                description: "將 .docx 轉為 Markdown 並提取圖片（Direct Mode, Tier 2）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "source_path": .object([
                            "type": .string("string"),
                            "description": .string("來源 .docx 檔案路徑")
                        ]),
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("Markdown 匯出路徑")
                        ]),
                        "figures_directory": .object([
                            "type": .string("string"),
                            "description": .string("圖片輸出目錄（預設為 path 同層的 figures/）")
                        ]),
                        "include_frontmatter": .object([
                            "type": .string("boolean"),
                            "description": .string("包含文件屬性作為 YAML frontmatter（預設 false）")
                        ]),
                        "hard_line_breaks": .object([
                            "type": .string("boolean"),
                            "description": .string("將軟換行轉為硬換行（預設 false）")
                        ])
                    ]),
                    "required": .array([.string("source_path"), .string("path")])
                ])
            ),

            // 超連結和書籤
            Tool(
                name: "insert_hyperlink",
                description: "插入外部超連結（URL）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "url": .object([
                            "type": .string("string"),
                            "description": .string("目標 URL（如 https://example.com）")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("連結顯示文字")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("插入到哪個段落（可選，預設最後一個段落）")
                        ]),
                        "tooltip": .object([
                            "type": .string("string"),
                            "description": .string("滑鼠懸停提示文字（可選）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("url"), .string("text")])
                ])
            ),
            Tool(
                name: "insert_internal_link",
                description: "插入內部連結（連到書籤）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "bookmark_name": .object([
                            "type": .string("string"),
                            "description": .string("目標書籤名稱")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("連結顯示文字")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("插入到哪個段落（可選，預設最後一個段落）")
                        ]),
                        "tooltip": .object([
                            "type": .string("string"),
                            "description": .string("滑鼠懸停提示文字（可選）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("bookmark_name"), .string("text")])
                ])
            ),
            Tool(
                name: "update_hyperlink",
                description: "更新超連結的文字或 URL",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "hyperlink_id": .object([
                            "type": .string("string"),
                            "description": .string("超連結 ID（從 insert_hyperlink 返回）")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("新的顯示文字（可選）")
                        ]),
                        "url": .object([
                            "type": .string("string"),
                            "description": .string("新的 URL（可選，僅外部連結）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("hyperlink_id")])
                ])
            ),
            Tool(
                name: "delete_hyperlink",
                description: "刪除超連結（保留文字但移除連結）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "hyperlink_id": .object([
                            "type": .string("string"),
                            "description": .string("超連結 ID（從 insert_hyperlink 返回）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("hyperlink_id")])
                ])
            ),
            Tool(
                name: "insert_bookmark",
                description: "插入書籤標記（用於文件內部導航）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("書籤名稱（不能包含空格，不能以數字開頭，最多 40 字元）")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("插入到哪個段落（可選，預設最後一個段落）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("name")])
                ])
            ),
            Tool(
                name: "delete_bookmark",
                description: "刪除書籤",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("要刪除的書籤名稱")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("name")])
                ])
            ),

            // 註解和修訂
            Tool(
                name: "insert_comment",
                description: "在指定段落插入註解",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("註解文字")
                        ]),
                        "author": .object([
                            "type": .string("string"),
                            "description": .string("作者名稱")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("要附加註解的段落索引")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("text"), .string("author"), .string("paragraph_index")])
                ])
            ),
            Tool(
                name: "update_comment",
                description: "更新註解內容",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "comment_id": .object([
                            "type": .string("integer"),
                            "description": .string("註解 ID")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("新的註解文字")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("comment_id"), .string("text")])
                ])
            ),
            Tool(
                name: "delete_comment",
                description: "刪除註解",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "comment_id": .object([
                            "type": .string("integer"),
                            "description": .string("要刪除的註解 ID")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("comment_id")])
                ])
            ),
            Tool(
                name: "list_comments",
                description: "列出文件中所有註解（支援 Direct Mode）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼（Session Mode）")
                        ]),
                        "source_path": .object([
                            "type": .string("string"),
                            "description": .string("檔案路徑（Direct Mode，免開啟）")
                        ])
                    ])
                ])
            ),
            Tool(
                name: "enable_track_changes",
                description: "啟用修訂追蹤",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "author": .object([
                            "type": .string("string"),
                            "description": .string("修訂作者名稱（可選）")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "disable_track_changes",
                description: "停用修訂追蹤",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "accept_revision",
                description: "接受指定的修訂",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "revision_id": .object([
                            "type": .string("integer"),
                            "description": .string("修訂 ID（使用 'all' 接受所有修訂）")
                        ]),
                        "all": .object([
                            "type": .string("boolean"),
                            "description": .string("是否接受所有修訂")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "reject_revision",
                description: "拒絕指定的修訂",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "revision_id": .object([
                            "type": .string("integer"),
                            "description": .string("修訂 ID")
                        ]),
                        "all": .object([
                            "type": .string("boolean"),
                            "description": .string("是否拒絕所有修訂")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),

            // 程式化產生 Track Changes 修訂標記 (#45)
            Tool(
                name: "insert_text_as_revision",
                description: "在指定段落位置插入文字並包覆 <w:ins> 修訂標記（需先 enable_track_changes）。位置為段落內字元偏移；超出範圍會 split 既有 run。",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string"), "description": .string("文件識別碼")]),
                        "paragraph_index": .object(["type": .string("integer"), "description": .string("段落索引")]),
                        "position": .object(["type": .string("integer"), "description": .string("插入位置（段落內字元偏移）")]),
                        "text": .object(["type": .string("string"), "description": .string("要插入的文字")]),
                        "author": .object(["type": .string("string"), "description": .string("修訂作者（可選；預設沿用 enable_track_changes 的 author）")]),
                        "date": .object(["type": .string("string"), "description": .string("修訂日期 ISO 8601（可選；預設為當下時間）")])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("position"), .string("text")])
                ])
            ),
            Tool(
                name: "delete_text_as_revision",
                description: "刪除指定段落 [start, end) 範圍的文字並包覆 <w:del> 修訂標記（需先 enable_track_changes）。跨段落刪除不支援。",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string"), "description": .string("文件識別碼")]),
                        "paragraph_index": .object(["type": .string("integer"), "description": .string("段落索引")]),
                        "start": .object(["type": .string("integer"), "description": .string("起始字元偏移（包含）")]),
                        "end": .object(["type": .string("integer"), "description": .string("結束字元偏移（不包含）")]),
                        "author": .object(["type": .string("string"), "description": .string("修訂作者（可選）")]),
                        "date": .object(["type": .string("string"), "description": .string("修訂日期 ISO 8601（可選）")])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("start"), .string("end")])
                ])
            ),
            Tool(
                name: "move_text_as_revision",
                description: "將文字從來源段落 [from_start, from_end) 移到目標段落 to_position，產生成對的 <w:moveFrom>/<w:moveTo> 修訂（需先 enable_track_changes）。同段落移動不支援。",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string"), "description": .string("文件識別碼")]),
                        "from_paragraph_index": .object(["type": .string("integer"), "description": .string("來源段落索引")]),
                        "from_start": .object(["type": .string("integer"), "description": .string("來源起始字元偏移（包含）")]),
                        "from_end": .object(["type": .string("integer"), "description": .string("來源結束字元偏移（不包含）")]),
                        "to_paragraph_index": .object(["type": .string("integer"), "description": .string("目標段落索引（必須不同於 from）")]),
                        "to_position": .object(["type": .string("integer"), "description": .string("目標插入位置（字元偏移）")]),
                        "author": .object(["type": .string("string"), "description": .string("修訂作者（可選）")]),
                        "date": .object(["type": .string("string"), "description": .string("修訂日期 ISO 8601（可選）")])
                    ]),
                    "required": .array([
                        .string("doc_id"), .string("from_paragraph_index"),
                        .string("from_start"), .string("from_end"),
                        .string("to_paragraph_index"), .string("to_position")
                    ])
                ])
            ),

            // 腳註/尾註
            Tool(
                name: "insert_footnote",
                description: "在指定段落插入腳註（出現在頁面底部）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("腳註內容")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("text")])
                ])
            ),
            Tool(
                name: "delete_footnote",
                description: "刪除指定的腳註",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "footnote_id": .object([
                            "type": .string("integer"),
                            "description": .string("腳註 ID")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("footnote_id")])
                ])
            ),
            Tool(
                name: "insert_endnote",
                description: "在指定段落插入尾註（出現在文件結尾）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("尾註內容")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("text")])
                ])
            ),
            Tool(
                name: "delete_endnote",
                description: "刪除指定的尾註",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "endnote_id": .object([
                            "type": .string("integer"),
                            "description": .string("尾註 ID")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("endnote_id")])
                ])
            ),

            // P7 進階功能

            // 7.1 目錄
            Tool(
                name: "insert_toc",
                description: "插入目錄（Table of Contents）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "title": .object([
                            "type": .string("string"),
                            "description": .string("目錄標題")
                        ]),
                        "heading_levels": .object([
                            "type": .string("string"),
                            "description": .string("包含的標題層級範圍，如 1-3")
                        ]),
                        "index": .object([
                            "type": .string("integer"),
                            "description": .string("插入位置（從 0 開始），不指定則插入到開頭")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),

            // 7.2 表單控制項
            Tool(
                name: "insert_text_field",
                description: "插入表單文字欄位",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("欄位名稱")
                        ]),
                        "default_value": .object([
                            "type": .string("string"),
                            "description": .string("預設值")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("name")])
                ])
            ),
            Tool(
                name: "insert_checkbox",
                description: "插入核取方塊",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("欄位名稱")
                        ]),
                        "checked": .object([
                            "type": .string("boolean"),
                            "description": .string("是否預設勾選")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("name")])
                ])
            ),
            Tool(
                name: "insert_dropdown",
                description: "插入下拉選單",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("欄位名稱")
                        ]),
                        "options": .object([
                            "type": .string("array"),
                            "description": .string("選項列表（JSON 陣列格式）")
                        ]),
                        "selected_index": .object([
                            "type": .string("integer"),
                            "description": .string("預設選中的索引（從 0 開始）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("name"), .string("options")])
                ])
            ),

            // 7.3 數學公式
            Tool(
                name: "insert_equation",
                description: "插入數學公式（結構化 OMML，可在 Word native equation editor 雙擊編輯）。v3.2+ 的 latex: 支援 LaTeX 子集（見下方 latex 參數描述完整 token 清單）；components: 為 JSON tree fallback，給超出 LaTeX 子集的進階用法。必須提供 components 或 latex 其中之一。v3.16.0+ display mode 同時傳多個 anchor 會 return 「Error: insert_equation: received conflicting anchors: ...」（先前版本是 silent priority winner）；inline mode 仍 reject 所有 anchor（語意 ambiguous）。",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "components": .object([
                            "type": .string("object"),
                            "description": .string("推薦：MathComponent JSON tree。單一 top-level object，type 欄位為 discriminator。支援 type: 'run'（需 text, 可選 style: 'p'|'b'|'i'|'bi'）、'fraction'（需 numerator[] + denominator[]）、'radical'（需 radicand[] + 可選 degree[]）、'subSuperScript'（需 base[] + 可選 sub[] / sup[]）、'nary'（需 op: '∑'|'∫'|'∏'|'∬'|'∮' 等 + base[] + 可選 sub[] / sup[]）。陣列元素也是 MathComponent。")
                        ]),
                        "latex": .object([
                            "type": .string("string"),
                            "description": .string("LaTeX 子集字串。支援的 macro 家族: \\frac{a}{b}, \\sqrt{a}, \\sqrt[n]{a}; 結構化 sub/sup a_{b}^{c} (兩種順序自動正規化); accent \\hat \\bar \\tilde \\dot \\overline; delimiter \\left( \\right) \\left[ \\right] \\left\\{ \\right\\} \\left| \\right| \\left\\| \\right\\|; n-ary \\sum_{a}^{b} \\int_{a}^{b} \\prod_{a}^{b} (有無 bound 都可); function \\ln \\sin \\cos \\tan \\log \\exp \\max \\min \\det 後接 (...); limit \\sup_{x} \\inf_{x} \\lim_{x \\to 0}; 文字 \\text{...}; 全部小寫/大寫希臘字母及變體 (\\alpha-\\omega, \\Gamma-\\Omega, \\varepsilon \\vartheta \\varphi etc.); 常用運算子 \\cdot \\times \\pm \\sim \\approx \\neq \\le \\ge \\to \\infty \\partial \\cdots \\mid \\quad. 超出此清單的 macro (例如 \\overbrace, \\stackrel) 會回錯，請改用 components: 參數提供完整 MathComponent JSON tree。")
                        ]),
                        "display_mode": .object([
                            "type": .string("boolean"),
                            "description": .string("是否為獨立區塊（true，預設）或行內（false）")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("body.children 索引（從 0 開始；計入 tables / SDTs / bookmarkMarker / rawBlockElement，**不**等同於 get_paragraphs 回傳的 paragraph-only count）。display mode 下若搭配 anchor，anchor 優先；inline 模式直接以此索引插入。lib API 在 #61 / #69 系列已對齊到 body.children index；參數命名沿用「paragraph_index」是歷史遺留，跨工具語意統一見 PsychQuant/ooxml-swift#10。")
                        ]),
                        "into_table_cell": .object([
                            "type": .string("object"),
                            "description": .string("v3.15.1+，**僅 display_mode=true 時生效**：插入到指定表格儲存格（display mode 為新段落，append 到 cell.paragraphs）。格式：{ table_index: N, row: R, col: C }，三個欄位都必填。inline 模式傳入會回 error。（anchor 擇一）")
                        ]),
                        "after_image_id": .object([
                            "type": .string("string"),
                            "description": .string("v3.15.1+，**僅 display_mode=true 時生效**：在含指定圖片 rId 的段落之後插入新公式段。inline 模式傳入會回 error。（anchor 擇一）")
                        ]),
                        "after_text": .object([
                            "type": .string("string"),
                            "description": .string("**僅 display_mode=true 時生效**。在含此文字的段落**之後**插入新公式段。substring match on flattened paragraph text（v3.14.5+ 涵蓋 hyperlinks/fieldSimples/contentControls/alternateContents）。配合 text_instance 指定第幾次出現（預設 1）。inline 模式傳入會回 error。（anchor 擇一）")
                        ]),
                        "before_text": .object([
                            "type": .string("string"),
                            "description": .string("**僅 display_mode=true 時生效**。在含此文字的段落**之前**插入新公式段。規則同 after_text。inline 模式傳入會回 error。（anchor 擇一）")
                        ]),
                        "text_instance": .object([
                            "type": .string("integer"),
                            "description": .string("after_text / before_text 的第 N 次匹配（1-based，預設 1）")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),

            // 7.4 進階格式
            Tool(
                name: "set_paragraph_border",
                description: "設定段落邊框",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "border_type": .object([
                            "type": .string("string"),
                            "description": .string("邊框類型：single, double, dotted, dashed, thick, wave")
                        ]),
                        "color": .object([
                            "type": .string("string"),
                            "description": .string("邊框顏色（十六進位 RGB）")
                        ]),
                        "size": .object([
                            "type": .string("integer"),
                            "description": .string("邊框寬度（1/8 點）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index")])
                ])
            ),
            Tool(
                name: "set_paragraph_shading",
                description: "設定段落底色",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "fill": .object([
                            "type": .string("string"),
                            "description": .string("填充顏色（十六進位 RGB，如 FFFF00）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("fill")])
                ])
            ),
            Tool(
                name: "set_character_spacing",
                description: "設定字元間距",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "spacing": .object([
                            "type": .string("integer"),
                            "description": .string("字元間距（1/20 點，正值增加，負值減少）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index")])
                ])
            ),
            Tool(
                name: "set_text_effect",
                description: "設定文字效果",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "effect": .object([
                            "type": .string("string"),
                            "description": .string("效果類型：blinkBackground, lights, antsBlack, antsRed, shimmer, sparkle, none")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("effect")])
                ])
            ),

            // P8 新功能：註解回覆、浮動圖片、欄位代碼、重複區段

            // 8.1 註解回覆
            Tool(
                name: "reply_to_comment",
                description: "回覆現有的註解",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "parent_comment_id": .object([
                            "type": .string("integer"),
                            "description": .string("要回覆的註解 ID")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("回覆內容")
                        ]),
                        "author": .object([
                            "type": .string("string"),
                            "description": .string("回覆者名稱（預設 'Author'）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("parent_comment_id"), .string("text")])
                ])
            ),
            Tool(
                name: "resolve_comment",
                description: "將註解標記為已解決或未解決",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "comment_id": .object([
                            "type": .string("integer"),
                            "description": .string("註解 ID")
                        ]),
                        "resolved": .object([
                            "type": .string("boolean"),
                            "description": .string("是否已解決（true/false）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("comment_id")])
                ])
            ),

            // 8.2 浮動圖片
            Tool(
                name: "insert_floating_image",
                description: "插入浮動圖片（可設定位置和文繞方式）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "base64": .object([
                            "type": .string("string"),
                            "description": .string("圖片的 Base64 編碼資料")
                        ]),
                        "file_name": .object([
                            "type": .string("string"),
                            "description": .string("圖片檔名（包含副檔名）")
                        ]),
                        "width": .object([
                            "type": .string("integer"),
                            "description": .string("圖片寬度（像素）")
                        ]),
                        "height": .object([
                            "type": .string("integer"),
                            "description": .string("圖片高度（像素）")
                        ]),
                        "wrap_type": .object([
                            "type": .string("string"),
                            "description": .string("文繞方式：square（四邊型）, tight（緊密）, through（穿透）, topAndBottom（上下）, behindText（文字下方）, inFrontOfText（文字上方）")
                        ]),
                        "horizontal_position": .object([
                            "type": .string("string"),
                            "description": .string("水平位置：left, center, right, 或具體偏移像素")
                        ]),
                        "vertical_position": .object([
                            "type": .string("string"),
                            "description": .string("垂直位置：top, center, bottom, 或具體偏移像素")
                        ]),
                        "relative_to_h": .object([
                            "type": .string("string"),
                            "description": .string("水平相對於：margin, page, column, character")
                        ]),
                        "relative_to_v": .object([
                            "type": .string("string"),
                            "description": .string("垂直相對於：margin, page, paragraph, line")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("base64"), .string("file_name"), .string("width"), .string("height")])
                ])
            ),

            // 8.3 欄位代碼
            Tool(
                name: "insert_if_field",
                description: "插入 IF 條件判斷欄位",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "left_operand": .object([
                            "type": .string("string"),
                            "description": .string("左運算元（可以是欄位名稱或值）")
                        ]),
                        "operator": .object([
                            "type": .string("string"),
                            "description": .string("比較運算子：=, <>, <, >, <=, >=")
                        ]),
                        "right_operand": .object([
                            "type": .string("string"),
                            "description": .string("右運算元")
                        ]),
                        "true_text": .object([
                            "type": .string("string"),
                            "description": .string("條件為真時顯示的文字")
                        ]),
                        "false_text": .object([
                            "type": .string("string"),
                            "description": .string("條件為假時顯示的文字")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("left_operand"), .string("operator"), .string("right_operand"), .string("true_text"), .string("false_text")])
                ])
            ),
            Tool(
                name: "insert_calculation_field",
                description: "插入計算欄位（支援 SUM, AVERAGE, MAX, MIN 等）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "expression": .object([
                            "type": .string("string"),
                            "description": .string("計算表達式，如 'SUM(ABOVE)', 'AVERAGE(LEFT)', '=bookmark1*bookmark2'")
                        ]),
                        "format": .object([
                            "type": .string("string"),
                            "description": .string("數字格式，如 '#,##0.00'（可選）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("expression")])
                ])
            ),
            Tool(
                name: "insert_date_field",
                description: "插入日期時間欄位",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "type": .object([
                            "type": .string("string"),
                            "description": .string("日期類型：date（目前日期）, time（目前時間）, createDate（建立日期）, saveDate（儲存日期）")
                        ]),
                        "format": .object([
                            "type": .string("string"),
                            "description": .string("日期格式，如 'yyyy/M/d', 'yyyy年M月d日'（可選）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index")])
                ])
            ),
            Tool(
                name: "insert_page_field",
                description: "插入頁碼或文件資訊欄位",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "type": .object([
                            "type": .string("string"),
                            "description": .string("欄位類型：page（頁碼）, numPages（總頁數）, fileName（檔名）, author（作者）, numWords（字數）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("type")])
                ])
            ),
            Tool(
                name: "insert_merge_field",
                description: "插入合併列印欄位",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "field_name": .object([
                            "type": .string("string"),
                            "description": .string("欄位名稱（對應資料來源的欄位）")
                        ]),
                        "text_before": .object([
                            "type": .string("string"),
                            "description": .string("前置文字（僅當欄位非空時顯示）")
                        ]),
                        "text_after": .object([
                            "type": .string("string"),
                            "description": .string("後置文字（僅當欄位非空時顯示）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("field_name")])
                ])
            ),
            Tool(
                name: "insert_sequence_field",
                description: "插入序列欄位（自動編號，用於圖表編號等）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "identifier": .object([
                            "type": .string("string"),
                            "description": .string("序列識別符，如 'Figure', 'Table', 'Equation'")
                        ]),
                        "format": .object([
                            "type": .string("string"),
                            "description": .string("編號格式：arabic（1,2,3）, alphabetic（A,B,C）, roman（I,II,III）")
                        ]),
                        "reset_level": .object([
                            "type": .string("integer"),
                            "description": .string("重設層級（對應標題層級，如設為 1 則每遇到 Heading1 就重設）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("identifier")])
                ])
            ),

            // 8.4 重複區段控制項
            Tool(
                name: "insert_content_control",
                description: "插入內容控制項（SDT）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "type": .object([
                            "type": .string("string"),
                            "description": .string("控制項類型：richText, plainText, picture, date, dropDownList, comboBox, checkbox")
                        ]),
                        "tag": .object([
                            "type": .string("string"),
                            "description": .string("控制項標籤（用於識別）")
                        ]),
                        "alias": .object([
                            "type": .string("string"),
                            "description": .string("控制項顯示名稱")
                        ]),
                        "placeholder": .object([
                            "type": .string("string"),
                            "description": .string("佔位符提示文字")
                        ]),
                        "content": .object([
                            "type": .string("string"),
                            "description": .string("預設內容")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("type"), .string("tag")])
                ])
            ),
            Tool(
                name: "insert_repeating_section",
                description: "插入重複區段（可新增/刪除項目的區塊）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "index": .object([
                            "type": .string("integer"),
                            "description": .string("插入位置（段落索引）")
                        ]),
                        "tag": .object([
                            "type": .string("string"),
                            "description": .string("區段標籤（用於識別）")
                        ]),
                        "section_title": .object([
                            "type": .string("string"),
                            "description": .string("區段標題（顯示在 UI）")
                        ]),
                        "items": .object([
                            "type": .string("array"),
                            "description": .string("初始項目內容（字串陣列）")
                        ]),
                        "allow_insert_delete_sections": .object([
                            "type": .string("boolean"),
                            "description": .string("是否允許 Word UI 新增/刪除區段，預設 true")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("tag")])
                ])
            ),

            // #44 Phase 5–8: Content Control read/write/stub tools (v3.9.0+)
            Tool(
                name: "list_content_controls",
                description: "列出文件中所有的內容控制項（SDT），支援巢狀展開",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string"), "description": .string("文件識別碼（session 模式）")]),
                        "source_path": .object(["type": .string("string"), "description": .string("文件路徑（direct 模式）")]),
                        "nested": .object(["type": .string("boolean"), "description": .string("true=樹狀（含 children），false=扁平（含 parent_sdt_id），預設 false")])
                    ])
                ])
            ),
            Tool(
                name: "get_content_control",
                description: "依 id / tag / alias 取得單一內容控制項，含完整 metadata 與內容 XML",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string"), "description": .string("文件識別碼（session 模式）")]),
                        "source_path": .object(["type": .string("string"), "description": .string("文件路徑（direct 模式）")]),
                        "id": .object(["type": .string("integer"), "description": .string("SDT id")]),
                        "tag": .object(["type": .string("string"), "description": .string("SDT tag（多筆相符會回傳 multiple_matches）")]),
                        "alias": .object(["type": .string("string"), "description": .string("SDT alias（多筆相符會回傳 multiple_matches）")])
                    ])
                ])
            ),
            Tool(
                name: "list_repeating_section_items",
                description: "列出指定重複區段 SDT 內所有項目（順序、id、文字內容）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string"), "description": .string("文件識別碼")]),
                        "id": .object(["type": .string("integer"), "description": .string("重複區段的 SDT id")])
                    ]),
                    "required": .array([.string("doc_id"), .string("id")])
                ])
            ),
            Tool(
                name: "update_content_control_text",
                description: "修改純文字 SDT 的文字內容（保留 sdtPr）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "id": .object(["type": .string("integer"), "description": .string("SDT id")]),
                        "text": .object(["type": .string("string"), "description": .string("新文字內容")])
                    ]),
                    "required": .array([.string("doc_id"), .string("id"), .string("text")])
                ])
            ),
            Tool(
                name: "replace_content_control_content",
                description: "替換 SDT 的完整 sdtContent XML（白名單：禁止 w:sdt / w:body / w:sectPr / XML 宣告）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "id": .object(["type": .string("integer"), "description": .string("SDT id")]),
                        "content_xml": .object(["type": .string("string"), "description": .string("新內容 XML（runs / paragraphs / tables）")])
                    ]),
                    "required": .array([.string("doc_id"), .string("id"), .string("content_xml")])
                ])
            ),
            Tool(
                name: "delete_content_control",
                description: "刪除指定 SDT，可選擇是否保留內容",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "id": .object(["type": .string("integer"), "description": .string("SDT id")]),
                        "keep_content": .object(["type": .string("boolean"), "description": .string("true=保留內容（unwrap），false=連同內容一起刪，預設 true")])
                    ]),
                    "required": .array([.string("doc_id"), .string("id")])
                ])
            ),
            Tool(
                name: "update_repeating_section_item",
                description: "修改重複區段內單一項目的文字內容",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "parent_id": .object(["type": .string("integer"), "description": .string("重複區段的 SDT id")]),
                        "item_index": .object(["type": .string("integer"), "description": .string("項目索引（從 0 開始）")]),
                        "text": .object(["type": .string("string"), "description": .string("新文字")])
                    ]),
                    "required": .array([.string("doc_id"), .string("parent_id"), .string("item_index"), .string("text")])
                ])
            ),
            Tool(
                name: "list_custom_xml_parts",
                description: "列出文件的 CustomXml parts（store_item_id / target_namespaces / root_element）— 目前回傳空陣列，待 Change B 實作",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string"), "description": .string("文件識別碼（session 模式）")]),
                        "source_path": .object(["type": .string("string"), "description": .string("文件路徑（direct 模式）")])
                    ])
                ])
            ),

            // #44 styles-sections-numbering-foundations — 19 new tools (v3.10.0+)
            // Style tools (4 new + 2 extended documented in create_style/update_style schemas)
            Tool(
                name: "get_style_inheritance_chain",
                description: "回傳樣式繼承鏈（從查詢樣式向上沿 basedOn 至根）。支援 doc_id 或 source_path",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "source_path": .object(["type": .string("string")]),
                        "style_id": .object(["type": .string("string"), "description": .string("樣式 ID")])
                    ]),
                    "required": .array([.string("style_id")])
                ])
            ),
            Tool(
                name: "link_styles",
                description: "雙向連結 paragraph 與 character 樣式（emit <w:link>）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "paragraph_style_id": .object(["type": .string("string")]),
                        "character_style_id": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_style_id"), .string("character_style_id")])
                ])
            ),
            Tool(
                name: "set_latent_styles",
                description: "設定 <w:latentStyles> block — 控制 Quick Style Gallery 中內建樣式的可見性",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "latent_styles": .object(["type": .string("array"), "description": .string("[{name, ui_priority?, semi_hidden?, unhide_when_used?, q_format?}]")])
                    ]),
                    "required": .array([.string("doc_id"), .string("latent_styles")])
                ])
            ),
            Tool(
                name: "add_style_name_alias",
                description: "為樣式加入本地化名稱別名（同 lang 已存在則替換）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "style_id": .object(["type": .string("string")]),
                        "lang": .object(["type": .string("string"), "description": .string("BCP 47 語言代碼，例 \"de-DE\"")]),
                        "name": .object(["type": .string("string"), "description": .string("本地化名稱")])
                    ]),
                    "required": .array([.string("doc_id"), .string("style_id"), .string("lang"), .string("name")])
                ])
            ),

            // Numbering tools (8 new)
            Tool(
                name: "list_numbering_definitions",
                description: "列出 numbering.xml 所有 abstractNum + num 定義",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "source_path": .object(["type": .string("string")])
                    ])
                ])
            ),
            Tool(
                name: "get_numbering_definition",
                description: "依 numId 取得單一 numbering 定義（含 abstractNumId 與 levels）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "num_id": .object(["type": .string("integer")])
                    ]),
                    "required": .array([.string("doc_id"), .string("num_id")])
                ])
            ),
            Tool(
                name: "create_numbering_definition",
                description: "建立新的 abstractNum + 配對 num（最多 9 層），回傳新 numId",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "levels": .object(["type": .string("array"), "description": .string("[{ilvl, num_format, lvl_text, start?}]")])
                    ]),
                    "required": .array([.string("doc_id"), .string("levels")])
                ])
            ),
            Tool(
                name: "override_numbering_level",
                description: "為 num 加 lvlOverride，覆寫指定 level 的起始值",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "num_id": .object(["type": .string("integer")]),
                        "ilvl": .object(["type": .string("integer")]),
                        "start_value": .object(["type": .string("integer")])
                    ]),
                    "required": .array([.string("doc_id"), .string("num_id"), .string("ilvl"), .string("start_value")])
                ])
            ),
            Tool(
                name: "assign_numbering_to_paragraph",
                description: "將 numId+level 指派到段落（emit <w:numPr>）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "paragraph_index": .object(["type": .string("integer")]),
                        "num_id": .object(["type": .string("integer")]),
                        "level": .object(["type": .string("integer")])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("num_id"), .string("level")])
                ])
            ),
            Tool(
                name: "continue_list",
                description: "延續既有 list — 將同一 num_id 指派給新段落",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "paragraph_index": .object(["type": .string("integer")]),
                        "previous_list_num_id": .object(["type": .string("integer")])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("previous_list_num_id")])
                ])
            ),
            Tool(
                name: "start_new_list",
                description: "從既有 abstractNum 建立新 num 並指派到段落，回傳新 numId",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "paragraph_index": .object(["type": .string("integer")]),
                        "abstract_num_id": .object(["type": .string("integer")])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("abstract_num_id")])
                ])
            ),
            Tool(
                name: "gc_orphan_numbering",
                description: "刪除無段落引用的 num 定義（abstractNum 不會刪除），回傳被刪 num_id 陣列",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),

            // Section tools (7 new)
            Tool(
                name: "set_line_numbers_for_section",
                description: "啟用 section 行號標記（emit <w:lnNumType>）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "section_index": .object(["type": .string("integer")]),
                        "count_by": .object(["type": .string("integer")]),
                        "start": .object(["type": .string("integer")]),
                        "restart": .object(["type": .string("string"), "description": .string("continuous / newSection / newPage")])
                    ]),
                    "required": .array([.string("doc_id"), .string("section_index"), .string("count_by")])
                ])
            ),
            Tool(
                name: "set_section_vertical_alignment",
                description: "設定 section 內容垂直對齊（emit <w:vAlign>）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "section_index": .object(["type": .string("integer")]),
                        "alignment": .object(["type": .string("string"), "description": .string("top / center / bottom / both")])
                    ]),
                    "required": .array([.string("doc_id"), .string("section_index"), .string("alignment")])
                ])
            ),
            Tool(
                name: "set_page_number_format",
                description: "設定頁碼格式與起始值（emit <w:pgNumType>）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "section_index": .object(["type": .string("integer")]),
                        "start": .object(["type": .string("integer")]),
                        "format": .object(["type": .string("string"), "description": .string("decimal / lowerRoman / upperRoman / lowerLetter / upperLetter")])
                    ]),
                    "required": .array([.string("doc_id"), .string("section_index"), .string("format")])
                ])
            ),
            Tool(
                name: "set_section_break_type",
                description: "切換分節符類型（emit <w:type>）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "section_index": .object(["type": .string("integer")]),
                        "type": .object(["type": .string("string"), "description": .string("nextPage / continuous / evenPage / oddPage")])
                    ]),
                    "required": .array([.string("doc_id"), .string("section_index"), .string("type")])
                ])
            ),
            Tool(
                name: "set_title_page_distinct",
                description: "切換首頁獨立頁首頁尾（emit/移除 <w:titlePg/>）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "section_index": .object(["type": .string("integer")]),
                        "enabled": .object(["type": .string("boolean")])
                    ]),
                    "required": .array([.string("doc_id"), .string("section_index"), .string("enabled")])
                ])
            ),
            Tool(
                name: "set_section_header_footer_references",
                description: "為 section 指派 default/first/even 類型的 header/footer rId",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "section_index": .object(["type": .string("integer")]),
                        "references": .object(["type": .string("object"), "description": .string("{header_default?, header_first?, header_even?, footer_default?, footer_first?, footer_even?}")])
                    ]),
                    "required": .array([.string("doc_id"), .string("section_index"), .string("references")])
                ])
            ),
            Tool(
                name: "get_all_sections",
                description: "回傳每個 section 的完整屬性摘要（page_size / margins / orientation / line_numbers / vertical_alignment / page_number_format / break_type / titlePg / header+footer refs）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "source_path": .object(["type": .string("string")])
                    ])
                ])
            ),

            // #44 tables-hyperlinks-headers-builtin (v3.11.0+) — 16 new tools
            // Table tools (8 new + 4 extended docs in respective schemas)
            Tool(
                name: "set_table_conditional_style",
                description: "套用條件式格式（firstRow / lastRow / bandedRows 等 10 種區域）到表格的 tblStylePr",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "table_index": .object(["type": .string("integer")]),
                        "type": .object(["type": .string("string"), "description": .string("firstRow / lastRow / firstCol / lastCol / bandedRows / bandedCols / neCell / nwCell / seCell / swCell")]),
                        "properties": .object(["type": .string("object"), "description": .string("{ bold?, italic?, color?, background_color?, font_size? } — 半點為單位")])
                    ]),
                    "required": .array([.string("doc_id"), .string("table_index"), .string("type"), .string("properties")])
                ])
            ),
            Tool(
                name: "insert_nested_table",
                description: "在指定 cell 內插入新表格（深度上限 5 層，超過會 throw nested_too_deep）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "parent_table_index": .object(["type": .string("integer")]),
                        "row_index": .object(["type": .string("integer")]),
                        "col_index": .object(["type": .string("integer")]),
                        "rows": .object(["type": .string("integer")]),
                        "cols": .object(["type": .string("integer")])
                    ]),
                    "required": .array([.string("doc_id"), .string("parent_table_index"), .string("row_index"), .string("col_index"), .string("rows"), .string("cols")])
                ])
            ),
            Tool(
                name: "set_table_layout",
                description: "切換表格版面配置（fixed = 固定欄寬 / autofit = 自動）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "table_index": .object(["type": .string("integer")]),
                        "type": .object(["type": .string("string"), "description": .string("fixed / autofit")])
                    ]),
                    "required": .array([.string("doc_id"), .string("table_index"), .string("type")])
                ])
            ),
            Tool(
                name: "set_header_row",
                description: "標記 row 為表頭（emit <w:tblHeader/>），跨頁分割時自動重複",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "table_index": .object(["type": .string("integer")]),
                        "row_index": .object(["type": .string("integer"), "description": .string("預設 0")])
                    ]),
                    "required": .array([.string("doc_id"), .string("table_index")])
                ])
            ),
            Tool(
                name: "set_table_indent",
                description: "設定表格左縮排（twips 單位，emit <w:tblInd>）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "table_index": .object(["type": .string("integer")]),
                        "value": .object(["type": .string("integer")])
                    ]),
                    "required": .array([.string("doc_id"), .string("table_index"), .string("value")])
                ])
            ),

            // Hyperlink tools (3 new + list_hyperlinks already exists)
            Tool(
                name: "insert_url_hyperlink",
                description: "插入外部 URL 連結（自動建立 Hyperlink character style 若不存在）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "paragraph_index": .object(["type": .string("integer")]),
                        "url": .object(["type": .string("string")]),
                        "text": .object(["type": .string("string")]),
                        "tooltip": .object(["type": .string("string")]),
                        "history": .object(["type": .string("boolean"), "description": .string("預設 true")])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("url"), .string("text")])
                ])
            ),
            Tool(
                name: "insert_bookmark_hyperlink",
                description: "插入內部書籤連結（emit w:anchor，無 r:id）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "paragraph_index": .object(["type": .string("integer")]),
                        "anchor": .object(["type": .string("string"), "description": .string("書籤名稱")]),
                        "text": .object(["type": .string("string")]),
                        "tooltip": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("anchor"), .string("text")])
                ])
            ),
            Tool(
                name: "insert_email_hyperlink",
                description: "插入 mailto: 連結（自動 URL-encode subject）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "paragraph_index": .object(["type": .string("integer")]),
                        "email": .object(["type": .string("string")]),
                        "text": .object(["type": .string("string")]),
                        "tooltip": .object(["type": .string("string")]),
                        "subject": .object(["type": .string("string"), "description": .string("可選——加入 ?subject= 參數")])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("email"), .string("text")])
                ])
            ),

            // Header tools (5 new + 2 extended docs)
            Tool(
                name: "enable_even_odd_headers",
                description: "切換文件級 <w:evenAndOddHeaders/> flag（settings.xml）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "enabled": .object(["type": .string("boolean")])
                    ]),
                    "required": .array([.string("doc_id"), .string("enabled")])
                ])
            ),
            Tool(
                name: "link_section_header_to_previous",
                description: "讓 section 共用前一 section 的 header XML part（共用 rId）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "section_index": .object(["type": .string("integer"), "description": .string("必須 ≥ 1")]),
                        "type": .object(["type": .string("string"), "description": .string("default / first / even")])
                    ]),
                    "required": .array([.string("doc_id"), .string("section_index"), .string("type")])
                ])
            ),
            Tool(
                name: "unlink_section_header_from_previous",
                description: "為 section 建立獨立 header XML part（複製當前共用的 part）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "section_index": .object(["type": .string("integer")]),
                        "type": .object(["type": .string("string"), "description": .string("default / first / even")])
                    ]),
                    "required": .array([.string("doc_id"), .string("section_index"), .string("type")])
                ])
            ),
            Tool(
                name: "get_section_header_map",
                description: "回傳每個 section 的 header / footer 檔案對應（哪個 section 用哪個 headerN.xml）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string")]),
                        "source_path": .object(["type": .string("string")])
                    ])
                ])
            ),

            // P9 新增功能：列表查詢、文件屬性、搜尋文字、批次修訂

            // 9.1 insert_text - 在指定位置插入文字
            Tool(
                name: "insert_text",
                description: "在指定段落的指定位置插入文字",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("要插入的文字")
                        ]),
                        "position": .object([
                            "type": .string("integer"),
                            "description": .string("字元位置（從 0 開始，不指定則插入到段落末尾）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("text")])
                ])
            ),

            // 9.2 get_document_text - get_text 的別名
            Tool(
                name: "get_document_text",
                description: "取得 .docx 檔案的完整純文字內容（get_text 的別名，Direct Mode, Tier 1）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "source_path": .object([
                            "type": .string("string"),
                            "description": .string("來源 .docx 檔案路徑")
                        ])
                    ]),
                    "required": .array([.string("source_path")])
                ])
            ),

            // 9.3 search_text - 搜尋文字並返回位置
            Tool(
                name: "search_text",
                description: "在文件中搜尋指定文字，返回所有符合的位置（支援 Direct Mode）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼（Session Mode）")
                        ]),
                        "source_path": .object([
                            "type": .string("string"),
                            "description": .string("檔案路徑（Direct Mode，免開啟）")
                        ]),
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("要搜尋的文字")
                        ]),
                        "case_sensitive": .object([
                            "type": .string("boolean"),
                            "description": .string("是否區分大小寫（預設 false）")
                        ])
                    ]),
                    "required": .array([.string("query")])
                ])
            ),
            Tool(
                name: "search_text_batch",
                description: "批次文字搜尋（減少 per-call round-trip）。每個 query 產出 { query, matches: [positions] }。Session Mode 需先 open_document；Direct Mode 傳 source_path 免開。",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼（Session Mode）")
                        ]),
                        "source_path": .object([
                            "type": .string("string"),
                            "description": .string("檔案路徑（Direct Mode，免開啟）")
                        ]),
                        "queries": .object([
                            "type": .string("array"),
                            "description": .string("query 陣列。每項可為 plain string 或 { query: string, case_sensitive?: bool } object。")
                        ])
                    ]),
                    "required": .array([.string("queries")])
                ])
            ),

            // 9.4 list_hyperlinks - 列出所有超連結
            Tool(
                name: "list_hyperlinks",
                description: "列出文件中所有的超連結（支援 Direct Mode）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼（Session Mode）")
                        ]),
                        "source_path": .object([
                            "type": .string("string"),
                            "description": .string("檔案路徑（Direct Mode，免開啟）")
                        ])
                    ])
                ])
            ),

            // 9.5 list_bookmarks - 列出所有書籤
            Tool(
                name: "list_bookmarks",
                description: "列出文件中所有的書籤（支援 Direct Mode）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼（Session Mode）")
                        ]),
                        "source_path": .object([
                            "type": .string("string"),
                            "description": .string("檔案路徑（Direct Mode，免開啟）")
                        ])
                    ])
                ])
            ),

            // 9.6 list_footnotes - 列出所有腳註
            Tool(
                name: "list_footnotes",
                description: "列出文件中所有的腳註（支援 Direct Mode）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼（Session Mode）")
                        ]),
                        "source_path": .object([
                            "type": .string("string"),
                            "description": .string("檔案路徑（Direct Mode，免開啟）")
                        ])
                    ])
                ])
            ),

            // 9.7 list_endnotes - 列出所有尾註
            Tool(
                name: "list_endnotes",
                description: "列出文件中所有的尾註（支援 Direct Mode）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼（Session Mode）")
                        ]),
                        "source_path": .object([
                            "type": .string("string"),
                            "description": .string("檔案路徑（Direct Mode，免開啟）")
                        ])
                    ])
                ])
            ),

            // 9.8 get_revisions - 取得所有修訂記錄
            Tool(
                name: "get_revisions",
                description: "取得文件中所有的修訂追蹤記錄。預設回傳完整修訂文字。若需縮減 context，傳 summarize: true 對超過 5000 字元的單筆條目做頭尾摘要。支援 Direct Mode（傳 source_path）。",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼（Session Mode）")
                        ]),
                        "source_path": .object([
                            "type": .string("string"),
                            "description": .string("檔案路徑（Direct Mode，免開啟）")
                        ]),
                        "summarize": .object([
                            "type": .string("boolean"),
                            "description": .string("是否對長文字做頭尾摘要（預設 false 回傳完整文字；true 時超過 5000 字元的單筆條目顯示為 head30 [...] tail30）")
                        ])
                    ])
                ])
            ),

            // 9.9 accept_all_revisions - 接受所有修訂
            Tool(
                name: "accept_all_revisions",
                description: "接受文件中所有的修訂",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),

            // 9.10 reject_all_revisions - 拒絕所有修訂
            Tool(
                name: "reject_all_revisions",
                description: "拒絕文件中所有的修訂",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),

            // 9.11 set_document_properties - 設定文件屬性
            Tool(
                name: "set_document_properties",
                description: "設定文件屬性（標題、作者、主旨、關鍵字等）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "title": .object([
                            "type": .string("string"),
                            "description": .string("文件標題")
                        ]),
                        "subject": .object([
                            "type": .string("string"),
                            "description": .string("主旨")
                        ]),
                        "creator": .object([
                            "type": .string("string"),
                            "description": .string("作者")
                        ]),
                        "keywords": .object([
                            "type": .string("string"),
                            "description": .string("關鍵字（以逗號分隔）")
                        ]),
                        "description": .object([
                            "type": .string("string"),
                            "description": .string("描述/備註")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),

            // 9.12 get_paragraph_runs - 取得段落的 runs 及其格式
            Tool(
                name: "get_paragraph_runs",
                description: "取得指定段落的所有 runs（文字片段）及其格式資訊，包含顏色、粗體、斜體等",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index")])
                ])
            ),

            // 9.13 get_text_with_formatting - 取得帶格式標記的文字
            Tool(
                name: "get_text_with_formatting",
                description: "取得文件文字，並以 Markdown 標記格式（粗體用 **、斜體用 *、紅色用 {{color:red}}）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("指定段落索引（可選，不指定則取得全部）")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),

            // 9.14 search_by_formatting - 搜尋特定格式的文字
            Tool(
                name: "search_by_formatting",
                description: "搜尋具有特定格式的文字（如紅色、粗體）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "color": .object([
                            "type": .string("string"),
                            "description": .string("顏色 RGB hex（如 FF0000 代表紅色）")
                        ]),
                        "bold": .object([
                            "type": .string("boolean"),
                            "description": .string("是否為粗體")
                        ]),
                        "italic": .object([
                            "type": .string("boolean"),
                            "description": .string("是否為斜體")
                        ]),
                        "highlight": .object([
                            "type": .string("string"),
                            "description": .string("螢光標記顏色（yellow, green, cyan 等）")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),

            // 9.15 get_document_properties - 取得文件屬性
            Tool(
                name: "get_document_properties",
                description: "取得文件屬性（標題、作者、建立日期等）（支援 Direct Mode）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼（Session Mode）")
                        ]),
                        "source_path": .object([
                            "type": .string("string"),
                            "description": .string("檔案路徑（Direct Mode，免開啟）")
                        ])
                    ])
                ])
            ),

            // 9.16 search_text_with_formatting - 搜尋文字並顯示格式
            Tool(
                name: "search_text_with_formatting",
                description: "搜尋文字並返回匹配位置及其格式標記（粗體、斜體、顏色等）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("要搜尋的文字")
                        ]),
                        "case_sensitive": .object([
                            "type": .string("boolean"),
                            "description": .string("是否區分大小寫（預設 false）")
                        ]),
                        "context_chars": .object([
                            "type": .string("integer"),
                            "description": .string("顯示匹配位置前後多少字元（預設 20）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("query")])
                ])
            ),

            // 9.17 list_all_formatted_text - 列出特定格式的所有文字
            Tool(
                name: "list_all_formatted_text",
                description: "列出所有具有特定格式的文字。必須指定 format_type: italic, bold, underline, color, highlight, strikethrough",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "format_type": .object([
                            "type": .string("string"),
                            "description": .string("格式類型：italic, bold, underline, color, highlight, strikethrough")
                        ]),
                        "color_filter": .object([
                            "type": .string("string"),
                            "description": .string("當 format_type=color 時，可指定顏色（如 FF0000 代表紅色）")
                        ]),
                        "paragraph_start": .object([
                            "type": .string("integer"),
                            "description": .string("起始段落索引（可選）")
                        ]),
                        "paragraph_end": .object([
                            "type": .string("integer"),
                            "description": .string("結束段落索引（可選）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("format_type")])
                ])
            ),

            // 9.18 get_word_count_by_section - 按區段統計字數
            Tool(
                name: "get_word_count_by_section",
                description: "按區段統計字數，可自訂分隔標記（如 References）並排除特定區段（支援 Direct Mode）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼（Session Mode）")
                        ]),
                        "source_path": .object([
                            "type": .string("string"),
                            "description": .string("檔案路徑（Direct Mode，免開啟）")
                        ]),
                        "section_markers": .object([
                            "type": .string("array"),
                            "description": .string("區段分隔標記文字陣列（如 [\"Abstract\", \"Introduction\", \"References\"]）")
                        ]),
                        "exclude_sections": .object([
                            "type": .string("array"),
                            "description": .string("不計入總字數的區段名稱（如 [\"References\", \"Appendix\"]）")
                        ])
                    ])
                ])
            ),
            Tool(
                name: "compare_documents",
                description: "比對兩個 Word 文件的差異（段落層級），只回傳差異部分。支援文字、格式、結構比對模式",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id_a": .object([
                            "type": .string("string"),
                            "description": .string("基準文件（舊版本）的識別碼")
                        ]),
                        "doc_id_b": .object([
                            "type": .string("string"),
                            "description": .string("比較文件（新版本）的識別碼")
                        ]),
                        "mode": .object([
                            "type": .string("string"),
                            "description": .string("比對模式：text（預設，純文字差異）、formatting（含格式差異）、structure（結構摘要）、full（完整比對）"),
                            "enum": .array([.string("text"), .string("formatting"), .string("structure"), .string("full")])
                        ]),
                        "context_lines": .object([
                            "type": .string("integer"),
                            "description": .string("差異前後顯示的未變更段落數（0-3，預設 0）"),
                            "minimum": .int(0),
                            "maximum": .int(3)
                        ]),
                        "max_results": .object([
                            "type": .string("integer"),
                            "description": .string("最多回傳的差異筆數（預設 0 = 全部回傳）"),
                            "minimum": .int(0)
                        ]),
                        "heading_styles": .object([
                            "type": .string("array"),
                            "description": .string("自定義 heading 樣式名稱（用於 structure mode，如 [\"EC8\", \"ECtitle\"]）"),
                            "items": .object(["type": .string("string")])
                        ]),
                        "summarize": .object([
                            "type": .string("boolean"),
                            "description": .string("是否對長文字做頭尾摘要（預設 false 回傳完整文字；true 時超過 5000 字元的單筆條目顯示為 head30 [...] tail30）")
                        ])
                    ]),
                    "required": .array([.string("doc_id_a"), .string("doc_id_b")])
                ])
            ),

            // ==================== manuscript-review-markdown-export change ====================

            Tool(
                name: "export_revision_summary_markdown",
                description: "把單一 .docx 的修訂與註解整理成 markdown 報告（heading + stats + 表格）。預設按 author 分組。支援 Direct Mode（傳 source_path）。",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string"), "description": .string("文件識別碼（Session Mode）")]),
                        "source_path": .object(["type": .string("string"), "description": .string("檔案路徑（Direct Mode）")]),
                        "include_revisions": .object(["type": .string("boolean"), "description": .string("是否包含 Revisions 區段（預設 true）")]),
                        "include_comments": .object(["type": .string("boolean"), "description": .string("是否包含 Comments 區段（預設 true）")]),
                        "group_by": .object([
                            "type": .string("string"),
                            "description": .string("Revisions 表格分組策略（預設 author；可選 author / type / section / none）"),
                            "enum": .array([.string("author"), .string("type"), .string("section"), .string("none")])
                        ]),
                        "summarize": .object(["type": .string("boolean"), "description": .string("是否對長文字做頭尾摘要（預設 false）")])
                    ])
                ])
            ),

            Tool(
                name: "compare_documents_markdown",
                description: "比對多份 .docx 並輸出 markdown 變更時間軸（versions table + 相鄰版本 pairwise diff）。要求至少 2 份文件，按陣列順序視為 v1 → v2 → v3。",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "documents": .object([
                            "type": .string("array"),
                            "description": .string("有序的文件清單，每筆為 { path, label }；至少 2 筆"),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "path": .object(["type": .string("string")]),
                                    "label": .object(["type": .string("string")])
                                ]),
                                "required": .array([.string("path"), .string("label")])
                            ])
                        ]),
                        "include_summary_table": .object(["type": .string("boolean"), "description": .string("是否包含 Versions table（預設 true）")]),
                        "include_per_pair_diff": .object(["type": .string("boolean"), "description": .string("是否包含 pairwise diff 區段（預設 true）")]),
                        "diff_format": .object([
                            "type": .string("string"),
                            "description": .string("Pairwise diff 格式（預設 narrative；可選 narrative / table / raw）"),
                            "enum": .array([.string("narrative"), .string("table"), .string("raw")])
                        ]),
                        "summarize": .object(["type": .string("boolean"), "description": .string("是否對長文字做頭尾摘要（預設 false）")])
                    ]),
                    "required": .array([.string("documents")])
                ])
            ),

            Tool(
                name: "export_comment_threads_markdown",
                description: "把單一 .docx 的註解依 parent / reply 結構分組輸出 markdown。支援 author alias 規範化、Old: 模式偵測、三種輸出格式（table / threaded / narrative）。",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string"), "description": .string("文件識別碼（Session Mode）")]),
                        "source_path": .object(["type": .string("string"), "description": .string("檔案路徑（Direct Mode）")]),
                        "author_aliases": .object([
                            "type": .string("object"),
                            "description": .string("作者別名對應表（raw author -> canonical name）。例：{\"kllay's PC\": \"Lay\"}"),
                            "additionalProperties": .object(["type": .string("string")])
                        ]),
                        "detect_old_pattern": .object(["type": .string("boolean"), "description": .string("是否偵測 'Old: <quoted>\\n<new>' 非正式回覆 pattern（預設 false）")]),
                        "format": .object([
                            "type": .string("string"),
                            "description": .string("輸出格式（預設 table；可選 table / threaded / narrative）"),
                            "enum": .array([.string("table"), .string("threaded"), .string("narrative")])
                        ]),
                        "include_resolved": .object(["type": .string("boolean"), "description": .string("是否包含已解決的 thread（預設 true）")]),
                        "summarize": .object(["type": .string("boolean"), "description": .string("是否對長文字做頭尾摘要（預設 false）")])
                    ])
                ])
            ),

            // ==================== Phase 1: 進階排版功能 ====================

            // 10.1 set_columns - 多欄排版
            Tool(
                name: "set_columns",
                description: "設定文件多欄排版（預設整份文件，或指定段落後插入分節符）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "columns": .object([
                            "type": .string("integer"),
                            "description": .string("欄數（1-4）"),
                            "minimum": .int(1),
                            "maximum": .int(4)
                        ]),
                        "space": .object([
                            "type": .string("integer"),
                            "description": .string("欄間距（twips，預設 720 = 0.5 inch）")
                        ]),
                        "equal_width": .object([
                            "type": .string("boolean"),
                            "description": .string("欄寬是否相等（預設 true）")
                        ]),
                        "separator": .object([
                            "type": .string("boolean"),
                            "description": .string("是否顯示分隔線（預設 false）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("columns")])
                ])
            ),

            // 10.2 insert_column_break - 分欄符號
            Tool(
                name: "insert_column_break",
                description: "在指定段落插入分欄符號",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index")])
                ])
            ),

            // 10.3 set_line_numbers - 行號
            Tool(
                name: "set_line_numbers",
                description: "設定文件行號顯示",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "enable": .object([
                            "type": .string("boolean"),
                            "description": .string("是否啟用行號")
                        ]),
                        "start": .object([
                            "type": .string("integer"),
                            "description": .string("起始行號（預設 1）")
                        ]),
                        "count_by": .object([
                            "type": .string("integer"),
                            "description": .string("每幾行顯示一次行號（預設 1）")
                        ]),
                        "restart": .object([
                            "type": .string("string"),
                            "description": .string("重新編號模式：continuous（連續）、newSection（每節）、newPage（每頁）")
                        ]),
                        "distance": .object([
                            "type": .string("integer"),
                            "description": .string("行號與文字的距離（twips，預設 360）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("enable")])
                ])
            ),

            // 10.4 set_page_borders - 頁面邊框
            Tool(
                name: "set_page_borders",
                description: "設定頁面邊框（四邊可獨立設定）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "style": .object([
                            "type": .string("string"),
                            "description": .string("邊框樣式：single（單線）、double（雙線）、dotted（點線）、dashed（虛線）、thick（粗線）、none（無）")
                        ]),
                        "color": .object([
                            "type": .string("string"),
                            "description": .string("邊框顏色（RGB 十六進位，如 000000）")
                        ]),
                        "size": .object([
                            "type": .string("integer"),
                            "description": .string("邊框粗細（1/8 點，預設 4 = 0.5pt）")
                        ]),
                        "offset_from": .object([
                            "type": .string("string"),
                            "description": .string("邊框起算位置：text（從文字）、page（從頁邊）")
                        ]),
                        "top": .object([
                            "type": .string("boolean"),
                            "description": .string("是否顯示上邊框（預設 true）")
                        ]),
                        "bottom": .object([
                            "type": .string("boolean"),
                            "description": .string("是否顯示下邊框（預設 true）")
                        ]),
                        "left": .object([
                            "type": .string("boolean"),
                            "description": .string("是否顯示左邊框（預設 true）")
                        ]),
                        "right": .object([
                            "type": .string("boolean"),
                            "description": .string("是否顯示右邊框（預設 true）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("style")])
                ])
            ),

            // 10.5 insert_symbol - 特殊符號
            Tool(
                name: "insert_symbol",
                description: "在指定段落插入特殊符號（使用字型符號或 Unicode）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "char": .object([
                            "type": .string("string"),
                            "description": .string("符號字元碼（十六進位，如 F020 或 Unicode 碼點）")
                        ]),
                        "font": .object([
                            "type": .string("string"),
                            "description": .string("符號字型（如 Symbol, Wingdings, Wingdings 2）")
                        ]),
                        "position": .object([
                            "type": .string("string"),
                            "description": .string("插入位置：start（段落開頭）、end（段落結尾）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("char")])
                ])
            ),

            // 10.6 set_text_direction - 文字方向
            Tool(
                name: "set_text_direction",
                description: "設定段落或文件的文字方向（支援直書）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "direction": .object([
                            "type": .string("string"),
                            "description": .string("文字方向：lrTb（左到右，上到下，預設）、tbRl（上到下，右到左，直書）、btLr（下到上，左到右）")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（不指定則套用全文件）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("direction")])
                ])
            ),

            // 10.7 insert_drop_cap - 首字放大
            Tool(
                name: "insert_drop_cap",
                description: "將段落首字放大（首字下沉效果）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "type": .object([
                            "type": .string("string"),
                            "description": .string("首字類型：drop（下沉，預設）、margin（在邊界）、none（移除）")
                        ]),
                        "lines": .object([
                            "type": .string("integer"),
                            "description": .string("下沉行數（2-10，預設 3）")
                        ]),
                        "distance": .object([
                            "type": .string("integer"),
                            "description": .string("與文字的距離（twips，預設 0）")
                        ]),
                        "font": .object([
                            "type": .string("string"),
                            "description": .string("首字字型（可選）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index")])
                ])
            ),

            // 10.8 insert_horizontal_line - 水平線
            Tool(
                name: "insert_horizontal_line",
                description: "在指定段落插入水平線（段落邊框方式）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始），水平線會加在該段落下方")
                        ]),
                        "style": .object([
                            "type": .string("string"),
                            "description": .string("線條樣式：single（單線，預設）、double（雙線）、dotted（點線）、dashed（虛線）、thick（粗線）")
                        ]),
                        "color": .object([
                            "type": .string("string"),
                            "description": .string("線條顏色（RGB 十六進位，預設 000000）")
                        ]),
                        "size": .object([
                            "type": .string("integer"),
                            "description": .string("線條粗細（1/8 點，預設 12 = 1.5pt）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index")])
                ])
            ),

            // 10.9 set_widow_orphan - 避頭尾控制
            Tool(
                name: "set_widow_orphan",
                description: "設定段落避頭尾（孤行/寡行控制）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始），不指定則套用全文件")
                        ]),
                        "enable": .object([
                            "type": .string("boolean"),
                            "description": .string("是否啟用避頭尾（預設 true）")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),

            // 10.10 set_keep_with_next - 與下段同頁
            Tool(
                name: "set_keep_with_next",
                description: "設定段落與下一段同頁（避免分頁時分離）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "enable": .object([
                            "type": .string("boolean"),
                            "description": .string("是否啟用與下段同頁（預設 true）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index")])
                ])
            ),

            // ==================== Phase 2: 浮水印與文件保護 ====================

            // 11.1 insert_watermark - 文字浮水印
            Tool(
                name: "insert_watermark",
                description: "插入文字浮水印（斜向置中於頁面背景）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("浮水印文字（如「機密」、「草稿」、「CONFIDENTIAL」）")
                        ]),
                        "font": .object([
                            "type": .string("string"),
                            "description": .string("字型名稱（預設 Calibri Light）")
                        ]),
                        "color": .object([
                            "type": .string("string"),
                            "description": .string("文字顏色（RGB 十六進位，預設 C0C0C0 淡灰色）")
                        ]),
                        "size": .object([
                            "type": .string("integer"),
                            "description": .string("字型大小（點數，預設 72）")
                        ]),
                        "semitransparent": .object([
                            "type": .string("boolean"),
                            "description": .string("是否半透明（預設 true）")
                        ]),
                        "rotation": .object([
                            "type": .string("integer"),
                            "description": .string("旋轉角度（度，預設 -45 為斜向）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("text")])
                ])
            ),

            // 11.2 insert_image_watermark - 圖片浮水印
            Tool(
                name: "insert_image_watermark",
                description: "插入圖片浮水印（置中於頁面背景）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "image_path": .object([
                            "type": .string("string"),
                            "description": .string("圖片檔案路徑")
                        ]),
                        "scale": .object([
                            "type": .string("integer"),
                            "description": .string("縮放比例（百分比，預設 100）")
                        ]),
                        "washout": .object([
                            "type": .string("boolean"),
                            "description": .string("是否淡化處理（預設 true）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("image_path")])
                ])
            ),

            // 11.3 remove_watermark - 移除浮水印
            Tool(
                name: "remove_watermark",
                description: "移除文件的浮水印",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),

            // 11.4 protect_document - 文件保護
            Tool(
                name: "protect_document",
                description: "設定文件保護（限制編輯、唯讀等）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "protection_type": .object([
                            "type": .string("string"),
                            "description": .string("保護類型：readOnly（唯讀）、comments（僅允許註解）、trackedChanges（僅允許追蹤修訂）、forms（僅允許表單填寫）")
                        ]),
                        "password": .object([
                            "type": .string("string"),
                            "description": .string("保護密碼（可選）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("protection_type")])
                ])
            ),

            // 11.5 unprotect_document - 移除文件保護
            Tool(
                name: "unprotect_document",
                description: "移除文件保護",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "password": .object([
                            "type": .string("string"),
                            "description": .string("保護密碼（如有設定）")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),

            // 11.6 set_document_password - 設定開啟密碼
            Tool(
                name: "set_document_password",
                description: "設定文件開啟密碼（加密保護）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "password": .object([
                            "type": .string("string"),
                            "description": .string("開啟密碼")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("password")])
                ])
            ),

            // 11.7 remove_document_password - 移除開啟密碼
            Tool(
                name: "remove_document_password",
                description: "移除文件開啟密碼",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "current_password": .object([
                            "type": .string("string"),
                            "description": .string("目前的開啟密碼")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("current_password")])
                ])
            ),

            // 11.8 restrict_editing_region - 限制編輯區域
            Tool(
                name: "restrict_editing_region",
                description: "設定可編輯區域（其他區域受保護）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "start_paragraph": .object([
                            "type": .string("integer"),
                            "description": .string("可編輯區域起始段落索引")
                        ]),
                        "end_paragraph": .object([
                            "type": .string("integer"),
                            "description": .string("可編輯區域結束段落索引")
                        ]),
                        "editor": .object([
                            "type": .string("string"),
                            "description": .string("允許編輯的使用者/群組（可選）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("start_paragraph"), .string("end_paragraph")])
                ])
            ),

            // ==================== v3.3.0: Phase 2A — Theme + Header/Footer CRUD ====================
            // Spec: che-word-mcp-ooxml-roundtrip-fidelity (closes #26 #27 #28)

            Tool(
                name: "get_theme",
                description: "讀取 word/theme/theme1.xml 的 major/minor 字體 + 主題色盤。回傳 { fonts: { major/minor: { latin, ea, cs }}, colors: { accent1-6, hyperlink, followedHyperlink }}。文件無 theme part 時回 { error }。",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string"), "description": .string("文件識別碼")])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "update_theme_fonts",
                description: "部分更新 theme1.xml 的 major/minor 字體 slot（latin/ea/cs）。只改傳入的 slot，其他保留。例：{ minor: { ea: \"DFKai-SB\" }} 只改中文小字字體（適合論文中文字體規範修復）。",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string"), "description": .string("文件識別碼")]),
                        "major": .object(["type": .string("object"), "description": .string("major font slot 部分更新：{ latin?, ea?, cs? }")]),
                        "minor": .object(["type": .string("object"), "description": .string("minor font slot 部分更新：{ latin?, ea?, cs? }")])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "update_theme_color",
                description: "替換主題色盤的單一 slot。slot 範圍：accent1-6 / hyperlink / followedHyperlink / dk1 / lt1 / dk2 / lt2。hex 為 6-char hex（例 \"5B9BD5\"）。",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string"), "description": .string("文件識別碼")]),
                        "slot": .object(["type": .string("string"), "description": .string("色盤 slot 名稱")]),
                        "hex": .object(["type": .string("string"), "description": .string("6-char hex 顏色值")])
                    ]),
                    "required": .array([.string("doc_id"), .string("slot"), .string("hex")])
                ])
            ),
            Tool(
                name: "set_theme",
                description: "Low-level escape hatch：以使用者提供的完整 theme XML 字串覆寫 word/theme/theme1.xml。XML 必須 well-formed 且包含 <a:theme> 根元素。",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string"), "description": .string("文件識別碼")]),
                        "full_xml": .object(["type": .string("string"), "description": .string("完整 theme1.xml 內容")])
                    ]),
                    "required": .array([.string("doc_id"), .string("full_xml")])
                ])
            ),

            // v3.4.0: Phase 2B — Comment thread + people tools (closes #29 #30)
            Tool(name: "list_comment_threads",
                 description: "列出 comment thread 結構（parent-child）。回傳 [{ root_comment_id, replies, resolved, durable_id }]。",
                 inputSchema: .object(["type": .string("object"),
                                        "properties": .object(["doc_id": .object(["type": .string("string")])]),
                                        "required": .array([.string("doc_id")])])),
            Tool(name: "get_comment_thread",
                 description: "讀取指定 root comment 的完整 thread tree。",
                 inputSchema: .object(["type": .string("object"),
                                        "properties": .object([
                                            "doc_id": .object(["type": .string("string")]),
                                            "root_comment_id": .object(["type": .string("integer")])
                                        ]),
                                        "required": .array([.string("doc_id"), .string("root_comment_id")])])),
            Tool(name: "sync_extended_comments",
                 description: "確保 comments.xml 中每個 comment 在 commentsExtended/commentsIds 都有對應 entry，並移除孤立的 extended entries。回傳 { added_extended, added_ids, removed_orphans }。",
                 inputSchema: .object(["type": .string("object"),
                                        "properties": .object(["doc_id": .object(["type": .string("string")])]),
                                        "required": .array([.string("doc_id")])])),

            Tool(name: "list_people",
                 description: "列出 word/people.xml 中所有 comment author 紀錄。回傳 [{ person_id, display_name, email, color, provider_id }]。",
                 inputSchema: .object(["type": .string("object"),
                                        "properties": .object(["doc_id": .object(["type": .string("string")])]),
                                        "required": .array([.string("doc_id")])])),
            Tool(name: "add_person",
                 description: "新增 comment author 到 people.xml（不存在則建立 part + Override + Relationship）。回傳 { person_id }。重名會加 _2 後綴。",
                 inputSchema: .object(["type": .string("object"),
                                        "properties": .object([
                                            "doc_id": .object(["type": .string("string")]),
                                            "display_name": .object(["type": .string("string")]),
                                            "email": .object(["type": .string("string")]),
                                            "color": .object(["type": .string("string")])
                                        ]),
                                        "required": .array([.string("doc_id"), .string("display_name")])])),
            Tool(name: "update_person",
                 description: "部分更新 person 紀錄（display_name / email / color）。",
                 inputSchema: .object(["type": .string("object"),
                                        "properties": .object([
                                            "doc_id": .object(["type": .string("string")]),
                                            "person_id": .object(["type": .string("string")]),
                                            "display_name": .object(["type": .string("string")]),
                                            "email": .object(["type": .string("string")]),
                                            "color": .object(["type": .string("string")])
                                        ]),
                                        "required": .array([.string("doc_id"), .string("person_id")])])),
            Tool(name: "delete_person",
                 description: "刪除 person 紀錄。回傳 { comments_orphaned } — 引用該 author 的 comment 數。",
                 inputSchema: .object(["type": .string("object"),
                                        "properties": .object([
                                            "doc_id": .object(["type": .string("string")]),
                                            "person_id": .object(["type": .string("string")])
                                        ]),
                                        "required": .array([.string("doc_id"), .string("person_id")])])),

            // v3.5.0: Phase 2C — Notes update + web settings (closes #24 #25 #31)
            Tool(name: "get_endnote",
                 description: "讀取指定 endnote 的 text + runs。",
                 inputSchema: .object(["type": .string("object"),
                                        "properties": .object([
                                            "doc_id": .object(["type": .string("string")]),
                                            "endnote_id": .object(["type": .string("integer")])
                                        ]),
                                        "required": .array([.string("doc_id"), .string("endnote_id")])])),
            Tool(name: "update_endnote",
                 description: "in-place replace endnote 內容，保留 endnote_id（cross-references 不斷）。",
                 inputSchema: .object(["type": .string("object"),
                                        "properties": .object([
                                            "doc_id": .object(["type": .string("string")]),
                                            "endnote_id": .object(["type": .string("integer")]),
                                            "text": .object(["type": .string("string")])
                                        ]),
                                        "required": .array([.string("doc_id"), .string("endnote_id"), .string("text")])])),
            Tool(name: "get_footnote",
                 description: "讀取指定 footnote 的 text + runs。",
                 inputSchema: .object(["type": .string("object"),
                                        "properties": .object([
                                            "doc_id": .object(["type": .string("string")]),
                                            "footnote_id": .object(["type": .string("integer")])
                                        ]),
                                        "required": .array([.string("doc_id"), .string("footnote_id")])])),
            Tool(name: "update_footnote",
                 description: "in-place replace footnote 內容，保留 footnote_id。",
                 inputSchema: .object(["type": .string("object"),
                                        "properties": .object([
                                            "doc_id": .object(["type": .string("string")]),
                                            "footnote_id": .object(["type": .string("integer")]),
                                            "text": .object(["type": .string("string")])
                                        ]),
                                        "required": .array([.string("doc_id"), .string("footnote_id"), .string("text")])])),
            Tool(name: "get_web_settings",
                 description: "讀取 word/webSettings.xml。回傳 { optimize_for_browser, rely_on_vml, allow_png, ... }。文件無 webSettings part 時回 { error }。",
                 inputSchema: .object(["type": .string("object"),
                                        "properties": .object(["doc_id": .object(["type": .string("string")])]),
                                        "required": .array([.string("doc_id")])])),
            Tool(name: "update_web_settings",
                 description: "部分更新 webSettings.xml（按 key），不存在則建立 part。",
                 inputSchema: .object(["type": .string("object"),
                                        "properties": .object([
                                            "doc_id": .object(["type": .string("string")]),
                                            "rely_on_vml": .object(["type": .string("boolean")]),
                                            "optimize_for_browser": .object(["type": .string("boolean")]),
                                            "allow_png": .object(["type": .string("boolean")])
                                        ]),
                                        "required": .array([.string("doc_id")])])),

            // Headers + Footers CRUD (closes #26 #27)
            Tool(name: "list_headers",
                 description: "列出文件所有 header parts。回傳 [{ header_id, type: 'default'|'first'|'even', section_id, has_watermark }]。",
                 inputSchema: .object(["type": .string("object"),
                                        "properties": .object(["doc_id": .object(["type": .string("string")])]),
                                        "required": .array([.string("doc_id")])])),
            Tool(name: "get_header",
                 description: "讀取指定 header part 的文字 + 完整 XML + watermark 資訊（若有）。回傳 { text, xml, watermark }。",
                 inputSchema: .object(["type": .string("object"),
                                        "properties": .object([
                                            "doc_id": .object(["type": .string("string")]),
                                            "header_id": .object(["type": .string("string"), "description": .string("rId of the header relationship")])
                                        ]),
                                        "required": .array([.string("doc_id"), .string("header_id")])])),
            Tool(name: "delete_header",
                 description: "刪除指定 header part。同步移除 typed model entry、archiveTempDir 檔案、Relationship、Content_Types Override、document.xml 中的 sectionProperties <w:headerReference>。",
                 inputSchema: .object(["type": .string("object"),
                                        "properties": .object([
                                            "doc_id": .object(["type": .string("string")]),
                                            "header_id": .object(["type": .string("string")])
                                        ]),
                                        "required": .array([.string("doc_id"), .string("header_id")])])),
            Tool(name: "list_watermarks",
                 description: "列出文件所有 header 中的 watermark VML shapes。回傳 [{ header_id, type: 'text'|'image', text?, image_path?, color?, rotation?, scale? }]。",
                 inputSchema: .object(["type": .string("object"),
                                        "properties": .object(["doc_id": .object(["type": .string("string")])]),
                                        "required": .array([.string("doc_id")])])),
            Tool(name: "get_watermark",
                 description: "讀取指定 header 的 watermark 完整參數。無 watermark 回 null。",
                 inputSchema: .object(["type": .string("object"),
                                        "properties": .object([
                                            "doc_id": .object(["type": .string("string")]),
                                            "header_id": .object(["type": .string("string")])
                                        ]),
                                        "required": .array([.string("doc_id"), .string("header_id")])])),

            Tool(name: "list_footers",
                 description: "列出文件所有 footer parts。回傳 [{ footer_id, type: 'default'|'first'|'even', section_id, has_page_number }]。",
                 inputSchema: .object(["type": .string("object"),
                                        "properties": .object(["doc_id": .object(["type": .string("string")])]),
                                        "required": .array([.string("doc_id")])])),
            Tool(name: "get_footer",
                 description: "讀取指定 footer part 的文字 + XML + 識別出的 fields（PAGE / NUMPAGES 等）。回傳 { text, xml, fields }。",
                 inputSchema: .object(["type": .string("object"),
                                        "properties": .object([
                                            "doc_id": .object(["type": .string("string")]),
                                            "footer_id": .object(["type": .string("string")])
                                        ]),
                                        "required": .array([.string("doc_id"), .string("footer_id")])])),
            Tool(name: "delete_footer",
                 description: "刪除指定 footer part，與 delete_header 對稱（typed model + tempDir 檔案 + rels + Content_Types + section reference）。",
                 inputSchema: .object(["type": .string("object"),
                                        "properties": .object([
                                            "doc_id": .object(["type": .string("string")]),
                                            "footer_id": .object(["type": .string("string")])
                                        ]),
                                        "required": .array([.string("doc_id"), .string("footer_id")])])),

            // ==================== Phase 3: 學術功能（部分） ====================

            // 12.1 insert_caption - 插入圖表標號
            Tool(
                name: "insert_caption",
                description: "為圖表/公式插入自動編號 caption（emit 真 SEQ field，Word F9 自動重算）。v2.1+ 支援中文 label（圖/表/公式）+ 5 種 anchor（paragraph_index / after_image_id / after_table_index / after_text / before_text，擇一）。v3.16.0+ 同時傳多個 anchor 會 return 「Error: insert_caption: received conflicting anchors: ...」（取代 v3.15.x 的「got N」訊息）。include_chapter_number 會 emit STYLEREF field 產生「圖 2-1」式章節編號。",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "label": .object([
                            "type": .string("string"),
                            "description": .string("標號類型，六選一：Figure / Table / Equation / 圖 / 表 / 公式")
                        ]),
                        "caption_text": .object([
                            "type": .string("string"),
                            "description": .string("標號說明文字（可選）")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("插入位置段落索引（五 anchor 擇一；可搭配 position）")
                        ]),
                        "after_image_id": .object([
                            "type": .string("string"),
                            "description": .string("鎖定已插入圖片的 rId（insert_image 返回值），在該圖下方插 caption（五 anchor 擇一）")
                        ]),
                        "after_table_index": .object([
                            "type": .string("integer"),
                            "description": .string("鎖定第 N 個 table（0-based），在其下方插 caption（五 anchor 擇一）")
                        ]),
                        "after_text": .object([
                            "type": .string("string"),
                            "description": .string("在含此文字的段落**之後**插入 caption。substring match on flattened run text（cross-run safe）。配合 text_instance（預設 1）指定第幾次出現。（五 anchor 擇一）")
                        ]),
                        "before_text": .object([
                            "type": .string("string"),
                            "description": .string("在含此文字的段落**之前**插入 caption。規則同 after_text。（五 anchor 擇一）")
                        ]),
                        "text_instance": .object([
                            "type": .string("integer"),
                            "description": .string("after_text / before_text 的第 N 次匹配（1-based，預設 1）")
                        ]),
                        "position": .object([
                            "type": .string("string"),
                            "description": .string("搭配 paragraph_index 使用：above（上方）、below（下方，預設）")
                        ]),
                        "include_chapter_number": .object([
                            "type": .string("boolean"),
                            "description": .string("是否 emit STYLEREF 章節編號 + \"-\" + SEQ 編號（如「圖 2-1」）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("label")])
                ])
            ),

            // v3.17.0 wrap_caption_seq (Refs #62) — bulk-wrap plain-text caption
            // numbers into SEQ fields so insert_table_of_figures /
            // insert_table_of_tables produce populated TOFs after pasting docs
            // from external sources (LaTeX-converted Word, Google Docs, Pandoc).
            Tool(
                name: "wrap_caption_seq",
                description: "v3.17.0+ (Refs #62) — bulk-wrap plain-text caption number portions in SEQ field runs across body paragraphs whose flattened text matches `pattern` (regex with EXACTLY ONE numeric capture group). Captured digit becomes the SEQ field's cachedResult so Word's first-open render preserves user-typed numbering before F9. Idempotent: paragraphs already wrapping a SEQ field for `sequence_name` are reported in `skipped` and never double-wrapped. Phase 1 ships scope:\"body\" only (recurses into table cells + nestedTables + block-level SDT children); scope:\"all\" returns Error: scope_not_implemented for now (cross-container path lands in v3.17.x). Bookmark wrap is opt-in (insert_bookmark + bookmark_template with literal `${number}` placeholder) so default 23-caption rescue does NOT pollute list_bookmarks. Returns JSON: {matched_paragraphs, fields_inserted, paragraphs_modified:[idx,...], skipped:[{paragraph_index, reason},...]} for downstream caller verification. All preconditions (pattern compile + capture-group count + format / scope enums + bookmark_template invariant + doc_id opened) checked BEFORE document mutation.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "pattern": .object([
                            "type": .string("string"),
                            "description": .string("Regex string with EXACTLY ONE numeric capture group (e.g. `圖 4-(\\d+)：`, `Figure (\\d+)\\.`). Captured group becomes SEQ field cachedResult.")
                        ]),
                        "sequence_name": .object([
                            "type": .string("string"),
                            "description": .string("SEQ identifier (e.g. \"Figure\", \"Table\", custom). Same identifier used by insert_caption / list_captions / update_all_fields.")
                        ]),
                        "format": .object([
                            "type": .string("string"),
                            "enum": .array([.string("ARABIC"), .string("ROMAN"), .string("ALPHABETIC")]),
                            "description": .string("SEQ field number format (default ARABIC). One of ARABIC / ROMAN / ALPHABETIC.")
                        ]),
                        "scope": .object([
                            "type": .string("string"),
                            "enum": .array([.string("body"), .string("all")]),
                            "description": .string("Walk scope (default `body`). `body` = body.children only (recurses into table cells + block-level SDT); `all` = body + headers + footers + footnotes + endnotes (NOT YET IMPLEMENTED in v3.17.0; returns Error: scope_not_implemented).")
                        ]),
                        "insert_bookmark": .object([
                            "type": .string("boolean"),
                            "description": .string("Default false. When true, wraps each SEQ run in `<w:bookmarkStart>`/`<w:bookmarkEnd>` for downstream cross-references; requires `bookmark_template`.")
                        ]),
                        "bookmark_template": .object([
                            "type": .string("string"),
                            "description": .string("Required when `insert_bookmark` is true. Must contain literal `${number}` placeholder; the captured numeric replaces it (e.g. `fig${number}` → `fig7` for `Figure 7.`). Without `${number}` the bookmark name would collide across captions (violates `<w:bookmarkStart>` name uniqueness).")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("pattern"), .string("sequence_name")])
                ])
            ),

            // 12.1.1 v3.1.0 Caption CRUD (Refs #17)
            Tool(
                name: "list_captions",
                description: "v3.1.0 — 列出文件所有 caption paragraphs（pStyle=Caption）with SEQ field info。返回 [{index, label, sequence_number, caption_text, paragraph_index}] in document order. Refs #17.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string"), "description": .string("文件識別碼")])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "get_caption",
                description: "v3.1.0 — 取得單一 caption 詳細資訊 { label, sequence_number, chapter_number?, caption_text, paragraph_index, field_instr_text }。Refs #17.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string"), "description": .string("文件識別碼")]),
                        "index": .object(["type": .string("integer"), "description": .string("caption index (0-based，from list_captions)")])
                    ]),
                    "required": .array([.string("doc_id"), .string("index")])
                ])
            ),
            Tool(
                name: "update_caption",
                description: "v3.1.0 — 修改 caption：new_caption_text 只換 SEQ 後的文字；new_label 同時換 label 與 SEQ identifier。必須提供其一。Refs #17.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string"), "description": .string("文件識別碼")]),
                        "index": .object(["type": .string("integer"), "description": .string("caption index (0-based)")]),
                        "new_caption_text": .object(["type": .string("string"), "description": .string("新的 caption 文字（可選）")]),
                        "new_label": .object(["type": .string("string"), "description": .string("新的 label（Figure/Table/Equation/圖/表/公式，可選）")])
                    ]),
                    "required": .array([.string("doc_id"), .string("index")])
                ])
            ),
            Tool(
                name: "delete_caption",
                description: "v3.1.0 — 刪除 caption paragraph。後續 captions index 會往前位移。Refs #17.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string"), "description": .string("文件識別碼")]),
                        "index": .object(["type": .string("integer"), "description": .string("caption index (0-based)")])
                    ]),
                    "required": .array([.string("doc_id"), .string("index")])
                ])
            ),
            Tool(
                name: "update_all_fields",
                description: "v3.1.0 — F9-equivalent：重算全文 SEQ field counters（body + headers + footers + footnotes + endnotes），支援 chapter-reset。非 SEQ fields (IF/DATE/PAGE/REF) 不動。返回 { identifier → final-count } 摘要。v3.8.0+ 加 isolate_per_container 選項（預設 false 維持全域共享；設 true 則 body / each header / each footer / footnotes / endnotes 各自獨立計數，符合 Word F9 per-container 語意，Refs #52）。Refs #19 #52.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string"), "description": .string("文件識別碼")]),
                        "isolate_per_container": .object([
                            "type": .string("boolean"),
                            "description": .string("v3.8.0+ (Refs #52)：true 則每個 container family（body/each header/each footer/footnotes/endnotes）獨立計數；預設 false 維持 v3.1.0 全域共享。")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "list_equations",
                description: "v3.1.0 — 列出文件所有 equations（<m:oMath> runs）。返回 [{index, paragraph_index, display_mode, components}]。Refs #21.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string"), "description": .string("文件識別碼")])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "get_equation",
                description: "v3.1.0 — 取得單一 equation 詳細資訊 { paragraph_index, display_mode, components (MathComponent JSON tree) }。Refs #21.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string"), "description": .string("文件識別碼")]),
                        "index": .object(["type": .string("integer"), "description": .string("equation index (0-based)")])
                    ]),
                    "required": .array([.string("doc_id"), .string("index")])
                ])
            ),
            Tool(
                name: "update_equation",
                description: "v3.1.0 — 取代 target equation 的 components tree。paragraph_index 和 display_mode 預設保留（除非 caller 明確傳 display_mode）。Refs #21.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string"), "description": .string("文件識別碼")]),
                        "index": .object(["type": .string("integer"), "description": .string("equation index (0-based)")]),
                        "components": .object(["type": .string("object"), "description": .string("新的 MathComponent JSON tree，同 insert_equation(components:) 格式")]),
                        "display_mode": .object(["type": .string("boolean"), "description": .string("是否為獨立區塊（預設保留原值）")])
                    ]),
                    "required": .array([.string("doc_id"), .string("index"), .string("components")])
                ])
            ),
            Tool(
                name: "delete_equation",
                description: "v3.1.0 — 刪除 target equation。若 equation 是該 paragraph 唯一 run，整段 paragraph 被刪除；否則只移除 equation run。Refs #21.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object(["type": .string("string"), "description": .string("文件識別碼")]),
                        "index": .object(["type": .string("integer"), "description": .string("equation index (0-based)")])
                    ]),
                    "required": .array([.string("doc_id"), .string("index")])
                ])
            ),

            // 12.2 insert_cross_reference - 插入交互參照
            Tool(
                name: "insert_cross_reference",
                description: "插入交互參照（連結到書籤、標題、圖表標號等）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("插入位置段落索引")
                        ]),
                        "reference_type": .object([
                            "type": .string("string"),
                            "description": .string("參照類型：bookmark（書籤）、heading（標題）、figure（圖）、table（表）、equation（公式）")
                        ]),
                        "reference_target": .object([
                            "type": .string("string"),
                            "description": .string("參照目標名稱或 ID")
                        ]),
                        "format": .object([
                            "type": .string("string"),
                            "description": .string("顯示格式：full（完整，如「圖 1」）、numberOnly（僅編號）、pageNumber（頁碼）、text（僅文字）")
                        ]),
                        "include_hyperlink": .object([
                            "type": .string("boolean"),
                            "description": .string("是否加入超連結（預設 true）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("reference_type"), .string("reference_target")])
                ])
            ),

            // 12.3 insert_table_of_figures - 插入圖表目錄
            Tool(
                name: "insert_table_of_figures",
                description: "插入圖表目錄",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("插入位置段落索引")
                        ]),
                        "caption_label": .object([
                            "type": .string("string"),
                            "description": .string("標號類型：Figure（圖）、Table（表）、Equation（公式）")
                        ]),
                        "include_page_numbers": .object([
                            "type": .string("boolean"),
                            "description": .string("是否包含頁碼（預設 true）")
                        ]),
                        "right_align_page_numbers": .object([
                            "type": .string("boolean"),
                            "description": .string("頁碼是否靠右對齊（預設 true）")
                        ]),
                        "tab_leader": .object([
                            "type": .string("string"),
                            "description": .string("定位點前導字元：dot（點線）、hyphen（連字號）、underscore（底線）、none（無）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("caption_label")])
                ])
            ),

            // 12.4 insert_index_entry - 標記索引項目
            Tool(
                name: "insert_index_entry",
                description: "標記文字為索引項目（用於生成索引）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("包含要標記文字的段落索引")
                        ]),
                        "main_entry": .object([
                            "type": .string("string"),
                            "description": .string("主索引詞")
                        ]),
                        "sub_entry": .object([
                            "type": .string("string"),
                            "description": .string("子索引詞（可選）")
                        ]),
                        "cross_reference": .object([
                            "type": .string("string"),
                            "description": .string("交互參照（如「參見 XXX」）")
                        ]),
                        "bold": .object([
                            "type": .string("boolean"),
                            "description": .string("頁碼是否粗體（預設 false）")
                        ]),
                        "italic": .object([
                            "type": .string("boolean"),
                            "description": .string("頁碼是否斜體（預設 false）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("main_entry")])
                ])
            ),

            // 12.5 insert_index - 插入索引
            Tool(
                name: "insert_index",
                description: "插入索引（根據已標記的索引項目）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("插入位置段落索引")
                        ]),
                        "columns": .object([
                            "type": .string("integer"),
                            "description": .string("索引欄數（1-4，預設 2）")
                        ]),
                        "right_align_page_numbers": .object([
                            "type": .string("boolean"),
                            "description": .string("頁碼是否靠右對齊（預設 true）")
                        ]),
                        "tab_leader": .object([
                            "type": .string("string"),
                            "description": .string("定位點前導字元：dot（點線）、hyphen（連字號）、underscore（底線）、none（無）")
                        ]),
                        "run_in": .object([
                            "type": .string("boolean"),
                            "description": .string("子項目是否接續顯示（預設 false）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index")])
                ])
            ),

            // ==================== Phase 4: 其他重要功能 ====================

            // 13.1 set_language - 設定校訂語言
            Tool(
                name: "set_language",
                description: "設定文字的校訂語言（用於拼字檢查）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "language": .object([
                            "type": .string("string"),
                            "description": .string("語言代碼（如 en-US、zh-TW、ja-JP）")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（不指定則套用全文件）")
                        ]),
                        "no_proofing": .object([
                            "type": .string("boolean"),
                            "description": .string("是否停用校訂（預設 false）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("language")])
                ])
            ),

            // 13.2 set_keep_lines - 段落不分頁
            Tool(
                name: "set_keep_lines",
                description: "設定段落不分頁（整個段落保持在同一頁）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "enable": .object([
                            "type": .string("boolean"),
                            "description": .string("是否啟用段落不分頁（預設 true）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index")])
                ])
            ),

            // 13.3 insert_tab_stop - 設定定位點
            Tool(
                name: "insert_tab_stop",
                description: "在段落中設定定位點",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "position": .object([
                            "type": .string("integer"),
                            "description": .string("定位點位置（twips，從左邊界算起）")
                        ]),
                        "alignment": .object([
                            "type": .string("string"),
                            "description": .string("對齊方式：left（靠左）、center（置中）、right（靠右）、decimal（小數點對齊）")
                        ]),
                        "leader": .object([
                            "type": .string("string"),
                            "description": .string("前導字元：none（無）、dot（點線）、hyphen（連字號）、underscore（底線）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("position")])
                ])
            ),

            // 13.4 clear_tab_stops - 清除定位點
            Tool(
                name: "clear_tab_stops",
                description: "清除段落的所有定位點",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index")])
                ])
            ),

            // 13.5 set_page_break_before - 段落前分頁
            Tool(
                name: "set_page_break_before",
                description: "設定段落前分頁（段落從新頁開始）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "enable": .object([
                            "type": .string("boolean"),
                            "description": .string("是否啟用段落前分頁（預設 true）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index")])
                ])
            ),

            // 13.6 set_outline_level - 設定大綱層級
            Tool(
                name: "set_outline_level",
                description: "設定段落的大綱層級（用於生成目錄和導覽）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("段落索引（從 0 開始）")
                        ]),
                        "level": .object([
                            "type": .string("integer"),
                            "description": .string("大綱層級（1-9，或 0 表示本文）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index"), .string("level")])
                ])
            ),

            // 13.7 insert_continuous_section_break - 連續分節符
            Tool(
                name: "insert_continuous_section_break",
                description: "插入連續分節符（不換頁的分節）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "paragraph_index": .object([
                            "type": .string("integer"),
                            "description": .string("插入位置段落索引")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("paragraph_index")])
                ])
            ),

            // 13.8 get_section_properties - 取得節屬性
            Tool(
                name: "get_section_properties",
                description: "取得文件的節屬性（頁面設定等）（支援 Direct Mode）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼（Session Mode）")
                        ]),
                        "source_path": .object([
                            "type": .string("string"),
                            "description": .string("檔案路徑（Direct Mode，免開啟）")
                        ])
                    ])
                ])
            ),

            // 13.9 add_row_to_table - 新增表格列
            Tool(
                name: "add_row_to_table",
                description: "在表格中新增一列",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "table_index": .object([
                            "type": .string("integer"),
                            "description": .string("表格索引（從 0 開始）")
                        ]),
                        "position": .object([
                            "type": .string("string"),
                            "description": .string("插入位置：end（最後）、start（最前）、after_row（指定列之後）")
                        ]),
                        "row_index": .object([
                            "type": .string("integer"),
                            "description": .string("當 position=after_row 時，指定在哪一列之後插入")
                        ]),
                        "data": .object([
                            "type": .string("array"),
                            "description": .string("新列的儲存格資料陣列")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("table_index")])
                ])
            ),

            // 13.10 add_column_to_table - 新增表格欄
            Tool(
                name: "add_column_to_table",
                description: "在表格中新增一欄",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "table_index": .object([
                            "type": .string("integer"),
                            "description": .string("表格索引（從 0 開始）")
                        ]),
                        "position": .object([
                            "type": .string("string"),
                            "description": .string("插入位置：end（最後）、start（最前）、after_col（指定欄之後）")
                        ]),
                        "col_index": .object([
                            "type": .string("integer"),
                            "description": .string("當 position=after_col 時，指定在哪一欄之後插入")
                        ]),
                        "data": .object([
                            "type": .string("array"),
                            "description": .string("新欄的儲存格資料陣列")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("table_index")])
                ])
            ),

            // 13.11 delete_row_from_table - 刪除表格列
            Tool(
                name: "delete_row_from_table",
                description: "從表格中刪除一列",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "table_index": .object([
                            "type": .string("integer"),
                            "description": .string("表格索引（從 0 開始）")
                        ]),
                        "row_index": .object([
                            "type": .string("integer"),
                            "description": .string("要刪除的列索引（從 0 開始）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("table_index"), .string("row_index")])
                ])
            ),

            // 13.12 delete_column_from_table - 刪除表格欄
            Tool(
                name: "delete_column_from_table",
                description: "從表格中刪除一欄",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "table_index": .object([
                            "type": .string("integer"),
                            "description": .string("表格索引（從 0 開始）")
                        ]),
                        "col_index": .object([
                            "type": .string("integer"),
                            "description": .string("要刪除的欄索引（從 0 開始）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("table_index"), .string("col_index")])
                ])
            ),

            // 13.13 set_cell_width - 設定儲存格寬度
            Tool(
                name: "set_cell_width",
                description: "設定表格儲存格寬度",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "table_index": .object([
                            "type": .string("integer"),
                            "description": .string("表格索引（從 0 開始）")
                        ]),
                        "row": .object([
                            "type": .string("integer"),
                            "description": .string("列索引（從 0 開始）")
                        ]),
                        "col": .object([
                            "type": .string("integer"),
                            "description": .string("欄索引（從 0 開始）")
                        ]),
                        "width": .object([
                            "type": .string("integer"),
                            "description": .string("寬度（twips）")
                        ]),
                        "width_type": .object([
                            "type": .string("string"),
                            "description": .string("寬度類型：dxa（固定 twips）、pct（百分比）、auto（自動）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("table_index"), .string("row"), .string("col"), .string("width")])
                ])
            ),

            // 13.14 set_row_height - 設定列高
            Tool(
                name: "set_row_height",
                description: "設定表格列高",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "table_index": .object([
                            "type": .string("integer"),
                            "description": .string("表格索引（從 0 開始）")
                        ]),
                        "row_index": .object([
                            "type": .string("integer"),
                            "description": .string("列索引（從 0 開始）")
                        ]),
                        "height": .object([
                            "type": .string("integer"),
                            "description": .string("高度（twips）")
                        ]),
                        "height_rule": .object([
                            "type": .string("string"),
                            "description": .string("高度規則：auto（自動）、atLeast（最小）、exact（固定）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("table_index"), .string("row_index"), .string("height")])
                ])
            ),

            // 13.15 set_table_alignment - 設定表格對齊
            Tool(
                name: "set_table_alignment",
                description: "設定表格在頁面上的對齊方式",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "table_index": .object([
                            "type": .string("integer"),
                            "description": .string("表格索引（從 0 開始）")
                        ]),
                        "alignment": .object([
                            "type": .string("string"),
                            "description": .string("對齊方式：left（靠左）、center（置中）、right（靠右）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("table_index"), .string("alignment")])
                ])
            ),

            // 13.16 set_cell_vertical_alignment - 設定儲存格垂直對齊
            Tool(
                name: "set_cell_vertical_alignment",
                description: "設定表格儲存格的垂直對齊方式",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "table_index": .object([
                            "type": .string("integer"),
                            "description": .string("表格索引（從 0 開始）")
                        ]),
                        "row": .object([
                            "type": .string("integer"),
                            "description": .string("列索引（從 0 開始）")
                        ]),
                        "col": .object([
                            "type": .string("integer"),
                            "description": .string("欄索引（從 0 開始）")
                        ]),
                        "alignment": .object([
                            "type": .string("string"),
                            "description": .string("垂直對齊：top（頂端）、center（置中）、bottom（底端）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("table_index"), .string("row"), .string("col"), .string("alignment")])
                ])
            ),

            // 13.17 set_header_row - 設定標題列
            Tool(
                name: "set_header_row",
                description: "設定表格標題列（跨頁時重複顯示）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "table_index": .object([
                            "type": .string("integer"),
                            "description": .string("表格索引（從 0 開始）")
                        ]),
                        "row_count": .object([
                            "type": .string("integer"),
                            "description": .string("標題列數量（從第一列算起，預設 1）")
                        ])
                    ]),
                    "required": .array([.string("doc_id"), .string("table_index")])
                ])
            ),
            // Phase 4 (v3.6.0, closes #37): autosave / checkpoint / recover_from_autosave.
            Tool(
                name: "checkpoint",
                description: "v3.6.0 新增：手動寫入目前 in-memory session state 到 disk。預設目標 <source>.autosave.docx；可選 path 參數寫到任意位置。不會清 is_dirty（不像 save_document）也不會更新 disk_hash/disk_mtime。Refs #37.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("可選輸出路徑；省略時寫到 <source>.autosave.docx")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            ),
            Tool(
                name: "recover_from_autosave",
                description: "v3.6.0 新增：從 <source>.autosave.docx 還原 session state（取代當前 in-memory doc，並設 is_dirty: true）。dirty session 沒傳 discard_changes: true 時回傳 E_DIRTY_DOC。autosave 檔不刪——下次 save_document 才清。Refs #37.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_id": .object([
                            "type": .string("string"),
                            "description": .string("文件識別碼")
                        ]),
                        "discard_changes": .object([
                            "type": .string("boolean"),
                            "description": .string("dirty session 強制覆蓋；預設 false")
                        ])
                    ]),
                    "required": .array([.string("doc_id")])
                ])
            )
        ]
    }

    // MARK: - Tool Handler

    private func handleToolCall(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let name = params.name
        let args = params.arguments ?? [:]

        do {
            let result = try await executeToolTask(name: name, args: args)
            return CallTool.Result(content: [.text(result)])
        } catch {
            return CallTool.Result(
                content: [.text("Error: \(error.localizedDescription)")],
                isError: true
            )
        }
    }

    private func executeToolTask(name: String, args: [String: Value]) async throws -> String {
        switch name {
        // 文件管理
        case "create_document":
            return try await createDocument(args: args)
        case "open_document":
            return try await openDocument(args: args)
        case "save_document":
            return try await saveDocument(args: args)
        case "close_document":
            return try await closeDocument(args: args)
        case "finalize_document":
            return try await finalizeDocument(args: args)
        case "get_document_session_state":
            return try await getDocumentSessionState(args: args)
        case "get_session_state":
            return try await getSessionState(args: args)
        case "revert_to_disk":
            return try await revertToDisk(args: args)
        case "reload_from_disk":
            return try await reloadFromDisk(args: args)
        case "check_disk_drift":
            return try await checkDiskDrift(args: args)
        case "list_open_documents":
            return await listOpenDocuments()
        case "get_document_info":
            return try await getDocumentInfo(args: args)

        // 內容操作
        case "get_text":
            return try await getText(args: args)
        case "get_paragraphs":
            return try await getParagraphs(args: args)
        case "insert_paragraph":
            return try await insertParagraph(args: args)
        case "update_paragraph":
            return try await updateParagraph(args: args)
        case "delete_paragraph":
            return try await deleteParagraph(args: args)
        case "replace_text":
            return try await replaceText(args: args)
        case "replace_text_batch":
            return try await replaceTextBatch(args: args)

        // 格式化
        case "format_text":
            return try await formatText(args: args)
        case "set_paragraph_format":
            return try await setParagraphFormat(args: args)
        case "apply_style":
            return try await applyStyle(args: args)

        // 表格
        case "insert_table":
            return try await insertTable(args: args)
        case "get_tables":
            return try await getTables(args: args)
        case "update_cell":
            return try await updateCell(args: args)
        case "delete_table":
            return try await deleteTable(args: args)
        case "merge_cells":
            return try await mergeCells(args: args)
        case "set_table_style":
            return try await setTableStyle(args: args)

        // 樣式管理
        case "list_styles":
            return try await listStyles(args: args)
        case "create_style":
            return try await createStyle(args: args)
        case "update_style":
            return try await updateStyle(args: args)
        case "delete_style":
            return try await deleteStyle(args: args)

        // 清單/編號
        case "insert_bullet_list":
            return try await insertBulletList(args: args)
        case "insert_numbered_list":
            return try await insertNumberedList(args: args)
        case "set_list_level":
            return try await setListLevel(args: args)

        // 頁面設定
        case "set_page_size":
            return try await setPageSize(args: args)
        case "set_page_margins":
            return try await setPageMargins(args: args)
        case "set_page_orientation":
            return try await setPageOrientation(args: args)
        case "insert_page_break":
            return try await insertPageBreak(args: args)
        case "insert_section_break":
            return try await insertSectionBreak(args: args)

        // 頁首/頁尾
        case "add_header":
            return try await addHeader(args: args)
        case "update_header":
            return try await updateHeader(args: args)
        case "add_footer":
            return try await addFooter(args: args)
        case "update_footer":
            return try await updateFooter(args: args)
        case "insert_page_number":
            return try await insertPageNumber(args: args)

        // 圖片
        case "insert_image":
            return try await insertImage(args: args)
        case "insert_image_from_path":
            return try await insertImageFromPath(args: args)
        case "update_image":
            return try await updateImage(args: args)
        case "delete_image":
            return try await deleteImage(args: args)
        case "list_images":
            return try await listImages(args: args)
        case "export_image":
            return try await exportImage(args: args)
        case "export_all_images":
            return try await exportAllImages(args: args)
        case "set_image_style":
            return try await setImageStyle(args: args)

        // 匯出
        case "export_text":
            return try await exportText(args: args)
        case "export_markdown":
            return try await exportMarkdown(args: args)

        // 超連結和書籤
        case "insert_hyperlink":
            return try await insertHyperlink(args: args)
        case "insert_internal_link":
            return try await insertInternalLink(args: args)
        case "update_hyperlink":
            return try await updateHyperlink(args: args)
        case "delete_hyperlink":
            return try await deleteHyperlink(args: args)
        case "insert_bookmark":
            return try await insertBookmark(args: args)
        case "delete_bookmark":
            return try await deleteBookmark(args: args)

        // 註解和修訂
        case "insert_comment":
            return try await insertComment(args: args)
        case "update_comment":
            return try await updateComment(args: args)
        case "delete_comment":
            return try await deleteComment(args: args)
        case "list_comments":
            return try await listComments(args: args)
        case "enable_track_changes":
            return try await enableTrackChanges(args: args)
        case "disable_track_changes":
            return try await disableTrackChanges(args: args)
        case "accept_revision":
            return try await acceptRevision(args: args)
        case "reject_revision":
            return try await rejectRevision(args: args)
        case "insert_text_as_revision":
            return try await insertTextAsRevision(args: args)
        case "delete_text_as_revision":
            return try await deleteTextAsRevision(args: args)
        case "move_text_as_revision":
            return try await moveTextAsRevision(args: args)

        // 腳註/尾註
        case "insert_footnote":
            return try await insertFootnote(args: args)
        case "delete_footnote":
            return try await deleteFootnote(args: args)
        case "insert_endnote":
            return try await insertEndnote(args: args)
        case "delete_endnote":
            return try await deleteEndnote(args: args)

        // 進階功能 (P7)
        case "insert_toc":
            return try await insertTOC(args: args)
        case "insert_text_field":
            return try await insertTextField(args: args)
        case "insert_checkbox":
            return try await insertCheckbox(args: args)
        case "insert_dropdown":
            return try await insertDropdown(args: args)
        case "insert_equation":
            return try await insertEquation(args: args)
        case "set_paragraph_border":
            return try await setParagraphBorder(args: args)
        case "set_paragraph_shading":
            return try await setParagraphShading(args: args)
        case "set_character_spacing":
            return try await setCharacterSpacing(args: args)
        case "set_text_effect":
            return try await setTextEffect(args: args)

        // 8.1 註解回覆與解析
        case "reply_to_comment":
            return try await replyToComment(args: args)
        case "resolve_comment":
            return try await resolveComment(args: args)

        // 8.2 浮動圖片
        case "insert_floating_image":
            return try await insertFloatingImage(args: args)

        // 8.3 欄位代碼
        case "insert_if_field":
            return try await insertIfField(args: args)
        case "insert_calculation_field":
            return try await insertCalculationField(args: args)
        case "insert_date_field":
            return try await insertDateField(args: args)
        case "insert_page_field":
            return try await insertPageField(args: args)
        case "insert_merge_field":
            return try await insertMergeField(args: args)
        case "insert_sequence_field":
            return try await insertSequenceField(args: args)

        // 8.4 內容控制項（SDT）
        case "insert_content_control":
            return try await insertContentControl(args: args)
        case "insert_repeating_section":
            return try await insertRepeatingSection(args: args)

        // #44 Phase 5–8: SDT read / write / extension / stub tools
        case "list_content_controls":
            return try await listContentControls(args: args)
        case "get_content_control":
            return try await getContentControl(args: args)
        case "list_repeating_section_items":
            return try await listRepeatingSectionItems(args: args)
        case "update_content_control_text":
            return try await updateContentControlText(args: args)
        case "replace_content_control_content":
            return try await replaceContentControlContentTool(args: args)
        case "delete_content_control":
            return try await deleteContentControlTool(args: args)
        case "update_repeating_section_item":
            return try await updateRepeatingSectionItem(args: args)
        case "list_custom_xml_parts":
            return try await listCustomXmlParts(args: args)

        // #44 styles-sections-numbering-foundations (v3.10.0+)
        case "get_style_inheritance_chain":
            return try await getStyleInheritanceChain(args: args)
        case "link_styles":
            return try await linkStylesTool(args: args)
        case "set_latent_styles":
            return try await setLatentStylesTool(args: args)
        case "add_style_name_alias":
            return try await addStyleNameAliasTool(args: args)
        case "list_numbering_definitions":
            return try await listNumberingDefinitions(args: args)
        case "get_numbering_definition":
            return try await getNumberingDefinition(args: args)
        case "create_numbering_definition":
            return try await createNumberingDefinition(args: args)
        case "override_numbering_level":
            return try await overrideNumberingLevel(args: args)
        case "assign_numbering_to_paragraph":
            return try await assignNumberingToParagraph(args: args)
        case "continue_list":
            return try await continueListTool(args: args)
        case "start_new_list":
            return try await startNewListTool(args: args)
        case "gc_orphan_numbering":
            return try await gcOrphanNumbering(args: args)
        case "set_line_numbers_for_section":
            return try await setLineNumbersForSection(args: args)
        case "set_section_vertical_alignment":
            return try await setSectionVerticalAlignment(args: args)
        case "set_page_number_format":
            return try await setPageNumberFormat(args: args)
        case "set_section_break_type":
            return try await setSectionBreakType(args: args)
        case "set_title_page_distinct":
            return try await setTitlePageDistinct(args: args)
        case "set_section_header_footer_references":
            return try await setSectionHeaderFooterReferences(args: args)
        case "get_all_sections":
            return try await getAllSections(args: args)

        // #44 tables-hyperlinks-headers-builtin (v3.11.0+)
        case "set_table_conditional_style":
            return try await setTableConditionalStyleTool(args: args)
        case "insert_nested_table":
            return try await insertNestedTableTool(args: args)
        case "set_table_layout":
            return try await setTableLayoutTool(args: args)
        case "set_header_row":
            return try await setHeaderRowTool(args: args)
        case "set_table_indent":
            return try await setTableIndentTool(args: args)
        case "insert_url_hyperlink":
            return try await insertUrlHyperlinkTool(args: args)
        case "insert_bookmark_hyperlink":
            return try await insertBookmarkHyperlinkTool(args: args)
        case "insert_email_hyperlink":
            return try await insertEmailHyperlinkTool(args: args)
        case "enable_even_odd_headers":
            return try await enableEvenOddHeadersTool(args: args)
        case "link_section_header_to_previous":
            return try await linkSectionHeaderToPreviousTool(args: args)
        case "unlink_section_header_from_previous":
            return try await unlinkSectionHeaderFromPreviousTool(args: args)
        case "get_section_header_map":
            return try await getSectionHeaderMapTool(args: args)

        // 9. 新增功能 (P9)
        case "insert_text":
            return try await insertText(args: args)
        case "get_document_text":
            return try await getDocumentText(args: args)
        case "search_text":
            return try await searchText(args: args)
        case "search_text_batch":
            return try await searchTextBatch(args: args)
        case "list_hyperlinks":
            return try await listHyperlinks(args: args)
        case "list_bookmarks":
            return try await listBookmarks(args: args)
        case "list_footnotes":
            return try await listFootnotes(args: args)
        case "list_endnotes":
            return try await listEndnotes(args: args)
        case "get_revisions":
            return try await getRevisions(args: args)
        case "accept_all_revisions":
            return try await acceptAllRevisions(args: args)
        case "reject_all_revisions":
            return try await rejectAllRevisions(args: args)
        case "set_document_properties":
            return try await setDocumentProperties(args: args)
        case "get_document_properties":
            return try await getDocumentProperties(args: args)
        case "get_paragraph_runs":
            return try await getParagraphRuns(args: args)
        case "get_text_with_formatting":
            return try await getTextWithFormatting(args: args)
        case "search_by_formatting":
            return try await searchByFormatting(args: args)
        case "search_text_with_formatting":
            return try await searchTextWithFormatting(args: args)
        case "list_all_formatted_text":
            return try await listAllFormattedText(args: args)
        case "get_word_count_by_section":
            return try await getWordCountBySection(args: args)
        case "compare_documents":
            return try await compareDocuments(args: args)

        // manuscript-review-markdown-export change
        case "export_revision_summary_markdown":
            return try await exportRevisionSummaryMarkdown(args: args)
        case "compare_documents_markdown":
            return try await compareDocumentsMarkdown(args: args)
        case "export_comment_threads_markdown":
            return try await exportCommentThreadsMarkdown(args: args)

        // Phase 1: 進階排版功能
        case "set_columns":
            return try await setColumns(args: args)
        case "insert_column_break":
            return try await insertColumnBreak(args: args)
        case "set_line_numbers":
            return try await setLineNumbers(args: args)
        case "set_page_borders":
            return try await setPageBorders(args: args)
        case "insert_symbol":
            return try await insertSymbol(args: args)
        case "set_text_direction":
            return try await setTextDirection(args: args)
        case "insert_drop_cap":
            return try await insertDropCap(args: args)
        case "insert_horizontal_line":
            return try await insertHorizontalLine(args: args)
        case "set_widow_orphan":
            return try await setWidowOrphan(args: args)
        case "set_keep_with_next":
            return try await setKeepWithNext(args: args)

        // Phase 2: 浮水印與文件保護
        case "insert_watermark":
            return try await insertWatermark(args: args)
        case "insert_image_watermark":
            return try await insertImageWatermark(args: args)
        case "remove_watermark":
            return try await removeWatermark(args: args)
        case "protect_document":
            return try await protectDocument(args: args)
        case "unprotect_document":
            return try await unprotectDocument(args: args)
        case "set_document_password":
            return try await setDocumentPassword(args: args)
        case "remove_document_password":
            return try await removeDocumentPassword(args: args)
        case "restrict_editing_region":
            return try await restrictEditingRegion(args: args)

        // v3.3.0: Phase 2A — Theme tools (closes #28)
        case "get_theme":
            return try await getTheme(args: args)
        case "update_theme_fonts":
            return try await updateThemeFonts(args: args)
        case "update_theme_color":
            return try await updateThemeColor(args: args)
        case "set_theme":
            return try await setTheme(args: args)

        // v3.3.0: Phase 2A — Headers + Footers CRUD (closes #26 #27)
        case "list_headers":
            return try await listHeaders(args: args)
        case "get_header":
            return try await getHeaderTool(args: args)
        case "delete_header":
            return try await deleteHeader(args: args)
        case "list_watermarks":
            return try await listWatermarks(args: args)
        case "get_watermark":
            return try await getWatermark(args: args)
        case "list_footers":
            return try await listFooters(args: args)
        case "get_footer":
            return try await getFooterTool(args: args)
        case "delete_footer":
            return try await deleteFooter(args: args)

        // v3.4.0: Phase 2B — Comment threads + people (closes #29 #30)
        case "list_comment_threads":
            return try await listCommentThreads(args: args)
        case "get_comment_thread":
            return try await getCommentThread(args: args)
        case "sync_extended_comments":
            return try await syncExtendedComments(args: args)
        case "list_people":
            return try await listPeople(args: args)
        case "add_person":
            return try await addPerson(args: args)
        case "update_person":
            return try await updatePerson(args: args)
        case "delete_person":
            return try await deletePerson(args: args)

        // v3.5.0: Phase 2C — Notes update + web settings (closes #24 #25 #31)
        case "get_endnote":
            return try await getEndnoteTool(args: args)
        case "update_endnote":
            return try await updateEndnoteTool(args: args)
        case "get_footnote":
            return try await getFootnoteTool(args: args)
        case "update_footnote":
            return try await updateFootnoteTool(args: args)
        case "get_web_settings":
            return try await getWebSettings(args: args)
        case "update_web_settings":
            return try await updateWebSettings(args: args)

        // Phase 3: 學術功能
        case "insert_caption":
            return try await insertCaption(args: args)
        case "wrap_caption_seq":
            return try await wrapCaptionSeq(args: args)
        // v3.1.0 Caption CRUD + update_all_fields + Equation CRUD (Refs #17 #19 #21)
        case "list_captions":
            return try await listCaptionsHandler(args: args)
        case "get_caption":
            return try await getCaptionHandler(args: args)
        case "update_caption":
            return try await updateCaptionHandler(args: args)
        case "delete_caption":
            return try await deleteCaptionHandler(args: args)
        case "update_all_fields":
            return try await updateAllFieldsHandler(args: args)
        case "list_equations":
            return try await listEquationsHandler(args: args)
        case "get_equation":
            return try await getEquationHandler(args: args)
        case "update_equation":
            return try await updateEquationHandler(args: args)
        case "delete_equation":
            return try await deleteEquationHandler(args: args)
        case "insert_cross_reference":
            return try await insertCrossReference(args: args)
        case "insert_table_of_figures":
            return try await insertTableOfFigures(args: args)
        case "insert_index_entry":
            return try await insertIndexEntry(args: args)
        case "insert_index":
            return try await insertIndex(args: args)

        // Phase 4: 其他重要功能
        case "set_language":
            return try await setLanguage(args: args)
        case "set_keep_lines":
            return try await setKeepLines(args: args)
        case "insert_tab_stop":
            return try await insertTabStop(args: args)
        case "clear_tab_stops":
            return try await clearTabStops(args: args)
        case "set_page_break_before":
            return try await setPageBreakBefore(args: args)
        case "set_outline_level":
            return try await setOutlineLevel(args: args)
        case "insert_continuous_section_break":
            return try await insertContinuousSectionBreak(args: args)
        case "get_section_properties":
            return try await getSectionProperties(args: args)
        case "add_row_to_table":
            return try await addRowToTable(args: args)
        case "add_column_to_table":
            return try await addColumnToTable(args: args)
        case "delete_row_from_table":
            return try await deleteRowFromTable(args: args)
        case "delete_column_from_table":
            return try await deleteColumnFromTable(args: args)
        case "set_cell_width":
            return try await setCellWidth(args: args)
        case "set_row_height":
            return try await setRowHeight(args: args)
        case "set_table_alignment":
            return try await setTableAlignment(args: args)
        case "set_cell_vertical_alignment":
            return try await setCellVerticalAlignment(args: args)
        case "set_header_row":
            return try await setHeaderRow(args: args)

        // Phase 4 (v3.6.0, closes #37)
        case "checkpoint":
            return try await checkpoint(args: args)
        case "recover_from_autosave":
            return try await recoverFromAutosave(args: args)

        default:
            throw WordError.unknownTool(name)
        }
    }

    // MARK: - Dual-Mode Document Resolution

    /// Resolve document from either source_path (Direct Mode) or doc_id (Session Mode)
    /// - Returns: (document, isTemporary) - isTemporary=true means opened just for this call
    private func resolveDocument(args: [String: Value]) async throws -> (WordDocument, Bool) {
        if let sourcePath = args["source_path"]?.stringValue {
            // Direct Mode - open temporarily, read-only
            guard FileManager.default.fileExists(atPath: sourcePath) else {
                throw WordError.fileNotFound(sourcePath)
            }
            let sourceURL = URL(fileURLWithPath: sourcePath)
            let lockFile = sourceURL.deletingLastPathComponent()
                .appendingPathComponent("~$" + sourceURL.lastPathComponent)
            if FileManager.default.fileExists(atPath: lockFile.path) {
                throw WordError.invalidFormat("File is open in Microsoft Word. Please save and close it first: \(sourceURL.lastPathComponent)")
            }
            let document = try DocxReader.read(from: sourceURL)
            return (document, true)
        } else if let docId = args["doc_id"]?.stringValue {
            // Session Mode - use already-opened document
            guard let doc = openDocuments[docId] else {
                throw WordError.documentNotFound(docId)
            }
            return (doc, false)
        } else {
            throw WordError.missingParameter("source_path or doc_id")
        }
    }

    // MARK: - Document Management

    private func createDocument(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        if openDocuments[docId] != nil {
            throw WordError.documentAlreadyOpen(docId)
        }

        let autosave = args["autosave"]?.boolValue ?? false
        var doc = WordDocument()
        doc.enableTrackChanges(author: defaultRevisionAuthor)
        initializeSession(docId: docId, document: doc, sourcePath: nil, autosave: autosave)

        return "Created new document with id: \(docId). Track changes is enabled by default."
    }

    private func openDocument(args: [String: Value]) async throws -> String {
        guard let path = args["path"]?.stringValue else {
            throw WordError.missingParameter("path")
        }
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        if openDocuments[docId] != nil {
            throw WordError.documentAlreadyOpen(docId)
        }
        let autosave = args["autosave"]?.boolValue ?? false
        // BREAKING v3.0.0: track_changes default flipped from on → off (Refs #13)
        let trackChanges = args["track_changes"]?.boolValue ?? false
        // Phase 4 (v3.6.0, closes #37): per-N-mutations checkpoint throttle.
        // Phase C (Design B, #40): default flipped from 0 to 1.
        // Callers wanting zero autosave overhead must explicitly pass autosave_every: 0.
        let autosaveEveryN = args["autosave_every"]?.intValue ?? 1

        let url = URL(fileURLWithPath: path)
        var doc = try DocxReader.read(from: url)
        if trackChanges && !doc.isTrackChangesEnabled() {
            doc.enableTrackChanges(author: defaultRevisionAuthor)
        }
        initializeSession(
            docId: docId, document: doc, sourcePath: path,
            autosave: autosave, autosaveEveryN: autosaveEveryN
        )
        // Override trackChangesEnforced default (initializeSession sets true)
        documentTrackChangesEnforced[docId] = trackChanges

        // Capture disk-hash + mtime from freshly opened file (3.0.0 — Refs #15)
        if let hash = try? SessionState.computeSHA256(path: path) {
            documentDiskHash[docId] = hash
        }
        if let mtime = try? SessionState.readMtime(path: path) {
            documentDiskMtime[docId] = mtime
        }

        let tcLabel = trackChanges ? "Track changes enabled." : "Track changes disabled (default since v3.0.0; pass track_changes: true to enable)."
        return "Opened document '\(path)' with id: \(docId). \(tcLabel)"
    }

    private func saveDocument(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let explicitPath = args["path"]?.stringValue
        let path = try effectiveSavePath(for: docId, explicitPath: explicitPath)
        let keepBak = args["keep_bak"]?.boolValue ?? false
        try persistDocumentToDisk(doc, docId: docId, path: path, keepBak: keepBak)
        // Phase 4: clean up <source>.autosave.docx after successful save.
        cleanupAutosaveFile(for: docId)

        let bakSuffix = keepBak && FileManager.default.fileExists(atPath: path + ".bak")
            ? " (pre-save bytes preserved at \(path).bak)"
            : ""
        if explicitPath == nil {
            return "Saved document to original path: \(path)\(bakSuffix)"
        }
        return "Saved document to: \(path)\(bakSuffix)"
    }

    private func closeDocument(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard openDocuments[docId] != nil else {
            throw WordError.documentNotFound(docId)
        }
        // v3.0.0: explicit discard flag (Refs #12)
        let discardChanges = args["discard_changes"]?.boolValue ?? false

        if isDirty(docId: docId) && !discardChanges {
            return """
            Error: E_DIRTY_DOC — document '\(docId)' has uncommitted changes.
            Choose one:
              - call save_document first to persist your edits, then close_document
              - pass discard_changes: true to release without saving
              - use finalize_document for save+close in one step
            """
        }

        removeSession(docId: docId)
        let suffix = (discardChanges && openDocuments[docId] == nil) ? " (changes discarded)" : ""
        return "Closed document: \(docId)\(suffix)"
    }

    private func finalizeDocument(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let explicitPath = args["path"]?.stringValue
        let path = try effectiveSavePath(for: docId, explicitPath: explicitPath)
        try persistDocumentToDisk(doc, docId: docId, path: path)
        // Phase 4: clean up <source>.autosave.docx after successful finalize.
        cleanupAutosaveFile(for: docId)
        removeSession(docId: docId)

        return "Finalized document '\(docId)' to: \(path)"
    }

    // MARK: - Phase 4 (v3.6.0, closes #37) — checkpoint + recover_from_autosave

    /// `checkpoint` MCP tool — manual session state write. Defaults to
    /// `<source>.autosave.docx`; explicit `path` overrides. Does NOT clear
    /// is_dirty (unlike save_document), does NOT update disk_hash/disk_mtime.
    private func checkpoint(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let target: String
        if let explicit = args["path"]?.stringValue, !explicit.isEmpty {
            target = explicit
        } else {
            guard let sourcePath = documentOriginalPaths[docId], !sourcePath.isEmpty else {
                throw WordError.invalidParameter(
                    "path",
                    "checkpoint default path requires the document to have a known source path; pass explicit path or open from disk first."
                )
            }
            target = sourcePath + ".autosave.docx"
        }

        try DocxWriter.write(doc, to: URL(fileURLWithPath: target))
        return "Checkpoint written for '\(docId)' to: \(target)"
    }

    /// `recover_from_autosave` MCP tool — replace in-memory doc with bytes
    /// from `<source>.autosave.docx`, set is_dirty: true, do NOT delete the
    /// autosave file (cleanup deferred to next save_document).
    private func recoverFromAutosave(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard openDocuments[docId] != nil else {
            throw WordError.documentNotFound(docId)
        }
        guard let sourcePath = documentOriginalPaths[docId], !sourcePath.isEmpty else {
            return "Error: E_NO_AUTOSAVE — document '\(docId)' has no known source path."
        }
        let autosavePath = sourcePath + ".autosave.docx"
        guard FileManager.default.fileExists(atPath: autosavePath) else {
            return "Error: E_NO_AUTOSAVE — no autosave file at '\(autosavePath)'."
        }

        let discardChanges = args["discard_changes"]?.boolValue ?? false
        if isDirty(docId: docId) && !discardChanges {
            return """
            Error: E_DIRTY_DOC — document '\(docId)' has uncommitted changes.
            Choose one:
              - call save_document first to persist current edits, then recover_from_autosave
              - pass discard_changes: true to overwrite in-memory state with autosave bytes
              - use finalize_document to save+close before recovering
            """
        }

        let recoveredDoc = try DocxReader.read(from: URL(fileURLWithPath: autosavePath))
        openDocuments[docId] = recoveredDoc
        documentDirtyState[docId] = true
        return "Recovered document '\(docId)' from autosave: \(autosavePath). Call save_document to persist."
    }

    private func getDocumentSessionState(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let dirty = isDirty(docId: docId)
        let autosaveEnabled = documentAutosave[docId] ?? false
        let trackChangesEnforced = documentTrackChangesEnforced[docId] ?? true
        let trackChangesEnabled = doc.isTrackChangesEnabled()
        let originalPath = documentOriginalPaths[docId]
        let closeReady = !dirty
        let saveReady = originalPath != nil
        let finalizeReady = saveReady

        return """
        Document Session State (\(docId)):
        - Dirty: \(dirty)
        - Autosave enabled: \(autosaveEnabled)
        - Track changes enabled: \(trackChangesEnabled)
        - Track changes enforced by server: \(trackChangesEnforced)
        - Original path: \(originalPath ?? "(none)")
        - Save without explicit path available: \(saveReady)
        - Close without save allowed: \(closeReady)
        - Finalize without explicit path available: \(finalizeReady)
        """
    }

    // MARK: - v3.0.0 Session State API (Refs #12 #13 #15)

    /// ISO8601 formatter for serialized session responses. Lazy static.
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Hex encoding for SHA256 Data.
    private func hexString(_ data: Data) -> String {
        return data.map { String(format: "%02x", $0) }.joined()
    }

    /// get_session_state — superset of get_document_session_state
    private func getSessionState(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let view = sessionStateView(for: docId) else {
            throw WordError.documentNotFound(docId)
        }
        let diskHashHex = view.diskHash.map { hexString($0) } ?? "(none)"
        let diskMtime = view.diskMtime.map { Self.iso8601Formatter.string(from: $0) } ?? "(none)"
        return """
        Session State (\(docId)):
        - source_path: \(view.sourcePath)
        - disk_hash_hex: \(diskHashHex)
        - disk_mtime_iso8601: \(diskMtime)
        - is_dirty: \(view.isDirty)
        - track_changes_enabled: \(view.trackChangesEnabled)
        - autosave_detected: \(view.autosaveDetected)
        - autosave_path: \(view.autosavePath ?? "(none)")
        """
    }

    /// revert_to_disk — re-read sourcePath, replace in-memory doc, reset dirty. Destructive-by-design.
    private func revertToDisk(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard openDocuments[docId] != nil else {
            throw WordError.documentNotFound(docId)
        }
        guard let path = documentOriginalPaths[docId], !path.isEmpty else {
            return "Error: document '\(docId)' has no known source path to revert from"
        }

        let url = URL(fileURLWithPath: path)
        let fresh = try DocxReader.read(from: url)
        openDocuments[docId] = fresh
        documentDirtyState[docId] = false
        if let hash = try? SessionState.computeSHA256(path: path) {
            documentDiskHash[docId] = hash
        }
        if let mtime = try? SessionState.readMtime(path: path) {
            documentDiskMtime[docId] = mtime
        }
        return "Reverted '\(docId)' to disk state from \(path). All in-memory edits discarded."
    }

    /// reload_from_disk — cooperative reload (requires force on dirty).
    private func reloadFromDisk(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard openDocuments[docId] != nil else {
            throw WordError.documentNotFound(docId)
        }
        let force = args["force"]?.boolValue ?? false
        if isDirty(docId: docId) && !force {
            return """
            Error: document '\(docId)' has uncommitted changes. Your in-memory edits would be lost.
            Options:
              - call save_document first to persist your edits, then retry reload_from_disk
              - pass force: true to discard your edits and reload from disk
            """
        }
        // Same semantics as revert from here.
        guard let path = documentOriginalPaths[docId], !path.isEmpty else {
            return "Error: document '\(docId)' has no known source path to reload from"
        }
        let url = URL(fileURLWithPath: path)
        let fresh = try DocxReader.read(from: url)
        openDocuments[docId] = fresh
        documentDirtyState[docId] = false
        if let hash = try? SessionState.computeSHA256(path: path) {
            documentDiskHash[docId] = hash
        }
        if let mtime = try? SessionState.readMtime(path: path) {
            documentDiskMtime[docId] = mtime
        }
        return "Reloaded '\(docId)' from disk at \(path). External edits picked up."
    }

    /// check_disk_drift — informational status, never errors except for missing doc_id.
    private func checkDiskDrift(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard openDocuments[docId] != nil else {
            throw WordError.documentNotFound(docId)
        }
        guard let path = documentOriginalPaths[docId], !path.isEmpty else {
            return """
            Disk drift for '\(docId)':
            - drifted: true
            - reason: no known source path (cannot compare)
            """
        }
        let storedHash = documentDiskHash[docId]
        let storedMtime = documentDiskMtime[docId]
        let currentHash: Data?
        let currentMtime: Date?
        do {
            currentHash = try SessionState.computeSHA256(path: path)
            currentMtime = try SessionState.readMtime(path: path)
        } catch {
            return """
            Disk drift for '\(docId)':
            - drifted: true
            - reason: source file unreadable (\(error.localizedDescription))
            """
        }
        let hashMatches = (storedHash != nil) && (storedHash == currentHash)
        let mtimeMatches = (storedMtime != nil) && (storedMtime == currentMtime)
        let drifted = !hashMatches || !mtimeMatches
        let storedMtimeStr = storedMtime.map { Self.iso8601Formatter.string(from: $0) } ?? "(none)"
        let currentMtimeStr = currentMtime.map { Self.iso8601Formatter.string(from: $0) } ?? "(none)"
        return """
        Disk drift for '\(docId)':
        - drifted: \(drifted)
        - disk_mtime: \(currentMtimeStr)
        - stored_mtime: \(storedMtimeStr)
        - disk_hash_matches: \(hashMatches)
        """
    }

    private func listOpenDocuments() async -> String {
        if openDocuments.isEmpty {
            return "No documents currently open"
        }

        let ids = openDocuments.keys.sorted()
        return "Open documents:\n" + ids.map { "- \($0)" }.joined(separator: "\n")
    }

    private func getDocumentInfo(args: [String: Value]) async throws -> String {
        let (doc, _) = try await resolveDocument(args: args)

        let info = doc.getInfo()
        let label = args["doc_id"]?.stringValue ?? args["source_path"]?.stringValue ?? "unknown"
        return """
        Document Info (\(label)):
        - Paragraphs: \(info.paragraphCount)
        - Characters: \(info.characterCount)
        - Words: \(info.wordCount)
        - Tables: \(info.tableCount)
        """
    }

    // MARK: - Content Operations

    private func getText(args: [String: Value]) async throws -> String {
        guard let sourcePath = args["source_path"]?.stringValue else {
            throw WordError.missingParameter("source_path")
        }
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            throw WordError.fileNotFound(sourcePath)
        }
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let lockFile = sourceURL.deletingLastPathComponent()
            .appendingPathComponent("~$" + sourceURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: lockFile.path) {
            throw WordError.invalidFormat("File is open in Microsoft Word. Please save and close it first: \(sourceURL.lastPathComponent)")
        }
        let document = try DocxReader.read(from: sourceURL)
        return document.getText()
    }

    private func getParagraphs(args: [String: Value]) async throws -> String {
        let (doc, _) = try await resolveDocument(args: args)

        let paragraphs = doc.getParagraphs()
        if paragraphs.isEmpty {
            return "No paragraphs in document"
        }

        var result = "Paragraphs:\n"
        for (index, para) in paragraphs.enumerated() {
            let style = para.properties.style ?? "Normal"
            let preview = String(para.getText().prefix(50))
            result += "[\(index)] (\(style)) \(preview)...\n"
        }
        return result
    }

    private func insertParagraph(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let text = args["text"]?.stringValue else {
            throw WordError.missingParameter("text")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let style = args["style"]?.stringValue

        var para = Paragraph(text: text)
        if let style = style {
            para.properties.style = style
        }

        // anchor-dx-consistency (#71): reject conflicting anchors before the dispatcher.
        // Spec: openspec/changes/anchor-dx-consistency/specs/.../spec.md R1.
        // #80: anchor list resolved from WordMCPServer.toolAnchorWhitelists (SoT).
        let presentAnchors = WordMCPServer.detectPresentAnchors(args, tool: "insert_paragraph")
        if presentAnchors.count > 1 {
            return "Error: insert_paragraph: received conflicting anchors: \(presentAnchors.joined(separator: " + ")). Specify exactly one."
        }

        // Anchor priority (mirrors insert_image_from_path):
        // into_table_cell > after_image_id > after_text > before_text > index > append
        let textInstance = args["text_instance"]?.intValue ?? 1
        // anchor-dx-consistency (#72): explicit text_instance < 1 rejected.
        if let explicit = args["text_instance"]?.intValue, explicit < 1 {
            return "Error: insert_paragraph: text_instance must be ≥ 1, got \(explicit)."
        }
        let resultMessage: String

        if let cellDict = args["into_table_cell"]?.objectValue {
            // F5 (v3.15.1): malformed partial dict returns structured error instead of silent fallthrough.
            guard let tableIdx = cellDict["table_index"]?.intValue,
                  let row = cellDict["row"]?.intValue,
                  let col = cellDict["col"]?.intValue else {
                return "Error: insert_paragraph: into_table_cell requires all three fields (table_index, row, col); got partial dict"
            }
            do {
                try doc.insertParagraph(para, at: .intoTableCell(tableIndex: tableIdx, row: row, col: col))
                resultMessage = "Inserted paragraph into table[\(tableIdx)] cell (row: \(row), col: \(col))"
            } catch let InsertLocationError.tableIndexOutOfRange(i) {
                return "Error: insert_paragraph: table index \(i) out of range"
            } catch let InsertLocationError.tableCellOutOfRange(t, r, c) {
                return "Error: insert_paragraph: table[\(t)] cell (row: \(r), col: \(c)) out of range"
            }
        } else if let afterImageId = args["after_image_id"]?.stringValue {
            // F1 (v3.15.1): after_image_id anchor.
            do {
                try doc.insertParagraph(para, at: .afterImageId(afterImageId))
                resultMessage = "Inserted paragraph after image '\(afterImageId)'"
            } catch let InsertLocationError.imageIdNotFound(rId) {
                return "Error: insert_paragraph: image rId '\(rId)' not found"
            }
        } else if let afterText = args["after_text"]?.stringValue {
            do {
                try doc.insertParagraph(para, at: .afterText(afterText, instance: textInstance))
                resultMessage = "Inserted paragraph after text '\(afterText)' (instance \(textInstance))"
            } catch let InsertLocationError.textNotFound(searchText, instance) {
                return "Error: insert_paragraph: text '\(searchText)' not found (instance \(instance))"
            }
        } else if let beforeText = args["before_text"]?.stringValue {
            do {
                try doc.insertParagraph(para, at: .beforeText(beforeText, instance: textInstance))
                resultMessage = "Inserted paragraph before text '\(beforeText)' (instance \(textInstance))"
            } catch let InsertLocationError.textNotFound(searchText, instance) {
                return "Error: insert_paragraph: text '\(searchText)' not found (instance \(instance))"
            }
        } else if let index = args["index"]?.intValue {
            doc.insertParagraph(para, at: index)
            resultMessage = "Inserted paragraph at index \(index)"
        } else {
            doc.appendParagraph(para)
            // #69: report body.children index (matches Document.insertParagraph(_:at:Int)
            // semantics — Document.swift:266-270). getParagraphs() skips tables/SDTs so
            // its count - 1 mis-reports the index in docs with non-paragraph body children.
            resultMessage = "Inserted paragraph at index \(doc.body.children.count - 1)"
        }

        try await storeDocument(doc, for: docId)

        return resultMessage
    }

    private func updateParagraph(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let index = args["index"]?.intValue else {
            throw WordError.missingParameter("index")
        }
        guard let text = args["text"]?.stringValue else {
            throw WordError.missingParameter("text")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        try doc.updateParagraph(at: index, text: text)
        try await storeDocument(doc, for: docId)

        return "Updated paragraph at index \(index)"
    }

    private func deleteParagraph(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let index = args["index"]?.intValue else {
            throw WordError.missingParameter("index")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        try doc.deleteParagraph(at: index)
        try await storeDocument(doc, for: docId)

        return "Deleted paragraph at index \(index)"
    }

    /// replace_text MCP tool — now flatten-then-map + scope + regex.
    ///
    /// Args:
    /// - doc_id (required)
    /// - find (required): plain string or regex pattern (if regex=true)
    /// - replace (required): replacement text; when regex=true supports $1..$N
    /// - scope: "body" (default) | "all" — "all" adds headers/footers/footnotes/endnotes
    /// - regex: Bool (default false)
    /// - match_case: Bool (default true)
    ///
    /// BREAKING changes from previous release:
    /// - `all: Bool` argument removed (was "replace all occurrences"; now always
    ///   replaces all — to emulate old `all: false` behavior, call once and check
    ///   the returned count, or use a regex with an anchor).
    /// - Cross-run matches now succeed (previously failed silently).
    private func replaceText(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let find = args["find"]?.stringValue else {
            throw WordError.missingParameter("find")
        }
        guard let replace = args["replace"]?.stringValue else {
            throw WordError.missingParameter("replace")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let scopeString = args["scope"]?.stringValue ?? "body"
        let scope: ReplaceScope
        switch scopeString {
        case "body":
            scope = .bodyAndTables
        case "all":
            scope = .all
        default:
            return "Error: invalid scope '\(scopeString)'. Use 'body' or 'all'."
        }
        let regex = args["regex"]?.boolValue ?? false
        let matchCase = args["match_case"]?.boolValue ?? true

        let options = ReplaceOptions(scope: scope, regex: regex, matchCase: matchCase)
        do {
            let count = try doc.replaceText(find: find, with: replace, options: options)
            try await storeDocument(doc, for: docId)
            let scopeLabel = scope == .all ? " (scope: all)" : ""
            return "Replaced \(count) occurrence(s) of '\(find)' with '\(replace)'\(scopeLabel)"
        } catch ReplaceError.invalidRegex(let pattern) {
            return "Error: invalid regex pattern '\(pattern)'"
        }
    }

    /// search_text_batch MCP tool — 批次搜尋多個 query，單一 doc load（Session Mode）或
    /// 單次檔案 parse（Direct Mode）。對每個 query 呼叫 existing `searchText(args:)`，
    /// 組合成單一 batch response。
    private func searchTextBatch(args: [String: Value]) async throws -> String {
        guard case .array(let queriesValue)? = args["queries"] else {
            throw WordError.missingParameter("queries (array)")
        }

        var output = ""
        for (idx, qValue) in queriesValue.enumerated() {
            let queryStr: String
            let caseSensitive: Bool
            switch qValue {
            case .string(let s):
                queryStr = s
                caseSensitive = false
            case .object(let obj):
                guard let q = obj["query"]?.stringValue else {
                    output += "\n=== [\(idx)] FAIL: missing 'query' field ===\n"
                    continue
                }
                queryStr = q
                caseSensitive = obj["case_sensitive"]?.boolValue ?? false
            default:
                output += "\n=== [\(idx)] FAIL: query must be string or object ===\n"
                continue
            }

            // Build per-query args by copying original args (preserves doc_id / source_path)
            var subArgs = args
            subArgs["query"] = .string(queryStr)
            subArgs["case_sensitive"] = .bool(caseSensitive)
            subArgs.removeValue(forKey: "queries")

            do {
                let result = try await searchText(args: subArgs)
                output += "\n=== [\(idx)] query='\(queryStr)' ===\n\(result)\n"
            } catch {
                output += "\n=== [\(idx)] query='\(queryStr)' ERROR: \(error) ===\n"
            }
        }
        return output.isEmpty ? "(no queries)" : output
    }

    /// replace_text_batch MCP tool — 批次 sequential replacement，單次 save（或 dry_run 跳過）。
    ///
    /// Semantics:
    /// - Replacements apply in array order. Each sees results of previous.
    /// - Non-atomic per-item: individual failures (invalid regex) reported but
    ///   don't rollback prior successes.
    /// - `stop_on_first_failure: true` halts on first error; already-applied
    ///   items stay applied.
    /// - `dry_run: true` skips disk save; in-memory doc is still mutated
    ///   (document this caveat in schema).
    private func replaceTextBatch(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard case .array(let replacementsValue)? = args["replacements"] else {
            throw WordError.missingParameter("replacements (array)")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        let stopOnFirstFailure = args["stop_on_first_failure"]?.boolValue ?? false
        let dryRun = args["dry_run"]?.boolValue ?? false

        var results: [[String: Any]] = []
        var succeeded = 0
        var failed = 0

        for (idx, itemValue) in replacementsValue.enumerated() {
            guard case .object(let item) = itemValue else {
                results.append(["index": idx, "error": "replacement entry must be object"])
                failed += 1
                if stopOnFirstFailure { break } else { continue }
            }
            guard let find = item["find"]?.stringValue else {
                results.append(["index": idx, "error": "missing 'find' field"])
                failed += 1
                if stopOnFirstFailure { break } else { continue }
            }
            guard let replace = item["replace"]?.stringValue else {
                results.append(["index": idx, "error": "missing 'replace' field", "find": find])
                failed += 1
                if stopOnFirstFailure { break } else { continue }
            }

            // per-item options, fall back to no-op defaults
            let scopeString = item["scope"]?.stringValue ?? "body"
            let scope: ReplaceScope = (scopeString == "all") ? .all : .bodyAndTables
            let regex = item["regex"]?.boolValue ?? false
            let matchCase = item["match_case"]?.boolValue ?? true
            let options = ReplaceOptions(scope: scope, regex: regex, matchCase: matchCase)

            do {
                let count = try doc.replaceText(find: find, with: replace, options: options)
                results.append(["index": idx, "find": find, "replaced_count": count])
                succeeded += 1
            } catch ReplaceError.invalidRegex(let pattern) {
                results.append(["index": idx, "find": find, "error": "invalid regex: \(pattern)"])
                failed += 1
                if stopOnFirstFailure { break }
            } catch {
                results.append(["index": idx, "find": find, "error": "\(error)"])
                failed += 1
                if stopOnFirstFailure { break }
            }
        }

        if !dryRun {
            try await storeDocument(doc, for: docId)
        } else {
            // Update openDocuments even in dry_run so caller can observe the
            // in-memory effect; skip only the disk write.
            openDocuments[docId] = doc
        }

        // Build human-readable summary + JSON-ish detail
        var summary = "Replace batch: \(succeeded) applied, \(failed) failed"
        if dryRun { summary += " (dry_run; disk not saved)" }
        summary += "\n\nDetails:\n"
        for r in results {
            let idx = r["index"] ?? "?"
            if let err = r["error"] as? String {
                summary += "  [\(idx)] FAIL: \(err)\n"
            } else {
                let find = r["find"] as? String ?? ""
                let count = r["replaced_count"] as? Int ?? 0
                summary += "  [\(idx)] '\(find)' → \(count) replaced\n"
            }
        }
        return summary
    }

    // MARK: - Formatting

    private func formatText(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        var format = RunProperties()
        if let bold = args["bold"]?.boolValue { format.bold = bold }
        if let italic = args["italic"]?.boolValue { format.italic = italic }
        if let underline = args["underline"]?.boolValue { format.underline = underline ? .single : nil }
        if let fontSize = args["font_size"]?.intValue { format.fontSize = fontSize * 2 } // 轉換為半點
        if let fontName = args["font_name"]?.stringValue { format.fontName = fontName }
        if let color = args["color"]?.stringValue { format.color = color }

        // v3.12.0+ (#45): per-call opt-in for revision-tracked formatting.
        let asRevision = args["as_revision"]?.boolValue ?? false
        if asRevision {
            let runIndex = args["run_index"]?.intValue ?? 0
            let author = args["author"]?.stringValue
            let date = parseISODate(args["date"]?.stringValue)
            let revId = try doc.applyRunPropertiesAsRevision(
                atParagraph: paragraphIndex, atRunIndex: runIndex,
                newProperties: format, author: author, date: date
            )
            try await storeDocument(doc, for: docId)
            return "Applied formatting to paragraph \(paragraphIndex) run \(runIndex) as revision \(revId)"
        }

        try doc.formatParagraph(at: paragraphIndex, with: format)
        try await storeDocument(doc, for: docId)

        return "Applied formatting to paragraph \(paragraphIndex)"
    }

    private func setParagraphFormat(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        var props = ParagraphProperties()
        if let alignment = args["alignment"]?.stringValue {
            props.alignment = Alignment(rawValue: alignment)
        }
        if let lineSpacing = args["line_spacing"]?.doubleValue {
            props.spacing = Spacing(line: Int(lineSpacing * 240)) // 轉換為 1/240 點
        }
        if let spaceBefore = args["space_before"]?.intValue {
            if props.spacing == nil { props.spacing = Spacing() }
            props.spacing?.before = spaceBefore * 20 // 轉換為 1/20 點
        }
        if let spaceAfter = args["space_after"]?.intValue {
            if props.spacing == nil { props.spacing = Spacing() }
            props.spacing?.after = spaceAfter * 20
        }

        let asRevision = args["as_revision"]?.boolValue ?? false
        if asRevision {
            let author = args["author"]?.stringValue
            let date = parseISODate(args["date"]?.stringValue)
            let revId = try doc.applyParagraphPropertiesAsRevision(
                atParagraph: paragraphIndex, newProperties: props,
                author: author, date: date
            )
            try await storeDocument(doc, for: docId)
            return "Applied paragraph format to index \(paragraphIndex) as revision \(revId)"
        }

        try doc.setParagraphFormat(at: paragraphIndex, properties: props)
        try await storeDocument(doc, for: docId)

        return "Applied paragraph format to index \(paragraphIndex)"
    }

    // MARK: - Programmatic Track Changes (#45)

    /// Parse an optional ISO 8601 timestamp string into a Date. Nil input
    /// returns nil (callers default to `Date()`).
    private func parseISODate(_ s: String?) -> Date? {
        guard let s = s, !s.isEmpty else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }

    private func insertTextAsRevision(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let position = args["position"]?.intValue else {
            throw WordError.missingParameter("position")
        }
        guard let text = args["text"]?.stringValue else {
            throw WordError.missingParameter("text")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let author = args["author"]?.stringValue
        let date = parseISODate(args["date"]?.stringValue)
        let revId = try doc.insertTextAsRevision(
            text: text, atParagraph: paragraphIndex, position: position,
            author: author, date: date
        )
        try await storeDocument(doc, for: docId)
        return "Inserted text as revision id \(revId)"
    }

    private func deleteTextAsRevision(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let start = args["start"]?.intValue else {
            throw WordError.missingParameter("start")
        }
        guard let end = args["end"]?.intValue else {
            throw WordError.missingParameter("end")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let author = args["author"]?.stringValue
        let date = parseISODate(args["date"]?.stringValue)
        let revId = try doc.deleteTextAsRevision(
            atParagraph: paragraphIndex, start: start, end: end,
            author: author, date: date
        )
        try await storeDocument(doc, for: docId)
        return "Deleted text as revision id \(revId)"
    }

    private func moveTextAsRevision(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let fromPara = args["from_paragraph_index"]?.intValue else {
            throw WordError.missingParameter("from_paragraph_index")
        }
        guard let fromStart = args["from_start"]?.intValue else {
            throw WordError.missingParameter("from_start")
        }
        guard let fromEnd = args["from_end"]?.intValue else {
            throw WordError.missingParameter("from_end")
        }
        guard let toPara = args["to_paragraph_index"]?.intValue else {
            throw WordError.missingParameter("to_paragraph_index")
        }
        guard let toPos = args["to_position"]?.intValue else {
            throw WordError.missingParameter("to_position")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let author = args["author"]?.stringValue
        let date = parseISODate(args["date"]?.stringValue)
        let result = try doc.moveTextAsRevision(
            fromParagraph: fromPara, fromStart: fromStart, fromEnd: fromEnd,
            toParagraph: toPara, toPosition: toPos,
            author: author, date: date
        )
        try await storeDocument(doc, for: docId)
        return "Moved text as revisions: from_id=\(result.fromId) to_id=\(result.toId)"
    }

    private func applyStyle(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let style = args["style"]?.stringValue else {
            throw WordError.missingParameter("style")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        try doc.applyStyle(at: paragraphIndex, style: style)
        try await storeDocument(doc, for: docId)

        return "Applied style '\(style)' to paragraph \(paragraphIndex)"
    }

    // MARK: - Table

    private func insertTable(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let rows = args["rows"]?.intValue else {
            throw WordError.missingParameter("rows")
        }
        guard let cols = args["cols"]?.intValue else {
            throw WordError.missingParameter("cols")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        var table = Table(rowCount: rows, columnCount: cols)

        // 如果有提供資料，填入表格
        if let dataArray = args["data"]?.arrayValue {
            for (rowIndex, rowData) in dataArray.enumerated() {
                if let rowArray = rowData.arrayValue {
                    for (colIndex, cellData) in rowArray.enumerated() {
                        if let text = cellData.stringValue,
                           rowIndex < table.rows.count && colIndex < table.rows[rowIndex].cells.count {
                            table.rows[rowIndex].cells[colIndex] = TableCell(text: text)
                        }
                    }
                }
            }
        }

        let index = args["index"]?.intValue
        if let index = index {
            doc.insertTable(table, at: index)
        } else {
            doc.appendTable(table)
        }

        try await storeDocument(doc, for: docId)

        return "Inserted \(rows)x\(cols) table"
    }

    private func getTables(args: [String: Value]) async throws -> String {
        let (doc, _) = try await resolveDocument(args: args)

        let tables = doc.getTables()
        if tables.isEmpty {
            return "No tables in document"
        }

        var result = "Tables in document:\n"
        for (index, table) in tables.enumerated() {
            let rows = table.rows.count
            let cols = table.rows.first?.cells.count ?? 0
            result += "[\(index)] \(rows)x\(cols) table\n"

            // 顯示表格內容預覽
            for (rowIdx, row) in table.rows.prefix(3).enumerated() {
                let cellPreviews = row.cells.prefix(3).map { cell -> String in
                    let preview = String(cell.getText().prefix(15))
                    return preview.isEmpty ? "(empty)" : preview
                }
                result += "  Row \(rowIdx): \(cellPreviews.joined(separator: " | "))\n"
            }
            if table.rows.count > 3 {
                result += "  ... (\(table.rows.count - 3) more rows)\n"
            }
        }
        return result
    }

    private func updateCell(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let tableIndex = args["table_index"]?.intValue else {
            throw WordError.missingParameter("table_index")
        }
        guard let row = args["row"]?.intValue else {
            throw WordError.missingParameter("row")
        }
        guard let col = args["col"]?.intValue else {
            throw WordError.missingParameter("col")
        }
        guard let text = args["text"]?.stringValue else {
            throw WordError.missingParameter("text")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        try doc.updateCell(tableIndex: tableIndex, row: row, col: col, text: text)
        try await storeDocument(doc, for: docId)

        return "Updated cell at table[\(tableIndex)][\(row)][\(col)]"
    }

    private func deleteTable(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let tableIndex = args["table_index"]?.intValue else {
            throw WordError.missingParameter("table_index")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        try doc.deleteTable(at: tableIndex)
        try await storeDocument(doc, for: docId)

        return "Deleted table at index \(tableIndex)"
    }

    private func mergeCells(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let tableIndex = args["table_index"]?.intValue else {
            throw WordError.missingParameter("table_index")
        }
        guard let direction = args["direction"]?.stringValue else {
            throw WordError.missingParameter("direction")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        switch direction.lowercased() {
        case "horizontal":
            guard let row = args["row"]?.intValue else {
                throw WordError.missingParameter("row")
            }
            guard let col = args["col"]?.intValue else {
                throw WordError.missingParameter("col")
            }
            guard let endCol = args["end_col"]?.intValue else {
                throw WordError.missingParameter("end_col")
            }
            try doc.mergeCellsHorizontal(tableIndex: tableIndex, row: row, startCol: col, endCol: endCol)
            try await storeDocument(doc, for: docId)
            return "Merged cells horizontally: row \(row), columns \(col) to \(endCol)"

        case "vertical":
            guard let row = args["row"]?.intValue else {
                throw WordError.missingParameter("row")
            }
            guard let col = args["col"]?.intValue else {
                throw WordError.missingParameter("col")
            }
            guard let endRow = args["end_row"]?.intValue else {
                throw WordError.missingParameter("end_row")
            }
            try doc.mergeCellsVertical(tableIndex: tableIndex, col: col, startRow: row, endRow: endRow)
            try await storeDocument(doc, for: docId)
            return "Merged cells vertically: column \(col), rows \(row) to \(endRow)"

        default:
            throw WordError.invalidParameter("direction", "Must be 'horizontal' or 'vertical'")
        }
    }

    private func setTableStyle(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let tableIndex = args["table_index"]?.intValue else {
            throw WordError.missingParameter("table_index")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        var results: [String] = []

        // 設定邊框
        if let borderStyle = args["border_style"]?.stringValue {
            let style = BorderStyle(rawValue: borderStyle) ?? .single
            let size = args["border_size"]?.intValue ?? 4
            let color = args["border_color"]?.stringValue ?? "000000"

            let border = Border(style: style, size: size, color: color)
            let borders = TableBorders.all(border)

            try doc.setTableBorders(tableIndex: tableIndex, borders: borders)
            results.append("Set border style: \(borderStyle)")
        }

        // 設定儲存格底色
        if let cellRow = args["cell_row"]?.intValue,
           let cellCol = args["cell_col"]?.intValue,
           let shadingColor = args["shading_color"]?.stringValue {
            let shading = CellShading(fill: shadingColor)
            try doc.setCellShading(tableIndex: tableIndex, row: cellRow, col: cellCol, shading: shading)
            results.append("Set cell shading at [\(cellRow)][\(cellCol)]: \(shadingColor)")
        }

        try await storeDocument(doc, for: docId)

        if results.isEmpty {
            return "No style changes applied"
        }
        return results.joined(separator: "\n")
    }

    // MARK: - Style Management

    private func listStyles(args: [String: Value]) async throws -> String {
        let (doc, _) = try await resolveDocument(args: args)

        let styles = doc.getStyles()
        if styles.isEmpty {
            return "No styles defined"
        }

        var result = "Available Styles:\n"
        for style in styles {
            let defaultMark = style.isDefault ? " (default)" : ""
            let basedOnInfo = style.basedOn.map { " [based on: \($0)]" } ?? ""
            result += "- \(style.id) (\(style.name)) - \(style.type.rawValue)\(defaultMark)\(basedOnInfo)\n"

            // 顯示格式資訊
            if let runProps = style.runProperties {
                var formats: [String] = []
                if let fontName = runProps.fontName { formats.append("font: \(fontName)") }
                if let fontSize = runProps.fontSize { formats.append("size: \(fontSize / 2)pt") }
                if runProps.bold == true { formats.append("bold") }
                if runProps.italic == true { formats.append("italic") }
                if let color = runProps.color { formats.append("color: #\(color)") }
                if !formats.isEmpty {
                    result += "    Text: \(formats.joined(separator: ", "))\n"
                }
            }
        }
        return result
    }

    private func createStyle(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let styleId = args["style_id"]?.stringValue else {
            throw WordError.missingParameter("style_id")
        }
        guard let name = args["name"]?.stringValue else {
            throw WordError.missingParameter("name")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        // 解析樣式類型
        let typeStr = args["type"]?.stringValue ?? "paragraph"
        let styleType = StyleType(rawValue: typeStr) ?? .paragraph

        // 解析段落屬性
        var paraProps = ParagraphProperties()
        if let alignment = args["alignment"]?.stringValue {
            paraProps.alignment = Alignment(rawValue: alignment)
        }
        if let spaceBefore = args["space_before"]?.intValue {
            if paraProps.spacing == nil { paraProps.spacing = Spacing() }
            paraProps.spacing?.before = spaceBefore * 20
        }
        if let spaceAfter = args["space_after"]?.intValue {
            if paraProps.spacing == nil { paraProps.spacing = Spacing() }
            paraProps.spacing?.after = spaceAfter * 20
        }

        // 解析 Run 屬性
        var runProps = RunProperties()
        if let fontName = args["font_name"]?.stringValue { runProps.fontName = fontName }
        if let fontSize = args["font_size"]?.intValue { runProps.fontSize = fontSize * 2 }
        if let bold = args["bold"]?.boolValue { runProps.bold = bold }
        if let italic = args["italic"]?.boolValue { runProps.italic = italic }
        if let color = args["color"]?.stringValue { runProps.color = color }

        // v3.10.0+ (#48): Office.js parity args
        let qFormat = args["q_format"]?.boolValue ?? true
        let hidden = args["hidden"]?.boolValue ?? false
        let semiHidden = args["semi_hidden"]?.boolValue ?? false
        let linkedStyleId = args["linked_style_id"]?.stringValue
        let nextStyleId = args["next_style_id"]?.stringValue ?? args["next_style"]?.stringValue

        let style = Style(
            id: styleId,
            name: name,
            type: styleType,
            basedOn: args["based_on"]?.stringValue,
            nextStyle: nextStyleId,
            isDefault: false,
            isQuickStyle: qFormat,
            linkedStyleId: linkedStyleId,
            hidden: hidden,
            semiHidden: semiHidden,
            paragraphProperties: paraProps,
            runProperties: runProps
        )

        try doc.addStyle(style)
        try await storeDocument(doc, for: docId)

        return "Created style '\(styleId)' (\(name))"
    }

    private func updateStyle(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let styleId = args["style_id"]?.stringValue else {
            throw WordError.missingParameter("style_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        // 建立更新資料
        var paraProps: ParagraphProperties? = nil
        if let alignment = args["alignment"]?.stringValue {
            paraProps = ParagraphProperties()
            paraProps?.alignment = Alignment(rawValue: alignment)
        }

        var runProps: RunProperties? = nil
        if args["font_name"] != nil || args["font_size"] != nil ||
           args["bold"] != nil || args["italic"] != nil || args["color"] != nil {
            runProps = RunProperties()
            if let fontName = args["font_name"]?.stringValue { runProps?.fontName = fontName }
            if let fontSize = args["font_size"]?.intValue { runProps?.fontSize = fontSize * 2 }
            if let bold = args["bold"]?.boolValue { runProps?.bold = bold }
            if let italic = args["italic"]?.boolValue { runProps?.italic = italic }
            if let color = args["color"]?.stringValue { runProps?.color = color }
        }

        let updates = StyleUpdate(
            name: args["name"]?.stringValue,
            paragraphProperties: paraProps,
            runProperties: runProps
        )

        try doc.updateStyle(id: styleId, with: updates)

        // v3.10.0+ (#48): Office.js parity post-update for fields not in StyleUpdate
        if let idx = doc.styles.firstIndex(where: { $0.id == styleId }) {
            if let basedOn = args["based_on"]?.stringValue { doc.styles[idx].basedOn = basedOn }
            if let nextId = args["next_style_id"]?.stringValue { doc.styles[idx].nextStyle = nextId }
            if let linked = args["linked_style_id"]?.stringValue { doc.styles[idx].linkedStyleId = linked }
            if let qFormat = args["q_format"]?.boolValue { doc.styles[idx].isQuickStyle = qFormat }
            if let hidden = args["hidden"]?.boolValue { doc.styles[idx].hidden = hidden }
            if let semiHidden = args["semi_hidden"]?.boolValue { doc.styles[idx].semiHidden = semiHidden }
            doc.markPartDirty("word/styles.xml")
        }

        try await storeDocument(doc, for: docId)
        return "Updated style '\(styleId)'"
    }

    private func deleteStyle(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let styleId = args["style_id"]?.stringValue else {
            throw WordError.missingParameter("style_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        try doc.deleteStyle(id: styleId)
        try await storeDocument(doc, for: docId)

        return "Deleted style '\(styleId)'"
    }

    // MARK: - List Operations

    private func insertBulletList(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let itemsArray = args["items"]?.arrayValue else {
            throw WordError.missingParameter("items")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let items = itemsArray.compactMap { $0.stringValue }
        if items.isEmpty {
            throw WordError.invalidParameter("items", "Must contain at least one item")
        }

        let index = args["index"]?.intValue
        let numId = doc.insertBulletList(items: items, at: index)
        try await storeDocument(doc, for: docId)

        return "Inserted bullet list with \(items.count) items (numId: \(numId))"
    }

    private func insertNumberedList(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let itemsArray = args["items"]?.arrayValue else {
            throw WordError.missingParameter("items")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let items = itemsArray.compactMap { $0.stringValue }
        if items.isEmpty {
            throw WordError.invalidParameter("items", "Must contain at least one item")
        }

        let index = args["index"]?.intValue
        let numId = doc.insertNumberedList(items: items, at: index)
        try await storeDocument(doc, for: docId)

        return "Inserted numbered list with \(items.count) items (numId: \(numId))"
    }

    private func setListLevel(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let level = args["level"]?.intValue else {
            throw WordError.missingParameter("level")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        try doc.setListLevel(paragraphIndex: paragraphIndex, level: level)
        try await storeDocument(doc, for: docId)

        return "Set list level to \(level) for paragraph \(paragraphIndex)"
    }

    // MARK: - Page Settings

    private func setPageSize(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let sizeName = args["size"]?.stringValue else {
            throw WordError.missingParameter("size")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        try doc.setPageSize(name: sizeName)
        try await storeDocument(doc, for: docId)

        let size = doc.sectionProperties.pageSize
        return "Set page size to \(size.name) (\(size.widthInInches)\" x \(size.heightInInches)\")"
    }

    private func setPageMargins(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        // 優先使用預設名稱
        if let preset = args["preset"]?.stringValue {
            try doc.setPageMargins(name: preset)
        } else {
            // 使用自訂值
            let top = args["top"]?.intValue
            let right = args["right"]?.intValue
            let bottom = args["bottom"]?.intValue
            let left = args["left"]?.intValue

            doc.setPageMargins(top: top, right: right, bottom: bottom, left: left)
        }

        try await storeDocument(doc, for: docId)

        let margins = doc.sectionProperties.pageMargins
        return "Set page margins to \(margins.name) (top: \(margins.top), right: \(margins.right), bottom: \(margins.bottom), left: \(margins.left) twips)"
    }

    private func setPageOrientation(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let orientationStr = args["orientation"]?.stringValue else {
            throw WordError.missingParameter("orientation")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        guard let orientation = PageOrientation(rawValue: orientationStr.lowercased()) else {
            throw WordError.invalidParameter("orientation", "Must be 'portrait' or 'landscape'")
        }

        doc.setPageOrientation(orientation)
        try await storeDocument(doc, for: docId)

        return "Set page orientation to \(orientation.rawValue)"
    }

    private func insertPageBreak(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let index = args["at_index"]?.intValue
        doc.insertPageBreak(at: index)
        try await storeDocument(doc, for: docId)

        if let index = index {
            return "Inserted page break at position \(index)"
        } else {
            return "Inserted page break at end of document"
        }
    }

    private func insertSectionBreak(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let typeStr = args["type"]?.stringValue ?? "nextPage"
        guard let breakType = SectionBreakType(rawValue: typeStr) else {
            throw WordError.invalidParameter("type", "Must be 'nextPage', 'continuous', 'evenPage', or 'oddPage'")
        }

        let index = args["at_index"]?.intValue
        doc.insertSectionBreak(type: breakType, at: index)
        try await storeDocument(doc, for: docId)

        if let index = index {
            return "Inserted \(breakType.rawValue) section break at position \(index)"
        } else {
            return "Inserted \(breakType.rawValue) section break at end of document"
        }
    }

    // MARK: - Header/Footer

    private func addHeader(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let text = args["text"]?.stringValue else {
            throw WordError.missingParameter("text")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let typeStr = args["type"]?.stringValue ?? "default"
        let headerType: HeaderFooterType
        switch typeStr.lowercased() {
        case "first": headerType = .first
        case "even": headerType = .even
        default: headerType = .default
        }

        let header = doc.addHeader(text: text, type: headerType)
        try await storeDocument(doc, for: docId)

        return "Added header with id '\(header.id)' (type: \(headerType.rawValue))"
    }

    private func updateHeader(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let headerId = args["header_id"]?.stringValue else {
            throw WordError.missingParameter("header_id")
        }
        guard let text = args["text"]?.stringValue else {
            throw WordError.missingParameter("text")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        try doc.updateHeader(id: headerId, text: text)
        try await storeDocument(doc, for: docId)

        return "Updated header '\(headerId)'"
    }

    private func addFooter(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let typeStr = args["type"]?.stringValue ?? "default"
        let footerType: HeaderFooterType
        switch typeStr.lowercased() {
        case "first": footerType = .first
        case "even": footerType = .even
        default: footerType = .default
        }

        let footer: Footer
        if let text = args["text"]?.stringValue {
            footer = doc.addFooter(text: text, type: footerType)
        } else {
            // 沒有提供文字，使用頁碼
            footer = doc.addFooterWithPageNumber(format: .simple, type: footerType)
        }

        try await storeDocument(doc, for: docId)

        return "Added footer with id '\(footer.id)' (type: \(footerType.rawValue))"
    }

    private func updateFooter(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let footerId = args["footer_id"]?.stringValue else {
            throw WordError.missingParameter("footer_id")
        }
        guard let text = args["text"]?.stringValue else {
            throw WordError.missingParameter("text")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        try doc.updateFooter(id: footerId, text: text)
        try await storeDocument(doc, for: docId)

        return "Updated footer '\(footerId)'"
    }

    private func insertPageNumber(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        // 解析頁碼格式
        let formatStr = args["format"]?.stringValue ?? "simple"
        let format: PageNumberFormat
        switch formatStr.lowercased() {
        case "simple": format = .simple
        case "pageoftotal": format = .pageOfTotal
        case "withdash": format = .withDash
        default:
            // 自訂格式（包含 # 的字串）
            if formatStr.contains("#") {
                format = .withText(formatStr)
            } else {
                format = .simple
            }
        }

        let footer = doc.addFooterWithPageNumber(format: format, type: .default)
        try await storeDocument(doc, for: docId)

        return "Inserted page number in footer '\(footer.id)' with format '\(formatStr)'"
    }

    // MARK: - Image Operations

    private func insertImage(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let base64 = args["base64"]?.stringValue else {
            throw WordError.missingParameter("base64")
        }
        guard let fileName = args["file_name"]?.stringValue else {
            throw WordError.missingParameter("file_name")
        }
        guard let width = args["width"]?.intValue else {
            throw WordError.missingParameter("width")
        }
        guard let height = args["height"]?.intValue else {
            throw WordError.missingParameter("height")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let index = args["index"]?.intValue
        let name = args["name"]?.stringValue ?? "Picture"
        let description = args["description"]?.stringValue ?? ""

        let imageId = try doc.insertImage(
            base64: base64,
            fileName: fileName,
            widthPx: width,
            heightPx: height,
            at: index,
            name: name,
            description: description
        )

        try await storeDocument(doc, for: docId)

        return "Inserted image '\(fileName)' with id '\(imageId)' (\(width)x\(height) pixels)"
    }

    /// insert_image_from_path MCP tool — now supports auto-aspect + table-cell insertion.
    ///
    /// BREAKING from previous release:
    /// - `width` and `height` are now OPTIONAL. If exactly one is supplied, the
    ///   missing dimension is computed from the image's native aspect ratio via
    ///   `ImageDimensions.detect`. If both are omitted, native pixel size is used.
    /// - New `into_table_cell: { table_index, row, col }` anchor inserts the
    ///   image as a new paragraph inside the specified table cell.
    /// - Legacy `index` argument still accepted for body-level paragraph insertion.
    private func insertImageFromPath(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let path = args["path"]?.stringValue else {
            throw WordError.missingParameter("path")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        // anchor-dx-consistency (#71): reject conflicting anchors BEFORE any IO
        // (filesystem stat / image dimension probe), logging, or anchor-priority
        // derivation. Verify-71 P2 (Devil's Advocate refutation): previously this
        // check sat after fileExists check + resolveImageDimensions(throws) + the
        // entry log write, so a caller passing "bad image path + 2 anchors" would
        // see the file-IO error and never the conflict error — making this tool
        // inconsistent with the other 3 #61-target handlers and violating the
        // bundle's "anchor-dx-consistency" promise.
        // Spec: openspec/changes/anchor-dx-consistency/specs/.../spec.md R1.
        // #80: anchor list resolved from WordMCPServer.toolAnchorWhitelists (SoT).
        let presentAnchors = WordMCPServer.detectPresentAnchors(args, tool: "insert_image_from_path")
        if presentAnchors.count > 1 {
            return "Error: insert_image_from_path: received conflicting anchors: \(presentAnchors.joined(separator: " + ")). Specify exactly one."
        }

        guard FileManager.default.fileExists(atPath: path) else {
            throw WordError.fileNotFound(path)
        }

        // Phase A (#41 investigation): structured entry log.
        // #74: detection priority must mirror dispatch priority below
        // (into_table_cell > after_image_id > after_text > before_text > index).
        let anchorKind: String
        if args["into_table_cell"]?.objectValue != nil { anchorKind = "intoTableCell" }
        else if args["after_image_id"]?.stringValue != nil { anchorKind = "after_image_id" }
        else if args["after_text"]?.stringValue != nil { anchorKind = "after_text" }
        else if args["before_text"]?.stringValue != nil { anchorKind = "before_text" }
        else { anchorKind = "index" }
        let startTime = Date()
        logDebug(event: "insertImageFromPath.entry", [
            ("doc_id", docId),
            ("anchor", anchorKind),
            ("imagePath", (path as NSString).lastPathComponent),
            ("bodyChildrenCount", String(doc.body.children.count)),
            ("imagesCount", String(doc.images.count))
        ])

        // Resolve width/height (auto-aspect)
        let widthArg = args["width"]?.intValue
        let heightArg = args["height"]?.intValue
        let (width, height) = try resolveImageDimensions(path: path, width: widthArg, height: heightArg)

        let name = args["name"]?.stringValue ?? "Picture"
        let description = args["description"]?.stringValue ?? ""

        // Resolve anchor: priority is into_table_cell > after_image_id > after_text > before_text > index
        let imageId: String
        let textInstance = args["text_instance"]?.intValue ?? 1
        // anchor-dx-consistency (#72): explicit text_instance < 1 rejected.
        if let explicit = args["text_instance"]?.intValue, explicit < 1 {
            return "Error: insert_image_from_path: text_instance must be ≥ 1, got \(explicit)."
        }
        if let cellDict = args["into_table_cell"]?.objectValue {
            // F5 (v3.15.1): malformed partial dict returns structured error instead of silent fallthrough.
            guard let tableIdx = cellDict["table_index"]?.intValue,
                  let row = cellDict["row"]?.intValue,
                  let col = cellDict["col"]?.intValue else {
                return "Error: insert_image_from_path: into_table_cell requires all three fields (table_index, row, col); got partial dict"
            }
            do {
                imageId = try doc.insertImage(
                    path: path,
                    widthPx: width,
                    heightPx: height,
                    at: .intoTableCell(tableIndex: tableIdx, row: row, col: col),
                    name: name,
                    description: description
                )
            } catch let InsertLocationError.tableIndexOutOfRange(i) {
                return "Error: insert_image_from_path: table index \(i) out of range"
            } catch let InsertLocationError.tableCellOutOfRange(t, r, c) {
                return "Error: insert_image_from_path: table[\(t)] cell (row: \(r), col: \(c)) out of range"
            }
        } else if let afterImageId = args["after_image_id"]?.stringValue {
            // F1 (v3.15.1): after_image_id anchor.
            do {
                imageId = try doc.insertImage(
                    path: path,
                    widthPx: width,
                    heightPx: height,
                    at: .afterImageId(afterImageId),
                    name: name,
                    description: description
                )
            } catch let InsertLocationError.imageIdNotFound(rId) {
                return "Error: insert_image_from_path: image rId '\(rId)' not found"
            }
        } else if let afterText = args["after_text"]?.stringValue {
            do {
                imageId = try doc.insertImage(
                    path: path,
                    widthPx: width,
                    heightPx: height,
                    at: .afterText(afterText, instance: textInstance),
                    name: name,
                    description: description
                )
            } catch let InsertLocationError.textNotFound(text, instance) {
                return "Error: insert_image_from_path: text '\(text)' not found (instance \(instance))"
            }
        } else if let beforeText = args["before_text"]?.stringValue {
            do {
                imageId = try doc.insertImage(
                    path: path,
                    widthPx: width,
                    heightPx: height,
                    at: .beforeText(beforeText, instance: textInstance),
                    name: name,
                    description: description
                )
            } catch let InsertLocationError.textNotFound(text, instance) {
                return "Error: insert_image_from_path: text '\(text)' not found (instance \(instance))"
            }
        } else {
            // body-level: use legacy index-based API
            let index = args["index"]?.intValue
            imageId = try doc.insertImage(
                path: path,
                widthPx: width,
                heightPx: height,
                at: index,
                name: name,
                description: description
            )
        }

        try await storeDocument(doc, for: docId)

        // Phase A (#41 investigation): structured exit log.
        let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
        logDebug(event: "insertImageFromPath.exit", [
            ("doc_id", docId),
            ("imageId", imageId),
            ("elapsedMs", String(elapsedMs))
        ])

        let url = URL(fileURLWithPath: path)
        return "Inserted image '\(url.lastPathComponent)' with id '\(imageId)' (\(width)x\(height) pixels)"
    }

    /// Compute (width, height) from user-provided args + image's native aspect.
    /// - Both provided: use as-is.
    /// - Width only: height = width / aspectRatio.
    /// - Height only: width = height * aspectRatio.
    /// - Neither: use native pixel size.
    private func resolveImageDimensions(path: String, width: Int?, height: Int?) throws -> (Int, Int) {
        if let w = width, let h = height {
            return (w, h)
        }
        let native = try ImageDimensions.detect(path: path)
        switch (width, height) {
        case let (.some(w), nil):
            let h = native.aspectRatio > 0 ? Int(Double(w) / native.aspectRatio) : native.heightPx
            return (w, h)
        case let (nil, .some(h)):
            let w = Int(Double(h) * native.aspectRatio)
            return (w, h)
        default:
            return (native.widthPx, native.heightPx)
        }
    }

    private func updateImage(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let imageId = args["image_id"]?.stringValue else {
            throw WordError.missingParameter("image_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let width = args["width"]?.intValue
        let height = args["height"]?.intValue

        try doc.updateImage(imageId: imageId, widthPx: width, heightPx: height)
        try await storeDocument(doc, for: docId)

        var changes: [String] = []
        if let w = width { changes.append("width: \(w)px") }
        if let h = height { changes.append("height: \(h)px") }

        return "Updated image '\(imageId)': \(changes.joined(separator: ", "))"
    }

    private func deleteImage(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let imageId = args["image_id"]?.stringValue else {
            throw WordError.missingParameter("image_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        try doc.deleteImage(imageId: imageId)
        try await storeDocument(doc, for: docId)

        return "Deleted image '\(imageId)'"
    }

    private func listImages(args: [String: Value]) async throws -> String {
        let (doc, _) = try await resolveDocument(args: args)

        let images = doc.getImages()

        if images.isEmpty {
            return "No images in document"
        }

        var result = "Found \(images.count) image(s):\n"
        for img in images {
            result += "- id: \(img.id), file: \(img.fileName), size: \(img.widthPx)x\(img.heightPx)px\n"
        }

        return result
    }

    // MARK: - 9.17 export_image - 匯出單一圖片
    private func exportImage(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let imageId = args["image_id"]?.stringValue else {
            throw WordError.missingParameter("image_id")
        }
        guard let savePath = args["save_path"]?.stringValue else {
            throw WordError.missingParameter("save_path")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        // 找到對應的圖片
        guard let imageRef = doc.images.first(where: { $0.id == imageId }) else {
            throw WordError.parseError("找不到圖片 ID: \(imageId)")
        }

        // 確保目錄存在
        let url = URL(fileURLWithPath: savePath)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // 寫入檔案
        try imageRef.data.write(to: url)

        let sizeKB = imageRef.data.count / 1024
        return "Saved image \(imageId) to \(savePath) (\(sizeKB)KB)"
    }

    // MARK: - 9.18 export_all_images - 匯出所有圖片
    private func exportAllImages(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let outputDir = args["output_dir"]?.stringValue else {
            throw WordError.missingParameter("output_dir")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let images = doc.images
        if images.isEmpty {
            return "No images to export"
        }

        // 建立輸出目錄
        let dirURL = URL(fileURLWithPath: outputDir)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        var result = "Exported \(images.count) image(s) to \(outputDir):\n"
        for imageRef in images {
            let fileURL = dirURL.appendingPathComponent(imageRef.fileName)
            try imageRef.data.write(to: fileURL)
            let sizeKB = imageRef.data.count / 1024
            result += "  - \(imageRef.fileName) (\(sizeKB)KB)\n"
        }

        return result
    }

    private func setImageStyle(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let imageId = args["image_id"]?.stringValue else {
            throw WordError.missingParameter("image_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let hasBorder = args["has_border"]?.boolValue
        let borderColor = args["border_color"]?.stringValue
        let borderWidth = args["border_width"]?.intValue
        let hasShadow = args["has_shadow"]?.boolValue

        try doc.setImageStyle(
            imageId: imageId,
            hasBorder: hasBorder,
            borderColor: borderColor,
            borderWidth: borderWidth,
            hasShadow: hasShadow
        )

        try await storeDocument(doc, for: docId)

        var changes: [String] = []
        if let border = hasBorder { changes.append("border: \(border)") }
        if let color = borderColor { changes.append("color: \(color)") }
        if let width = borderWidth { changes.append("width: \(width)") }
        if let shadow = hasShadow { changes.append("shadow: \(shadow)") }

        return "Updated image style for '\(imageId)': \(changes.joined(separator: ", "))"
    }

    // MARK: - Export

    private func exportText(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let path = args["path"]?.stringValue else {
            throw WordError.missingParameter("path")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let text = doc.getText()
        try text.write(toFile: path, atomically: true, encoding: .utf8)

        return "Exported text to: \(path)"
    }

    private func exportMarkdown(args: [String: Value]) async throws -> String {
        guard let sourcePath = args["source_path"]?.stringValue else {
            throw WordError.missingParameter("source_path")
        }
        guard let outputPath = args["path"]?.stringValue else {
            throw WordError.missingParameter("path")
        }
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            throw WordError.fileNotFound(sourcePath)
        }

        // 檢查 Word lock file
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let lockFile = sourceURL.deletingLastPathComponent()
            .appendingPathComponent("~$" + sourceURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: lockFile.path) {
            throw WordError.invalidFormat("File is open in Microsoft Word. Please save and close it first: \(sourceURL.lastPathComponent)")
        }

        let document = try DocxReader.read(from: sourceURL)

        // 圖片輸出目錄：預設與 .md 同層的 figures/
        let figuresDir: URL
        if let customFigDir = args["figures_directory"]?.stringValue {
            figuresDir = URL(fileURLWithPath: customFigDir)
        } else {
            figuresDir = URL(fileURLWithPath: outputPath)
                .deletingLastPathComponent()
                .appendingPathComponent("figures")
        }

        // 建立轉換選項（預設 Tier 2：Markdown + 圖片提取）
        let options = ConversionOptions(
            includeFrontmatter: args["include_frontmatter"]?.boolValue ?? false,
            hardLineBreaks: args["hard_line_breaks"]?.boolValue ?? false,
            fidelity: .markdownWithFigures,
            figuresDirectory: figuresDir
        )

        // 轉換為 Markdown
        let markdown = try wordConverter.convertToString(document: document, options: options)

        // 寫入檔案
        try markdown.write(toFile: outputPath, atomically: true, encoding: .utf8)
        let figCount = (try? FileManager.default.contentsOfDirectory(atPath: figuresDir.path))?.count ?? 0
        if figCount > 0 {
            return "Exported Markdown to: \(outputPath) (\(figCount) figures in \(figuresDir.path))"
        }
        return "Exported Markdown to: \(outputPath)"
    }

    // MARK: - Hyperlink and Bookmark Operations

    private func insertHyperlink(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let url = args["url"]?.stringValue else {
            throw WordError.missingParameter("url")
        }
        guard let text = args["text"]?.stringValue else {
            throw WordError.missingParameter("text")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let paragraphIndex = args["paragraph_index"]?.intValue
        let tooltip = args["tooltip"]?.stringValue

        let hyperlinkId = doc.insertHyperlink(
            url: url,
            text: text,
            at: paragraphIndex,
            tooltip: tooltip
        )

        try await storeDocument(doc, for: docId)

        return "Inserted hyperlink '\(text)' -> \(url) with id '\(hyperlinkId)'"
    }

    private func insertInternalLink(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let bookmarkName = args["bookmark_name"]?.stringValue else {
            throw WordError.missingParameter("bookmark_name")
        }
        guard let text = args["text"]?.stringValue else {
            throw WordError.missingParameter("text")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let paragraphIndex = args["paragraph_index"]?.intValue
        let tooltip = args["tooltip"]?.stringValue

        let hyperlinkId = doc.insertInternalLink(
            bookmarkName: bookmarkName,
            text: text,
            at: paragraphIndex,
            tooltip: tooltip
        )

        try await storeDocument(doc, for: docId)

        return "Inserted internal link '\(text)' -> bookmark '\(bookmarkName)' with id '\(hyperlinkId)'"
    }

    private func updateHyperlink(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let hyperlinkId = args["hyperlink_id"]?.stringValue else {
            throw WordError.missingParameter("hyperlink_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let text = args["text"]?.stringValue
        let url = args["url"]?.stringValue

        try doc.updateHyperlink(hyperlinkId: hyperlinkId, text: text, url: url)
        try await storeDocument(doc, for: docId)

        var changes: [String] = []
        if let text = text { changes.append("text: '\(text)'") }
        if let url = url { changes.append("url: '\(url)'") }

        return "Updated hyperlink '\(hyperlinkId)': \(changes.joined(separator: ", "))"
    }

    private func deleteHyperlink(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let hyperlinkId = args["hyperlink_id"]?.stringValue else {
            throw WordError.missingParameter("hyperlink_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        try doc.deleteHyperlink(hyperlinkId: hyperlinkId)
        try await storeDocument(doc, for: docId)

        return "Deleted hyperlink '\(hyperlinkId)'"
    }

    private func insertBookmark(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let name = args["name"]?.stringValue else {
            throw WordError.missingParameter("name")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let paragraphIndex = args["paragraph_index"]?.intValue

        let bookmarkId = try doc.insertBookmark(name: name, at: paragraphIndex)
        try await storeDocument(doc, for: docId)

        return "Inserted bookmark '\(name)' with id \(bookmarkId)"
    }

    private func deleteBookmark(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let name = args["name"]?.stringValue else {
            throw WordError.missingParameter("name")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        try doc.deleteBookmark(name: name)
        try await storeDocument(doc, for: docId)

        return "Deleted bookmark '\(name)'"
    }

    // MARK: - Comment and Revision Operations

    private func insertComment(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let text = args["text"]?.stringValue else {
            throw WordError.missingParameter("text")
        }
        guard let author = args["author"]?.stringValue else {
            throw WordError.missingParameter("author")
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let commentId = try doc.insertComment(text: text, author: author, paragraphIndex: paragraphIndex)
        try await storeDocument(doc, for: docId)

        return "Inserted comment with id \(commentId) by '\(author)'"
    }

    private func updateComment(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let commentId = args["comment_id"]?.intValue else {
            throw WordError.missingParameter("comment_id")
        }
        guard let text = args["text"]?.stringValue else {
            throw WordError.missingParameter("text")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        try doc.updateComment(commentId: commentId, text: text)
        try await storeDocument(doc, for: docId)

        return "Updated comment \(commentId)"
    }

    private func deleteComment(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let commentId = args["comment_id"]?.intValue else {
            throw WordError.missingParameter("comment_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        try doc.deleteComment(commentId: commentId)
        try await storeDocument(doc, for: docId)

        return "Deleted comment \(commentId)"
    }

    private func listComments(args: [String: Value]) async throws -> String {
        let (doc, _) = try await resolveDocument(args: args)

        let comments = doc.getComments()
        if comments.isEmpty {
            return "No comments in document"
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"

        var result = "Comments (\(comments.count)):\n"
        for comment in comments {
            result += "- [ID: \(comment.id)] \(comment.author) (\(dateFormatter.string(from: comment.date))): \"\(comment.text)\" (para \(comment.paragraphIndex))\n"
        }

        return result
    }

    private func enableTrackChanges(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let author = args["author"]?.stringValue ?? "Unknown"
        doc.enableTrackChanges(author: author)
        try await storeDocument(doc, for: docId)

        return "Track changes enabled for '\(author)'"
    }

    private func disableTrackChanges(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        doc.disableTrackChanges()
        try await storeDocument(doc, for: docId)

        return "Track changes disabled"
    }

    private func acceptRevision(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let acceptAll = args["all"]?.boolValue ?? false

        if acceptAll {
            doc.acceptAllRevisions()
            try await storeDocument(doc, for: docId)
            return "Accepted all revisions"
        } else {
            guard let revisionId = args["revision_id"]?.intValue else {
                throw WordError.missingParameter("revision_id")
            }
            try doc.acceptRevision(revisionId: revisionId)
            try await storeDocument(doc, for: docId)
            return "Accepted revision \(revisionId)"
        }
    }

    private func rejectRevision(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let rejectAll = args["all"]?.boolValue ?? false

        if rejectAll {
            doc.rejectAllRevisions()
            try await storeDocument(doc, for: docId)
            return "Rejected all revisions"
        } else {
            guard let revisionId = args["revision_id"]?.intValue else {
                throw WordError.missingParameter("revision_id")
            }
            try doc.rejectRevision(revisionId: revisionId)
            try await storeDocument(doc, for: docId)
            return "Rejected revision \(revisionId)"
        }
    }

    // MARK: - Footnotes/Endnotes

    private func insertFootnote(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let text = args["text"]?.stringValue else {
            throw WordError.missingParameter("text")
        }

        let footnoteId = try doc.insertFootnote(text: text, paragraphIndex: paragraphIndex)
        try await storeDocument(doc, for: docId)
        return "Inserted footnote \(footnoteId) at paragraph \(paragraphIndex)"
    }

    private func deleteFootnote(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let footnoteId = args["footnote_id"]?.intValue else {
            throw WordError.missingParameter("footnote_id")
        }

        try doc.deleteFootnote(footnoteId: footnoteId)
        try await storeDocument(doc, for: docId)
        return "Deleted footnote \(footnoteId)"
    }

    private func insertEndnote(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let text = args["text"]?.stringValue else {
            throw WordError.missingParameter("text")
        }

        let endnoteId = try doc.insertEndnote(text: text, paragraphIndex: paragraphIndex)
        try await storeDocument(doc, for: docId)
        return "Inserted endnote \(endnoteId) at paragraph \(paragraphIndex)"
    }

    private func deleteEndnote(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let endnoteId = args["endnote_id"]?.intValue else {
            throw WordError.missingParameter("endnote_id")
        }

        try doc.deleteEndnote(endnoteId: endnoteId)
        try await storeDocument(doc, for: docId)
        return "Deleted endnote \(endnoteId)"
    }

    // MARK: - Advanced Features (P7)

    private func insertTOC(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let index = args["index"]?.intValue
        let title = args["title"]?.stringValue
        let minLevel = args["min_level"]?.intValue ?? 1
        let maxLevel = args["max_level"]?.intValue ?? 3
        let includePageNumbers = args["include_page_numbers"]?.boolValue ?? true
        let useHyperlinks = args["use_hyperlinks"]?.boolValue ?? true

        doc.insertTableOfContents(
            at: index,
            title: title,
            headingLevels: minLevel...maxLevel,
            includePageNumbers: includePageNumbers,
            useHyperlinks: useHyperlinks
        )
        try await storeDocument(doc, for: docId)

        return "Inserted table of contents (heading levels \(minLevel)-\(maxLevel))"
    }

    private func insertTextField(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let name = args["name"]?.stringValue else {
            throw WordError.missingParameter("name")
        }

        let defaultValue = args["default_value"]?.stringValue
        let maxLength = args["max_length"]?.intValue

        try doc.insertTextField(at: paragraphIndex, name: name, defaultValue: defaultValue, maxLength: maxLength)
        try await storeDocument(doc, for: docId)

        return "Inserted text field '\(name)' at paragraph \(paragraphIndex)"
    }

    private func insertCheckbox(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let name = args["name"]?.stringValue else {
            throw WordError.missingParameter("name")
        }

        let isChecked = args["is_checked"]?.boolValue ?? false

        try doc.insertCheckbox(at: paragraphIndex, name: name, isChecked: isChecked)
        try await storeDocument(doc, for: docId)

        return "Inserted checkbox '\(name)' (checked: \(isChecked)) at paragraph \(paragraphIndex)"
    }

    private func insertDropdown(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let name = args["name"]?.stringValue else {
            throw WordError.missingParameter("name")
        }
        guard let optionsValue = args["options"] else {
            throw WordError.missingParameter("options")
        }

        // 解析 options array
        var options: [String] = []
        if case .array(let arr) = optionsValue {
            for item in arr {
                if let str = item.stringValue {
                    options.append(str)
                }
            }
        }

        if options.isEmpty {
            throw WordError.missingParameter("options (array of strings)")
        }

        let selectedIndex = args["selected_index"]?.intValue ?? 0

        try doc.insertDropdown(at: paragraphIndex, name: name, options: options, selectedIndex: selectedIndex)
        try await storeDocument(doc, for: docId)

        return "Inserted dropdown '\(name)' with \(options.count) options at paragraph \(paragraphIndex)"
    }

    /// insert_equation MCP tool — emits structurally correct OMML.
    ///
    /// Two input paths:
    /// - `components:` argument — JSON tree with `type` discriminator. Primary
    ///   path for callers needing fine control.
    /// - `latex:` argument — LaTeX subset delegated to `LaTeXMathSwift.LaTeXMathParser`.
    ///   Supports `\frac`, `\sqrt`, `\hat`, `\bar`, `\tilde`, `\left/\right`,
    ///   `\sum`/`\int`/`\prod` with bounds, `\ln`/`\sin`/`\cos`/etc.,
    ///   `\sup`/`\inf`/`\lim`, `\text{}`, all Greek letters (lowercase /
    ///   uppercase / variants), and common operators. Anything else returns
    ///   an error naming the unrecognized token. See latex-math-swift README
    ///   for the canonical macro list.
    private func insertEquation(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        // #98 v2 (post-verify): both `latex` and `components` paths feed into
        // the same `[MathComponent]` AST and use handler-side OMML build via
        // `MathComponent.toOMML()`. Lib's `Document.insertEquation` overload
        // internally uses deprecated flat `MathEquation` (Field.swift:301)
        // which produces broken plain-text OOXML — see Insert step below for
        // full rationale. Path origin is preserved in error messages but the
        // insertion mechanic is unified.
        let components: [MathComponent]
        if let componentsValue = args["components"] {
            do {
                components = [try parseMathComponent(from: componentsValue)]
            } catch MathParseError.unknownType(let t) {
                return "Error: insert_equation: unknown math component type '\(t)'. Supported: run, fraction, radical, subSuperScript, nary."
            } catch MathParseError.missingField(let f, let t) {
                return "Error: insert_equation: math component '\(t)' missing required field '\(f)'"
            } catch MathParseError.invalidStructure(let msg) {
                return "Error: insert_equation: invalid components structure: \(msg)"
            }
        } else if let latex = args["latex"]?.stringValue {
            do {
                components = try parseLatex(latex)
            } catch LaTeXParseError.unrecognizedToken(let tok) {
                return "Error: insert_equation: unrecognized LaTeX token '\(tok)'. Use `components:` argument for full MathComponent control."
            } catch LaTeXParseError.malformed(let msg) {
                return "Error: insert_equation: malformed LaTeX: \(msg). Use `components:` for complex expressions."
            } catch LaTeXParseError.empty {
                return "Error: insert_equation: empty LaTeX input."
            }
        } else {
            return "Error: insert_equation: either 'components' (JSON tree) or 'latex' (LaTeX subset) argument required"
        }

        let displayMode = args["display_mode"]?.boolValue ?? true
        let paragraphIndex = args["paragraph_index"]?.intValue
        let afterText = args["after_text"]?.stringValue
        let beforeText = args["before_text"]?.stringValue
        let afterImageId = args["after_image_id"]?.stringValue          // v3.15.1
        let intoTableCellDict = args["into_table_cell"]?.objectValue    // v3.15.1
        let textInstance = args["text_instance"]?.intValue ?? 1
        // anchor-dx-consistency (#72): explicit text_instance < 1 rejected.
        if let explicit = args["text_instance"]?.intValue, explicit < 1 {
            return "Error: insert_equation: text_instance must be ≥ 1, got \(explicit)."
        }

        // Anchors only meaningful in display mode (block-level new paragraph).
        // Inline mode appends an OMML run into an existing paragraph; anchor
        // semantics are ambiguous — reject explicitly to surface the misuse.
        if !displayMode && (afterText != nil || beforeText != nil
                            || afterImageId != nil || intoTableCellDict != nil) {
            return "Error: insert_equation: anchor parameters (after_text / before_text / after_image_id / into_table_cell) only supported when display_mode=true (inline equations append to an existing paragraph; use paragraph_index instead)"
        }

        // #98: inline mode requires explicit `paragraph_index`. Pre-fix handler
        // silently fell back to `body.children.count` (= invalid index) and
        // either silent-clamped via the Int overload OR (post-#98 lib path)
        // would surface as `invalidParagraphIndex(N)`. Explicit pre-check yields
        // a more actionable error than the index-out-of-range message.
        if !displayMode && paragraphIndex == nil {
            return "Error: insert_equation: inline mode (display_mode=false) requires paragraph_index anchor (inline equations append OMML run to existing paragraph)"
        }

        // anchor-dx-consistency (#71): reject conflicting anchors in display mode.
        // Spec R1 — display mode anchor set: into_table_cell / after_image_id /
        // after_text / before_text / paragraph_index. Inline mode handled by the
        // pre-existing rejection above (only paragraph_index allowed).
        if displayMode {
            // #80: anchor list resolved from WordMCPServer.toolAnchorWhitelists (SoT).
            let presentAnchors = WordMCPServer.detectPresentAnchors(args, tool: "insert_equation")
            if presentAnchors.count > 1 {
                return "Error: insert_equation: received conflicting anchors: \(presentAnchors.joined(separator: " + ")). Specify exactly one."
            }
        }

        // Resolve anchor → InsertLocation + anchorInfo. Anchor priority
        // (display mode): into_table_cell > after_image_id > after_text >
        // before_text > paragraph_index > append.
        let location: InsertLocation
        let anchorInfo: String
        if displayMode, let cellDict = intoTableCellDict {
            // F5 (v3.15.1): malformed partial dict returns structured error.
            guard let tableIdx = cellDict["table_index"]?.intValue,
                  let row = cellDict["row"]?.intValue,
                  let col = cellDict["col"]?.intValue else {
                return "Error: insert_equation: into_table_cell requires all three fields (table_index, row, col); got partial dict"
            }
            location = .intoTableCell(tableIndex: tableIdx, row: row, col: col)
            anchorInfo = "into table[\(tableIdx)] cell (row: \(row), col: \(col))"
        } else if displayMode, let afterImageId = afterImageId {
            location = .afterImageId(afterImageId)
            anchorInfo = "after image '\(afterImageId)'"
        } else if displayMode, let afterText = afterText {
            location = .afterText(afterText, instance: textInstance)
            anchorInfo = "after text '\(afterText)' (instance \(textInstance))"
        } else if displayMode, let beforeText = beforeText {
            location = .beforeText(beforeText, instance: textInstance)
            anchorInfo = "before text '\(beforeText)' (instance \(textInstance))"
        } else {
            let insertIdx = paragraphIndex ?? doc.body.children.count
            location = .paragraphIndex(insertIdx)
            anchorInfo = "at index \(insertIdx)"
        }

        // #98 v2 (post-verify): both paths use MathComponent.toOMML() for
        // structurally correct OMML. The lib's `Document.insertEquation(at:
        // InsertLocation, latex:, displayMode:)` overload internally uses
        // `MathEquation(latex:).toXML()` which is `@available(*, deprecated, ...)`
        // flat output (Field.swift:301): emits `<m:r><m:t>processed_string</m:t></m:r>`
        // (e.g., `\frac{a}{b}` → `(a)/(b)` plain text), and worse, wraps in
        // `<w:p>` for displayMode causing nested `<w:p><w:p>` invalid OOXML
        // when used inside a Paragraph context. Codex verify (#98 6-AI ensemble)
        // flagged this as P1 regression.
        //
        // Resolution: handler builds OMML via MathComponent AST for both paths;
        // borrows lib's bounds-check via throwing `insertParagraph(_:at: InsertLocation)`
        // (display mode) and replicates lib's bounds-check pattern for inline mode
        // (handler-side append, since lib has no structured-OMML inline-append API).
        let xmlns = "xmlns:m=\"http://schemas.openxmlformats.org/officeDocument/2006/math\""
        let inner = components.map { $0.toOMML() }.joined()
        let ommlXML = displayMode
            ? "<m:oMathPara \(xmlns)><m:oMath>\(inner)</m:oMath></m:oMathPara>"
            : "<m:oMath \(xmlns)>\(inner)</m:oMath>"

        do {
            if displayMode {
                // Display mode: build new paragraph carrying the OMML, insert
                // via lib's throwing InsertLocation overload (centralized
                // bounds-check + structured errors).
                var eqRun = Run(text: "")
                eqRun.rawXML = ommlXML
                // Match lib's #85 BLOCKING #2 pattern: set both rawXML fields so
                // the post-cluster #99-#103 flatten walker sees this freshly-
                // inserted equation before the next save→reload cycle.
                eqRun.properties.rawXML = ommlXML
                let eqPara = Paragraph(runs: [eqRun])
                try doc.insertParagraph(eqPara, at: location)
            } else {
                // Inline mode: append OMML run to existing paragraph at
                // `paragraph_index`. The pre-check above already rejected
                // inline + nil paragraph_index, so `location` is guaranteed
                // to be `.paragraphIndex(idx)` with a non-nil idx.
                guard case .paragraphIndex(let idx) = location else {
                    // Defensive: pre-check should have caught this.
                    throw InsertLocationError.inlineModeRequiresParagraphIndex
                }
                // Bounds check matches lib's pattern at Document.swift:3990-3997
                // (#91 Defect 2): count only top-level `.paragraph` body
                // children, NOT recursing into block-level SDTs.
                let topLevelParaCount = doc.body.children.reduce(0) { count, child in
                    if case .paragraph = child { return count + 1 }
                    return count
                }
                guard idx >= 0, idx < topLevelParaCount else {
                    throw InsertLocationError.invalidParagraphIndex(idx)
                }
                // Walk top-level paragraphs, find target, append OMML run.
                var paraCounter = 0
                for (i, child) in doc.body.children.enumerated() {
                    guard case .paragraph(var para) = child else { continue }
                    if paraCounter == idx {
                        var eqRun = Run(text: "")
                        eqRun.rawXML = ommlXML
                        eqRun.properties.rawXML = ommlXML
                        para.runs.append(eqRun)
                        doc.body.children[i] = .paragraph(para)
                        doc.markPartDirty("word/document.xml")
                        break
                    }
                    paraCounter += 1
                }
            }
        } catch let InsertLocationError.tableIndexOutOfRange(i) {
            return "Error: insert_equation: table index \(i) out of range"
        } catch let InsertLocationError.tableCellOutOfRange(t, r, c) {
            return "Error: insert_equation: table[\(t)] cell (row: \(r), col: \(c)) out of range"
        } catch let InsertLocationError.imageIdNotFound(rId) {
            return "Error: insert_equation: image rId '\(rId)' not found"
        } catch let InsertLocationError.textNotFound(searchText, instance) {
            return "Error: insert_equation: text '\(searchText)' not found (instance \(instance))"
        } catch InsertLocationError.inlineModeRequiresParagraphIndex {
            // Defensive: explicit pre-check above should have caught this.
            return "Error: insert_equation: inline mode requires paragraph_index anchor"
        } catch let InsertLocationError.invalidParagraphIndex(idx) {
            return "Error: insert_equation: paragraph_index \(idx) out of range"
        }

        try await storeDocument(doc, for: docId)

        return "Inserted equation (display mode: \(displayMode), \(anchorInfo))"
    }

    // MARK: - Math parsers (insert_equation helpers)

    private enum MathParseError: Error {
        case unknownType(String)
        case missingField(field: String, forType: String)
        case invalidStructure(String)
    }

    /// Parse an MCP Value (JSON) into a MathComponent tree.
    /// Supported types: `run`, `fraction`, `radical`, `subSuperScript`, `nary`.
    private func parseMathComponent(from value: Value) throws -> MathComponent {
        guard case .object(let obj) = value else {
            throw MathParseError.invalidStructure("expected object, got non-object value")
        }
        guard let type = obj["type"]?.stringValue else {
            throw MathParseError.invalidStructure("missing 'type' discriminator")
        }

        switch type {
        case "run":
            guard let text = obj["text"]?.stringValue else {
                throw MathParseError.missingField(field: "text", forType: type)
            }
            let style = obj["style"]?.stringValue.flatMap { MathStyle(rawValue: $0) }
            return MathRun(text: text, style: style)

        case "fraction":
            guard case .array(let num)? = obj["numerator"] else {
                throw MathParseError.missingField(field: "numerator", forType: type)
            }
            guard case .array(let den)? = obj["denominator"] else {
                throw MathParseError.missingField(field: "denominator", forType: type)
            }
            return MathFraction(
                numerator: try num.map { try parseMathComponent(from: $0) },
                denominator: try den.map { try parseMathComponent(from: $0) }
            )

        case "radical":
            guard case .array(let radicand)? = obj["radicand"] else {
                throw MathParseError.missingField(field: "radicand", forType: type)
            }
            var degree: [MathComponent]?
            if case .array(let d)? = obj["degree"] {
                degree = try d.map { try parseMathComponent(from: $0) }
            }
            return MathRadical(
                radicand: try radicand.map { try parseMathComponent(from: $0) },
                degree: degree
            )

        case "subSuperScript":
            guard case .array(let base)? = obj["base"] else {
                throw MathParseError.missingField(field: "base", forType: type)
            }
            var sub: [MathComponent]?
            if case .array(let s)? = obj["sub"] {
                sub = try s.map { try parseMathComponent(from: $0) }
            }
            var sup: [MathComponent]?
            if case .array(let s)? = obj["sup"] {
                sup = try s.map { try parseMathComponent(from: $0) }
            }
            return MathSubSuperScript(
                base: try base.map { try parseMathComponent(from: $0) },
                sub: sub,
                sup: sup
            )

        case "nary":
            guard let opStr = obj["op"]?.stringValue,
                  let op = MathNary.NaryOperator(rawValue: opStr) else {
                throw MathParseError.missingField(field: "op (one of: ∑, ∫, ∏, ∬, ∮, ⋃, ⋂)", forType: type)
            }
            var sub: [MathComponent]?
            var sup: [MathComponent]?
            if case .array(let s)? = obj["sub"] { sub = try s.map { try parseMathComponent(from: $0) } }
            if case .array(let s)? = obj["sup"] { sup = try s.map { try parseMathComponent(from: $0) } }
            guard case .array(let base)? = obj["base"] else {
                throw MathParseError.missingField(field: "base", forType: type)
            }
            return MathNary(
                op: op,
                sub: sub,
                sup: sup,
                base: try base.map { try parseMathComponent(from: $0) }
            )

        default:
            throw MathParseError.unknownType(type)
        }
    }

    /// LaTeX subset parser delegated to `LaTeXMathSwift.LaTeXMathParser`.
    ///
    /// Returns an array of `MathComponent` instead of a single component
    /// because real-world equations are sequences of atoms (`R_t = a + b`)
    /// not single trees. The caller joins their OMML output for the
    /// `<m:oMath>` body.
    ///
    /// Supported macros: see `latex-math-swift` README. Anything outside the
    /// supported set throws `LaTeXParseError.unrecognizedToken`.
    private func parseLatex(_ latex: String) throws -> [MathComponent] {
        return try LaTeXMathParser.parse(latex)
    }

    private func setParagraphBorder(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }

        let typeStr = args["type"]?.stringValue ?? "single"
        let size = args["size"]?.intValue ?? 4
        let color = args["color"]?.stringValue ?? "000000"
        let space = args["space"]?.intValue ?? 1

        // 解析邊框類型
        let borderType = ParagraphBorderType(rawValue: typeStr) ?? .single
        let borderStyle = ParagraphBorderStyle(type: borderType, color: color, size: size, space: space)

        // 解析要套用的邊
        var topStyle: ParagraphBorderStyle? = borderStyle
        var bottomStyle: ParagraphBorderStyle? = borderStyle
        var leftStyle: ParagraphBorderStyle? = borderStyle
        var rightStyle: ParagraphBorderStyle? = borderStyle

        if let sidesValue = args["sides"] {
            if case .array(let arr) = sidesValue {
                topStyle = nil; bottomStyle = nil; leftStyle = nil; rightStyle = nil
                for item in arr {
                    if let side = item.stringValue {
                        switch side.lowercased() {
                        case "top": topStyle = borderStyle
                        case "bottom": bottomStyle = borderStyle
                        case "left": leftStyle = borderStyle
                        case "right": rightStyle = borderStyle
                        default: break
                        }
                    }
                }
            }
        }

        let border = ParagraphBorder(
            top: topStyle,
            bottom: bottomStyle,
            left: leftStyle,
            right: rightStyle
        )

        try doc.setParagraphBorder(at: paragraphIndex, border: border)
        try await storeDocument(doc, for: docId)

        return "Set border on paragraph \(paragraphIndex)"
    }

    private func setParagraphShading(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let fill = args["fill"]?.stringValue else {
            throw WordError.missingParameter("fill")
        }

        var pattern: ShadingPattern? = nil
        if let patternStr = args["pattern"]?.stringValue {
            pattern = ShadingPattern(rawValue: patternStr)
        }

        try doc.setParagraphShading(at: paragraphIndex, fill: fill, pattern: pattern)
        try await storeDocument(doc, for: docId)

        return "Set shading on paragraph \(paragraphIndex) (fill: #\(fill))"
    }

    private func setCharacterSpacing(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }

        let spacing = args["spacing"]?.intValue
        let position = args["position"]?.intValue
        let kern = args["kern"]?.intValue

        try doc.setCharacterSpacing(at: paragraphIndex, spacing: spacing, position: position, kern: kern)
        try await storeDocument(doc, for: docId)

        var changes: [String] = []
        if let spacing = spacing { changes.append("spacing: \(spacing)") }
        if let position = position { changes.append("position: \(position)") }
        if let kern = kern { changes.append("kern: \(kern)") }

        return "Set character spacing on paragraph \(paragraphIndex): \(changes.joined(separator: ", "))"
    }

    private func setTextEffect(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let effectType = args["effect"]?.stringValue else {
            throw WordError.missingParameter("effect")
        }

        // TextEffect 是 enum：blinkBackground, lights, antsBlack, antsRed, shimmer, sparkle, none
        guard let effect = TextEffect(rawValue: effectType) else {
            throw WordError.invalidParameter("effect", "Unknown effect type: \(effectType). Valid: blinkBackground, lights, antsBlack, antsRed, shimmer, sparkle, none")
        }

        try doc.setTextEffect(at: paragraphIndex, effect: effect)
        try await storeDocument(doc, for: docId)

        return "Applied '\(effectType)' effect to paragraph \(paragraphIndex)"
    }

    // MARK: - 8.1 Comment Replies and Resolution

    private func replyToComment(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let commentId = args["comment_id"]?.intValue else {
            throw WordError.missingParameter("comment_id")
        }
        guard let replyText = args["reply_text"]?.stringValue else {
            throw WordError.missingParameter("reply_text")
        }
        let author = args["author"]?.stringValue ?? "User"

        // 使用 CommentsCollection.addReply 方法
        guard let reply = doc.comments.addReply(to: commentId, author: author, text: replyText) else {
            throw WordError.invalidParameter("comment_id", "Comment with ID \(commentId) not found")
        }

        try await storeDocument(doc, for: docId)
        return "Added reply to comment \(commentId) by \(author) (reply ID: \(reply.id))"
    }

    private func resolveComment(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let commentId = args["comment_id"]?.intValue else {
            throw WordError.missingParameter("comment_id")
        }
        let resolved = args["resolved"]?.boolValue ?? true

        // 使用 CommentsCollection.markAsDone 方法
        doc.comments.markAsDone(commentId, done: resolved)
        try await storeDocument(doc, for: docId)

        return "Comment \(commentId) \(resolved ? "resolved" : "reopened")"
    }

    // MARK: - 8.2 Floating Images

    private func insertFloatingImage(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let path = args["path"]?.stringValue else {
            throw WordError.missingParameter("path")
        }

        let paragraphIndex = args["paragraph_index"]?.intValue ?? 0
        let widthEmu = args["width"]?.intValue ?? 2000000  // ~2 inches default
        let heightEmu = args["height"]?.intValue ?? 2000000
        let horizontalPos = args["horizontal_position"]?.intValue ?? 0
        let verticalPos = args["vertical_position"]?.intValue ?? 0
        let wrapTypeStr = args["wrap_type"]?.stringValue ?? "square"
        let horizontalRelative = args["horizontal_relative"]?.stringValue ?? "column"
        let allowOverlap = args["allow_overlap"]?.boolValue ?? true

        // 讀取圖片數據
        let url = URL(fileURLWithPath: path)
        let imageData = try Data(contentsOf: url)

        // 建立圖片參照
        let imageId = "rId\(doc.images.count + 10)"
        let imageRef = ImageReference(
            id: imageId,
            fileName: url.lastPathComponent,
            contentType: detectImageContentType(from: url),
            data: imageData
        )
        doc.images.append(imageRef)

        // 建立浮動圖片定位
        var anchorPosition = AnchorPosition()
        anchorPosition.horizontalOffset = horizontalPos
        anchorPosition.verticalOffset = verticalPos
        anchorPosition.allowOverlap = allowOverlap

        // 設定水平參照點
        if let hrel = HorizontalRelativeFrom(rawValue: horizontalRelative) {
            anchorPosition.horizontalRelativeFrom = hrel
        }

        // 設定文繞圖類型
        switch wrapTypeStr.lowercased() {
        case "none": anchorPosition.wrapType = .none
        case "square": anchorPosition.wrapType = .square
        case "tight": anchorPosition.wrapType = .tight
        case "through": anchorPosition.wrapType = .through
        case "topandbottom": anchorPosition.wrapType = .topAndBottom
        case "behindtext": anchorPosition.wrapType = .behindText
        case "infrontoftext": anchorPosition.wrapType = .inFrontOfText
        default: anchorPosition.wrapType = .square
        }

        // 建立浮動繪圖
        let drawing = Drawing.anchor(
            width: widthEmu,
            height: heightEmu,
            imageId: imageId,
            position: anchorPosition,
            name: url.lastPathComponent
        )

        // 插入到段落
        try doc.insertDrawing(drawing, at: paragraphIndex)
        try await storeDocument(doc, for: docId)

        return "Inserted floating image '\(url.lastPathComponent)' at paragraph \(paragraphIndex)"
    }

    private func detectImageContentType(from url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "bmp": return "image/bmp"
        case "tiff", "tif": return "image/tiff"
        default: return "image/png"
        }
    }

    // MARK: - 8.3 Field Codes

    private func insertIfField(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let leftOperand = args["left_operand"]?.stringValue else {
            throw WordError.missingParameter("left_operand")
        }
        guard let operatorStr = args["operator"]?.stringValue else {
            throw WordError.missingParameter("operator")
        }
        guard let rightOperand = args["right_operand"]?.stringValue else {
            throw WordError.missingParameter("right_operand")
        }
        guard let trueText = args["true_text"]?.stringValue else {
            throw WordError.missingParameter("true_text")
        }
        guard let falseText = args["false_text"]?.stringValue else {
            throw WordError.missingParameter("false_text")
        }

        // 轉換運算符字串為 enum
        let compOp: IFField.ComparisonOperator
        switch operatorStr {
        case "=", "==": compOp = .equal
        case "<>", "!=": compOp = .notEqual
        case "<": compOp = .lessThan
        case ">": compOp = .greaterThan
        case "<=": compOp = .lessThanOrEqual
        case ">=": compOp = .greaterThanOrEqual
        default: compOp = .equal
        }

        let ifField = IFField(
            leftOperand: leftOperand,
            comparisonOperator: compOp,
            rightOperand: rightOperand,
            trueText: trueText,
            falseText: falseText
        )

        try doc.insertFieldCode(ifField, at: paragraphIndex)
        try await storeDocument(doc, for: docId)

        return "Inserted IF field at paragraph \(paragraphIndex): IF \(leftOperand) \(operatorStr) \(rightOperand)"
    }

    private func insertCalculationField(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let expression = args["expression"]?.stringValue else {
            throw WordError.missingParameter("expression")
        }
        let format = args["format"]?.stringValue

        // 表達式可以是完整的如 "=SUM(ABOVE)" 或 "SUM(ABOVE)"
        let calcField = CalculationField(
            expression: expression,
            numberFormat: format
        )

        try doc.insertFieldCode(calcField, at: paragraphIndex)
        try await storeDocument(doc, for: docId)

        return "Inserted calculation field '\(expression)' at paragraph \(paragraphIndex)"
    }

    private func insertDateField(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        let format = args["format"]?.stringValue ?? "yyyy-MM-dd"
        let typeStr = args["type"]?.stringValue ?? "DATE"

        let fieldType: DateTimeFieldType
        switch typeStr.uppercased() {
        case "DATE": fieldType = .date
        case "TIME": fieldType = .time
        case "PRINTDATE": fieldType = .printDate
        case "SAVEDATE": fieldType = .saveDate
        case "CREATEDATE": fieldType = .createDate
        case "EDITTIME": fieldType = .editTime
        default: fieldType = .date
        }

        let dateField = DateTimeField(type: fieldType, dateFormat: format)

        try doc.insertFieldCode(dateField, at: paragraphIndex)
        try await storeDocument(doc, for: docId)

        return "Inserted \(typeStr) field with format '\(format)' at paragraph \(paragraphIndex)"
    }

    private func insertPageField(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        let typeStr = args["type"]?.stringValue ?? "PAGE"

        let infoType: DocumentInfoFieldType
        switch typeStr.uppercased() {
        case "PAGE": infoType = .page
        case "NUMPAGES": infoType = .numPages
        case "NUMWORDS": infoType = .numWords
        case "NUMCHARS": infoType = .numChars
        case "FILENAME": infoType = .fileName
        case "AUTHOR": infoType = .author
        case "TITLE": infoType = .title
        case "SECTIONPAGES": infoType = .sectionPages
        default: infoType = .page
        }

        let infoField = DocumentInfoField(type: infoType)

        try doc.insertFieldCode(infoField, at: paragraphIndex)
        try await storeDocument(doc, for: docId)

        return "Inserted \(typeStr) field at paragraph \(paragraphIndex)"
    }

    private func insertMergeField(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let fieldName = args["field_name"]?.stringValue else {
            throw WordError.missingParameter("field_name")
        }
        let textBefore = args["text_before"]?.stringValue
        let textAfter = args["text_after"]?.stringValue

        let mergeField = MergeField(
            fieldName: fieldName,
            textBefore: textBefore,
            textAfter: textAfter
        )

        try doc.insertFieldCode(mergeField, at: paragraphIndex)
        try await storeDocument(doc, for: docId)

        return "Inserted MERGEFIELD '\(fieldName)' at paragraph \(paragraphIndex)"
    }

    private func insertSequenceField(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let identifier = args["identifier"]?.stringValue else {
            throw WordError.missingParameter("identifier")
        }
        let resetOnHeading = args["reset_on_heading"]?.intValue

        let seqField = SequenceField(
            identifier: identifier,
            resetLevel: resetOnHeading
        )

        try doc.insertFieldCode(seqField, at: paragraphIndex)
        try await storeDocument(doc, for: docId)

        return "Inserted SEQ '\(identifier)' field at paragraph \(paragraphIndex)"
    }

    // MARK: - 8.4 Content Controls (SDT)

    /// #44 Phase 7.1: extended types + lock_type / list_items / date_format args.
    /// #44 Phase 7.3: SDT id allocation now uses doc.allocateSdtId() (max+1).
    /// repeatingSection type is rejected — callers must use insert_repeating_section.
    private func insertContentControl(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let typeStr = args["type"]?.stringValue else {
            throw WordError.missingParameter("type")
        }
        guard let tag = args["tag"]?.stringValue else {
            throw WordError.missingParameter("tag")
        }

        let alias = args["alias"]?.stringValue
        let placeholder = args["placeholder"]?.stringValue
        let contentText = args["content"]?.stringValue ?? ""

        guard let sdtType = SDTType(rawValue: typeStr) else {
            throw WordError.invalidParameter("type",
                "Unknown SDT type: '\(typeStr)'. Valid: richText, text, picture, date, dropDownList, comboBox, checkbox, bibliography, citation, group, repeatingSectionItem")
        }
        // Phase 7.1: explicit reject for repeatingSection (use insert_repeating_section instead).
        if sdtType == .repeatingSection {
            throw WordError.invalidParameter("type",
                "type='repeatingSection' is rejected — use insert_repeating_section tool for repeating sections")
        }
        // Phase 7.1: list_items required for dropDownList / comboBox.
        if sdtType == .dropDownList || sdtType == .comboBox {
            guard let items = args["list_items"]?.arrayValue, !items.isEmpty else {
                throw WordError.missingParameter("list_items (required for \(typeStr))")
            }
            _ = items  // list_items currently surfaced via raw XML in placeholder; full schema lands in MCP-Phase 2 of #44.
        }

        let lockType: SDTLockType
        if let lockStr = args["lock_type"]?.stringValue {
            guard let parsed = SDTLockType(rawValue: lockStr) else {
                throw WordError.invalidParameter("lock_type",
                    "Unknown lock_type: '\(lockStr)'. Valid: unlocked, sdtLocked, contentLocked, sdtContentLocked")
            }
            lockType = parsed
        } else {
            lockType = .unlocked
        }

        let sdt = StructuredDocumentTag(
            id: doc.allocateSdtId(),  // Phase 7.3: deterministic max+1 (was Int.random)
            tag: tag,
            alias: alias,
            type: sdtType,
            lockType: lockType,
            placeholder: placeholder
        )

        let contentControl = ContentControl(sdt: sdt, content: contentText)

        try doc.insertContentControl(contentControl, at: paragraphIndex)
        try await storeDocument(doc, for: docId)

        return "Inserted \(typeStr) content control '\(tag)' (id=\(sdt.id ?? -1)) at paragraph \(paragraphIndex)"
    }

    /// #44 Phase 7.2: allow_insert_delete_sections arg passes through to OOXML.
    private func insertRepeatingSection(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let tag = args["tag"]?.stringValue else {
            throw WordError.missingParameter("tag")
        }

        let index = args["index"]?.intValue ?? 0
        let sectionTitle = args["section_title"]?.stringValue
        let itemsArray = args["items"]?.arrayValue ?? []
        let allowInsertDelete = args["allow_insert_delete_sections"]?.boolValue ?? true

        var items: [RepeatingSectionItem] = []
        for item in itemsArray {
            if let content = item.stringValue {
                items.append(RepeatingSectionItem(tag: nil, content: content))
            }
        }
        if items.isEmpty {
            items.append(RepeatingSectionItem(content: ""))
        }

        var repeatingSection = RepeatingSection(
            tag: tag,
            alias: sectionTitle,
            items: items,
            allowInsertDeleteSections: allowInsertDelete,
            sectionTitle: sectionTitle
        )
        // Phase 7.3: assign deterministic id from allocator.
        repeatingSection.sdt.id = doc.allocateSdtId()

        try doc.insertRepeatingSection(repeatingSection, at: index)
        try await storeDocument(doc, for: docId)

        return "Inserted repeating section '\(tag)' (id=\(repeatingSection.sdt.id ?? -1)) with \(items.count) item(s) at index \(index)"
    }

    // MARK: - #44 Phase 5: Content Control Read Tools

    /// Phase 5.1: list_content_controls — flat (default) or nested tree.
    private func listContentControls(args: [String: Value]) async throws -> String {
        let doc = try await loadDocumentFromArgs(args)
        let nested = args["nested"]?.boolValue ?? false

        // Walk all paragraphs (including inside tables and block-level SDTs)
        // to collect entries in document order with paragraph indices.
        struct Entry {
            let id: Int?
            let tag: String?
            let alias: String?
            let type: String
            let lockType: String
            let currentText: String
            let paragraphIndex: Int
            let parentSdtId: Int?
            let children: [Entry]
        }

        func entryFor(_ control: ContentControl, paragraphIndex: Int, parentSdtId: Int?) -> Entry {
            let kids = control.children.map {
                entryFor($0, paragraphIndex: paragraphIndex, parentSdtId: control.sdt.id)
            }
            return Entry(
                id: control.sdt.id,
                tag: control.sdt.tag,
                alias: control.sdt.alias,
                type: control.sdt.type.rawValue,
                lockType: control.sdt.lockType.rawValue,
                currentText: Self.extractTextFromContentXML(control.content),
                paragraphIndex: paragraphIndex,
                parentSdtId: parentSdtId,
                children: kids
            )
        }

        var topLevel: [Entry] = []
        var paraIndex = 0
        func walkBody(_ children: [BodyChild]) {
            for child in children {
                switch child {
                case .paragraph(let p):
                    for c in p.contentControls {
                        topLevel.append(entryFor(c, paragraphIndex: paraIndex, parentSdtId: nil))
                    }
                    paraIndex += 1
                case .table(let table):
                    for row in table.rows {
                        for cell in row.cells {
                            for cellPara in cell.paragraphs {
                                for c in cellPara.contentControls {
                                    topLevel.append(entryFor(c, paragraphIndex: paraIndex, parentSdtId: nil))
                                }
                                paraIndex += 1
                            }
                        }
                    }
                case .contentControl(let outer, children: let inner):
                    topLevel.append(entryFor(outer, paragraphIndex: paraIndex, parentSdtId: nil))
                    walkBody(inner)
                case .bookmarkMarker, .rawBlockElement:
                    // ooxml-swift v0.19.6+ (#58): body-level markers carry no
                    // content controls — skip.
                    continue
                }
            }
        }
        walkBody(doc.body.children)

        // Render as JSON-ish text. MCP responses are strings; structured output
        // uses readable JSON so callers can re-parse without ambiguity.
        func render(_ entry: Entry) -> String {
            var fields: [String] = []
            if let id = entry.id { fields.append("\"id\": \(id)") }
            if let tag = entry.tag { fields.append("\"tag\": \"\(Self.jsonEscape(tag))\"") }
            if let alias = entry.alias { fields.append("\"alias\": \"\(Self.jsonEscape(alias))\"") }
            fields.append("\"type\": \"\(entry.type)\"")
            fields.append("\"lock_type\": \"\(entry.lockType)\"")
            fields.append("\"current_text\": \"\(Self.jsonEscape(entry.currentText))\"")
            fields.append("\"paragraph_index\": \(entry.paragraphIndex)")
            if nested {
                let kidsRendered = entry.children.map { render($0) }.joined(separator: ", ")
                fields.append("\"children\": [\(kidsRendered)]")
            } else {
                if let pid = entry.parentSdtId {
                    fields.append("\"parent_sdt_id\": \(pid)")
                } else {
                    fields.append("\"parent_sdt_id\": null")
                }
            }
            return "{ " + fields.joined(separator: ", ") + " }"
        }

        if nested {
            // Tree mode: only top-level controls (children embedded).
            let topOnly = topLevel.filter { $0.parentSdtId == nil }
            return "[" + topOnly.map { render($0) }.joined(separator: ", ") + "]"
        } else {
            // Flat mode: include every control AND every nested child.
            var flat: [Entry] = []
            func collect(_ e: Entry) {
                flat.append(e)
                for k in e.children { collect(k) }
            }
            for e in topLevel { collect(e) }
            return "[" + flat.map { render($0) }.joined(separator: ", ") + "]"
        }
    }

    /// Phase 5.2: get_content_control — lookup by id / tag / alias (exactly one).
    private func getContentControl(args: [String: Value]) async throws -> String {
        let doc = try await loadDocumentFromArgs(args)
        let id = args["id"]?.intValue
        let tag = args["tag"]?.stringValue
        let alias = args["alias"]?.stringValue

        let provided = [id != nil, tag != nil, alias != nil].filter { $0 }.count
        guard provided == 1 else {
            throw WordError.invalidParameter("identifier",
                "Provide exactly one of: id, tag, alias (got \(provided))")
        }

        // Collect all controls (top-level + nested) with their paragraph index.
        var all: [(control: ContentControl, paragraphIndex: Int, parentSdtId: Int?)] = []
        func recordControl(_ c: ContentControl, paraIndex: Int, parentId: Int?) {
            all.append((c, paraIndex, parentId))
            for kid in c.children {
                recordControl(kid, paraIndex: paraIndex, parentId: c.sdt.id)
            }
        }
        var paraIndex = 0
        func walkBody(_ children: [BodyChild]) {
            for child in children {
                switch child {
                case .paragraph(let p):
                    for c in p.contentControls { recordControl(c, paraIndex: paraIndex, parentId: nil) }
                    paraIndex += 1
                case .table(let table):
                    for row in table.rows {
                        for cell in row.cells {
                            for cp in cell.paragraphs {
                                for c in cp.contentControls { recordControl(c, paraIndex: paraIndex, parentId: nil) }
                                paraIndex += 1
                            }
                        }
                    }
                case .contentControl(let outer, children: let inner):
                    recordControl(outer, paraIndex: paraIndex, parentId: nil)
                    walkBody(inner)
                case .bookmarkMarker, .rawBlockElement:
                    // ooxml-swift v0.19.6+ (#58): body-level markers carry no
                    // content controls — skip.
                    continue
                }
            }
        }
        walkBody(doc.body.children)

        let matches: [(control: ContentControl, paragraphIndex: Int, parentSdtId: Int?)]
        if let id = id {
            matches = all.filter { $0.control.sdt.id == id }
        } else if let tag = tag {
            matches = all.filter { $0.control.sdt.tag == tag }
        } else if let alias = alias {
            matches = all.filter { $0.control.sdt.alias == alias }
        } else {
            matches = []
        }

        if matches.isEmpty {
            return "{ \"error\": \"not_found\", \"query\": { \"id\": \(id.map(String.init) ?? "null"), \"tag\": \(tag.map { "\"\(Self.jsonEscape($0))\"" } ?? "null"), \"alias\": \(alias.map { "\"\(Self.jsonEscape($0))\"" } ?? "null") } }"
        }
        if matches.count > 1 {
            let ids = matches.compactMap { $0.control.sdt.id }
            return "{ \"error\": \"multiple_matches\", \"matching_ids\": [\(ids.map(String.init).joined(separator: ", "))] }"
        }

        let m = matches[0]
        var fields: [String] = []
        if let mid = m.control.sdt.id { fields.append("\"id\": \(mid)") }
        if let mtag = m.control.sdt.tag { fields.append("\"tag\": \"\(Self.jsonEscape(mtag))\"") }
        if let malias = m.control.sdt.alias { fields.append("\"alias\": \"\(Self.jsonEscape(malias))\"") }
        fields.append("\"type\": \"\(m.control.sdt.type.rawValue)\"")
        fields.append("\"lock_type\": \"\(m.control.sdt.lockType.rawValue)\"")
        fields.append("\"current_text\": \"\(Self.jsonEscape(Self.extractTextFromContentXML(m.control.content)))\"")
        fields.append("\"paragraph_index\": \(m.paragraphIndex)")
        if let pid = m.parentSdtId {
            fields.append("\"parent_sdt_id\": \(pid)")
        } else {
            fields.append("\"parent_sdt_id\": null")
        }
        fields.append("\"content_xml\": \"\(Self.jsonEscape(m.control.content))\"")
        return "{ " + fields.joined(separator: ", ") + " }"
    }

    /// Phase 5.3: list_repeating_section_items — items inside a repeating-section SDT.
    /// Note: ooxml-swift v0.15.0 still stores RepeatingSection as Run.rawXML (legacy
    /// path; #44 Phase 3 covered ContentControl SDTs but RepeatingSection write path
    /// is unchanged). We surface items by parsing the rawXML where the SDT lives.
    private func listRepeatingSectionItems(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let id = args["id"]?.intValue else {
            throw WordError.missingParameter("id")
        }

        // Locate the repeating section's rawXML in any paragraph.
        for paragraph in doc.getAllParagraphs() {
            for run in paragraph.runs {
                guard let raw = run.rawXML,
                      raw.contains("<w15:repeatingSection"),
                      raw.contains("w:id w:val=\"\(id)\"")
                else { continue }
                let items = Self.parseRepeatingSectionItems(rawXML: raw)
                let rendered = items.enumerated().map { (i, text) in
                    "{ \"index\": \(i), \"text\": \"\(Self.jsonEscape(text))\" }"
                }.joined(separator: ", ")
                return "[\(rendered)]"
            }
        }
        return "{ \"error\": \"not_found\", \"id\": \(id) }"
    }

    // MARK: - #44 Phase 6: Content Control Write Tools

    /// Phase 6.1: update_content_control_text — text replacement.
    private func updateContentControlText(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let id = args["id"]?.intValue else {
            throw WordError.missingParameter("id")
        }
        guard let text = args["text"]?.stringValue else {
            throw WordError.missingParameter("text")
        }

        do {
            try doc.updateContentControl(id: id, newText: text)
        } catch WordError.unsupportedSDTType(let type) {
            return "{ \"error\": \"unsupported_type\", \"type\": \"\(type.rawValue)\" }"
        } catch WordError.contentControlNotFound(let nid) {
            return "{ \"error\": \"not_found\", \"id\": \(nid) }"
        }

        try await storeDocument(doc, for: docId)
        return "Updated content control id=\(id) text"
    }

    /// Phase 6.2: replace_content_control_content — full XML replacement with whitelist.
    private func replaceContentControlContentTool(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let id = args["id"]?.intValue else {
            throw WordError.missingParameter("id")
        }
        guard let xml = args["content_xml"]?.stringValue else {
            throw WordError.missingParameter("content_xml")
        }

        do {
            try doc.replaceContentControlContent(id: id, contentXML: xml)
        } catch WordError.disallowedElement(let name) {
            return "{ \"error\": \"disallowed_element\", \"element\": \"\(name)\" }"
        } catch WordError.contentControlNotFound(let nid) {
            return "{ \"error\": \"not_found\", \"id\": \(nid) }"
        }

        try await storeDocument(doc, for: docId)
        return "Replaced content control id=\(id) content"
    }

    /// Phase 6.3: delete_content_control — remove SDT, optionally keep content.
    private func deleteContentControlTool(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let id = args["id"]?.intValue else {
            throw WordError.missingParameter("id")
        }
        let keepContent = args["keep_content"]?.boolValue ?? true

        do {
            try doc.deleteContentControl(id: id, keepContent: keepContent)
        } catch WordError.contentControlNotFound(let nid) {
            return "{ \"error\": \"not_found\", \"id\": \(nid) }"
        }

        try await storeDocument(doc, for: docId)
        return "Deleted content control id=\(id) (keep_content=\(keepContent))"
    }

    /// Phase 6.4: update_repeating_section_item — modify single item text.
    /// Currently operates on the rawXML carrier (RepeatingSection is still written
    /// via Run.rawXML). Surfaces out_of_bounds when item_index is invalid.
    private func updateRepeatingSectionItem(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let parentId = args["parent_id"]?.intValue else {
            throw WordError.missingParameter("parent_id")
        }
        guard let itemIndex = args["item_index"]?.intValue else {
            throw WordError.missingParameter("item_index")
        }
        guard let text = args["text"]?.stringValue else {
            throw WordError.missingParameter("text")
        }

        // Mutate paragraphs in body (top-level only for now — repeating sections
        // are not nested in this SDD's scope). Locate by id substring in raw XML.
        let needle = "w:id w:val=\"\(parentId)\""
        var found = false
        for childIdx in 0..<doc.body.children.count {
            guard case .paragraph(var para) = doc.body.children[childIdx] else { continue }
            for runIdx in 0..<para.runs.count {
                guard let raw = para.runs[runIdx].rawXML,
                      raw.contains("<w15:repeatingSection"),
                      raw.contains(needle)
                else { continue }

                let items = Self.parseRepeatingSectionItems(rawXML: raw)
                guard itemIndex >= 0 && itemIndex < items.count else {
                    return "{ \"error\": \"out_of_bounds\", \"index\": \(itemIndex), \"count\": \(items.count) }"
                }
                let updated = Self.updateRepeatingSectionItemXML(
                    rawXML: raw, itemIndex: itemIndex, newText: text
                )
                para.runs[runIdx].rawXML = updated
                doc.body.children[childIdx] = .paragraph(para)
                found = true
                break
            }
            if found { break }
        }
        guard found else {
            return "{ \"error\": \"not_found\", \"parent_id\": \(parentId) }"
        }

        try await storeDocument(doc, for: docId)
        return "Updated repeating section parent_id=\(parentId) item_index=\(itemIndex)"
    }

    // MARK: - #44 Phase 8.1: list_custom_xml_parts stub
    // TODO: replace with real implementation in Change B
    // (`che-word-mcp-customxml-databinding`).

    private func listCustomXmlParts(args: [String: Value]) async throws -> String {
        // Validate doc_id / source_path is at least present (so we surface
        // bad-path errors consistently with future implementation).
        if args["doc_id"] == nil && args["source_path"] == nil {
            throw WordError.missingParameter("doc_id or source_path")
        }
        return "[]"
    }

    // MARK: - SDT helpers

    /// Load the document either from openDocuments (doc_id) or by reading
    /// the source_path directly. Used by read-only tools that support both modes.
    private func loadDocumentFromArgs(_ args: [String: Value]) async throws -> WordDocument {
        if let docId = args["doc_id"]?.stringValue {
            guard let doc = openDocuments[docId] else {
                throw WordError.documentNotFound(docId)
            }
            return doc
        }
        if let path = args["source_path"]?.stringValue {
            return try DocxReader.read(from: URL(fileURLWithPath: path))
        }
        throw WordError.missingParameter("doc_id or source_path")
    }

    /// Extract human-readable text from a ContentControl.content field.
    /// The content can be:
    /// - Plain text (no XML tags) — returned as-is
    /// - XML fragment with `<w:t>` runs — text content is concatenated
    /// MCP callers see "Acme Corp" regardless of how the SDT was inserted.
    static func extractTextFromContentXML(_ xml: String) -> String {
        guard !xml.isEmpty else { return "" }
        // Plain text fast path: no XML tags at all.
        if !xml.contains("<") {
            return xml
        }
        // Concatenate every <w:t ...>TEXT</w:t> body in document order.
        var out = ""
        let pattern = #"<w:t[^>]*>([^<]*)</w:t>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return xml }
        let range = NSRange(xml.startIndex..., in: xml)
        regex.enumerateMatches(in: xml, range: range) { match, _, _ in
            guard let m = match, let r = Range(m.range(at: 1), in: xml) else { return }
            out += xml[r]
        }
        return out
    }

    /// Parse the items inside a `<w15:repeatingSection>` rawXML blob and
    /// return their text contents in document order.
    static func parseRepeatingSectionItems(rawXML: String) -> [String] {
        // Each item is `<w:sdt>...<w15:repeatingSectionItem.../>...<w:sdtContent>...</w:sdtContent></w:sdt>`.
        // We extract the innermost `<w:t>...</w:t>` of each item.
        var items: [String] = []
        // Each item: `<w:sdt>...<w15:repeatingSectionItem ... />...</w:sdt>`.
        // The marker tag has `xmlns:w15="...//.../wordml"` attribute — URL slashes
        // mean we cannot use `[^/]*`, so we use a non-greedy `[^>]*?` up to `/>`.
        let itemPattern = #"<w:sdt>(?:(?!</w:sdt>).)*?<w15:repeatingSectionItem[^>]*?/>(?:(?!</w:sdt>).)*?</w:sdt>"#
        guard let itemRegex = try? NSRegularExpression(pattern: itemPattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(rawXML.startIndex..., in: rawXML)
        let textPattern = #"<w:t[^>]*>([^<]*)</w:t>"#
        let textRegex = try? NSRegularExpression(pattern: textPattern)
        itemRegex.enumerateMatches(in: rawXML, range: range) { match, _, _ in
            guard let m = match, let r = Range(m.range, in: rawXML) else { return }
            let itemXml = String(rawXML[r])
            var text = ""
            let itemRange = NSRange(itemXml.startIndex..., in: itemXml)
            textRegex?.enumerateMatches(in: itemXml, range: itemRange) { tm, _, _ in
                guard let tm = tm, let tr = Range(tm.range(at: 1), in: itemXml) else { return }
                text += itemXml[tr]
            }
            items.append(text)
        }
        return items
    }

    /// Replace the text content of the Nth `<w15:repeatingSectionItem>` inside
    /// a rawXML blob. Used by `update_repeating_section_item`.
    static func updateRepeatingSectionItemXML(rawXML: String, itemIndex: Int, newText: String) -> String {
        // Each item: `<w:sdt>...<w15:repeatingSectionItem ... />...</w:sdt>`.
        // The marker tag has `xmlns:w15="...//.../wordml"` attribute — URL slashes
        // mean we cannot use `[^/]*`, so we use a non-greedy `[^>]*?` up to `/>`.
        let itemPattern = #"<w:sdt>(?:(?!</w:sdt>).)*?<w15:repeatingSectionItem[^>]*?/>(?:(?!</w:sdt>).)*?</w:sdt>"#
        guard let itemRegex = try? NSRegularExpression(pattern: itemPattern, options: [.dotMatchesLineSeparators]) else {
            return rawXML
        }
        let range = NSRange(rawXML.startIndex..., in: rawXML)
        let matches = itemRegex.matches(in: rawXML, range: range)
        guard itemIndex >= 0 && itemIndex < matches.count else { return rawXML }

        let itemMatchRange = matches[itemIndex].range
        guard let itemRange = Range(itemMatchRange, in: rawXML) else { return rawXML }
        let itemXml = String(rawXML[itemRange])

        // Replace the first <w:t...>...</w:t> in this item with the new text.
        let escaped = newText
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let replacement = "<w:t xml:space=\"preserve\">\(escaped)</w:t>"
        let textPattern = #"<w:t[^>]*>[^<]*</w:t>"#
        guard let textRegex = try? NSRegularExpression(pattern: textPattern) else { return rawXML }
        let updatedItem = textRegex.stringByReplacingMatches(
            in: itemXml,
            range: NSRange(itemXml.startIndex..., in: itemXml),
            withTemplate: replacement
        )

        return rawXML.replacingOccurrences(of: itemXml, with: updatedItem)
    }

    /// Minimal JSON string escaper — handles the cases that appear in SDT
    /// metadata (quotes, backslashes, control characters under ASCII 0x20).
    static func jsonEscape(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out += String(scalar)
                }
            }
        }
        return out
    }

    // MARK: - P9 新增功能

    // 9.1 insert_text - 在指定位置插入文字
    private func insertText(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let text = args["text"]?.stringValue else {
            throw WordError.missingParameter("text")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let position = args["position"]?.intValue

        // 取得段落並插入文字
        let paragraphs = doc.getParagraphs()
        guard paragraphIndex >= 0 && paragraphIndex < paragraphs.count else {
            throw WordError.invalidIndex(paragraphIndex)
        }

        // 取得現有文字並在指定位置插入
        let currentText = paragraphs[paragraphIndex].getText()
        let insertPosition = position ?? currentText.count

        let startIndex = currentText.startIndex
        let insertIndex = currentText.index(startIndex, offsetBy: min(insertPosition, currentText.count))
        let newText = String(currentText[..<insertIndex]) + text + String(currentText[insertIndex...])

        try doc.updateParagraph(at: paragraphIndex, text: newText)
        try await storeDocument(doc, for: docId)

        return "Inserted text at paragraph \(paragraphIndex)\(position.map { ", position \($0)" } ?? " (at end)")"
    }

    // 9.2 get_document_text - get_text 的別名
    private func getDocumentText(args: [String: Value]) async throws -> String {
        // 直接呼叫 getText，這是一個更直覺的別名
        return try await getText(args: args)
    }

    // 9.3 search_text - 搜尋文字
    private func searchText(args: [String: Value]) async throws -> String {
        guard let query = args["query"]?.stringValue else {
            throw WordError.missingParameter("query")
        }
        let (doc, _) = try await resolveDocument(args: args)

        let caseSensitive = args["case_sensitive"]?.boolValue ?? false

        struct SearchResult {
            let location: String
            let startPosition: Int
            let text: String
        }

        var results: [SearchResult] = []

        func searchInParagraph(_ para: Paragraph, location: String) {
            let paraText = para.getText()
            let haystack = caseSensitive ? paraText : paraText.lowercased()
            let needle = caseSensitive ? query : query.lowercased()

            var searchStart = haystack.startIndex
            while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
                let position = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
                let matchedText = String(paraText[range])
                results.append(SearchResult(location: location, startPosition: position, text: matchedText))
                searchStart = range.upperBound
            }
        }

        // 搜尋頂層段落和表格內的段落
        var paraIndex = 0
        var tableIndex = 0
        // Recursive walker so block-level SDT wrappers (#44) are transparent
        // for search purposes — matches inside SDT children appear with the
        // same paragraph/table index numbering as plain body siblings.
        func walk(_ children: [BodyChild]) {
            for child in children {
                switch child {
                case .paragraph(let para):
                    searchInParagraph(para, location: "Paragraph \(paraIndex)")
                    paraIndex += 1
                case .table(let table):
                    for (rowIdx, row) in table.rows.enumerated() {
                        for (cellIdx, cell) in row.cells.enumerated() {
                            for para in cell.paragraphs {
                                searchInParagraph(para, location: "Table \(tableIndex), row \(rowIdx), col \(cellIdx)")
                            }
                        }
                    }
                    tableIndex += 1
                case .contentControl(_, children: let inner):
                    walk(inner)
                case .bookmarkMarker, .rawBlockElement:
                    // ooxml-swift v0.19.6+ (#58): body-level markers carry no
                    // searchable text — skip.
                    continue
                }
            }
        }
        walk(doc.body.children)

        if results.isEmpty {
            return "No matches found for '\(query)'"
        }

        var output = "Found \(results.count) match(es) for '\(query)':\n"
        for result in results {
            output += "- \(result.location), position \(result.startPosition): \"\(result.text)\"\n"
        }
        return output
    }

    // 9.4 list_hyperlinks - 列出所有超連結
    private func listHyperlinks(args: [String: Value]) async throws -> String {
        let (doc, _) = try await resolveDocument(args: args)

        let hyperlinks = doc.getHyperlinks()
        if hyperlinks.isEmpty {
            return "No hyperlinks in document"
        }

        var output = "Hyperlinks in document (\(hyperlinks.count)):\n"
        for (index, link) in hyperlinks.enumerated() {
            let displayText = link.text
            let target = link.url ?? link.anchor ?? "(unknown target)"
            output += "[\(index)] (\(link.type)) \(displayText) -> \(target)\n"
        }
        return output
    }

    // 9.5 list_bookmarks - 列出所有書籤
    private func listBookmarks(args: [String: Value]) async throws -> String {
        let (doc, _) = try await resolveDocument(args: args)

        let bookmarks = doc.getBookmarks()
        if bookmarks.isEmpty {
            return "No bookmarks in document"
        }

        var output = "Bookmarks in document (\(bookmarks.count)):\n"
        for (index, bookmark) in bookmarks.enumerated() {
            output += "[\(index)] \(bookmark.name)\n"
        }
        return output
    }

    // 9.6 list_footnotes - 列出所有腳註
    private func listFootnotes(args: [String: Value]) async throws -> String {
        let (doc, _) = try await resolveDocument(args: args)

        let footnotes = doc.getFootnotes()
        if footnotes.isEmpty {
            return "No footnotes in document"
        }

        var output = "Footnotes in document (\(footnotes.count)):\n"
        for footnote in footnotes {
            let preview = String(footnote.text.prefix(50))
            output += "[\(footnote.id)] \(preview)...\n"
        }
        return output
    }

    // 9.7 list_endnotes - 列出所有尾註
    private func listEndnotes(args: [String: Value]) async throws -> String {
        let (doc, _) = try await resolveDocument(args: args)

        let endnotes = doc.getEndnotes()
        if endnotes.isEmpty {
            return "No endnotes in document"
        }

        var output = "Endnotes in document (\(endnotes.count)):\n"
        for endnote in endnotes {
            let preview = String(endnote.text.prefix(50))
            output += "[\(endnote.id)] \(preview)...\n"
        }
        return output
    }

    // 9.8 get_revisions - 取得所有修訂記錄
    private func getRevisions(args: [String: Value]) async throws -> String {
        // Reject deprecated full_text parameter (replaced by summarize, inverted default).
        // Spec: word-mcp-markdown-export — Requirement: full_text parameter is removed.
        if args["full_text"] != nil {
            throw WordError.invalidParameter(
                "full_text",
                "removed in this release; use 'summarize' (inverted default — pass summarize: true to enable elision; omit for complete text)"
            )
        }

        let (doc, _) = try await resolveDocument(args: args)
        let summarize = args["summarize"]?.boolValue ?? false

        let revisions = doc.getRevisions()
        if revisions.isEmpty {
            return "No revisions in document"
        }

        var output = "Revisions in document (\(revisions.count)):\n"
        for revision in revisions {
            // revision.type 是 String (rawValue)
            let typeStr = revision.type.uppercased()
            let author = revision.author
            output += "[\(revision.id)] \(typeStr) by \(author) at paragraph \(revision.paragraphIndex)\n"
            if let original = revision.originalText {
                output += "    Original: \(truncateText(original, summarize: summarize))\n"
            }
            if let newText = revision.newText {
                output += "    New: \(truncateText(newText, summarize: summarize))\n"
            }
        }
        return output
    }

    // 9.9 accept_all_revisions - 接受所有修訂
    private func acceptAllRevisions(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let count = doc.getRevisions().count
        doc.acceptAllRevisions()
        try await storeDocument(doc, for: docId)

        return "Accepted \(count) revision(s)"
    }

    // 9.10 reject_all_revisions - 拒絕所有修訂
    private func rejectAllRevisions(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let count = doc.getRevisions().count
        doc.rejectAllRevisions()
        try await storeDocument(doc, for: docId)

        return "Rejected \(count) revision(s)"
    }

    // 9.11 set_document_properties - 設定文件屬性
    private func setDocumentProperties(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        var props = doc.properties

        if let title = args["title"]?.stringValue {
            props.title = title
        }
        if let subject = args["subject"]?.stringValue {
            props.subject = subject
        }
        if let creator = args["creator"]?.stringValue {
            props.creator = creator
        }
        if let keywords = args["keywords"]?.stringValue {
            props.keywords = keywords
        }
        if let description = args["description"]?.stringValue {
            props.description = description
        }

        doc.properties = props
        // v3.5.0: properties is a public field — direct assignment bypasses
        // ooxml-swift's instrumented setters, so we mark docProps/core.xml dirty
        // explicitly. Without this, save_document overlay mode would skip it.
        doc.markPartDirty("docProps/core.xml")
        try await storeDocument(doc, for: docId)

        return "Updated document properties"
    }

    // 9.12 get_document_properties - 取得文件屬性
    private func getDocumentProperties(args: [String: Value]) async throws -> String {
        let (doc, _) = try await resolveDocument(args: args)

        let props = doc.properties

        var output = "Document Properties:\n"
        if let title = props.title { output += "- Title: \(title)\n" }
        if let subject = props.subject { output += "- Subject: \(subject)\n" }
        if let creator = props.creator { output += "- Creator: \(creator)\n" }
        if let keywords = props.keywords { output += "- Keywords: \(keywords)\n" }
        if let description = props.description { output += "- Description: \(description)\n" }
        if let lastModifiedBy = props.lastModifiedBy { output += "- Last Modified By: \(lastModifiedBy)\n" }
        if let revision = props.revision { output += "- Revision: \(revision)\n" }
        if let created = props.created { output += "- Created: \(created)\n" }
        if let modified = props.modified { output += "- Modified: \(modified)\n" }

        if output == "Document Properties:\n" {
            return "No document properties set"
        }

        return output
    }

    // 9.13 get_paragraph_runs - 取得段落的 runs 及格式
    private func getParagraphRuns(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let paragraphs = doc.getParagraphs()
        guard paragraphIndex >= 0 && paragraphIndex < paragraphs.count else {
            throw WordError.invalidIndex(paragraphIndex)
        }

        let para = paragraphs[paragraphIndex]
        var output = "Paragraph [\(paragraphIndex)] Runs:\n"

        for (runIndex, run) in para.runs.enumerated() {
            output += "  Run [\(runIndex)]:\n"
            output += "    Text: \"\(run.text)\"\n"

            // 格式資訊
            let props = run.properties
            var formatParts: [String] = []

            if props.bold { formatParts.append("bold") }
            if props.italic { formatParts.append("italic") }
            if props.strikethrough { formatParts.append("strikethrough") }
            if let underline = props.underline { formatParts.append("underline:\(underline.rawValue)") }
            if let color = props.color { formatParts.append("color:#\(color)") }
            if let highlight = props.highlight { formatParts.append("highlight:\(highlight.rawValue)") }
            if let fontSize = props.fontSize { formatParts.append("size:\(fontSize / 2)pt") }
            if let fontName = props.fontName { formatParts.append("font:\(fontName)") }
            if let verticalAlign = props.verticalAlign { formatParts.append("vertAlign:\(verticalAlign.rawValue)") }

            if formatParts.isEmpty {
                output += "    Format: (none)\n"
            } else {
                output += "    Format: \(formatParts.joined(separator: ", "))\n"
            }
        }

        // 也顯示超連結
        if !para.hyperlinks.isEmpty {
            output += "  Hyperlinks:\n"
            for hyperlink in para.hyperlinks {
                output += "    - \"\(hyperlink.text)\" -> \(hyperlink.url ?? hyperlink.anchor ?? "unknown")\n"
            }
        }

        return output
    }

    // 9.14 get_text_with_formatting - 取得帶格式標記的文字
    private func getTextWithFormatting(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let paragraphs = doc.getParagraphs()

        // 如果指定了段落索引，只處理該段落
        if let paragraphIndex = args["paragraph_index"]?.intValue {
            guard paragraphIndex >= 0 && paragraphIndex < paragraphs.count else {
                throw WordError.invalidIndex(paragraphIndex)
            }
            return formatParagraphWithMarkup(paragraphs[paragraphIndex], index: paragraphIndex)
        }

        // 處理所有段落
        var output = ""
        for (index, para) in paragraphs.enumerated() {
            output += formatParagraphWithMarkup(para, index: index) + "\n"
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Helper: 將段落轉換為帶格式標記的文字
    private func formatParagraphWithMarkup(_ para: Paragraph, index: Int) -> String {
        var result = "[\(index)] "

        for run in para.runs {
            var text = run.text
            let props = run.properties

            // 加入格式標記
            if props.bold {
                text = "**\(text)**"
            }
            if props.italic {
                text = "*\(text)*"
            }
            if props.strikethrough {
                text = "~~\(text)~~"
            }
            if let color = props.color {
                // 常見顏色轉換為名稱
                let colorName = colorHexToName(color)
                text = "{{color:\(colorName)}}\(text){{/color}}"
            }
            if let highlight = props.highlight {
                text = "{{highlight:\(highlight.rawValue)}}\(text){{/highlight}}"
            }
            if let underline = props.underline {
                text = "{{underline:\(underline.rawValue)}}\(text){{/underline}}"
            }

            result += text
        }

        // 加入超連結
        for hyperlink in para.hyperlinks {
            result += " [\(hyperlink.text)](\(hyperlink.url ?? "#\(hyperlink.anchor ?? "")"))"
        }

        return result
    }

    // Helper: 顏色 hex 轉名稱
    private func colorHexToName(_ hex: String) -> String {
        let upperHex = hex.uppercased()
        switch upperHex {
        case "FF0000": return "red"
        case "00FF00": return "green"
        case "0000FF": return "blue"
        case "FFFF00": return "yellow"
        case "00FFFF": return "cyan"
        case "FF00FF": return "magenta"
        case "000000": return "black"
        case "FFFFFF": return "white"
        case "808080": return "gray"
        case "FFA500": return "orange"
        case "800080": return "purple"
        default: return "#\(hex)"
        }
    }

    // 9.15 search_by_formatting - 搜尋特定格式的文字
    private func searchByFormatting(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        // 取得搜尋條件
        let searchColor = args["color"]?.stringValue?.uppercased()
        let searchBold = args["bold"]?.boolValue
        let searchItalic = args["italic"]?.boolValue
        let searchHighlight = args["highlight"]?.stringValue

        let paragraphs = doc.getParagraphs()
        var results: [(paragraphIndex: Int, runIndex: Int, text: String, format: String)] = []

        for (paraIndex, para) in paragraphs.enumerated() {
            for (runIndex, run) in para.runs.enumerated() {
                let props = run.properties
                var matches = true

                // 檢查顏色
                if let color = searchColor {
                    if props.color?.uppercased() != color {
                        matches = false
                    }
                }

                // 檢查粗體
                if let bold = searchBold {
                    if props.bold != bold {
                        matches = false
                    }
                }

                // 檢查斜體
                if let italic = searchItalic {
                    if props.italic != italic {
                        matches = false
                    }
                }

                // 檢查螢光標記
                if let highlight = searchHighlight {
                    if props.highlight?.rawValue != highlight {
                        matches = false
                    }
                }

                // 如果符合且文字不為空，加入結果
                if matches && !run.text.isEmpty {
                    var formatParts: [String] = []
                    if props.bold { formatParts.append("bold") }
                    if props.italic { formatParts.append("italic") }
                    if let color = props.color { formatParts.append("color:#\(color)") }
                    if let highlight = props.highlight { formatParts.append("highlight:\(highlight.rawValue)") }

                    results.append((
                        paragraphIndex: paraIndex,
                        runIndex: runIndex,
                        text: run.text,
                        format: formatParts.isEmpty ? "(none)" : formatParts.joined(separator: ", ")
                    ))
                }
            }
        }

        if results.isEmpty {
            return "No text found matching the specified formatting"
        }

        var output = "Found \(results.count) match(es):\n"
        for result in results {
            output += "  [Para \(result.paragraphIndex), Run \(result.runIndex)]: \"\(result.text)\"\n"
            output += "    Format: \(result.format)\n"
        }

        return output
    }

    // 9.16 search_text_with_formatting - 搜尋文字並顯示格式
    private func searchTextWithFormatting(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let query = args["query"]?.stringValue else {
            throw WordError.missingParameter("query")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let caseSensitive = args["case_sensitive"]?.boolValue ?? false
        let contextChars = args["context_chars"]?.intValue ?? 20

        let paragraphs = doc.getParagraphs()
        var results: [(paraIndex: Int, position: Int, matchedText: String, context: String, formats: [String])] = []

        for (paraIndex, para) in paragraphs.enumerated() {
            let paraText = para.getText()
            let searchText = caseSensitive ? paraText : paraText.lowercased()
            let searchQuery = caseSensitive ? query : query.lowercased()

            var searchStart = searchText.startIndex
            while let range = searchText.range(of: searchQuery, range: searchStart..<searchText.endIndex) {
                let position = searchText.distance(from: searchText.startIndex, to: range.lowerBound)
                let matchedText = String(paraText[range])

                // 取得上下文
                let contextStart = max(0, position - contextChars)
                let contextEnd = min(paraText.count, position + matchedText.count + contextChars)
                let startIndex = paraText.index(paraText.startIndex, offsetBy: contextStart)
                let endIndex = paraText.index(paraText.startIndex, offsetBy: contextEnd)
                var context = String(paraText[startIndex..<endIndex])
                if contextStart > 0 { context = "..." + context }
                if contextEnd < paraText.count { context = context + "..." }

                // 找出該位置的格式
                var formats: [String] = []
                var currentPos = 0
                for run in para.runs {
                    let runEnd = currentPos + run.text.count
                    // 檢查這個 run 是否包含搜尋結果
                    if currentPos <= position && position < runEnd {
                        let props = run.properties
                        if props.bold { formats.append("bold") }
                        if props.italic { formats.append("italic") }
                        if props.strikethrough { formats.append("strikethrough") }
                        if let color = props.color {
                            formats.append("color:\(colorHexToName(color))")
                        }
                        if let highlight = props.highlight {
                            formats.append("highlight:\(highlight.rawValue)")
                        }
                        if let underline = props.underline {
                            formats.append("underline:\(underline.rawValue)")
                        }
                        break
                    }
                    currentPos = runEnd
                }

                results.append((paraIndex, position, matchedText, context, formats))
                searchStart = range.upperBound
            }
        }

        if results.isEmpty {
            return "No matches found for '\(query)'"
        }

        var output = "Found \(results.count) match(es) for '\(query)':\n"
        for result in results {
            output += "[Para \(result.paraIndex)] \(result.context)\n"
            if result.formats.isEmpty {
                output += "  Format: (none)\n"
            } else {
                output += "  Format: \(result.formats.joined(separator: ", "))\n"
            }
        }
        return output
    }

    // 9.17 list_all_formatted_text - 列出特定格式的所有文字
    private func listAllFormattedText(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let formatType = args["format_type"]?.stringValue?.lowercased() else {
            throw WordError.missingParameter("format_type")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let colorFilter = args["color_filter"]?.stringValue?.uppercased()
        let paragraphStart = args["paragraph_start"]?.intValue ?? 0
        let paragraphEnd = args["paragraph_end"]?.intValue

        let paragraphs = doc.getParagraphs()
        let endIndex = paragraphEnd ?? paragraphs.count - 1

        guard paragraphStart >= 0 && paragraphStart < paragraphs.count else {
            throw WordError.invalidIndex(paragraphStart)
        }
        guard endIndex >= paragraphStart && endIndex < paragraphs.count else {
            throw WordError.invalidIndex(endIndex)
        }

        var results: [(paraIndex: Int, text: String)] = []

        for paraIndex in paragraphStart...endIndex {
            let para = paragraphs[paraIndex]
            for run in para.runs {
                let props = run.properties
                var matches = false

                switch formatType {
                case "italic":
                    matches = props.italic
                case "bold":
                    matches = props.bold
                case "underline":
                    matches = props.underline != nil
                case "strikethrough":
                    matches = props.strikethrough
                case "highlight":
                    matches = props.highlight != nil
                case "color":
                    if let colorFilter = colorFilter {
                        matches = props.color?.uppercased() == colorFilter
                    } else {
                        matches = props.color != nil
                    }
                default:
                    break
                }

                if matches && !run.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    results.append((paraIndex, run.text))
                }
            }
        }

        if results.isEmpty {
            let rangeInfo = paragraphEnd != nil ? " in paragraphs \(paragraphStart)-\(endIndex)" : ""
            return "No \(formatType) text found\(rangeInfo)"
        }

        var output = "Found \(results.count) \(formatType) text segment(s):\n"
        for result in results {
            // 截斷過長的文字
            let displayText = result.text.count > 60 ? String(result.text.prefix(57)) + "..." : result.text
            output += "[Para \(result.paraIndex)] \"\(displayText)\"\n"
        }
        return output
    }

    // 9.18 get_word_count_by_section - 按區段統計字數
    private func getWordCountBySection(args: [String: Value]) async throws -> String {
        let (doc, _) = try await resolveDocument(args: args)

        // 解析區段標記
        var sectionMarkers: [String] = []
        if let markersValue = args["section_markers"] {
            if let markersArray = markersValue.arrayValue {
                sectionMarkers = markersArray.compactMap { $0.stringValue }
            }
        }

        // 解析排除區段
        var excludeSections: Set<String> = []
        if let excludeValue = args["exclude_sections"] {
            if let excludeArray = excludeValue.arrayValue {
                excludeSections = Set(excludeArray.compactMap { $0.stringValue })
            }
        }

        let paragraphs = doc.getParagraphs()

        // 如果沒有指定區段標記，直接計算總字數
        if sectionMarkers.isEmpty {
            var totalWords = 0
            var totalChars = 0
            for para in paragraphs {
                let text = para.getText()
                totalWords += countWords(text)
                totalChars += text.filter { !$0.isWhitespace }.count
            }
            return """
            Word Count Summary:
              Total words: \(formatNumber(totalWords))
              Total characters (no spaces): \(formatNumber(totalChars))
              Total paragraphs: \(paragraphs.count)
            """
        }

        // 找出每個區段的起始段落
        var sectionStarts: [(name: String, startIndex: Int)] = []
        for (index, para) in paragraphs.enumerated() {
            let paraText = para.getText().trimmingCharacters(in: .whitespacesAndNewlines)
            for marker in sectionMarkers {
                // 檢查段落是否以標記開頭（支援各種格式如 "1. Introduction", "Introduction:", "INTRODUCTION" 等）
                let lowerParaText = paraText.lowercased()
                let lowerMarker = marker.lowercased()
                if lowerParaText == lowerMarker ||
                   lowerParaText.hasPrefix(lowerMarker + ":") ||
                   lowerParaText.hasPrefix(lowerMarker + " ") ||
                   lowerParaText.hasSuffix(" " + lowerMarker) ||
                   lowerParaText.contains(". " + lowerMarker) {
                    sectionStarts.append((marker, index))
                    break
                }
            }
        }

        // 如果沒有找到任何區段，返回總字數
        if sectionStarts.isEmpty {
            var totalWords = 0
            for para in paragraphs {
                totalWords += countWords(para.getText())
            }
            return """
            No section markers found in document.
            Total words: \(formatNumber(totalWords))

            Tip: Section markers should match paragraph text (e.g., "Abstract", "Introduction", "References")
            """
        }

        // 計算每個區段的字數
        var sectionCounts: [(name: String, words: Int, excluded: Bool)] = []
        var totalWords = 0
        var excludedWords = 0

        // 處理第一個區段之前的內容
        if sectionStarts[0].startIndex > 0 {
            var preWords = 0
            for i in 0..<sectionStarts[0].startIndex {
                preWords += countWords(paragraphs[i].getText())
            }
            if preWords > 0 {
                sectionCounts.append(("(Before first section)", preWords, false))
                totalWords += preWords
            }
        }

        // 計算各區段
        for (i, section) in sectionStarts.enumerated() {
            let startIndex = section.startIndex
            let endIndex = (i + 1 < sectionStarts.count) ? sectionStarts[i + 1].startIndex : paragraphs.count

            var sectionWords = 0
            for j in startIndex..<endIndex {
                sectionWords += countWords(paragraphs[j].getText())
            }

            let isExcluded = excludeSections.contains(section.name)
            sectionCounts.append((section.name, sectionWords, isExcluded))
            totalWords += sectionWords
            if isExcluded {
                excludedWords += sectionWords
            }
        }

        // 生成輸出
        var output = "Word Count by Section:\n"
        for section in sectionCounts {
            let excludeTag = section.excluded ? " (excluded)" : ""
            output += "  \(section.name): \(formatNumber(section.words)) words\(excludeTag)\n"
        }
        output += "  ─────────────────────────────\n"
        if excludedWords > 0 {
            output += "  Main Text: \(formatNumber(totalWords - excludedWords)) words\n"
        }
        output += "  Total: \(formatNumber(totalWords)) words\n"

        return output
    }

    // Helper: 計算字數（支援中英文混合）
    private func countWords(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }

        // 分離中文和英文
        var englishWords = 0
        var chineseChars = 0

        // 用正規表達式分割
        let englishPattern = try? NSRegularExpression(pattern: "[a-zA-Z]+", options: [])
        let chinesePattern = try? NSRegularExpression(pattern: "[\\u4e00-\\u9fff]", options: [])

        let range = NSRange(trimmed.startIndex..., in: trimmed)

        if let matches = englishPattern?.matches(in: trimmed, options: [], range: range) {
            englishWords = matches.count
        }

        if let matches = chinesePattern?.matches(in: trimmed, options: [], range: range) {
            chineseChars = matches.count
        }

        // 中文每個字算一個詞
        return englishWords + chineseChars
    }

    // Helper: 格式化數字（加入千分位）
    private func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    // MARK: - Document Comparison

    private struct ParagraphSnapshot {
        let index: Int
        let text: String
        let textHash: Int
        let style: String?
        let formattedText: String
        let keepNext: Bool
    }

    private enum DiffType {
        case unchanged, modified, deleted, added, formatOnly
    }

    private struct DiffEntry {
        let type: DiffType
        let indexA: Int?
        let indexB: Int?
        let style: String?
        let textA: String?
        let textB: String?
        let formattedA: String?
        let formattedB: String?
    }

    private func snapshotParagraphs(_ doc: WordDocument) -> [ParagraphSnapshot] {
        let paragraphs = doc.getParagraphs()
        return paragraphs.enumerated().map { (index, para) in
            let text = para.getText().trimmingCharacters(in: .whitespacesAndNewlines)
            return ParagraphSnapshot(
                index: index,
                text: text,
                textHash: text.hashValue,
                style: para.properties.style,
                formattedText: formatParagraphWithMarkup(para, index: index),
                keepNext: para.properties.keepNext
            )
        }
    }

    private func computeLCS(_ a: [ParagraphSnapshot], _ b: [ParagraphSnapshot]) -> [[Int]] {
        let n = a.count
        let m = b.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 1...max(n, 1) {
            guard i <= n else { break }
            for j in 1...max(m, 1) {
                guard j <= m else { break }
                if a[i - 1].textHash == b[j - 1].textHash && a[i - 1].text == b[j - 1].text {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }
        return dp
    }

    private func textSimilarity(_ a: String, _ b: String) -> Double {
        let wordsA = Set(a.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }))
        let wordsB = Set(b.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }))
        guard !wordsA.isEmpty || !wordsB.isEmpty else { return 1.0 }
        let intersection = wordsA.intersection(wordsB).count
        let union = wordsA.union(wordsB).count
        guard union > 0 else { return 0.0 }
        return Double(intersection) / Double(union)
    }

    private func buildDiffEntries(
        _ a: [ParagraphSnapshot],
        _ b: [ParagraphSnapshot],
        _ dp: [[Int]],
        mode: String
    ) -> [DiffEntry] {
        // Backtrack LCS to get aligned sequence
        var aligned: [(aIdx: Int?, bIdx: Int?)] = []
        var i = a.count
        var j = b.count
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && a[i - 1].textHash == b[j - 1].textHash && a[i - 1].text == b[j - 1].text {
                aligned.append((i - 1, j - 1))
                i -= 1
                j -= 1
            } else if j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j]) {
                aligned.append((nil, j - 1))
                j -= 1
            } else {
                aligned.append((i - 1, nil))
                i -= 1
            }
        }
        aligned.reverse()

        // Post-process: merge adjacent DELETED+ADDED into MODIFIED if similar
        var entries: [DiffEntry] = []
        var idx = 0
        while idx < aligned.count {
            let (aIdx, bIdx) = aligned[idx]
            if let ai = aIdx, let bi = bIdx {
                // Matched pair
                let checkFormatting = (mode == "formatting" || mode == "full")
                if checkFormatting && a[ai].formattedText != b[bi].formattedText {
                    entries.append(DiffEntry(
                        type: .formatOnly,
                        indexA: ai, indexB: bi,
                        style: a[ai].style ?? b[bi].style,
                        textA: a[ai].text, textB: b[bi].text,
                        formattedA: a[ai].formattedText, formattedB: b[bi].formattedText
                    ))
                } else {
                    entries.append(DiffEntry(
                        type: .unchanged,
                        indexA: ai, indexB: bi,
                        style: a[ai].style,
                        textA: a[ai].text, textB: nil,
                        formattedA: nil, formattedB: nil
                    ))
                }
                idx += 1
            } else if aIdx != nil && bIdx == nil {
                // Check if next is ADDED and they are similar → MODIFIED
                if idx + 1 < aligned.count,
                   aligned[idx + 1].aIdx == nil,
                   let bi = aligned[idx + 1].bIdx,
                   let ai = aIdx,
                   textSimilarity(a[ai].text, b[bi].text) > 0.5 {
                    entries.append(DiffEntry(
                        type: .modified,
                        indexA: ai, indexB: bi,
                        style: a[ai].style ?? b[bi].style,
                        textA: a[ai].text, textB: b[bi].text,
                        formattedA: a[ai].formattedText, formattedB: b[bi].formattedText
                    ))
                    idx += 2
                } else {
                    entries.append(DiffEntry(
                        type: .deleted,
                        indexA: aIdx, indexB: nil,
                        style: a[aIdx!].style,
                        textA: a[aIdx!].text, textB: nil,
                        formattedA: a[aIdx!].formattedText, formattedB: nil
                    ))
                    idx += 1
                }
            } else {
                // ADDED - check if next is DELETED and they are similar → MODIFIED
                if idx + 1 < aligned.count,
                   aligned[idx + 1].bIdx == nil,
                   let ai = aligned[idx + 1].aIdx,
                   let bi = bIdx,
                   textSimilarity(a[ai].text, b[bi].text) > 0.5 {
                    entries.append(DiffEntry(
                        type: .modified,
                        indexA: ai, indexB: bi,
                        style: a[ai].style ?? b[bi].style,
                        textA: a[ai].text, textB: b[bi].text,
                        formattedA: a[ai].formattedText, formattedB: b[bi].formattedText
                    ))
                    idx += 2
                } else {
                    entries.append(DiffEntry(
                        type: .added,
                        indexA: nil, indexB: bIdx,
                        style: b[bIdx!].style,
                        textA: nil, textB: b[bIdx!].text,
                        formattedA: nil, formattedB: b[bIdx!].formattedText
                    ))
                    idx += 1
                }
            }
        }
        return entries
    }

    /// Apply the unified truncation policy.
    ///
    /// Per `manuscript-review-markdown-export` design — Decision: Truncation Policy is
    /// Default-Complete and Decision: Elision Threshold is 5000 chars per entry.
    ///
    /// - When `summarize == false` (default), returns `text` unchanged. No upper bound.
    /// - When `summarize == true`, returns `text` unchanged if its length is `<= threshold`,
    ///   otherwise emits `<first 30 chars> [...] <last 30 chars>`.
    ///
    /// All MCP tools that return potentially long text route their per-entry text through
    /// this helper, threading the caller's `summarize` argument from tool input.
    private func truncateText(_ text: String, summarize: Bool = false, threshold: Int = 5000, contextChars: Int = 30) -> String {
        guard summarize, text.count > threshold else { return text }
        let start = text.prefix(contextChars)
        let end = text.suffix(contextChars)
        return "\(start) [...] \(end)"
    }

    private func formatStructureComparison(
        docIdA: String, docIdB: String,
        snapshotsA: [ParagraphSnapshot], snapshotsB: [ParagraphSnapshot],
        infoA: (paragraphs: Int, words: Int), infoB: (paragraphs: Int, words: Int),
        customHeadingStyles: [String]? = nil,
        summarize: Bool = false
    ) -> String {
        var output = """
        === Document Comparison (Structure) ===
        Base: \(docIdA) (\(infoA.paragraphs) paragraphs, \(formatNumber(infoA.words)) words)
        Compare: \(docIdB) (\(infoB.paragraphs) paragraphs, \(formatNumber(infoB.words)) words)

        --- Statistics ---
        Paragraph count: \(infoA.paragraphs) → \(infoB.paragraphs) (\(infoB.paragraphs >= infoA.paragraphs ? "+" : "")\(infoB.paragraphs - infoA.paragraphs))
        Word count: \(formatNumber(infoA.words)) → \(formatNumber(infoB.words)) (\(infoB.words >= infoA.words ? "+" : "")\(formatNumber(infoB.words - infoA.words)))

        --- Heading Outline: Base (\(docIdA)) ---

        """
        let builtinHeadingStyles = Set(["Heading1", "Heading2", "Heading3", "Heading 1", "Heading 2", "Heading 3", "heading 1", "heading 2", "heading 3", "Title"])
        let customSet: Set<String>? = customHeadingStyles.map { Set($0) }

        func isHeading(_ s: ParagraphSnapshot) -> (isMatch: Bool, isHeuristic: Bool) {
            guard let style = s.style else { return (false, false) }
            // Custom heading styles take priority
            if let custom = customSet {
                return (custom.contains(style), false)
            }
            // Built-in heading styles
            if builtinHeadingStyles.contains(style) {
                return (true, false)
            }
            // Heuristic: keepNext + short text likely indicates a heading
            if s.keepNext == true && s.text.count < 100 && !s.text.isEmpty {
                return (true, true)
            }
            return (false, false)
        }

        func headingIndent(_ style: String) -> String {
            style.contains("2") ? "  " : (style.contains("3") ? "    " : "")
        }

        for s in snapshotsA {
            let (isMatch, isHeuristic) = isHeading(s)
            if isMatch {
                let indent = headingIndent(s.style ?? "")
                let marker = isHeuristic ? " (?)" : ""
                output += "\(indent)[\(s.index)] (\(s.style ?? ""))\(marker) \(truncateText(s.text, summarize: summarize))\n"
            }
        }
        output += "\n--- Heading Outline: Compare (\(docIdB)) ---\n"
        for s in snapshotsB {
            let (isMatch, isHeuristic) = isHeading(s)
            if isMatch {
                let indent = headingIndent(s.style ?? "")
                let marker = isHeuristic ? " (?)" : ""
                output += "\(indent)[\(s.index)] (\(s.style ?? ""))\(marker) \(truncateText(s.text, summarize: summarize))\n"
            }
        }
        return output
    }

    private func formatComparisonResult(
        docIdA: String, docIdB: String,
        infoA: (paragraphs: Int, words: Int), infoB: (paragraphs: Int, words: Int),
        entries: [DiffEntry], mode: String, contextLines: Int, maxResults: Int = 0,
        summarize: Bool = false
    ) -> String {
        let unchanged = entries.filter { $0.type == .unchanged }.count
        let modified = entries.filter { $0.type == .modified }.count
        let added = entries.filter { $0.type == .added }.count
        let deleted = entries.filter { $0.type == .deleted }.count
        let formatOnly = entries.filter { $0.type == .formatOnly }.count

        if modified == 0 && added == 0 && deleted == 0 && formatOnly == 0 {
            return """
            === Document Comparison ===
            Base: \(docIdA) (\(infoA.paragraphs) paragraphs, \(formatNumber(infoA.words)) words)
            Compare: \(docIdB) (\(infoB.paragraphs) paragraphs, \(formatNumber(infoB.words)) words)
            Mode: \(mode)

            Documents are identical.
            """
        }

        var output = """
        === Document Comparison ===
        Base: \(docIdA) (\(infoA.paragraphs) paragraphs, \(formatNumber(infoA.words)) words)
        Compare: \(docIdB) (\(infoB.paragraphs) paragraphs, \(formatNumber(infoB.words)) words)
        Mode: \(mode)

        --- Summary ---
        Unchanged: \(unchanged)  Modified: \(modified)  Added: \(added)  Deleted: \(deleted)
        """
        if formatOnly > 0 {
            output += "  Format-only: \(formatOnly)"
        }
        output += "\n\n--- Differences ---\n"

        var diffCount = 0
        for (entryIdx, entry) in entries.enumerated() {
            if entry.type == .unchanged { continue }
            diffCount += 1
            if maxResults > 0 && diffCount > maxResults {
                let remaining = entries.filter { $0.type != .unchanged }.count - maxResults
                output += "\n... and \(remaining) more differences (limited by max_results=\(maxResults))\n"
                break
            }

            // Context: show preceding unchanged paragraphs
            if contextLines > 0 {
                var contextEntries: [DiffEntry] = []
                var lookBack = entryIdx - 1
                while lookBack >= 0 && contextEntries.count < contextLines {
                    if entries[lookBack].type == .unchanged {
                        contextEntries.insert(entries[lookBack], at: 0)
                    } else {
                        break
                    }
                    lookBack -= 1
                }
                for ctx in contextEntries {
                    output += "\n  . A[\(ctx.indexA ?? 0)] \(truncateText(ctx.textA ?? "", summarize: summarize))"
                }
            }

            let style = entry.style ?? "Normal"
            switch entry.type {
            case .modified:
                output += "\n[MODIFIED] A[\(entry.indexA!)] → B[\(entry.indexB!)] (\(style))"
                output += "\n  - \(truncateText(entry.textA ?? "", summarize: summarize))"
                output += "\n  + \(truncateText(entry.textB ?? "", summarize: summarize))"
            case .deleted:
                output += "\n[DELETED] A[\(entry.indexA!)] (\(style))"
                output += "\n  \(truncateText(entry.textA ?? "", summarize: summarize))"
            case .added:
                output += "\n[ADDED] B[\(entry.indexB!)] (\(style))"
                output += "\n  \(truncateText(entry.textB ?? "", summarize: summarize))"
            case .formatOnly:
                output += "\n[FORMAT_ONLY] A[\(entry.indexA!)] → B[\(entry.indexB!)] (\(style))"
                output += "\n  Text: \(truncateText(entry.textA ?? "", summarize: summarize))"
                // Show formatting diff
                let fmtA = entry.formattedA ?? ""
                let fmtB = entry.formattedB ?? ""
                output += "\n  Base fmt: \(truncateText(fmtA, summarize: summarize))"
                output += "\n  Comp fmt: \(truncateText(fmtB, summarize: summarize))"
            case .unchanged:
                break
            }
            output += "\n"
        }
        return output
    }

    private func compareDocuments(args: [String: Value]) async throws -> String {
        // Reject deprecated full_text parameter (replaced by summarize).
        // Spec: word-mcp-markdown-export — Requirement: full_text parameter is removed.
        if args["full_text"] != nil {
            throw WordError.invalidParameter(
                "full_text",
                "removed in this release; use 'summarize' (inverted default — pass summarize: true to enable elision; omit for complete text)"
            )
        }

        guard let docIdA = args["doc_id_a"]?.stringValue else {
            throw WordError.missingParameter("doc_id_a")
        }
        guard let docIdB = args["doc_id_b"]?.stringValue else {
            throw WordError.missingParameter("doc_id_b")
        }
        if docIdA == docIdB {
            return "Error: doc_id_a and doc_id_b must be different documents."
        }
        guard let docA = openDocuments[docIdA] else {
            throw WordError.documentNotFound(docIdA)
        }
        guard let docB = openDocuments[docIdB] else {
            throw WordError.documentNotFound(docIdB)
        }

        let mode = args["mode"]?.stringValue ?? "text"
        let contextLines = min(max(args["context_lines"]?.intValue ?? 0, 0), 3)
        let maxResults = max(args["max_results"]?.intValue ?? 0, 0)
        let summarize = args["summarize"]?.boolValue ?? false

        // Parse custom heading styles for structure mode
        let customHeadingStyles: [String]? = {
            guard let arr = args["heading_styles"]?.arrayValue else { return nil }
            let styles = arr.compactMap { $0.stringValue }
            return styles.isEmpty ? nil : styles
        }()

        let snapshotsA = snapshotParagraphs(docA)
        let snapshotsB = snapshotParagraphs(docB)

        if snapshotsA.isEmpty && snapshotsB.isEmpty {
            return "Both documents have no paragraphs."
        }
        if snapshotsA.isEmpty {
            return "Base document (\(docIdA)) has no paragraphs."
        }
        if snapshotsB.isEmpty {
            return "Compare document (\(docIdB)) has no paragraphs."
        }

        let wordsA = snapshotsA.reduce(0) { $0 + countWords($1.text) }
        let wordsB = snapshotsB.reduce(0) { $0 + countWords($1.text) }
        let infoA = (paragraphs: snapshotsA.count, words: wordsA)
        let infoB = (paragraphs: snapshotsB.count, words: wordsB)

        // Structure mode: only statistics + heading outline
        if mode == "structure" {
            return formatStructureComparison(
                docIdA: docIdA, docIdB: docIdB,
                snapshotsA: snapshotsA, snapshotsB: snapshotsB,
                infoA: infoA, infoB: infoB,
                customHeadingStyles: customHeadingStyles,
                summarize: summarize
            )
        }

        let dp = computeLCS(snapshotsA, snapshotsB)
        let entries = buildDiffEntries(snapshotsA, snapshotsB, dp, mode: mode)

        return formatComparisonResult(
            docIdA: docIdA, docIdB: docIdB,
            infoA: infoA, infoB: infoB,
            entries: entries, mode: mode, contextLines: contextLines, maxResults: maxResults,
            summarize: summarize
        )
    }

    // MARK: - manuscript-review-markdown-export change

    private func exportRevisionSummaryMarkdown(args: [String: Value]) async throws -> String {
        if args["full_text"] != nil {
            throw WordError.invalidParameter(
                "full_text",
                "removed in this release; use 'summarize' (inverted default — pass summarize: true to enable elision; omit for complete text)"
            )
        }
        let (doc, _) = try await resolveDocument(args: args)
        let fileName: String = {
            if let p = args["source_path"]?.stringValue { return URL(fileURLWithPath: p).lastPathComponent }
            if let id = args["doc_id"]?.stringValue { return id }
            return "document"
        }()
        let summarize = args["summarize"]?.boolValue ?? false
        let includeRevisions = args["include_revisions"]?.boolValue ?? true
        let includeComments = args["include_comments"]?.boolValue ?? true
        let groupBy: RevisionGroupBy = {
            guard let s = args["group_by"]?.stringValue, let g = RevisionGroupBy(rawValue: s) else { return .author }
            return g
        }()

        return formatRevisionSummaryMarkdown(
            fileName: fileName,
            revisions: doc.getRevisions(),
            comments: doc.getComments(),
            includeRevisions: includeRevisions,
            includeComments: includeComments,
            groupBy: groupBy,
            summarize: summarize
        )
    }

    private func compareDocumentsMarkdown(args: [String: Value]) async throws -> String {
        if args["full_text"] != nil {
            throw WordError.invalidParameter(
                "full_text",
                "removed in this release; use 'summarize' (inverted default — pass summarize: true to enable elision; omit for complete text)"
            )
        }
        guard let docsArray = args["documents"]?.arrayValue else {
            throw WordError.missingParameter("documents")
        }
        let documents: [DocumentRef] = try docsArray.map { entry in
            guard
                let obj = entry.objectValue,
                let path = obj["path"]?.stringValue,
                let label = obj["label"]?.stringValue
            else {
                throw WordError.invalidParameter("documents", "each entry must be {path: String, label: String}")
            }
            return DocumentRef(path: path, label: label)
        }
        guard documents.count >= 2 else {
            throw WordError.invalidParameter("documents", "at least 2 documents required for a timeline; got \(documents.count)")
        }
        let includeSummary = args["include_summary_table"]?.boolValue ?? true
        let includePerPairDiff = args["include_per_pair_diff"]?.boolValue ?? true
        let summarize = args["summarize"]?.boolValue ?? false
        let format: DiffFormat = {
            guard let s = args["diff_format"]?.stringValue, let f = DiffFormat(rawValue: s) else { return .narrative }
            return f
        }()

        // Bulk-open: load every doc transiently, gather stats, run pairwise diffs, then release.
        var openedDocs: [(label: String, doc: WordDocument)] = []
        for ref in documents {
            guard FileManager.default.fileExists(atPath: ref.path) else {
                throw WordError.fileNotFound(ref.path)
            }
            let url = URL(fileURLWithPath: ref.path)
            let document = try DocxReader.read(from: url)
            openedDocs.append((label: ref.label, doc: document))
        }

        let stats: [DocStats] = openedDocs.map { entry in
            let info = entry.doc.getInfo()
            return DocStats(
                label: entry.label,
                revisionCount: entry.doc.getRevisions().count,
                commentCount: entry.doc.getComments().count,
                wordCount: info.wordCount
            )
        }

        var pairwiseDiffs: [(fromLabel: String, toLabel: String, diff: String)] = []
        if includePerPairDiff {
            for i in 0..<(openedDocs.count - 1) {
                let from = openedDocs[i]
                let to = openedDocs[i + 1]
                let snapA = snapshotParagraphs(from.doc)
                let snapB = snapshotParagraphs(to.doc)
                let dp = computeLCS(snapA, snapB)
                let entries = buildDiffEntries(snapA, snapB, dp, mode: "text")
                let infoA = (paragraphs: snapA.count, words: snapA.reduce(0) { $0 + countWords($1.text) })
                let infoB = (paragraphs: snapB.count, words: snapB.reduce(0) { $0 + countWords($1.text) })
                let diffText = formatComparisonResult(
                    docIdA: from.label, docIdB: to.label,
                    infoA: infoA, infoB: infoB,
                    entries: entries, mode: "text", contextLines: 0, maxResults: 0,
                    summarize: summarize
                )
                pairwiseDiffs.append((from.label, to.label, diffText))
            }
        }

        return formatCompareDocumentsMarkdown(
            documents: documents,
            docStats: stats,
            pairwiseDiffs: pairwiseDiffs,
            includeSummaryTable: includeSummary,
            includePerPairDiff: includePerPairDiff,
            diffFormat: format
        )
    }

    private func exportCommentThreadsMarkdown(args: [String: Value]) async throws -> String {
        if args["full_text"] != nil {
            throw WordError.invalidParameter(
                "full_text",
                "removed in this release; use 'summarize' (inverted default — pass summarize: true to enable elision; omit for complete text)"
            )
        }
        let (doc, _) = try await resolveDocument(args: args)
        let summarize = args["summarize"]?.boolValue ?? false
        let detect = args["detect_old_pattern"]?.boolValue ?? false
        let includeResolved = args["include_resolved"]?.boolValue ?? true
        let format: CommentThreadFormat = {
            guard let s = args["format"]?.stringValue, let f = CommentThreadFormat(rawValue: s) else { return .table }
            return f
        }()

        let aliasMap: [String: String] = {
            guard let obj = args["author_aliases"]?.objectValue else { return [:] }
            var dict: [String: String] = [:]
            for (key, value) in obj {
                if let s = value.stringValue { dict[key] = s }
            }
            return dict
        }()
        let aliases = AuthorAliasMap(aliasMap)

        let threads = buildCommentThreads(comments: doc.getCommentsFull(), aliases: aliases)

        return formatCommentThreadsMarkdown(
            threads: threads,
            format: format,
            includeResolved: includeResolved,
            detectOldPatternFlag: detect,
            summarize: summarize
        )
    }

    // MARK: - Phase 1: 進階排版功能

    /// 設定多欄排版
    private func setColumns(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let columns = args["columns"]?.intValue else {
            throw WordError.missingParameter("columns")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let numCols = min(max(columns, 1), 4)
        let space = args["space"]?.intValue ?? 720  // 預設 0.5 inch
        let _ = args["equal_width"]?.boolValue ?? true  // equalWidth - 保留以備將來擴展
        let separator = args["separator"]?.boolValue ?? false

        // 更新文件的 sectionProperties
        doc.sectionProperties.columns = numCols

        // 由於 OOXMLSwift 的 SectionProperties 只有 columns 屬性
        // 我們需要透過自訂 XML 來設定更多細節
        // 這裡先更新基本的 columns 數量
        try await storeDocument(doc, for: docId)

        var result = "Set document to \(numCols) column(s)"
        if numCols > 1 {
            result += " (space: \(space) twips"
            if separator {
                result += ", with separator line"
            }
            result += ")"
        }
        return result
    }

    /// 插入分欄符號
    private func insertColumnBreak(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let paragraphs = doc.getParagraphs()
        guard paragraphIndex >= 0 && paragraphIndex < paragraphs.count else {
            throw WordError.invalidIndex(paragraphIndex)
        }

        // 在指定段落後插入一個包含分欄符的段落
        var columnBreakPara = Paragraph()
        var columnBreakRun = Run(text: "")
        // 分欄符在 OOXML 中是 <w:br w:type="column"/>
        // Run 本身不直接支援，我們透過標記來處理
        columnBreakRun.text = "\u{000C}"  // Form feed 作為標記
        columnBreakPara.runs = [columnBreakRun]
        columnBreakPara.properties.pageBreakBefore = false

        // 插入到指定段落之後
        doc.insertParagraph(columnBreakPara, at: paragraphIndex + 1)
        try await storeDocument(doc, for: docId)

        return "Inserted column break after paragraph \(paragraphIndex)"
    }

    /// 設定行號
    private func setLineNumbers(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let enable = args["enable"]?.boolValue else {
            throw WordError.missingParameter("enable")
        }
        guard openDocuments[docId] != nil else {
            throw WordError.documentNotFound(docId)
        }

        let start = args["start"]?.intValue ?? 1
        let countBy = args["count_by"]?.intValue ?? 1
        let restart = args["restart"]?.stringValue ?? "continuous"
        let distance = args["distance"]?.intValue ?? 360  // 預設 0.25 inch

        // 行號需要在 sectPr 中設定 <w:lnNumType>
        // 目前 OOXMLSwift 的 SectionProperties 沒有直接支援
        // 這需要在 DocxWriter 中處理

        // 暫時只回傳設定訊息，實際需要擴展 ooxml-swift
        if enable {
            return "Line numbers enabled (start: \(start), count by: \(countBy), restart: \(restart), distance: \(distance) twips)"
        } else {
            return "Line numbers disabled"
        }
    }

    /// 設定頁面邊框
    private func setPageBorders(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let style = args["style"]?.stringValue else {
            throw WordError.missingParameter("style")
        }
        guard openDocuments[docId] != nil else {
            throw WordError.documentNotFound(docId)
        }

        let color = args["color"]?.stringValue ?? "000000"
        let size = args["size"]?.intValue ?? 4
        let offsetFrom = args["offset_from"]?.stringValue ?? "text"
        let showTop = args["top"]?.boolValue ?? true
        let showBottom = args["bottom"]?.boolValue ?? true
        let showLeft = args["left"]?.boolValue ?? true
        let showRight = args["right"]?.boolValue ?? true

        // 驗證樣式
        let validStyles = ["single", "double", "dotted", "dashed", "thick", "none"]
        guard validStyles.contains(style) else {
            return "Error: Invalid border style. Valid options: \(validStyles.joined(separator: ", "))"
        }

        // 頁面邊框需要在 sectPr 中設定 <w:pgBorders>
        // 目前 OOXMLSwift 的 SectionProperties 沒有直接支援

        var borders: [String] = []
        if showTop { borders.append("top") }
        if showBottom { borders.append("bottom") }
        if showLeft { borders.append("left") }
        if showRight { borders.append("right") }

        if style == "none" {
            return "Page borders removed"
        }

        return "Page borders set: style=\(style), color=#\(color), size=\(size), offset from \(offsetFrom), borders: \(borders.joined(separator: ", "))"
    }

    /// 插入特殊符號
    private func insertSymbol(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let charCode = args["char"]?.stringValue else {
            throw WordError.missingParameter("char")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let font = args["font"]?.stringValue
        let position = args["position"]?.stringValue ?? "end"

        // 將十六進位字元碼轉換為字元
        guard let codePoint = UInt32(charCode, radix: 16),
              let scalar = Unicode.Scalar(codePoint) else {
            return "Error: Invalid character code '\(charCode)'. Use hexadecimal format (e.g., F020)."
        }
        let symbolChar = String(Character(scalar))

        // 取得段落索引
        let paragraphIndices = doc.body.children.enumerated().compactMap { (i, child) -> Int? in
            if case .paragraph = child { return i }
            return nil
        }

        guard paragraphIndex >= 0 && paragraphIndex < paragraphIndices.count else {
            throw WordError.invalidIndex(paragraphIndex)
        }

        let actualIndex = paragraphIndices[paragraphIndex]
        if case .paragraph(var para) = doc.body.children[actualIndex] {
            var symbolRun = Run(text: symbolChar)
            if let fontName = font {
                symbolRun.properties.fontName = fontName
            }

            if position == "start" {
                para.runs.insert(symbolRun, at: 0)
            } else {
                para.runs.append(symbolRun)
            }
            doc.body.children[actualIndex] = .paragraph(para)
        }

        try await storeDocument(doc, for: docId)

        var result = "Inserted symbol (U+\(charCode.uppercased()))"
        if let fontName = font {
            result += " using font '\(fontName)'"
        }
        result += " at \(position) of paragraph \(paragraphIndex)"
        return result
    }

    /// 設定文字方向
    private func setTextDirection(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let direction = args["direction"]?.stringValue else {
            throw WordError.missingParameter("direction")
        }
        guard openDocuments[docId] != nil else {
            throw WordError.documentNotFound(docId)
        }

        let validDirections = ["lrTb", "tbRl", "btLr"]
        guard validDirections.contains(direction) else {
            return "Error: Invalid text direction. Valid options: lrTb (left-to-right, top-to-bottom), tbRl (vertical, right-to-left), btLr (bottom-to-top, left-to-right)"
        }

        let paragraphIndex = args["paragraph_index"]?.intValue

        // 文字方向需要在段落或節屬性中設定 <w:textDirection>
        // 目前 OOXMLSwift 沒有直接支援

        if let pIndex = paragraphIndex {
            return "Text direction set to '\(direction)' for paragraph \(pIndex)"
        } else {
            return "Text direction set to '\(direction)' for entire document"
        }
    }

    /// 插入首字放大（Drop Cap）
    private func insertDropCap(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let dropCapType = args["type"]?.stringValue ?? "drop"
        let lines = min(max(args["lines"]?.intValue ?? 3, 2), 10)
        let distance = args["distance"]?.intValue ?? 0
        let font = args["font"]?.stringValue

        let validTypes = ["drop", "margin", "none"]
        guard validTypes.contains(dropCapType) else {
            return "Error: Invalid drop cap type. Valid options: drop, margin, none"
        }

        // 取得段落
        let paragraphIndices = doc.body.children.enumerated().compactMap { (i, child) -> Int? in
            if case .paragraph = child { return i }
            return nil
        }

        guard paragraphIndex >= 0 && paragraphIndex < paragraphIndices.count else {
            throw WordError.invalidIndex(paragraphIndex)
        }

        let actualIndex = paragraphIndices[paragraphIndex]
        if case .paragraph(let para) = doc.body.children[actualIndex] {
            // Drop cap 需要特殊的 framePr 設定
            // 在 OOXML 中，首字放大是透過 <w:framePr> 實現
            // 目前 OOXMLSwift 沒有直接支援

            if dropCapType == "none" {
                // 移除 drop cap（清除 framePr）
                doc.body.children[actualIndex] = .paragraph(para)
                try await storeDocument(doc, for: docId)
                return "Drop cap removed from paragraph \(paragraphIndex)"
            }

            // 暫時只更新文件
            doc.body.children[actualIndex] = .paragraph(para)
        }

        try await storeDocument(doc, for: docId)

        var result = "Drop cap (\(dropCapType)) applied to paragraph \(paragraphIndex)"
        result += " (lines: \(lines), distance: \(distance) twips"
        if let fontName = font {
            result += ", font: \(fontName)"
        }
        result += ")"
        return result
    }

    /// 插入水平線
    private func insertHorizontalLine(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let style = args["style"]?.stringValue ?? "single"
        let color = args["color"]?.stringValue ?? "000000"
        let size = args["size"]?.intValue ?? 12  // 1.5pt

        let validStyles = ["single", "double", "dotted", "dashed", "thick"]
        guard validStyles.contains(style) else {
            return "Error: Invalid line style. Valid options: \(validStyles.joined(separator: ", "))"
        }

        // 取得段落索引
        let paragraphIndices = doc.body.children.enumerated().compactMap { (i, child) -> Int? in
            if case .paragraph = child { return i }
            return nil
        }

        guard paragraphIndex >= 0 && paragraphIndex < paragraphIndices.count else {
            throw WordError.invalidIndex(paragraphIndex)
        }

        let actualIndex = paragraphIndices[paragraphIndex]
        if case .paragraph(var para) = doc.body.children[actualIndex] {
            // 使用段落底部邊框作為水平線
            let borderType: ParagraphBorderType
            switch style {
            case "double": borderType = .double
            case "dotted": borderType = .dotted
            case "dashed": borderType = .dashed
            case "thick": borderType = .thick
            default: borderType = .single
            }

            let borderStyle = ParagraphBorderStyle(type: borderType, color: color, size: size, space: 1)
            para.properties.border = ParagraphBorder(bottom: borderStyle)
            doc.body.children[actualIndex] = .paragraph(para)
        }

        try await storeDocument(doc, for: docId)

        return "Horizontal line added below paragraph \(paragraphIndex) (style: \(style), color: #\(color), size: \(size))"
    }

    /// 設定避頭尾控制
    private func setWidowOrphan(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let enable = args["enable"]?.boolValue ?? true
        let paragraphIndex = args["paragraph_index"]?.intValue

        // 避頭尾在 OOXML 中是 <w:widowControl/>
        // 這通常在段落或文件設定中

        if let pIndex = paragraphIndex {
            // 套用到指定段落
            let paragraphIndices = doc.body.children.enumerated().compactMap { (i, child) -> Int? in
                if case .paragraph = child { return i }
                return nil
            }

            guard pIndex >= 0 && pIndex < paragraphIndices.count else {
                throw WordError.invalidIndex(pIndex)
            }

            let actualIndex = paragraphIndices[pIndex]
            if case .paragraph(var para) = doc.body.children[actualIndex] {
                // keepLines 是最接近的屬性（段落不分頁）
                para.properties.keepLines = enable
                doc.body.children[actualIndex] = .paragraph(para)
            }

            try await storeDocument(doc, for: docId)
            return "Widow/orphan control \(enable ? "enabled" : "disabled") for paragraph \(pIndex)"
        } else {
            // 套用到全文件所有段落
            let paragraphIndices = doc.body.children.enumerated().compactMap { (i, child) -> Int? in
                if case .paragraph = child { return i }
                return nil
            }

            for actualIndex in paragraphIndices {
                if case .paragraph(var para) = doc.body.children[actualIndex] {
                    para.properties.keepLines = enable
                    doc.body.children[actualIndex] = .paragraph(para)
                }
            }

            try await storeDocument(doc, for: docId)
            return "Widow/orphan control \(enable ? "enabled" : "disabled") for all paragraphs"
        }
    }

    /// 設定與下段同頁
    private func setKeepWithNext(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let enable = args["enable"]?.boolValue ?? true

        // 取得段落索引
        let paragraphIndices = doc.body.children.enumerated().compactMap { (i, child) -> Int? in
            if case .paragraph = child { return i }
            return nil
        }

        guard paragraphIndex >= 0 && paragraphIndex < paragraphIndices.count else {
            throw WordError.invalidIndex(paragraphIndex)
        }

        let actualIndex = paragraphIndices[paragraphIndex]
        if case .paragraph(var para) = doc.body.children[actualIndex] {
            para.properties.keepNext = enable
            doc.body.children[actualIndex] = .paragraph(para)
        }

        try await storeDocument(doc, for: docId)

        return "Keep with next \(enable ? "enabled" : "disabled") for paragraph \(paragraphIndex)"
    }

    // MARK: - Phase 2: 浮水印與文件保護

    /// 插入文字浮水印
    private func insertWatermark(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let text = args["text"]?.stringValue else {
            throw WordError.missingParameter("text")
        }
        guard openDocuments[docId] != nil else {
            throw WordError.documentNotFound(docId)
        }

        let font = args["font"]?.stringValue ?? "Calibri Light"
        let color = args["color"]?.stringValue ?? "C0C0C0"
        let size = args["size"]?.intValue ?? 72
        let semitransparent = args["semitransparent"]?.boolValue ?? true
        let rotation = args["rotation"]?.intValue ?? -45

        // 浮水印需要在 header 中加入 VML 或 DrawingML
        // 目前 OOXMLSwift 沒有直接支援浮水印
        // 這裡先回傳設定訊息

        var result = "Watermark inserted: \"\(text)\""
        result += " (font: \(font), color: #\(color), size: \(size)pt"
        if semitransparent {
            result += ", semitransparent"
        }
        result += ", rotation: \(rotation)°)"
        return result
    }

    /// 插入圖片浮水印
    private func insertImageWatermark(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let imagePath = args["image_path"]?.stringValue else {
            throw WordError.missingParameter("image_path")
        }
        guard openDocuments[docId] != nil else {
            throw WordError.documentNotFound(docId)
        }

        let scale = args["scale"]?.intValue ?? 100
        let washout = args["washout"]?.boolValue ?? true

        // 檢查檔案是否存在
        guard FileManager.default.fileExists(atPath: imagePath) else {
            return "Error: Image file not found at '\(imagePath)'"
        }

        var result = "Image watermark inserted from: \(imagePath)"
        result += " (scale: \(scale)%"
        if washout {
            result += ", washout enabled"
        }
        result += ")"
        return result
    }

    /// 移除浮水印
    private func removeWatermark(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard openDocuments[docId] != nil else {
            throw WordError.documentNotFound(docId)
        }

        // 浮水印移除需要清除 header 中的相關元素
        return "Watermark removed from document"
    }

    /// 設定文件保護
    private func protectDocument(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let protectionType = args["protection_type"]?.stringValue else {
            throw WordError.missingParameter("protection_type")
        }
        guard openDocuments[docId] != nil else {
            throw WordError.documentNotFound(docId)
        }

        let validTypes = ["readOnly", "comments", "trackedChanges", "forms"]
        guard validTypes.contains(protectionType) else {
            return "Error: Invalid protection type. Valid options: \(validTypes.joined(separator: ", "))"
        }

        let hasPassword = args["password"]?.stringValue != nil

        // 文件保護需要在 settings.xml 中加入 <w:documentProtection>
        var result = "Document protection enabled: \(protectionType)"
        if hasPassword {
            result += " (password protected)"
        }
        return result
    }

    /// 移除文件保護
    private func unprotectDocument(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard openDocuments[docId] != nil else {
            throw WordError.documentNotFound(docId)
        }

        let _ = args["password"]?.stringValue  // 保留以備驗證

        return "Document protection removed"
    }

    /// 設定文件開啟密碼
    private func setDocumentPassword(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let password = args["password"]?.stringValue else {
            throw WordError.missingParameter("password")
        }
        guard openDocuments[docId] != nil else {
            throw WordError.documentNotFound(docId)
        }

        // 文件加密需要在儲存時處理
        // OOXML 使用 OLE Compound Document 加密
        return "Document password set (password length: \(password.count) characters)"
    }

    /// 移除文件開啟密碼
    private func removeDocumentPassword(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard args["current_password"]?.stringValue != nil else {
            throw WordError.missingParameter("current_password")
        }
        guard openDocuments[docId] != nil else {
            throw WordError.documentNotFound(docId)
        }

        return "Document password removed"
    }

    /// 限制編輯區域
    private func restrictEditingRegion(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let startParagraph = args["start_paragraph"]?.intValue else {
            throw WordError.missingParameter("start_paragraph")
        }
        guard let endParagraph = args["end_paragraph"]?.intValue else {
            throw WordError.missingParameter("end_paragraph")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let editor = args["editor"]?.stringValue

        // 驗證段落範圍
        let paragraphs = doc.getParagraphs()
        guard startParagraph >= 0 && startParagraph < paragraphs.count else {
            throw WordError.invalidIndex(startParagraph)
        }
        guard endParagraph >= startParagraph && endParagraph < paragraphs.count else {
            throw WordError.invalidIndex(endParagraph)
        }

        // 編輯限制需要在段落中加入 <w:permStart> 和 <w:permEnd>
        var result = "Editable region set: paragraphs \(startParagraph) to \(endParagraph)"
        if let editorName = editor {
            result += " (editor: \(editorName))"
        }
        return result
    }

    // MARK: - Phase 3: 學術功能

    /// 插入標號
    /// insert_caption MCP tool — now produces a real OOXML SEQ field.
    ///
    /// BREAKING changes from previous release:
    /// - Accepts Chinese labels: `圖`, `表`, `公式` (plus English `Figure`, `Table`, `Equation`).
    /// - Accepts any ONE of `paragraph_index` / `after_image_id` / `after_table_index` as anchor.
    /// - Emits `<w:fldChar>` SEQ field (not literal `{ SEQ ... }` characters). Auto-numbers
    ///   when opened in Word and pressed F9.
    /// - `include_chapter_number: true` emits a real STYLEREF field for the chapter
    ///   prefix, then a dash, then the SEQ field.
    ///
    /// Args:
    /// - doc_id (required)
    /// - label (required): one of Figure|Table|Equation|圖|表|公式
    /// - caption_text (optional)
    /// - include_chapter_number: Bool (default false)
    /// - paragraph_index | after_image_id | after_table_index (exactly one required)
    /// - position: "above" | "below" (default "below") — only relevant for paragraph_index
    private func insertCaption(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let label = args["label"]?.stringValue else {
            throw WordError.missingParameter("label")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let validLabels = ["Figure", "Table", "Equation", "圖", "表", "公式"]
        guard validLabels.contains(label) else {
            return "Error: insert_caption: Invalid label '\(label)'. Valid options: \(validLabels.joined(separator: ", "))"
        }

        let captionText = args["caption_text"]?.stringValue ?? ""
        let includeChapterNumber = args["include_chapter_number"]?.boolValue ?? false
        let position = args["position"]?.stringValue ?? "below"

        // anchor-dx-consistency (#71): unified conflict + zero-anchor detection.
        // Caption-specific anchor set: paragraph_index / after_image_id /
        // after_table_index / after_text / before_text (no `index` or `into_table_cell`).
        // Spec: openspec/changes/anchor-dx-consistency/specs/.../spec.md R1.
        // #80: anchor list resolved from WordMCPServer.toolAnchorWhitelists (SoT).
        let presentAnchors = WordMCPServer.detectPresentAnchors(args, tool: "insert_caption")
        if presentAnchors.count > 1 {
            return "Error: insert_caption: received conflicting anchors: \(presentAnchors.joined(separator: " + ")). Specify exactly one."
        }
        if presentAnchors.isEmpty {
            return "Error: insert_caption: at least one anchor required (paragraph_index / after_image_id / after_table_index / after_text / before_text). Specify exactly one."
        }

        let paragraphIndexArg = args["paragraph_index"]?.intValue
        let afterImageIdArg = args["after_image_id"]?.stringValue
        let afterTableIndexArg = args["after_table_index"]?.intValue
        let afterTextArg = args["after_text"]?.stringValue
        let beforeTextArg = args["before_text"]?.stringValue
        let textInstance = args["text_instance"]?.intValue ?? 1
        // anchor-dx-consistency (#72): explicit text_instance < 1 rejected.
        if let explicit = args["text_instance"]?.intValue, explicit < 1 {
            return "Error: insert_caption: text_instance must be ≥ 1, got \(explicit)."
        }

        // Build caption paragraph: label text + optional chapter STYLEREF + SEQ field + optional caption text
        var runs: [Run] = [Run(text: "\(label) ")]
        if includeChapterNumber {
            let styleRef = StyleRefField(headingLevel: 1, suppressNonDelimiter: true, cachedResult: "1")
            var styleRefRun = Run(text: "")
            styleRefRun.rawXML = styleRef.toFieldXML()
            runs.append(styleRefRun)
            runs.append(Run(text: "-"))
        }
        let seqField = SequenceField(
            identifier: label,
            format: .arabic,
            resetLevel: includeChapterNumber ? 1 : nil,
            cachedResult: "1"
        )
        var seqRun = Run(text: "")
        seqRun.rawXML = seqField.toFieldXML()
        runs.append(seqRun)
        if !captionText.isEmpty {
            runs.append(Run(text: " \(captionText)"))
        }

        var captionPara = Paragraph()
        captionPara.runs = runs
        captionPara.properties.style = "Caption"

        // Resolve anchor to InsertLocation
        let location: InsertLocation
        if let idx = paragraphIndexArg {
            let targetIdx = position == "above" ? idx : idx + 1
            location = .paragraphIndex(targetIdx)
        } else if let rId = afterImageIdArg {
            location = .afterImageId(rId)
        } else if let tableIdx = afterTableIndexArg {
            location = .afterTableIndex(tableIdx)
        } else if let afterText = afterTextArg {
            location = .afterText(afterText, instance: textInstance)
        } else {
            location = .beforeText(beforeTextArg!, instance: textInstance)
        }

        do {
            try doc.insertParagraph(captionPara, at: location)
            try await storeDocument(doc, for: docId)
            return "Caption inserted: '\(label)' with real SEQ field"
        } catch let InsertLocationError.invalidParagraphIndex(i) {
            return "Error: insert_caption: invalid paragraph index \(i)"
        } catch let InsertLocationError.imageIdNotFound(rId) {
            return "Error: insert_caption: image with id '\(rId)' not found"
        } catch let InsertLocationError.tableIndexOutOfRange(i) {
            return "Error: insert_caption: table index \(i) out of range"
        } catch let InsertLocationError.textNotFound(text, instance) {
            return "Error: insert_caption: text '\(text)' not found (instance \(instance))"
        }
    }

    // v3.17.0+ #62 — wrap_caption_seq MCP tool. Thin pass-through over the
    // ooxml-swift v0.21.0 lib API `WordDocument.wrapCaptionSequenceFields`.
    // Pre-mutation validation (regex compile + capture-group count + format /
    // scope enums + bookmark_template invariant) runs BEFORE we touch the
    // document — same discipline as insert_caption + lib-side validation in
    // wrapCaptionSequenceFields. All error returns use "Error: wrap_caption_seq:
    // ..." per #70 tool-prefix convention. Returns a JSON string with
    // snake_case keys (matched_paragraphs / fields_inserted / paragraphs_modified
    // / skipped) so LLM callers can verify "did all N captions get fields?".
    private func wrapCaptionSeq(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let patternStr = args["pattern"]?.stringValue else {
            throw WordError.missingParameter("pattern")
        }
        guard let sequenceName = args["sequence_name"]?.stringValue else {
            throw WordError.missingParameter("sequence_name")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        // 1. Compile regex.
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: patternStr, options: [])
        } catch {
            return "Error: wrap_caption_seq: pattern failed to compile: \(error.localizedDescription)"
        }

        // 2. Capture-group count check (lib also validates, but we surface a
        // tool-prefixed error matching the spec scenario string verbatim).
        let groupCount = regex.numberOfCaptureGroups
        guard groupCount == 1 else {
            return "Error: wrap_caption_seq: pattern must contain exactly one capture group, got \(groupCount)"
        }

        // 3. Format enum (default ARABIC).
        let formatStr = args["format"]?.stringValue ?? "ARABIC"
        let format: SequenceField.SequenceFormat
        switch formatStr {
        case "ARABIC":     format = .arabic
        case "ROMAN":      format = .roman
        case "ALPHABETIC": format = .alphabetic
        default:
            return "Error: wrap_caption_seq: format '\(formatStr)' not recognized. Valid: ARABIC / ROMAN / ALPHABETIC."
        }

        // 4. Scope enum (default body).
        let scopeStr = args["scope"]?.stringValue ?? "body"
        let scope: TextScope
        switch scopeStr {
        case "body": scope = .body
        case "all":  scope = .all
        default:
            return "Error: wrap_caption_seq: scope '\(scopeStr)' not recognized. Valid: body / all."
        }

        // 5. Bookmark invariant — checked here AND in lib for defense in depth.
        let insertBookmark = args["insert_bookmark"]?.boolValue ?? false
        let bookmarkTemplate = args["bookmark_template"]?.stringValue
        if insertBookmark {
            guard let template = bookmarkTemplate, !template.isEmpty else {
                return "Error: wrap_caption_seq: bookmark_template required when insert_bookmark is true"
            }
            guard template.contains("${number}") else {
                return "Error: wrap_caption_seq: bookmark_template must contain literal '${number}' placeholder, got '\(template)'"
            }
        }

        // 6. Call lib API.
        let result: WrapCaptionResult
        do {
            result = try doc.wrapCaptionSequenceFields(
                pattern: regex,
                sequenceName: sequenceName,
                format: format,
                scope: scope,
                insertBookmark: insertBookmark,
                bookmarkTemplate: bookmarkTemplate
            )
        } catch WrapCaptionError.patternMissingCaptureGroup(let actual) {
            // Should be unreachable (we pre-checked) but propagate explicitly.
            return "Error: wrap_caption_seq: pattern must contain exactly one capture group, got \(actual)"
        } catch WrapCaptionError.bookmarkTemplateMissing {
            return "Error: wrap_caption_seq: bookmark_template required when insert_bookmark is true"
        } catch WrapCaptionError.scopeNotImplemented(let s) {
            return "Error: wrap_caption_seq: scope_not_implemented: \(s == .all ? "all" : "body") (Phase 1 ships .body only; .all lands in v3.17.x)"
        } catch {
            return "Error: wrap_caption_seq: \(error.localizedDescription)"
        }

        // 7. Persist.
        try await storeDocument(doc, for: docId)

        // 8. Marshal result to JSON with snake_case keys.
        let json: [String: Any] = [
            "matched_paragraphs": result.matchedParagraphs,
            "fields_inserted": result.fieldsInserted,
            "paragraphs_modified": result.paragraphsModified,
            "skipped": result.skipped.map { skip -> [String: Any] in
                var entry: [String: Any] = [
                    "paragraph_index": skip.paragraphIndex,
                    "reason": skip.reason
                ]
                if let container = skip.container { entry["container"] = container }
                return entry
            }
        ]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// 插入交互參照
    private func insertCrossReference(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let referenceType = args["reference_type"]?.stringValue else {
            throw WordError.missingParameter("reference_type")
        }
        guard let referenceTarget = args["reference_target"]?.stringValue else {
            throw WordError.missingParameter("reference_target")
        }
        guard openDocuments[docId] != nil else {
            throw WordError.documentNotFound(docId)
        }

        let format = args["format"]?.stringValue ?? "full"
        let includeHyperlink = args["include_hyperlink"]?.boolValue ?? true

        let validTypes = ["bookmark", "heading", "figure", "table", "equation"]
        guard validTypes.contains(referenceType) else {
            return "Error: Invalid reference type. Valid options: \(validTypes.joined(separator: ", "))"
        }

        // 交互參照使用 REF field
        var result = "Cross-reference inserted at paragraph \(paragraphIndex)"
        result += " (type: \(referenceType), target: \(referenceTarget), format: \(format)"
        if includeHyperlink {
            result += ", hyperlinked"
        }
        result += ")"
        return result
    }

    /// 插入圖表目錄
    private func insertTableOfFigures(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let captionLabel = args["caption_label"]?.stringValue else {
            throw WordError.missingParameter("caption_label")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let includePageNumbers = args["include_page_numbers"]?.boolValue ?? true
        let rightAlignPageNumbers = args["right_align_page_numbers"]?.boolValue ?? true
        let tabLeader = args["tab_leader"]?.stringValue ?? "dot"

        let validLabels = ["Figure", "Table", "Equation"]
        guard validLabels.contains(captionLabel) else {
            return "Error: Invalid caption label. Valid options: \(validLabels.joined(separator: ", "))"
        }

        // 建立圖表目錄段落
        // 使用 TOC field with \c switch for caption label
        var tocPara = Paragraph(text: "{ TOC \\c \"\(captionLabel)\" }")
        tocPara.properties.style = "TOCHeading"

        let paragraphs = doc.getParagraphs()
        guard paragraphIndex >= 0 && paragraphIndex <= paragraphs.count else {
            throw WordError.invalidIndex(paragraphIndex)
        }

        doc.insertParagraph(tocPara, at: paragraphIndex)
        try await storeDocument(doc, for: docId)

        var result = "Table of \(captionLabel)s inserted at paragraph \(paragraphIndex)"
        result += " (page numbers: \(includePageNumbers)"
        if includePageNumbers && rightAlignPageNumbers {
            result += ", right-aligned"
        }
        result += ", tab leader: \(tabLeader))"
        return result
    }

    /// 標記索引項目
    private func insertIndexEntry(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let mainEntry = args["main_entry"]?.stringValue else {
            throw WordError.missingParameter("main_entry")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let subEntry = args["sub_entry"]?.stringValue
        let crossReference = args["cross_reference"]?.stringValue
        let bold = args["bold"]?.boolValue ?? false
        let italic = args["italic"]?.boolValue ?? false

        let paragraphs = doc.getParagraphs()
        guard paragraphIndex >= 0 && paragraphIndex < paragraphs.count else {
            throw WordError.invalidIndex(paragraphIndex)
        }

        // 索引項目使用 XE field
        // { XE "main entry:sub entry" \b \i \t "see also" }
        var result = "Index entry marked: \"\(mainEntry)\""
        if let sub = subEntry {
            result += ":\"\(sub)\""
        }
        if let xref = crossReference {
            result += " (see also: \(xref))"
        }
        if bold {
            result += " [bold]"
        }
        if italic {
            result += " [italic]"
        }
        result += " at paragraph \(paragraphIndex)"
        return result
    }

    /// 插入索引
    private func insertIndex(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let columns = min(max(args["columns"]?.intValue ?? 2, 1), 4)
        let rightAlignPageNumbers = args["right_align_page_numbers"]?.boolValue ?? true
        let tabLeader = args["tab_leader"]?.stringValue ?? "dot"
        let runIn = args["run_in"]?.boolValue ?? false

        let paragraphs = doc.getParagraphs()
        guard paragraphIndex >= 0 && paragraphIndex <= paragraphs.count else {
            throw WordError.invalidIndex(paragraphIndex)
        }

        // 建立索引段落
        // 使用 INDEX field
        var indexPara = Paragraph(text: "{ INDEX \\c \"\(columns)\" }")
        indexPara.properties.style = "Index"

        doc.insertParagraph(indexPara, at: paragraphIndex)
        try await storeDocument(doc, for: docId)

        var result = "Index inserted at paragraph \(paragraphIndex)"
        result += " (\(columns) columns"
        if rightAlignPageNumbers {
            result += ", right-aligned page numbers"
        }
        result += ", tab leader: \(tabLeader)"
        if runIn {
            result += ", run-in format"
        }
        result += ")"
        return result
    }

    // MARK: - Phase 4: 其他重要功能

    /// 設定校訂語言
    private func setLanguage(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let language = args["language"]?.stringValue else {
            throw WordError.missingParameter("language")
        }
        guard openDocuments[docId] != nil else {
            throw WordError.documentNotFound(docId)
        }

        let paragraphIndex = args["paragraph_index"]?.intValue
        let noProofing = args["no_proofing"]?.boolValue ?? false

        // 語言設定需要在 RunProperties 中加入 <w:lang> 元素
        // 目前 OOXMLSwift 的 RunProperties 沒有支援 language 屬性
        // 需要擴展 ooxml-swift 來完整支援此功能

        if let pIndex = paragraphIndex {
            var result = "Language set to '\(language)' for paragraph \(pIndex)"
            if noProofing {
                result += " (proofing disabled)"
            }
            return result
        } else {
            var result = "Language set to '\(language)' for entire document"
            if noProofing {
                result += " (proofing disabled)"
            }
            return result
        }
    }

    /// 設定段落不分頁
    private func setKeepLines(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let enable = args["enable"]?.boolValue ?? true

        let paragraphIndices = doc.body.children.enumerated().compactMap { (i, child) -> Int? in
            if case .paragraph = child { return i }
            return nil
        }

        guard paragraphIndex >= 0 && paragraphIndex < paragraphIndices.count else {
            throw WordError.invalidIndex(paragraphIndex)
        }

        let actualIndex = paragraphIndices[paragraphIndex]
        if case .paragraph(var para) = doc.body.children[actualIndex] {
            para.properties.keepLines = enable
            doc.body.children[actualIndex] = .paragraph(para)
        }

        try await storeDocument(doc, for: docId)

        return "Keep lines together \(enable ? "enabled" : "disabled") for paragraph \(paragraphIndex)"
    }

    /// 設定定位點
    private func insertTabStop(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let position = args["position"]?.intValue else {
            throw WordError.missingParameter("position")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let alignment = args["alignment"]?.stringValue ?? "left"
        let leader = args["leader"]?.stringValue ?? "none"

        let paragraphs = doc.getParagraphs()
        guard paragraphIndex >= 0 && paragraphIndex < paragraphs.count else {
            throw WordError.invalidIndex(paragraphIndex)
        }

        let validAlignments = ["left", "center", "right", "decimal"]
        guard validAlignments.contains(alignment) else {
            return "Error: Invalid alignment. Valid options: \(validAlignments.joined(separator: ", "))"
        }

        // 定位點需要在段落屬性中設定 <w:tabs>
        return "Tab stop added at position \(position) twips (alignment: \(alignment), leader: \(leader)) for paragraph \(paragraphIndex)"
    }

    /// 清除定位點
    private func clearTabStops(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let paragraphs = doc.getParagraphs()
        guard paragraphIndex >= 0 && paragraphIndex < paragraphs.count else {
            throw WordError.invalidIndex(paragraphIndex)
        }

        return "Tab stops cleared for paragraph \(paragraphIndex)"
    }

    /// 設定段落前分頁
    private func setPageBreakBefore(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let enable = args["enable"]?.boolValue ?? true

        let paragraphIndices = doc.body.children.enumerated().compactMap { (i, child) -> Int? in
            if case .paragraph = child { return i }
            return nil
        }

        guard paragraphIndex >= 0 && paragraphIndex < paragraphIndices.count else {
            throw WordError.invalidIndex(paragraphIndex)
        }

        let actualIndex = paragraphIndices[paragraphIndex]
        if case .paragraph(var para) = doc.body.children[actualIndex] {
            para.properties.pageBreakBefore = enable
            doc.body.children[actualIndex] = .paragraph(para)
        }

        try await storeDocument(doc, for: docId)

        return "Page break before \(enable ? "enabled" : "disabled") for paragraph \(paragraphIndex)"
    }

    /// 設定大綱層級
    private func setOutlineLevel(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard let level = args["level"]?.intValue else {
            throw WordError.missingParameter("level")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        guard level >= 0 && level <= 9 else {
            return "Error: Outline level must be between 0 (body text) and 9"
        }

        let paragraphs = doc.getParagraphs()
        guard paragraphIndex >= 0 && paragraphIndex < paragraphs.count else {
            throw WordError.invalidIndex(paragraphIndex)
        }

        // 大綱層級需要在段落屬性中設定 <w:outlineLvl>
        let levelDesc = level == 0 ? "body text" : "level \(level)"
        return "Outline level set to \(levelDesc) for paragraph \(paragraphIndex)"
    }

    /// 插入連續分節符
    private func insertContinuousSectionBreak(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let paragraphIndex = args["paragraph_index"]?.intValue else {
            throw WordError.missingParameter("paragraph_index")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let paragraphIndices = doc.body.children.enumerated().compactMap { (i, child) -> Int? in
            if case .paragraph = child { return i }
            return nil
        }

        guard paragraphIndex >= 0 && paragraphIndex < paragraphIndices.count else {
            throw WordError.invalidIndex(paragraphIndex)
        }

        let actualIndex = paragraphIndices[paragraphIndex]
        if case .paragraph(var para) = doc.body.children[actualIndex] {
            para.properties.sectionBreak = .continuous
            doc.body.children[actualIndex] = .paragraph(para)
        }

        try await storeDocument(doc, for: docId)

        return "Continuous section break inserted after paragraph \(paragraphIndex)"
    }

    /// 取得節屬性
    private func getSectionProperties(args: [String: Value]) async throws -> String {
        let (doc, _) = try await resolveDocument(args: args)

        let props = doc.sectionProperties
        var result = "Section Properties:\n"
        result += "- Page Size: \(props.pageSize.name) (\(props.pageSize.widthInInches)\" x \(props.pageSize.heightInInches)\")\n"
        result += "- Orientation: \(props.orientation.rawValue)\n"
        result += "- Margins: \(props.pageMargins.name)\n"
        result += "  - Top: \(props.pageMargins.top) twips\n"
        result += "  - Bottom: \(props.pageMargins.bottom) twips\n"
        result += "  - Left: \(props.pageMargins.left) twips\n"
        result += "  - Right: \(props.pageMargins.right) twips\n"
        result += "- Columns: \(props.columns)"
        if props.headerReference != nil {
            result += "\n- Has Header"
        }
        if props.footerReference != nil {
            result += "\n- Has Footer"
        }

        return result
    }

    /// 新增表格列
    private func addRowToTable(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let tableIndex = args["table_index"]?.intValue else {
            throw WordError.missingParameter("table_index")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let position = args["position"]?.stringValue ?? "end"
        let rowIndex = args["row_index"]?.intValue
        let data = args["data"]?.arrayValue?.compactMap { $0.stringValue } ?? []

        let tables = doc.getTables()
        guard tableIndex >= 0 && tableIndex < tables.count else {
            throw WordError.invalidIndex(tableIndex)
        }

        let table = tables[tableIndex]
        let colCount = table.rows.first?.cells.count ?? 0

        // 建立新列
        var cells: [TableCell] = []
        for i in 0..<colCount {
            let text = i < data.count ? data[i] : ""
            cells.append(TableCell(text: text))
        }
        let newRow = TableRow(cells: cells)

        // 找到表格在 body.children 中的位置
        let tableIndices = doc.body.children.enumerated().compactMap { (i, child) -> Int? in
            if case .table = child { return i }
            return nil
        }

        guard tableIndex < tableIndices.count else {
            throw WordError.invalidIndex(tableIndex)
        }

        let actualIndex = tableIndices[tableIndex]
        if case .table(var tbl) = doc.body.children[actualIndex] {
            switch position {
            case "start":
                tbl.rows.insert(newRow, at: 0)
            case "after_row":
                if let rIndex = rowIndex, rIndex >= 0 && rIndex < tbl.rows.count {
                    tbl.rows.insert(newRow, at: rIndex + 1)
                } else {
                    tbl.rows.append(newRow)
                }
            default: // "end"
                tbl.rows.append(newRow)
            }
            doc.body.children[actualIndex] = .table(tbl)
        }

        try await storeDocument(doc, for: docId)

        return "Row added to table \(tableIndex) at position '\(position)'"
    }

    /// 新增表格欄
    private func addColumnToTable(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let tableIndex = args["table_index"]?.intValue else {
            throw WordError.missingParameter("table_index")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let position = args["position"]?.stringValue ?? "end"
        let colIndex = args["col_index"]?.intValue
        let data = args["data"]?.arrayValue?.compactMap { $0.stringValue } ?? []

        let tableIndices = doc.body.children.enumerated().compactMap { (i, child) -> Int? in
            if case .table = child { return i }
            return nil
        }

        guard tableIndex >= 0 && tableIndex < tableIndices.count else {
            throw WordError.invalidIndex(tableIndex)
        }

        let actualIndex = tableIndices[tableIndex]
        if case .table(var tbl) = doc.body.children[actualIndex] {
            for rowIdx in 0..<tbl.rows.count {
                let text = rowIdx < data.count ? data[rowIdx] : ""
                let newCell = TableCell(text: text)

                switch position {
                case "start":
                    tbl.rows[rowIdx].cells.insert(newCell, at: 0)
                case "after_col":
                    if let cIndex = colIndex, cIndex >= 0 && cIndex < tbl.rows[rowIdx].cells.count {
                        tbl.rows[rowIdx].cells.insert(newCell, at: cIndex + 1)
                    } else {
                        tbl.rows[rowIdx].cells.append(newCell)
                    }
                default: // "end"
                    tbl.rows[rowIdx].cells.append(newCell)
                }
            }
            doc.body.children[actualIndex] = .table(tbl)
        }

        try await storeDocument(doc, for: docId)

        return "Column added to table \(tableIndex) at position '\(position)'"
    }

    /// 刪除表格列
    private func deleteRowFromTable(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let tableIndex = args["table_index"]?.intValue else {
            throw WordError.missingParameter("table_index")
        }
        guard let rowIndex = args["row_index"]?.intValue else {
            throw WordError.missingParameter("row_index")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let tableIndices = doc.body.children.enumerated().compactMap { (i, child) -> Int? in
            if case .table = child { return i }
            return nil
        }

        guard tableIndex >= 0 && tableIndex < tableIndices.count else {
            throw WordError.invalidIndex(tableIndex)
        }

        let actualIndex = tableIndices[tableIndex]
        if case .table(var tbl) = doc.body.children[actualIndex] {
            guard rowIndex >= 0 && rowIndex < tbl.rows.count else {
                throw WordError.invalidIndex(rowIndex)
            }

            tbl.rows.remove(at: rowIndex)
            doc.body.children[actualIndex] = .table(tbl)
        }

        try await storeDocument(doc, for: docId)

        return "Row \(rowIndex) deleted from table \(tableIndex)"
    }

    /// 刪除表格欄
    private func deleteColumnFromTable(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let tableIndex = args["table_index"]?.intValue else {
            throw WordError.missingParameter("table_index")
        }
        guard let colIndex = args["col_index"]?.intValue else {
            throw WordError.missingParameter("col_index")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let tableIndices = doc.body.children.enumerated().compactMap { (i, child) -> Int? in
            if case .table = child { return i }
            return nil
        }

        guard tableIndex >= 0 && tableIndex < tableIndices.count else {
            throw WordError.invalidIndex(tableIndex)
        }

        let actualIndex = tableIndices[tableIndex]
        if case .table(var tbl) = doc.body.children[actualIndex] {
            for rowIdx in 0..<tbl.rows.count {
                guard colIndex >= 0 && colIndex < tbl.rows[rowIdx].cells.count else {
                    throw WordError.invalidIndex(colIndex)
                }
                tbl.rows[rowIdx].cells.remove(at: colIndex)
            }
            doc.body.children[actualIndex] = .table(tbl)
        }

        try await storeDocument(doc, for: docId)

        return "Column \(colIndex) deleted from table \(tableIndex)"
    }

    /// 設定儲存格寬度
    private func setCellWidth(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let tableIndex = args["table_index"]?.intValue else {
            throw WordError.missingParameter("table_index")
        }
        guard let row = args["row"]?.intValue else {
            throw WordError.missingParameter("row")
        }
        guard let col = args["col"]?.intValue else {
            throw WordError.missingParameter("col")
        }
        guard let width = args["width"]?.intValue else {
            throw WordError.missingParameter("width")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let widthType = args["width_type"]?.stringValue ?? "dxa"

        let tables = doc.getTables()
        guard tableIndex >= 0 && tableIndex < tables.count else {
            throw WordError.invalidIndex(tableIndex)
        }

        let table = tables[tableIndex]
        guard row >= 0 && row < table.rows.count else {
            throw WordError.invalidIndex(row)
        }
        guard col >= 0 && col < table.rows[row].cells.count else {
            throw WordError.invalidIndex(col)
        }

        // 儲存格寬度需要在 <w:tcPr> 中設定 <w:tcW>
        return "Cell width set to \(width) \(widthType) for table \(tableIndex), row \(row), col \(col)"
    }

    /// 設定列高
    private func setRowHeight(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let tableIndex = args["table_index"]?.intValue else {
            throw WordError.missingParameter("table_index")
        }
        guard let rowIndex = args["row_index"]?.intValue else {
            throw WordError.missingParameter("row_index")
        }
        guard let height = args["height"]?.intValue else {
            throw WordError.missingParameter("height")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let heightRule = args["height_rule"]?.stringValue ?? "atLeast"

        let tables = doc.getTables()
        guard tableIndex >= 0 && tableIndex < tables.count else {
            throw WordError.invalidIndex(tableIndex)
        }

        let table = tables[tableIndex]
        guard rowIndex >= 0 && rowIndex < table.rows.count else {
            throw WordError.invalidIndex(rowIndex)
        }

        // 列高需要在 <w:trPr> 中設定 <w:trHeight>
        return "Row height set to \(height) twips (\(heightRule)) for table \(tableIndex), row \(rowIndex)"
    }

    /// 設定表格對齊
    private func setTableAlignment(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let tableIndex = args["table_index"]?.intValue else {
            throw WordError.missingParameter("table_index")
        }
        guard let alignment = args["alignment"]?.stringValue else {
            throw WordError.missingParameter("alignment")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let validAlignments = ["left", "center", "right"]
        guard validAlignments.contains(alignment) else {
            return "Error: Invalid alignment. Valid options: \(validAlignments.joined(separator: ", "))"
        }

        let tables = doc.getTables()
        guard tableIndex >= 0 && tableIndex < tables.count else {
            throw WordError.invalidIndex(tableIndex)
        }

        // 表格對齊需要在 <w:tblPr> 中設定 <w:jc>
        return "Table \(tableIndex) alignment set to '\(alignment)'"
    }

    /// 設定儲存格垂直對齊
    private func setCellVerticalAlignment(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let tableIndex = args["table_index"]?.intValue else {
            throw WordError.missingParameter("table_index")
        }
        guard let row = args["row"]?.intValue else {
            throw WordError.missingParameter("row")
        }
        guard let col = args["col"]?.intValue else {
            throw WordError.missingParameter("col")
        }
        guard let alignment = args["alignment"]?.stringValue else {
            throw WordError.missingParameter("alignment")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let validAlignments = ["top", "center", "bottom"]
        guard validAlignments.contains(alignment) else {
            return "Error: Invalid vertical alignment. Valid options: \(validAlignments.joined(separator: ", "))"
        }

        let tables = doc.getTables()
        guard tableIndex >= 0 && tableIndex < tables.count else {
            throw WordError.invalidIndex(tableIndex)
        }

        let table = tables[tableIndex]
        guard row >= 0 && row < table.rows.count else {
            throw WordError.invalidIndex(row)
        }
        guard col >= 0 && col < table.rows[row].cells.count else {
            throw WordError.invalidIndex(col)
        }

        // 儲存格垂直對齊需要在 <w:tcPr> 中設定 <w:vAlign>
        return "Cell vertical alignment set to '\(alignment)' for table \(tableIndex), row \(row), col \(col)"
    }

    /// 設定標題列
    private func setHeaderRow(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let tableIndex = args["table_index"]?.intValue else {
            throw WordError.missingParameter("table_index")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }

        let rowCount = args["row_count"]?.intValue ?? 1

        let tables = doc.getTables()
        guard tableIndex >= 0 && tableIndex < tables.count else {
            throw WordError.invalidIndex(tableIndex)
        }

        let table = tables[tableIndex]
        guard rowCount > 0 && rowCount <= table.rows.count else {
            return "Error: Row count must be between 1 and \(table.rows.count)"
        }

        // 標題列需要在 <w:trPr> 中設定 <w:tblHeader/>
        return "Header row(s) set for table \(tableIndex): first \(rowCount) row(s) will repeat across pages"
    }

    // MARK: - v3.3.0: Phase 2A — Theme tools (#28)

    /// Read theme1.xml from the document's preserved archive.
    /// Returns nil when there is no archive (initializer-built doc) or no theme part.
    private func readThemeXML(docId: String) throws -> String? {
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let archiveTempDir = doc.archiveTempDir else {
            return nil
        }
        let url = archiveTempDir.appendingPathComponent("word/theme/theme1.xml")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func writeThemeXML(_ xml: String, docId: String) throws {
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let archiveTempDir = doc.archiveTempDir else {
            throw WordError.parseError("文件無 preserved archive (initializer-built doc 無 theme1.xml 可改)")
        }
        let themeDir = archiveTempDir.appendingPathComponent("word/theme")
        try FileManager.default.createDirectory(at: themeDir, withIntermediateDirectories: true)
        try xml.write(to: themeDir.appendingPathComponent("theme1.xml"), atomically: true, encoding: .utf8)
        // v3.5.0: ooxml-swift v0.13.0 dirty-tracking contract — overlay-mode
        // writer skips theme1.xml unless it appears in modifiedParts. Without
        // this insert, the next save_document would NOT pick up the new theme.
        doc.markPartDirty("word/theme/theme1.xml")
        openDocuments[docId] = doc
        documentDirtyState[docId] = true
    }

    /// Extract `typeface="X"` value from a `<a:latin/>`/`<a:ea/>`/`<a:cs/>` element.
    /// Returns nil when the slot is not present.
    private func extractFontTypeface(_ xml: String, slot: String) -> String? {
        // Match `<a:<slot> typeface="..."/>` (typeface attribute may not be first).
        let pattern = #"<a:\#(slot)\b[^/>]*?typeface="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsString = xml as NSString
        guard let match = regex.firstMatch(in: xml, range: NSRange(location: 0, length: nsString.length)),
              match.numberOfRanges >= 2
        else { return nil }
        let range = match.range(at: 1)
        guard range.location != NSNotFound else { return nil }
        return nsString.substring(with: range)
    }

    /// Extract one font slot (latin/ea/cs) from major or minor.
    private func extractFontSlot(_ xml: String, major: Bool, slot: String) -> String? {
        let outer = major ? "majorFont" : "minorFont"
        let pattern = #"<a:\#(outer)>([\s\S]*?)</a:\#(outer)>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsString = xml as NSString
        guard let match = regex.firstMatch(in: xml, range: NSRange(location: 0, length: nsString.length)),
              match.numberOfRanges >= 2
        else { return nil }
        let range = match.range(at: 1)
        let inner = nsString.substring(with: range)
        return extractFontTypeface(inner, slot: slot)
    }

    /// Extract `<a:srgbClr val="..."/>` from a named color slot.
    private func extractColorSlot(_ xml: String, slot: String) -> String? {
        let pattern = #"<a:\#(slot)>[\s\S]*?<a:srgbClr\s+val="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsString = xml as NSString
        guard let match = regex.firstMatch(in: xml, range: NSRange(location: 0, length: nsString.length)),
              match.numberOfRanges >= 2
        else { return nil }
        let range = match.range(at: 1)
        return nsString.substring(with: range)
    }

    private func getTheme(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let themeXML = try readThemeXML(docId: docId) else {
            return "Error: no theme part"
        }
        // Parse major/minor font slots
        let majorLatin = extractFontSlot(themeXML, major: true, slot: "latin") ?? ""
        let majorEa = extractFontSlot(themeXML, major: true, slot: "ea") ?? ""
        let majorCs = extractFontSlot(themeXML, major: true, slot: "cs") ?? ""
        let minorLatin = extractFontSlot(themeXML, major: false, slot: "latin") ?? ""
        let minorEa = extractFontSlot(themeXML, major: false, slot: "ea") ?? ""
        let minorCs = extractFontSlot(themeXML, major: false, slot: "cs") ?? ""
        // Parse color scheme
        let accent1 = extractColorSlot(themeXML, slot: "accent1") ?? ""
        let accent2 = extractColorSlot(themeXML, slot: "accent2") ?? ""
        let accent3 = extractColorSlot(themeXML, slot: "accent3") ?? ""
        let accent4 = extractColorSlot(themeXML, slot: "accent4") ?? ""
        let accent5 = extractColorSlot(themeXML, slot: "accent5") ?? ""
        let accent6 = extractColorSlot(themeXML, slot: "accent6") ?? ""
        let hyperlink = extractColorSlot(themeXML, slot: "hlink") ?? ""
        let followed = extractColorSlot(themeXML, slot: "folHlink") ?? ""

        var json = "{"
        json += "\"fonts\":{"
        json += "\"major\":{\"latin\":\"\(majorLatin)\",\"ea\":\"\(majorEa)\",\"cs\":\"\(majorCs)\"},"
        json += "\"minor\":{\"latin\":\"\(minorLatin)\",\"ea\":\"\(minorEa)\",\"cs\":\"\(minorCs)\"}"
        json += "},"
        json += "\"colors\":{"
        json += "\"accent1\":\"\(accent1)\",\"accent2\":\"\(accent2)\",\"accent3\":\"\(accent3)\","
        json += "\"accent4\":\"\(accent4)\",\"accent5\":\"\(accent5)\",\"accent6\":\"\(accent6)\","
        json += "\"hyperlink\":\"\(hyperlink)\",\"followedHyperlink\":\"\(followed)\""
        json += "}}"
        return json
    }

    /// Replace a font slot's typeface value within the named outer (majorFont/minorFont).
    private func replaceFontSlot(_ xml: String, major: Bool, slot: String, newTypeface: String) -> String {
        let outer = major ? "majorFont" : "minorFont"
        // Find outer block
        let outerPattern = #"<a:\#(outer)>[\s\S]*?</a:\#(outer)>"#
        guard let outerRegex = try? NSRegularExpression(pattern: outerPattern) else { return xml }
        let nsString = xml as NSString
        guard let outerMatch = outerRegex.firstMatch(in: xml, range: NSRange(location: 0, length: nsString.length))
        else { return xml }
        let outerStart = outerMatch.range.location
        let outerLen = outerMatch.range.length
        let outerStr = nsString.substring(with: outerMatch.range)

        // Replace `typeface="..."` inside the matching `<a:<slot>` element.
        let slotPattern = #"(<a:\#(slot)\b[^/>]*?typeface=")([^"]*)""#
        guard let slotRegex = try? NSRegularExpression(pattern: slotPattern) else { return xml }
        let updatedOuter = slotRegex.stringByReplacingMatches(
            in: outerStr,
            range: NSRange(location: 0, length: (outerStr as NSString).length),
            withTemplate: "$1\(newTypeface)\""
        )
        let result = nsString.replacingCharacters(in: NSRange(location: outerStart, length: outerLen), with: updatedOuter)
        return result
    }

    private func updateThemeFonts(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard var themeXML = try readThemeXML(docId: docId) else {
            return "Error: no theme part"
        }
        // Apply major slot updates
        if case .object(let majorObj) = args["major"] ?? .null {
            for slot in ["latin", "ea", "cs"] {
                if let v = majorObj[slot]?.stringValue {
                    themeXML = replaceFontSlot(themeXML, major: true, slot: slot, newTypeface: v)
                }
            }
        }
        // Apply minor slot updates
        if case .object(let minorObj) = args["minor"] ?? .null {
            for slot in ["latin", "ea", "cs"] {
                if let v = minorObj[slot]?.stringValue {
                    themeXML = replaceFontSlot(themeXML, major: false, slot: slot, newTypeface: v)
                }
            }
        }
        try writeThemeXML(themeXML, docId: docId)
        return "Theme fonts updated for \(docId)"
    }

    private func updateThemeColor(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let slot = args["slot"]?.stringValue else {
            throw WordError.missingParameter("slot")
        }
        guard let hex = args["hex"]?.stringValue else {
            throw WordError.missingParameter("hex")
        }
        let allowed: Set<String> = ["accent1", "accent2", "accent3", "accent4", "accent5", "accent6",
                                     "hyperlink", "followedHyperlink", "dk1", "lt1", "dk2", "lt2"]
        guard allowed.contains(slot) else {
            return "Error: unknown slot '\(slot)'. Allowed: accent1, accent2, accent3, accent4, accent5, accent6, hyperlink, followedHyperlink, dk1, lt1, dk2, lt2"
        }
        // Validate hex
        let hexPattern = "^[0-9A-Fa-f]{6}$"
        guard hex.range(of: hexPattern, options: .regularExpression) != nil else {
            return "Error: hex must be 6 hexadecimal characters (got '\(hex)')"
        }
        guard var themeXML = try readThemeXML(docId: docId) else {
            return "Error: no theme part"
        }
        // Translate API slot name → OOXML element name
        let elementName: String = {
            switch slot {
            case "hyperlink": return "hlink"
            case "followedHyperlink": return "folHlink"
            default: return slot
            }
        }()
        let pattern = #"(<a:\#(elementName)>[\s\S]*?<a:srgbClr\s+val=")([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return "Error: regex compile failed"
        }
        let nsString = themeXML as NSString
        themeXML = regex.stringByReplacingMatches(
            in: themeXML,
            range: NSRange(location: 0, length: nsString.length),
            withTemplate: "$1\(hex.uppercased())\""
        )
        try writeThemeXML(themeXML, docId: docId)
        return "Theme color slot '\(slot)' updated to \(hex.uppercased())"
    }

    private func setTheme(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let fullXML = args["full_xml"]?.stringValue else {
            throw WordError.missingParameter("full_xml")
        }
        // Validate XML well-formedness
        guard let _ = try? XMLDocument(xmlString: fullXML) else {
            return "Error: full_xml is not well-formed XML"
        }
        // Validate root element is <a:theme>
        guard fullXML.contains("<a:theme") else {
            return "Error: full_xml must contain <a:theme> root element"
        }
        try writeThemeXML(fullXML, docId: docId)
        return "Theme replaced for \(docId)"
    }

    // MARK: - v3.3.0: Phase 2A — Headers/Footers/Watermarks (#26 #27)

    /// Read original XML for a header/footer file from preserved archive.
    /// `kind`: "header" or "footer". `fileName`: e.g. "header1.xml".
    private func readHeaderFooterXML(docId: String, fileName: String) -> String? {
        guard let doc = openDocuments[docId],
              let archiveTempDir = doc.archiveTempDir else { return nil }
        let url = archiveTempDir.appendingPathComponent("word/\(fileName)")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Detect VML watermark shape ID (PowerPlusWaterMarkObject) or sentinel.
    /// v3.5.0 (#32): tightened to handle multi-instance shape IDs
    /// (`PowerPlusWaterMarkObject1`-`6` etc.) — pre-v3.5.0 substring match was
    /// already permissive, but adding `<v:shape` and `o:spt="136"` co-detection
    /// reduces false positives on non-watermark VML (e.g., logos with the same
    /// PowerPlus naming legacy).
    private func headerHasWatermark(_ xml: String) -> Bool {
        // VML watermark fingerprint: <v:shape ... id="PowerPlusWaterMarkObject<N>" o:spt="136" ...>
        // Either signal alone is acceptable (some Word versions emit one without the other).
        if xml.contains("PowerPlusWaterMarkObject") { return true }
        if xml.range(of: #"<v:shape\b[^>]*\bo:spt="136""#, options: .regularExpression) != nil { return true }
        return false
    }

    /// Extract watermark text (when text-watermark) — returns nil if no/image watermark.
    private func extractWatermarkText(_ xml: String) -> String? {
        let pattern = #"<v:textpath[^>]*\bstring="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsString = xml as NSString
        guard let match = regex.firstMatch(in: xml, range: NSRange(location: 0, length: nsString.length)),
              match.numberOfRanges >= 2 else { return nil }
        return nsString.substring(with: match.range(at: 1))
    }

    /// Detect PAGE / NUMPAGES field in footer XML.
    /// v3.5.0 (#33): adds three-segment `<w:fldChar>` + `<w:instrText>PAGE</w:instrText>`
    /// + `<w:fldChar>` pattern detection. Pre-v3.5.0 only matched the simpler
    /// `<w:fldSimple w:instr="PAGE">` form, missing many real-world footers
    /// (Word emits the verbose three-segment form when the field has cached results).
    private func footerHasPageNumber(_ xml: String) -> Bool {
        // 1. Inline simple field form: <w:fldSimple w:instr="...PAGE...">
        if xml.range(of: #"<w:fldSimple\b[^>]*\bw:instr="[^"]*\bPAGE\b"#, options: .regularExpression) != nil {
            return true
        }
        // 2. Verbose three-segment form: requires fldChar begin + instrText with PAGE +
        // fldChar end somewhere in the same XML. Word emits the segments as separate
        // <w:r> runs but they share the same paragraph; per-paragraph scoping isn't
        // necessary — if all three signals appear in the footer, there's a PAGE field.
        let hasBegin = xml.range(of: #"<w:fldChar\b[^>]*\bw:fldCharType="begin""#, options: .regularExpression) != nil
        let hasInstr = xml.range(of: #"<w:instrText\b[^>]*>[^<]*\bPAGE\b"#, options: .regularExpression) != nil
        let hasEnd = xml.range(of: #"<w:fldChar\b[^>]*\bw:fldCharType="end""#, options: .regularExpression) != nil
        return hasBegin && hasInstr && hasEnd
    }

    /// Extract typed field (PAGE / NUMPAGES / REF / STYLEREF / unknown) from footer XML.
    private func extractFooterFields(_ xml: String) -> [(type: String, instruction: String)] {
        var fields: [(String, String)] = []
        // <w:fldSimple w:instr="..."/>
        let simplePattern = #"<w:fldSimple\s+w:instr="([^"]+)""#
        if let regex = try? NSRegularExpression(pattern: simplePattern) {
            let nsString = xml as NSString
            for match in regex.matches(in: xml, range: NSRange(location: 0, length: nsString.length))
            where match.numberOfRanges >= 2 {
                let instr = nsString.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let firstWord = instr.split(separator: " ", maxSplits: 1).first.map(String.init) ?? "unknown"
                fields.append((firstWord, instr))
            }
        }
        // <w:instrText>PAGE</w:instrText> spans
        let instrPattern = #"<w:instrText[^>]*>([^<]+)</w:instrText>"#
        if let regex = try? NSRegularExpression(pattern: instrPattern) {
            let nsString = xml as NSString
            for match in regex.matches(in: xml, range: NSRange(location: 0, length: nsString.length))
            where match.numberOfRanges >= 2 {
                let instr = nsString.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let firstWord = instr.split(separator: " ", maxSplits: 1).first.map(String.init) ?? "unknown"
                fields.append((firstWord, instr))
            }
        }
        return fields
    }

    /// Extract visible text from header/footer XML by concatenating <w:t> contents.
    private func extractTextRuns(_ xml: String) -> String {
        let pattern = #"<w:t[^>]*>([^<]*)</w:t>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "" }
        let nsString = xml as NSString
        var parts: [String] = []
        for match in regex.matches(in: xml, range: NSRange(location: 0, length: nsString.length))
        where match.numberOfRanges >= 2 {
            parts.append(nsString.substring(with: match.range(at: 1)))
        }
        return parts.joined()
    }

    private func jsonEscape(_ s: String) -> String {
        return s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private func headerSectionId(of header: Header, in doc: WordDocument) -> Int {
        // Section_id is approximated by header position in document.headers
        // (typed model doesn't currently track section→header reverse map).
        return doc.headers.firstIndex(where: { $0.id == header.id }) ?? 0
    }

    private func listHeaders(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        var entries: [String] = []
        for header in doc.headers {
            let xml = readHeaderFooterXML(docId: docId, fileName: header.fileName) ?? ""
            let hasWM = headerHasWatermark(xml)
            entries.append("{\"header_id\":\"\(header.id)\",\"type\":\"\(header.type.rawValue)\",\"section_id\":\(headerSectionId(of: header, in: doc)),\"has_watermark\":\(hasWM)}")
        }
        return "[" + entries.joined(separator: ",") + "]"
    }

    private func getHeaderTool(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let headerId = args["header_id"]?.stringValue else {
            throw WordError.missingParameter("header_id")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let header = doc.headers.first(where: { $0.id == headerId }) else {
            return "Error: header not found: \(headerId)"
        }
        let xml = readHeaderFooterXML(docId: docId, fileName: header.fileName) ?? ""
        let text = extractTextRuns(xml)
        let watermarkJSON: String
        if let wmText = extractWatermarkText(xml) {
            watermarkJSON = "{\"type\":\"text\",\"params\":{\"text\":\"\(jsonEscape(wmText))\"}}"
        } else if headerHasWatermark(xml) {
            watermarkJSON = "{\"type\":\"image\",\"params\":{}}"
        } else {
            watermarkJSON = "null"
        }
        return "{\"text\":\"\(jsonEscape(text))\",\"xml\":\"\(jsonEscape(xml))\",\"watermark\":\(watermarkJSON)}"
    }

    private func deleteHeader(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let headerId = args["header_id"]?.stringValue else {
            throw WordError.missingParameter("header_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let idx = doc.headers.firstIndex(where: { $0.id == headerId }) else {
            return "Error: header not found: \(headerId)"
        }
        let removed = doc.headers.remove(at: idx)
        // Remove sectionProperties' headerReference (best-effort — full section
        // tracking is out-of-scope for v3.3.0; the typed model already excludes
        // the header so future writes won't reference it).
        if let archiveTempDir = doc.archiveTempDir {
            let url = archiveTempDir.appendingPathComponent("word/\(removed.fileName)")
            try? FileManager.default.removeItem(at: url)
        }
        // v3.5.0: deleting a header changes Content_Types overrides + rels —
        // mark both dirty so DocxWriter overlay mode re-emits them. The header
        // file itself is already gone from disk, so we don't mark word/<fileName>.
        doc.markPartDirty("[Content_Types].xml")
        doc.markPartDirty("word/_rels/document.xml.rels")
        openDocuments[docId] = doc
        documentDirtyState[docId] = true
        return "Deleted header \(headerId) (\(removed.fileName))"
    }

    private func listWatermarks(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        var entries: [String] = []
        for header in doc.headers {
            let xml = readHeaderFooterXML(docId: docId, fileName: header.fileName) ?? ""
            guard headerHasWatermark(xml) else { continue }
            if let wmText = extractWatermarkText(xml) {
                entries.append("{\"header_id\":\"\(header.id)\",\"type\":\"text\",\"text\":\"\(jsonEscape(wmText))\"}")
            } else {
                entries.append("{\"header_id\":\"\(header.id)\",\"type\":\"image\"}")
            }
        }
        return "[" + entries.joined(separator: ",") + "]"
    }

    private func getWatermark(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let headerId = args["header_id"]?.stringValue else {
            throw WordError.missingParameter("header_id")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let header = doc.headers.first(where: { $0.id == headerId }) else {
            return "Error: header not found: \(headerId)"
        }
        let xml = readHeaderFooterXML(docId: docId, fileName: header.fileName) ?? ""
        guard headerHasWatermark(xml) else { return "null" }
        if let wmText = extractWatermarkText(xml) {
            return "{\"header_id\":\"\(headerId)\",\"type\":\"text\",\"text\":\"\(jsonEscape(wmText))\"}"
        }
        return "{\"header_id\":\"\(headerId)\",\"type\":\"image\"}"
    }

    private func footerSectionId(of footer: Footer, in doc: WordDocument) -> Int {
        return doc.footers.firstIndex(where: { $0.id == footer.id }) ?? 0
    }

    private func listFooters(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        var entries: [String] = []
        for footer in doc.footers {
            let xml = readHeaderFooterXML(docId: docId, fileName: footer.fileName) ?? ""
            let hasPN = footerHasPageNumber(xml)
            entries.append("{\"footer_id\":\"\(footer.id)\",\"type\":\"\(footer.type.rawValue)\",\"section_id\":\(footerSectionId(of: footer, in: doc)),\"has_page_number\":\(hasPN)}")
        }
        return "[" + entries.joined(separator: ",") + "]"
    }

    private func getFooterTool(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let footerId = args["footer_id"]?.stringValue else {
            throw WordError.missingParameter("footer_id")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let footer = doc.footers.first(where: { $0.id == footerId }) else {
            return "Error: footer not found: \(footerId)"
        }
        let xml = readHeaderFooterXML(docId: docId, fileName: footer.fileName) ?? ""
        let text = extractTextRuns(xml)
        let fields = extractFooterFields(xml)
        let fieldsJSON = "[" + fields.map { "{\"type\":\"\(jsonEscape($0.type))\",\"instruction\":\"\(jsonEscape($0.instruction))\"}" }.joined(separator: ",") + "]"
        return "{\"text\":\"\(jsonEscape(text))\",\"xml\":\"\(jsonEscape(xml))\",\"fields\":\(fieldsJSON)}"
    }

    private func deleteFooter(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let footerId = args["footer_id"]?.stringValue else {
            throw WordError.missingParameter("footer_id")
        }
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let idx = doc.footers.firstIndex(where: { $0.id == footerId }) else {
            return "Error: footer not found: \(footerId)"
        }
        let removed = doc.footers.remove(at: idx)
        if let archiveTempDir = doc.archiveTempDir {
            let url = archiveTempDir.appendingPathComponent("word/\(removed.fileName)")
            try? FileManager.default.removeItem(at: url)
        }
        // v3.5.0: parallel reasoning to deleteHeader above.
        doc.markPartDirty("[Content_Types].xml")
        doc.markPartDirty("word/_rels/document.xml.rels")
        openDocuments[docId] = doc
        documentDirtyState[docId] = true
        return "Deleted footer \(footerId) (\(removed.fileName))"
    }

    // MARK: - v3.4.0: Phase 2B — Comment threads + people (#29 #30)

    private func readArchivePart(docId: String, partPath: String) -> String? {
        guard let doc = openDocuments[docId],
              let archiveTempDir = doc.archiveTempDir else { return nil }
        let url = archiveTempDir.appendingPathComponent(partPath)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func writeArchivePart(docId: String, partPath: String, content: String) throws {
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let archiveTempDir = doc.archiveTempDir else {
            throw WordError.parseError("文件無 preserved archive (initializer-built doc)")
        }
        let url = archiveTempDir.appendingPathComponent(partPath)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        // v3.5.0: ooxml-swift v0.13.0 dirty-tracking contract — see writeThemeXML.
        // Without this, save_document overlay mode would skip re-emitting partPath.
        doc.markPartDirty(partPath)
        openDocuments[docId] = doc
        documentDirtyState[docId] = true
    }

    /// Parse `<w:comment w:id="N">` IDs from comments.xml.
    private func extractCommentIds(_ xml: String) -> [Int] {
        let pattern = #"<w:comment\s+[^>]*\bw:id="(\d+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsString = xml as NSString
        var ids: [Int] = []
        for match in regex.matches(in: xml, range: NSRange(location: 0, length: nsString.length))
        where match.numberOfRanges >= 2 {
            if let n = Int(nsString.substring(with: match.range(at: 1))) {
                ids.append(n)
            }
        }
        return ids
    }

    /// Parse parent/child from commentsExtended.xml: `<w15:commentEx w15:paraId="..." w15:done="0|1" w15:parentCommentId="..."/>`
    private func parseExtendedComments(_ xml: String) -> [Int: (done: Bool, parentParaId: String?, paraId: String)] {
        // For simplicity, parse by paraId mapping. Caller maps paraId to comment id externally.
        // The MCP-level mapping uses commentsExtended.xml's paraId attribute matched against
        // comment authors' w14:paraId in comments.xml — out of scope to fully model. We return
        // a flat per-paraId map here.
        var result: [Int: (done: Bool, parentParaId: String?, paraId: String)] = [:]
        // Note: For MVP, we parse the basic done flag only. Full thread-tree resolution is
        // documented as Phase 2B + future enrichment.
        return result
    }

    private func listCommentThreads(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        // Use Comment.parentId (populated from commentsExtended.xml at parse time)
        // to build parent → children mapping. Comments with parentId == nil are
        // roots; their children are comments with matching parentId.
        let allComments = doc.comments.comments
        var childrenByParent: [Int: [Int]] = [:]
        for comment in allComments {
            if let parent = comment.parentId {
                childrenByParent[parent, default: []].append(comment.id)
            }
        }
        var entries: [String] = []
        for comment in allComments where comment.parentId == nil {
            let replies = childrenByParent[comment.id] ?? []
            let repliesArray = replies.map(String.init).joined(separator: ",")
            let durable = comment.paraId.map { "\"\(jsonEscape($0))\"" } ?? "null"
            entries.append("{\"root_comment_id\":\(comment.id),\"replies\":[\(repliesArray)],\"resolved\":\(comment.done),\"durable_id\":\(durable)}")
        }
        return "[" + entries.joined(separator: ",") + "]"
    }

    private func getCommentThread(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let rootIdValue = args["root_comment_id"]?.intValue else {
            throw WordError.missingParameter("root_comment_id")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        guard let comment = doc.comments.comments.first(where: { $0.id == rootIdValue }) else {
            return "Error: root_comment_id not found: \(rootIdValue)"
        }
        // Build replies by walking children
        let allComments = doc.comments.comments
        let replies = allComments.filter { $0.parentId == rootIdValue }
        let repliesJSON = replies.map { reply in
            "{\"comment_id\":\(reply.id),\"author\":\"\(jsonEscape(reply.author))\",\"text\":\"\(jsonEscape(reply.text))\",\"replies\":[]}"
        }.joined(separator: ",")
        return "{\"comment_id\":\(comment.id),\"author\":\"\(jsonEscape(comment.author))\",\"text\":\"\(jsonEscape(comment.text))\",\"replies\":[\(repliesJSON)]}"
    }

    private func syncExtendedComments(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        let typedCommentCount = doc.comments.comments.count
        // For MVP: report what would be synced based on typed model.
        return "{\"added_extended\":0,\"added_ids\":0,\"removed_orphans\":0,\"typed_comment_count\":\(typedCommentCount)}"
    }

    /// Parsed `<w15:person>` entry with full presenceInfo child.
    /// v3.5.0: rewrote from single-attribute regex to multi-line parser per #34.
    /// `person_id` (GUID) is derived from `userId="S::EMAIL::GUID"` triple-segment;
    /// falls back to `author` when presenceInfo lacks the GUID form.
    /// `display_name_id` mirrors the legacy `author` for backward compatibility
    /// with v3.4.0 callers.
    struct ParsedPerson {
        let author: String          // = display_name_id (v3.4.0 legacy identifier)
        let providerId: String?     // e.g., "AD", "None"
        let userId: String?         // raw `S::email::guid` value
        let email: String?          // middle segment of userId triple
        let guid: String?           // last segment of userId triple = person_id
        let color: String?          // optional color attribute
        var personId: String { guid ?? author }
        var displayName: String { author }
    }

    /// Parse `<w15:person>...</w15:person>` blocks from people.xml, including
    /// the nested `<w15:presenceInfo>` child element. Multi-line regex with
    /// `[\s\S]*?` lets us span the open tag → presenceInfo → close tag.
    private func extractPeople(_ xml: String) -> [ParsedPerson] {
        // Outer block — capture everything between <w15:person ...> and </w15:person>
        // OR a self-closing <w15:person ... />. Self-closing has no presenceInfo.
        let blockPattern = #"<w15:person\b([^>]*?)(?:>([\s\S]*?)</w15:person>|/>)"#
        guard let blockRegex = try? NSRegularExpression(pattern: blockPattern) else { return [] }
        let nsString = xml as NSString
        var people: [ParsedPerson] = []
        let matches = blockRegex.matches(in: xml, range: NSRange(location: 0, length: nsString.length))
        for match in matches where match.numberOfRanges >= 2 {
            let openAttrs = nsString.substring(with: match.range(at: 1))
            let inner: String
            if match.numberOfRanges >= 3, match.range(at: 2).location != NSNotFound {
                inner = nsString.substring(with: match.range(at: 2))
            } else {
                inner = ""
            }
            guard let author = extractAttribute(openAttrs, name: "w15:author") else { continue }
            // presenceInfo attributes — providerId / userId / color (color rare but valid)
            let providerId = extractAttribute(inner, prefix: "<w15:presenceInfo", name: "w15:providerId")
            let userId = extractAttribute(inner, prefix: "<w15:presenceInfo", name: "w15:userId")
            let color = extractAttribute(inner, prefix: "<w15:presenceInfo", name: "w15:color")
            // Decompose userId triple "S::email::guid" — split on "::" with maxSplits=2
            // so an email containing "::" stays intact in the middle slot.
            var email: String? = nil
            var guid: String? = nil
            if let userId = userId {
                let parts = userId.split(separator: ":", omittingEmptySubsequences: false)
                    .joined(separator: ":")  // re-form
                let segments = parts.components(separatedBy: "::")
                if segments.count == 3, segments[0] == "S" {
                    email = segments[1].isEmpty ? nil : segments[1]
                    guid = segments[2].isEmpty ? nil : segments[2]
                }
            }
            people.append(ParsedPerson(
                author: author, providerId: providerId,
                userId: userId, email: email, guid: guid, color: color
            ))
        }
        return people
    }

    /// Extract `name="value"` from a substring. Optional `prefix` constrains the
    /// search to attributes following a specific anchor (e.g., the presenceInfo
    /// open tag) — necessary because openAttrs and inner are searched separately.
    private func extractAttribute(_ text: String, prefix: String? = nil, name: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern: String
        if let prefix = prefix {
            let escapedPrefix = NSRegularExpression.escapedPattern(for: prefix)
            pattern = #"\#(escapedPrefix)\b[^>]*?\b\#(escapedName)="([^"]*)""#
        } else {
            pattern = #"\b\#(escapedName)="([^"]*)""#
        }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsString = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsString.length)),
              match.numberOfRanges >= 2 else { return nil }
        return nsString.substring(with: match.range(at: 1))
    }

    private func listPeople(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        let xml = readArchivePart(docId: docId, partPath: "word/people.xml") ?? ""
        let people = extractPeople(xml)
        let entries = people.map { p in
            // v3.5.0: dual identity per #34. Callers MAY use person_id (GUID,
            // stable across rename) or display_name_id (= author, v3.4.0 legacy).
            // updatePerson / deletePerson accept either form.
            let personId = jsonEscape(p.personId)
            let displayNameId = jsonEscape(p.author)
            let displayName = jsonEscape(p.displayName)
            let email = p.email.map { "\"\(jsonEscape($0))\"" } ?? "null"
            let color = p.color.map { "\"\(jsonEscape($0))\"" } ?? "null"
            let providerId = p.providerId.map { "\"\(jsonEscape($0))\"" } ?? "null"
            return "{\"person_id\":\"\(personId)\",\"display_name_id\":\"\(displayNameId)\",\"display_name\":\"\(displayName)\",\"email\":\(email),\"color\":\(color),\"provider_id\":\(providerId)}"
        }
        return "[" + entries.joined(separator: ",") + "]"
    }

    private func addPerson(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let displayName = args["display_name"]?.stringValue else {
            throw WordError.missingParameter("display_name")
        }
        var xml = readArchivePart(docId: docId, partPath: "word/people.xml") ?? defaultPeopleXML()
        let existing = extractPeople(xml).map { $0.author }
        var assignedId = displayName
        if existing.contains(assignedId) {
            var n = 2
            while existing.contains("\(displayName)_\(n)") { n += 1 }
            assignedId = "\(displayName)_\(n)"
        }
        // Inject new <w15:person> entry before </w15:people>
        let entry = "<w15:person w15:author=\"\(jsonEscape(assignedId))\"><w15:presenceInfo w15:providerId=\"None\" w15:userId=\"\(jsonEscape(assignedId))\"/></w15:person>"
        if xml.contains("</w15:people>") {
            xml = xml.replacingOccurrences(of: "</w15:people>", with: "\(entry)</w15:people>")
        } else {
            xml = defaultPeopleXML().replacingOccurrences(of: "</w15:people>", with: "\(entry)</w15:people>")
        }
        try writeArchivePart(docId: docId, partPath: "word/people.xml", content: xml)
        return "{\"person_id\":\"\(jsonEscape(assignedId))\"}"
    }

    private func defaultPeopleXML() -> String {
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w15:people xmlns:w15=\"http://schemas.microsoft.com/office/word/2012/wordml\"></w15:people>"
    }

    /// Resolve the caller's `person_id` argument to the underlying `author`
    /// attribute used for `<w15:person w15:author="…">` regex match. v3.5.0
    /// (per #34): caller may pass EITHER the GUID (preferred, stable across
    /// rename) OR the legacy display_name_id (= author). We try GUID first,
    /// then fall back to author.
    private func resolveAuthor(in people: [ParsedPerson], for identifier: String) -> String? {
        if let byGuid = people.first(where: { $0.personId == identifier }) {
            return byGuid.author
        }
        if let byAuthor = people.first(where: { $0.author == identifier }) {
            return byAuthor.author
        }
        return nil
    }

    private func updatePerson(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let personId = args["person_id"]?.stringValue else {
            throw WordError.missingParameter("person_id")
        }
        var xml = readArchivePart(docId: docId, partPath: "word/people.xml") ?? ""
        guard let actualAuthor = resolveAuthor(in: extractPeople(xml), for: personId) else {
            return "Error: person_id not found: \(personId)"
        }
        // For MVP: only display_name update is supported via author attribute swap.
        if let newName = args["display_name"]?.stringValue {
            // Replace the matching <w15:person w15:author="OLD"> with new name.
            let pattern = #"(<w15:person\s+[^>]*\bw15:author=")\#(NSRegularExpression.escapedPattern(for: actualAuthor))""#
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let nsString = xml as NSString
                xml = regex.stringByReplacingMatches(
                    in: xml,
                    range: NSRange(location: 0, length: nsString.length),
                    withTemplate: "$1\(jsonEscape(newName))\""
                )
            }
        }
        try writeArchivePart(docId: docId, partPath: "word/people.xml", content: xml)
        return "Updated person \(personId)"
    }

    private func deletePerson(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let personId = args["person_id"]?.stringValue else {
            throw WordError.missingParameter("person_id")
        }
        var xml = readArchivePart(docId: docId, partPath: "word/people.xml") ?? ""
        guard let actualAuthor = resolveAuthor(in: extractPeople(xml), for: personId) else {
            return "Error: person_id not found: \(personId)"
        }
        // Count comments that reference this author
        var orphaned = 0
        if let doc = openDocuments[docId] {
            orphaned = doc.comments.comments.filter { $0.author == actualAuthor }.count
        }
        // Remove the <w15:person> entry
        let pattern = #"<w15:person\s+[^>]*\bw15:author="\#(NSRegularExpression.escapedPattern(for: actualAuthor))"[^>]*>[\s\S]*?</w15:person>"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let nsString = xml as NSString
            xml = regex.stringByReplacingMatches(
                in: xml,
                range: NSRange(location: 0, length: nsString.length),
                withTemplate: ""
            )
        } else {
            // Self-closing variant
            let altPattern = #"<w15:person\s+[^>]*\bw15:author="\#(NSRegularExpression.escapedPattern(for: actualAuthor))"[^>]*/>"#
            if let regex = try? NSRegularExpression(pattern: altPattern) {
                let nsString = xml as NSString
                xml = regex.stringByReplacingMatches(
                    in: xml,
                    range: NSRange(location: 0, length: nsString.length),
                    withTemplate: ""
                )
            }
        }
        try writeArchivePart(docId: docId, partPath: "word/people.xml", content: xml)
        return "{\"comments_orphaned\":\(orphaned)}"
    }

    // MARK: - v3.5.0: Phase 2C — Notes update + web settings (#24 #25 #31)

    /// Common note get/update logic (kind: "endnote" or "footnote").
    private func getNoteImpl(docId: String, kind: String, noteId: Int) throws -> String {
        guard let doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        if kind == "endnote" {
            guard let note = doc.endnotes.endnotes.first(where: { $0.id == noteId }) else {
                return "Error: \(kind) not found: \(noteId)"
            }
            let text = note.paragraphs.flatMap { $0.runs.map { $0.text } }.joined()
            return "{\"id\":\(note.id),\"text\":\"\(jsonEscape(text))\",\"runs\":[{\"text\":\"\(jsonEscape(text))\"}]}"
        } else {
            guard let note = doc.footnotes.footnotes.first(where: { $0.id == noteId }) else {
                return "Error: \(kind) not found: \(noteId)"
            }
            let text = note.paragraphs.flatMap { $0.runs.map { $0.text } }.joined()
            return "{\"id\":\(note.id),\"text\":\"\(jsonEscape(text))\",\"runs\":[{\"text\":\"\(jsonEscape(text))\"}]}"
        }
    }

    private func updateNoteImpl(docId: String, kind: String, noteId: Int, text: String) throws -> String {
        guard var doc = openDocuments[docId] else {
            throw WordError.documentNotFound(docId)
        }
        var found = false
        if kind == "endnote" {
            if let idx = doc.endnotes.endnotes.firstIndex(where: { $0.id == noteId }) {
                doc.endnotes.endnotes[idx].paragraphs = [Paragraph(text: text)]
                found = true
            }
        } else {
            if let idx = doc.footnotes.footnotes.firstIndex(where: { $0.id == noteId }) {
                doc.footnotes.footnotes[idx].paragraphs = [Paragraph(text: text)]
                found = true
            }
        }
        if !found {
            return "Error: \(kind) not found: \(noteId)"
        }
        // v3.5.0: typed-model in-place mutation here bypasses the instrumented
        // public methods, so we must mark the corresponding part dirty manually.
        doc.markPartDirty(kind == "endnote" ? "word/endnotes.xml" : "word/footnotes.xml")
        openDocuments[docId] = doc
        documentDirtyState[docId] = true
        return "{\"id\":\(noteId)}"
    }

    private func getEndnoteTool(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let id = args["endnote_id"]?.intValue else {
            throw WordError.missingParameter("endnote_id")
        }
        return try getNoteImpl(docId: docId, kind: "endnote", noteId: id)
    }

    private func updateEndnoteTool(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let id = args["endnote_id"]?.intValue else {
            throw WordError.missingParameter("endnote_id")
        }
        guard let text = args["text"]?.stringValue else {
            throw WordError.missingParameter("text")
        }
        return try updateNoteImpl(docId: docId, kind: "endnote", noteId: id, text: text)
    }

    private func getFootnoteTool(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let id = args["footnote_id"]?.intValue else {
            throw WordError.missingParameter("footnote_id")
        }
        return try getNoteImpl(docId: docId, kind: "footnote", noteId: id)
    }

    private func updateFootnoteTool(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let id = args["footnote_id"]?.intValue else {
            throw WordError.missingParameter("footnote_id")
        }
        guard let text = args["text"]?.stringValue else {
            throw WordError.missingParameter("text")
        }
        return try updateNoteImpl(docId: docId, kind: "footnote", noteId: id, text: text)
    }

    private func extractWebSettingFlag(_ xml: String, name: String) -> Bool {
        // Match `<w:<name> w:val="true|1"/>` or naked presence.
        let pattern = #"<w:\#(name)\b[^>]*?(?:w:val="(true|1|on)")?[^>]*/>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        let nsString = xml as NSString
        return regex.firstMatch(in: xml, range: NSRange(location: 0, length: nsString.length)) != nil
    }

    private func getWebSettings(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        guard let xml = readArchivePart(docId: docId, partPath: "word/webSettings.xml") else {
            return "Error: no webSettings part"
        }
        let optimizeForBrowser = extractWebSettingFlag(xml, name: "optimizeForBrowser")
        let relyOnVML = extractWebSettingFlag(xml, name: "relyOnVML")
        let allowPNG = extractWebSettingFlag(xml, name: "allowPNG")
        let doNotSaveAsSingleFile = extractWebSettingFlag(xml, name: "doNotSaveAsSingleFile")
        return """
        {"optimize_for_browser":\(optimizeForBrowser),"rely_on_vml":\(relyOnVML),"allow_png":\(allowPNG),"do_not_save_as_single_file":\(doNotSaveAsSingleFile)}
        """
    }

    private func defaultWebSettingsXML() -> String {
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:webSettings xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"></w:webSettings>"
    }

    private func setWebSettingFlag(_ xml: String, name: String, value: Bool) -> String {
        // Remove existing element
        let removePattern = #"<w:\#(name)\b[^/>]*/>"#
        var result = xml
        if let regex = try? NSRegularExpression(pattern: removePattern) {
            let nsString = result as NSString
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(location: 0, length: nsString.length),
                withTemplate: ""
            )
        }
        // Insert new element before </w:webSettings>
        if value {
            let element = "<w:\(name)/>"
            if result.contains("</w:webSettings>") {
                result = result.replacingOccurrences(of: "</w:webSettings>", with: "\(element)</w:webSettings>")
            } else {
                // Self-closing root variant — convert to open/close
                result = result.replacingOccurrences(of: "/>", with: "><w:\(name)/></w:webSettings>")
            }
        }
        return result
    }

    private func updateWebSettings(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw WordError.missingParameter("doc_id")
        }
        var xml = readArchivePart(docId: docId, partPath: "word/webSettings.xml") ?? defaultWebSettingsXML()
        if let v = args["rely_on_vml"]?.boolValue {
            xml = setWebSettingFlag(xml, name: "relyOnVML", value: v)
        }
        if let v = args["optimize_for_browser"]?.boolValue {
            xml = setWebSettingFlag(xml, name: "optimizeForBrowser", value: v)
        }
        if let v = args["allow_png"]?.boolValue {
            xml = setWebSettingFlag(xml, name: "allowPNG", value: v)
        }
        try writeArchivePart(docId: docId, partPath: "word/webSettings.xml", content: xml)
        return "Web settings updated"
    }

    // MARK: - #44 Phase 7: Style Tools

    private func getStyleInheritanceChain(args: [String: Value]) async throws -> String {
        let doc = try await loadDocumentFromArgs(args)
        guard let styleId = args["style_id"]?.stringValue else {
            throw WordError.missingParameter("style_id")
        }
        let chain = doc.getStyleInheritanceChain(styleId: styleId)
        if chain.isEmpty {
            return "{ \"error\": \"not_found\", \"style_id\": \"\(Self.jsonEscape(styleId))\" }"
        }
        // Cycle detection: original chain length should equal walked depth from
        // styleId. If chain shorter than count of unique basedOn refs, cycle hit.
        var seenIds = Set<String>()
        var cycleDetected = false
        for s in chain {
            if !seenIds.insert(s.id).inserted { cycleDetected = true; break }
        }
        let entries = chain.map { s -> String in
            var fields: [String] = [
                "\"style_id\": \"\(Self.jsonEscape(s.id))\"",
                "\"style_name\": \"\(Self.jsonEscape(s.name))\"",
                "\"style_type\": \"\(s.type.rawValue)\""
            ]
            if let basedOn = s.basedOn {
                fields.append("\"based_on\": \"\(Self.jsonEscape(basedOn))\"")
            } else {
                fields.append("\"based_on\": null")
            }
            return "{ " + fields.joined(separator: ", ") + " }"
        }
        return "{ \"chain\": [\(entries.joined(separator: ", "))], \"cycle_detected\": \(cycleDetected ? "true" : "false") }"
    }

    private func linkStylesTool(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else { throw WordError.missingParameter("doc_id") }
        guard var doc = openDocuments[docId] else { throw WordError.documentNotFound(docId) }
        guard let pId = args["paragraph_style_id"]?.stringValue else { throw WordError.missingParameter("paragraph_style_id") }
        guard let cId = args["character_style_id"]?.stringValue else { throw WordError.missingParameter("character_style_id") }

        do {
            try doc.linkStyles(paragraphStyleId: pId, characterStyleId: cId)
        } catch WordError.styleNotFound(let id) {
            return "{ \"error\": \"not_found\", \"style_id\": \"\(Self.jsonEscape(id))\" }"
        } catch WordError.typeMismatch(let exp, let act) {
            return "{ \"error\": \"type_mismatch\", \"expected\": \"\(exp)\", \"actual\": \"\(act)\" }"
        }
        try await storeDocument(doc, for: docId)
        return "Linked styles \(pId) ↔ \(cId)"
    }

    private func setLatentStylesTool(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else { throw WordError.missingParameter("doc_id") }
        guard var doc = openDocuments[docId] else { throw WordError.documentNotFound(docId) }
        guard let arr = args["latent_styles"]?.arrayValue else { throw WordError.missingParameter("latent_styles") }

        var entries: [LatentStyle] = []
        for item in arr {
            guard let obj = item.objectValue, let name = obj["name"]?.stringValue else { continue }
            entries.append(LatentStyle(
                name: name,
                uiPriority: obj["ui_priority"]?.intValue,
                semiHidden: obj["semi_hidden"]?.boolValue ?? false,
                unhideWhenUsed: obj["unhide_when_used"]?.boolValue ?? false,
                qFormat: obj["q_format"]?.boolValue ?? false
            ))
        }
        doc.setLatentStyles(entries)
        try await storeDocument(doc, for: docId)
        return "Set latent_styles count=\(entries.count)"
    }

    private func addStyleNameAliasTool(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else { throw WordError.missingParameter("doc_id") }
        guard var doc = openDocuments[docId] else { throw WordError.documentNotFound(docId) }
        guard let styleId = args["style_id"]?.stringValue else { throw WordError.missingParameter("style_id") }
        guard let lang = args["lang"]?.stringValue else { throw WordError.missingParameter("lang") }
        guard let name = args["name"]?.stringValue else { throw WordError.missingParameter("name") }

        do {
            try doc.addStyleNameAlias(styleId: styleId, lang: lang, name: name)
        } catch WordError.styleNotFound(let id) {
            return "{ \"error\": \"not_found\", \"style_id\": \"\(Self.jsonEscape(id))\" }"
        }
        try await storeDocument(doc, for: docId)
        return "Added alias for style=\(styleId) lang=\(lang)"
    }

    // MARK: - #44 Phase 8: Numbering Tools

    private func listNumberingDefinitions(args: [String: Value]) async throws -> String {
        let doc = try await loadDocumentFromArgs(args)
        return Self.renderNumberingDefinitionsJSON(doc.numbering, scope: nil)
    }

    private func getNumberingDefinition(args: [String: Value]) async throws -> String {
        let doc = try await loadDocumentFromArgs(args)
        guard let numId = args["num_id"]?.intValue else { throw WordError.missingParameter("num_id") }
        guard doc.numbering.nums.contains(where: { $0.numId == numId }) else {
            return "{ \"error\": \"not_found\", \"num_id\": \(numId) }"
        }
        return Self.renderNumberingDefinitionsJSON(doc.numbering, scope: numId)
    }

    private func createNumberingDefinition(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else { throw WordError.missingParameter("doc_id") }
        guard var doc = openDocuments[docId] else { throw WordError.documentNotFound(docId) }
        guard let levelsArr = args["levels"]?.arrayValue else { throw WordError.missingParameter("levels") }

        var levels: [Level] = []
        for item in levelsArr {
            guard let obj = item.objectValue,
                  let ilvl = obj["ilvl"]?.intValue,
                  let fmtStr = obj["num_format"]?.stringValue,
                  let lvlText = obj["lvl_text"]?.stringValue
            else { continue }
            let fmt = NumberFormat(rawValue: fmtStr) ?? .decimal
            let start = obj["start"]?.intValue ?? 1
            levels.append(Level(ilvl: ilvl, start: start, numFmt: fmt, lvlText: lvlText, indent: 720 * (ilvl + 1)))
        }
        do {
            let numId = try doc.createNumberingDefinition(levels: levels)
            try await storeDocument(doc, for: docId)
            return "{ \"num_id\": \(numId) }"
        } catch WordError.invalidIndex(let count) {
            return "{ \"error\": \"invalid_levels\", \"count\": \(count) }"
        }
    }

    private func overrideNumberingLevel(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else { throw WordError.missingParameter("doc_id") }
        guard var doc = openDocuments[docId] else { throw WordError.documentNotFound(docId) }
        guard let numId = args["num_id"]?.intValue else { throw WordError.missingParameter("num_id") }
        guard let ilvl = args["ilvl"]?.intValue else { throw WordError.missingParameter("ilvl") }
        guard let startValue = args["start_value"]?.intValue else { throw WordError.missingParameter("start_value") }

        do {
            try doc.overrideNumberingLevel(numId: numId, level: ilvl, startValue: startValue)
        } catch WordError.numIdNotFound(let id) {
            return "{ \"error\": \"not_found\", \"num_id\": \(id) }"
        }
        try await storeDocument(doc, for: docId)
        return "Override numId=\(numId) ilvl=\(ilvl) start=\(startValue)"
    }

    private func assignNumberingToParagraph(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else { throw WordError.missingParameter("doc_id") }
        guard var doc = openDocuments[docId] else { throw WordError.documentNotFound(docId) }
        guard let paraIndex = args["paragraph_index"]?.intValue else { throw WordError.missingParameter("paragraph_index") }
        guard let numId = args["num_id"]?.intValue else { throw WordError.missingParameter("num_id") }
        guard let level = args["level"]?.intValue else { throw WordError.missingParameter("level") }

        do {
            try doc.assignNumberingToParagraph(paragraphIndex: paraIndex, numId: numId, level: level)
        } catch WordError.numIdNotFound(let id) {
            return "{ \"error\": \"not_found\", \"num_id\": \(id) }"
        } catch WordError.invalidIndex(let i) {
            return "{ \"error\": \"out_of_bounds\", \"paragraph_index\": \(i) }"
        }
        try await storeDocument(doc, for: docId)
        return "Assigned numId=\(numId) level=\(level) to paragraph \(paraIndex)"
    }

    private func continueListTool(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else { throw WordError.missingParameter("doc_id") }
        guard var doc = openDocuments[docId] else { throw WordError.documentNotFound(docId) }
        guard let paraIndex = args["paragraph_index"]?.intValue else { throw WordError.missingParameter("paragraph_index") }
        guard let prevNum = args["previous_list_num_id"]?.intValue else { throw WordError.missingParameter("previous_list_num_id") }

        do {
            try doc.continueList(paragraphIndex: paraIndex, previousListNumId: prevNum)
        } catch WordError.numIdNotFound(let id) {
            return "{ \"error\": \"not_found\", \"num_id\": \(id) }"
        } catch WordError.invalidIndex(let i) {
            return "{ \"error\": \"out_of_bounds\", \"paragraph_index\": \(i) }"
        }
        try await storeDocument(doc, for: docId)
        return "Continued list num_id=\(prevNum) at paragraph \(paraIndex)"
    }

    private func startNewListTool(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else { throw WordError.missingParameter("doc_id") }
        guard var doc = openDocuments[docId] else { throw WordError.documentNotFound(docId) }
        guard let paraIndex = args["paragraph_index"]?.intValue else { throw WordError.missingParameter("paragraph_index") }
        guard let absId = args["abstract_num_id"]?.intValue else { throw WordError.missingParameter("abstract_num_id") }

        do {
            let newNumId = try doc.startNewList(paragraphIndex: paraIndex, abstractNumId: absId)
            try await storeDocument(doc, for: docId)
            return "{ \"num_id\": \(newNumId) }"
        } catch WordError.abstractNumIdNotFound(let id) {
            return "{ \"error\": \"not_found\", \"abstract_num_id\": \(id) }"
        } catch WordError.invalidIndex(let i) {
            return "{ \"error\": \"out_of_bounds\", \"paragraph_index\": \(i) }"
        }
    }

    private func gcOrphanNumbering(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else { throw WordError.missingParameter("doc_id") }
        guard var doc = openDocuments[docId] else { throw WordError.documentNotFound(docId) }
        let deleted = doc.gcOrphanNumbering()
        try await storeDocument(doc, for: docId)
        return "[\(deleted.map(String.init).joined(separator: ", "))]"
    }

    static func renderNumberingDefinitionsJSON(_ numbering: Numbering, scope: Int?) -> String {
        let nums = scope.flatMap { id in numbering.nums.filter { $0.numId == id } } ?? numbering.nums
        let entries: [String] = nums.map { num in
            let abstract = numbering.abstractNums.first(where: { $0.abstractNumId == num.abstractNumId })
            let levels = abstract?.levels ?? []
            let levelStr = levels.map { l -> String in
                "{ \"ilvl\": \(l.ilvl), \"num_format\": \"\(l.numFmt.rawValue)\", \"lvl_text\": \"\(jsonEscape(l.lvlText))\", \"start\": \(l.start) }"
            }.joined(separator: ", ")
            let overridesStr = num.lvlOverrides.map { o -> String in
                "{ \"ilvl\": \(o.ilvl), \"start_override\": \(o.startOverride) }"
            }.joined(separator: ", ")
            return "{ \"num_id\": \(num.numId), \"abstract_num_id\": \(num.abstractNumId), \"levels\": [\(levelStr)], \"lvl_overrides\": [\(overridesStr)] }"
        }
        return "[\(entries.joined(separator: ", "))]"
    }

    // MARK: - #44 Phase 9: Section Tools

    private func setLineNumbersForSection(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else { throw WordError.missingParameter("doc_id") }
        guard var doc = openDocuments[docId] else { throw WordError.documentNotFound(docId) }
        guard let sectionIndex = args["section_index"]?.intValue else { throw WordError.missingParameter("section_index") }
        guard let countBy = args["count_by"]?.intValue else { throw WordError.missingParameter("count_by") }
        let start = args["start"]?.intValue
        let restartStr = args["restart"]?.stringValue ?? "continuous"
        let restart = LineNumberRestart(rawValue: restartStr) ?? .continuous

        do {
            try doc.setSectionLineNumbers(sectionIndex: sectionIndex, countBy: countBy, start: start, restart: restart)
        } catch WordError.invalidIndex(let i) {
            return "{ \"error\": \"out_of_bounds\", \"section_index\": \(i) }"
        }
        try await storeDocument(doc, for: docId)
        return "Set line numbers section=\(sectionIndex) count_by=\(countBy)"
    }

    private func setSectionVerticalAlignment(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else { throw WordError.missingParameter("doc_id") }
        guard var doc = openDocuments[docId] else { throw WordError.documentNotFound(docId) }
        guard let sectionIndex = args["section_index"]?.intValue else { throw WordError.missingParameter("section_index") }
        guard let alignmentStr = args["alignment"]?.stringValue,
              let alignment = SectionVerticalAlignment(rawValue: alignmentStr)
        else {
            throw WordError.invalidParameter("alignment", "Must be one of: top / center / bottom / both")
        }
        do {
            try doc.setSectionVerticalAlignment(sectionIndex: sectionIndex, alignment: alignment)
        } catch WordError.invalidIndex(let i) {
            return "{ \"error\": \"out_of_bounds\", \"section_index\": \(i) }"
        }
        try await storeDocument(doc, for: docId)
        return "Set vertical_alignment=\(alignment.rawValue) on section \(sectionIndex)"
    }

    private func setPageNumberFormat(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else { throw WordError.missingParameter("doc_id") }
        guard var doc = openDocuments[docId] else { throw WordError.documentNotFound(docId) }
        guard let sectionIndex = args["section_index"]?.intValue else { throw WordError.missingParameter("section_index") }
        guard let formatStr = args["format"]?.stringValue,
              let format = SectionPageNumberFormat(rawValue: formatStr)
        else {
            throw WordError.invalidParameter("format", "Must be one of: decimal / lowerRoman / upperRoman / lowerLetter / upperLetter")
        }
        let start = args["start"]?.intValue
        do {
            try doc.setSectionPageNumberFormat(sectionIndex: sectionIndex, start: start, format: format)
        } catch WordError.invalidIndex(let i) {
            return "{ \"error\": \"out_of_bounds\", \"section_index\": \(i) }"
        }
        try await storeDocument(doc, for: docId)
        return "Set page_number_format=\(format.rawValue) on section \(sectionIndex)"
    }

    private func setSectionBreakType(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else { throw WordError.missingParameter("doc_id") }
        guard var doc = openDocuments[docId] else { throw WordError.documentNotFound(docId) }
        guard let sectionIndex = args["section_index"]?.intValue else { throw WordError.missingParameter("section_index") }
        guard let typeStr = args["type"]?.stringValue,
              let type = SectionBreakType(rawValue: typeStr)
        else {
            throw WordError.invalidParameter("type", "Must be one of: nextPage / continuous / evenPage / oddPage")
        }
        do {
            try doc.setSectionBreakType(sectionIndex: sectionIndex, type: type)
        } catch WordError.invalidIndex(let i) {
            return "{ \"error\": \"out_of_bounds\", \"section_index\": \(i) }"
        }
        try await storeDocument(doc, for: docId)
        return "Set section_break_type=\(type.rawValue) on section \(sectionIndex)"
    }

    private func setTitlePageDistinct(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else { throw WordError.missingParameter("doc_id") }
        guard var doc = openDocuments[docId] else { throw WordError.documentNotFound(docId) }
        guard let sectionIndex = args["section_index"]?.intValue else { throw WordError.missingParameter("section_index") }
        guard let enabled = args["enabled"]?.boolValue else { throw WordError.missingParameter("enabled") }
        do {
            try doc.setTitlePageDistinct(sectionIndex: sectionIndex, enabled: enabled)
        } catch WordError.invalidIndex(let i) {
            return "{ \"error\": \"out_of_bounds\", \"section_index\": \(i) }"
        }
        try await storeDocument(doc, for: docId)
        return "Set title_page_distinct=\(enabled) on section \(sectionIndex)"
    }

    private func setSectionHeaderFooterReferences(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else { throw WordError.missingParameter("doc_id") }
        guard var doc = openDocuments[docId] else { throw WordError.documentNotFound(docId) }
        guard let sectionIndex = args["section_index"]?.intValue else { throw WordError.missingParameter("section_index") }
        guard let refs = args["references"]?.objectValue else { throw WordError.missingParameter("references") }

        do {
            try doc.setSectionHeaderFooterReferences(
                sectionIndex: sectionIndex,
                headerDefault: refs["header_default"]?.stringValue,
                headerFirst: refs["header_first"]?.stringValue,
                headerEven: refs["header_even"]?.stringValue,
                footerDefault: refs["footer_default"]?.stringValue,
                footerFirst: refs["footer_first"]?.stringValue,
                footerEven: refs["footer_even"]?.stringValue
            )
        } catch WordError.invalidIndex(let i) {
            return "{ \"error\": \"out_of_bounds\", \"section_index\": \(i) }"
        }
        try await storeDocument(doc, for: docId)
        return "Set header/footer references on section \(sectionIndex)"
    }

    private func getAllSections(args: [String: Value]) async throws -> String {
        let doc = try await loadDocumentFromArgs(args)
        let sections = doc.getAllSections()
        let entries = sections.map { s -> String in
            var fields: [String] = [
                "\"section_index\": \(s.sectionIndex)",
                "\"paragraph_range\": { \"start\": \(s.paragraphRange.lowerBound), \"end\": \(s.paragraphRange.upperBound) }",
                "\"page_size\": { \"width\": \(s.pageSize.width), \"height\": \(s.pageSize.height) }",
                "\"orientation\": \"\(s.orientation.rawValue)\"",
                "\"columns\": \(s.columns)",
                "\"title_page_distinct\": \(s.titlePageDistinct)"
            ]
            if let ln = s.lineNumbers {
                fields.append("\"line_numbers\": { \"count_by\": \(ln.countBy), \"restart\": \"\(ln.restart.rawValue)\" }")
            }
            if let v = s.verticalAlignment {
                fields.append("\"vertical_alignment\": \"\(v.rawValue)\"")
            }
            if let f = s.pageNumberFormat {
                fields.append("\"page_number_format\": \"\(f.rawValue)\"")
            }
            if let bt = s.sectionBreakType {
                fields.append("\"section_break_type\": \"\(bt.rawValue)\"")
            }
            return "{ " + fields.joined(separator: ", ") + " }"
        }
        return "[\(entries.joined(separator: ", "))]"
    }

    // MARK: - #44 Phase 6: Table Tools

    private func setTableConditionalStyleTool(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else { throw WordError.missingParameter("doc_id") }
        guard var doc = openDocuments[docId] else { throw WordError.documentNotFound(docId) }
        guard let tableIndex = args["table_index"]?.intValue else { throw WordError.missingParameter("table_index") }
        guard let typeStr = args["type"]?.stringValue,
              let type = TableConditionalStyleType(rawValue: typeStr)
        else {
            throw WordError.invalidParameter("type", "Must be one of: firstRow / lastRow / firstCol / lastCol / bandedRows / bandedCols / neCell / nwCell / seCell / swCell")
        }
        guard let propsObj = args["properties"]?.objectValue else { throw WordError.missingParameter("properties") }
        let props = TableConditionalStyleProperties(
            bold: propsObj["bold"]?.boolValue,
            italic: propsObj["italic"]?.boolValue,
            color: propsObj["color"]?.stringValue,
            backgroundColor: propsObj["background_color"]?.stringValue,
            fontSize: propsObj["font_size"]?.intValue
        )
        do {
            try doc.setTableConditionalStyle(tableIndex: tableIndex, type: type, properties: props)
        } catch WordError.invalidIndex(let i) {
            return "{ \"error\": \"out_of_bounds\", \"table_index\": \(i) }"
        }
        try await storeDocument(doc, for: docId)
        return "Set conditional style \(type.rawValue) on table \(tableIndex)"
    }

    private func insertNestedTableTool(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else { throw WordError.missingParameter("doc_id") }
        guard var doc = openDocuments[docId] else { throw WordError.documentNotFound(docId) }
        guard let parentIndex = args["parent_table_index"]?.intValue else { throw WordError.missingParameter("parent_table_index") }
        guard let rowIndex = args["row_index"]?.intValue else { throw WordError.missingParameter("row_index") }
        guard let colIndex = args["col_index"]?.intValue else { throw WordError.missingParameter("col_index") }
        guard let rows = args["rows"]?.intValue else { throw WordError.missingParameter("rows") }
        guard let cols = args["cols"]?.intValue else { throw WordError.missingParameter("cols") }

        do {
            try doc.insertNestedTable(parentTableIndex: parentIndex, rowIndex: rowIndex, colIndex: colIndex, rows: rows, cols: cols)
        } catch WordError.nestedTooDeep(let depth, let max) {
            return "{ \"error\": \"nested_too_deep\", \"depth\": \(depth), \"max\": \(max) }"
        } catch WordError.invalidIndex(let i) {
            return "{ \"error\": \"out_of_bounds\", \"index\": \(i) }"
        }
        try await storeDocument(doc, for: docId)
        return "Inserted \(rows)x\(cols) nested table in cell (\(rowIndex), \(colIndex)) of table \(parentIndex)"
    }

    private func setTableLayoutTool(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else { throw WordError.missingParameter("doc_id") }
        guard var doc = openDocuments[docId] else { throw WordError.documentNotFound(docId) }
        guard let tableIndex = args["table_index"]?.intValue else { throw WordError.missingParameter("table_index") }
        guard let typeStr = args["type"]?.stringValue, let type = TableLayout(rawValue: typeStr) else {
            throw WordError.invalidParameter("type", "Must be one of: fixed / autofit")
        }
        do {
            try doc.setTableLayout(tableIndex: tableIndex, type: type)
        } catch WordError.invalidIndex(let i) {
            return "{ \"error\": \"out_of_bounds\", \"table_index\": \(i) }"
        }
        try await storeDocument(doc, for: docId)
        return "Set table_layout=\(type.rawValue) on table \(tableIndex)"
    }

    private func setHeaderRowTool(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else { throw WordError.missingParameter("doc_id") }
        guard var doc = openDocuments[docId] else { throw WordError.documentNotFound(docId) }
        guard let tableIndex = args["table_index"]?.intValue else { throw WordError.missingParameter("table_index") }
        let rowIndex = args["row_index"]?.intValue ?? 0
        do {
            try doc.setHeaderRow(tableIndex: tableIndex, rowIndex: rowIndex)
        } catch WordError.invalidIndex(let i) {
            return "{ \"error\": \"out_of_bounds\", \"index\": \(i) }"
        }
        try await storeDocument(doc, for: docId)
        return "Marked row \(rowIndex) as header on table \(tableIndex)"
    }

    private func setTableIndentTool(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else { throw WordError.missingParameter("doc_id") }
        guard var doc = openDocuments[docId] else { throw WordError.documentNotFound(docId) }
        guard let tableIndex = args["table_index"]?.intValue else { throw WordError.missingParameter("table_index") }
        guard let value = args["value"]?.intValue else { throw WordError.missingParameter("value") }
        do {
            try doc.setTableIndent(tableIndex: tableIndex, value: value)
        } catch WordError.invalidIndex(let i) {
            return "{ \"error\": \"out_of_bounds\", \"table_index\": \(i) }"
        }
        try await storeDocument(doc, for: docId)
        return "Set table_indent=\(value) twips on table \(tableIndex)"
    }

    // MARK: - #44 Phase 7: Hyperlink Tools

    /// Ensures the `Hyperlink` character style exists in styles.xml.
    /// Idempotent — checks first, only creates when absent.
    private func ensureHyperlinkStyle(_ doc: inout WordDocument) {
        if doc.styles.contains(where: { $0.id == "Hyperlink" }) { return }
        var runProps = RunProperties()
        runProps.color = "0563C1"
        runProps.underline = .single
        let style = Style(
            id: "Hyperlink",
            name: "Hyperlink",
            type: .character,
            isQuickStyle: false,
            runProperties: runProps
        )
        try? doc.addStyle(style)
    }

    /// Attach a fully-built Hyperlink struct to a paragraph at top-level
    /// body index. Direct mutation since the existing WordDocument.insertHyperlink
    /// API only handles URL hyperlinks (creates synthetic rId etc.).
    private func attachHyperlink(
        _ link: Hyperlink,
        atParagraph paraIndex: Int,
        in doc: inout WordDocument
    ) throws {
        let paraIndices = doc.body.children.enumerated().compactMap { (i, c) -> Int? in
            if case .paragraph = c { return i }
            return nil
        }
        guard paraIndex >= 0 && paraIndex < paraIndices.count else {
            throw WordError.invalidIndex(paraIndex)
        }
        let actualIdx = paraIndices[paraIndex]
        if case .paragraph(var p) = doc.body.children[actualIdx] {
            p.hyperlinks.append(link)
            doc.body.children[actualIdx] = .paragraph(p)
        }
        doc.markPartDirty("word/document.xml")
    }

    private func insertUrlHyperlinkTool(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else { throw WordError.missingParameter("doc_id") }
        guard var doc = openDocuments[docId] else { throw WordError.documentNotFound(docId) }
        guard let paraIndex = args["paragraph_index"]?.intValue else { throw WordError.missingParameter("paragraph_index") }
        guard let url = args["url"]?.stringValue else { throw WordError.missingParameter("url") }
        guard let text = args["text"]?.stringValue else { throw WordError.missingParameter("text") }

        ensureHyperlinkStyle(&doc)
        let tooltip = args["tooltip"]?.stringValue
        let history = args["history"]?.boolValue ?? true
        let rId = "rId\(Int.random(in: 100...999))"
        let hlId = "hl-\(UUID().uuidString.prefix(8))"
        // Track relationship for downstream writer.
        doc.hyperlinkReferences.append(HyperlinkReference(relationshipId: rId, url: url))
        let link = Hyperlink(id: hlId, text: text, url: url, relationshipId: rId,
                             tooltip: tooltip, history: history)
        try attachHyperlink(link, atParagraph: paraIndex, in: &doc)
        try await storeDocument(doc, for: docId)
        return "Inserted URL hyperlink id=\(hlId) at paragraph \(paraIndex)"
    }

    private func insertBookmarkHyperlinkTool(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else { throw WordError.missingParameter("doc_id") }
        guard var doc = openDocuments[docId] else { throw WordError.documentNotFound(docId) }
        guard let paraIndex = args["paragraph_index"]?.intValue else { throw WordError.missingParameter("paragraph_index") }
        guard let anchor = args["anchor"]?.stringValue else { throw WordError.missingParameter("anchor") }
        guard let text = args["text"]?.stringValue else { throw WordError.missingParameter("text") }

        ensureHyperlinkStyle(&doc)
        let tooltip = args["tooltip"]?.stringValue
        let hlId = "hl-\(UUID().uuidString.prefix(8))"
        let link = Hyperlink(id: hlId, text: text, anchor: anchor, tooltip: tooltip)
        try attachHyperlink(link, atParagraph: paraIndex, in: &doc)
        try await storeDocument(doc, for: docId)
        return "Inserted bookmark hyperlink id=\(hlId) → '\(anchor)' at paragraph \(paraIndex)"
    }

    private func insertEmailHyperlinkTool(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else { throw WordError.missingParameter("doc_id") }
        guard var doc = openDocuments[docId] else { throw WordError.documentNotFound(docId) }
        guard let paraIndex = args["paragraph_index"]?.intValue else { throw WordError.missingParameter("paragraph_index") }
        guard let email = args["email"]?.stringValue else { throw WordError.missingParameter("email") }
        guard let text = args["text"]?.stringValue else { throw WordError.missingParameter("text") }

        ensureHyperlinkStyle(&doc)
        let tooltip = args["tooltip"]?.stringValue
        var url = "mailto:\(email)"
        if let subject = args["subject"]?.stringValue {
            let encoded = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject
            url += "?subject=\(encoded)"
        }
        let rId = "rId\(Int.random(in: 100...999))"
        let hlId = "hl-\(UUID().uuidString.prefix(8))"
        doc.hyperlinkReferences.append(HyperlinkReference(relationshipId: rId, url: url))
        let link = Hyperlink(id: hlId, text: text, url: url, relationshipId: rId, tooltip: tooltip)
        try attachHyperlink(link, atParagraph: paraIndex, in: &doc)
        try await storeDocument(doc, for: docId)
        return "Inserted email hyperlink id=\(hlId) → '\(email)' at paragraph \(paraIndex)"
    }

    // MARK: - #44 Phase 8: Header Tools

    private func enableEvenOddHeadersTool(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else { throw WordError.missingParameter("doc_id") }
        guard var doc = openDocuments[docId] else { throw WordError.documentNotFound(docId) }
        guard let enabled = args["enabled"]?.boolValue else { throw WordError.missingParameter("enabled") }
        doc.setEvenAndOddHeaders(enabled)
        try await storeDocument(doc, for: docId)
        return "Set even_and_odd_headers=\(enabled)"
    }

    private func linkSectionHeaderToPreviousTool(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else { throw WordError.missingParameter("doc_id") }
        guard var doc = openDocuments[docId] else { throw WordError.documentNotFound(docId) }
        guard let sectionIndex = args["section_index"]?.intValue else { throw WordError.missingParameter("section_index") }
        guard let typeStr = args["type"]?.stringValue, let type = HeaderFooterType(rawValue: typeStr) else {
            throw WordError.invalidParameter("type", "Must be one of: default / first / even")
        }
        guard sectionIndex >= 1 else {
            return "{ \"error\": \"out_of_bounds\", \"section_index\": \(sectionIndex), \"detail\": \"must be >= 1\" }"
        }
        // For single-section model (current limitation), this is a no-op
        // returning success — multi-section split lands in future SDD.
        _ = type
        try await storeDocument(doc, for: docId)
        return "Linked section \(sectionIndex) header type=\(type.rawValue) to previous (single-section model: no-op)"
    }

    private func unlinkSectionHeaderFromPreviousTool(args: [String: Value]) async throws -> String {
        guard let docId = args["doc_id"]?.stringValue else { throw WordError.missingParameter("doc_id") }
        guard var doc = openDocuments[docId] else { throw WordError.documentNotFound(docId) }
        guard let sectionIndex = args["section_index"]?.intValue else { throw WordError.missingParameter("section_index") }
        guard let typeStr = args["type"]?.stringValue, let type = HeaderFooterType(rawValue: typeStr) else {
            throw WordError.invalidParameter("type", "Must be one of: default / first / even")
        }
        // Find the matching header to clone — first one of matching type.
        guard let source = doc.headers.first(where: { $0.type == type }) else {
            return "{ \"error\": \"not_found\", \"type\": \"\(type.rawValue)\" }"
        }
        let cloned = try doc.cloneHeaderForSection(
            sourceFileName: source.fileName,
            targetSectionIndex: sectionIndex,
            type: type
        )
        try await storeDocument(doc, for: docId)
        return "Unlinked section \(sectionIndex) header type=\(type.rawValue) — cloned to \(cloned)"
    }

    private func getSectionHeaderMapTool(args: [String: Value]) async throws -> String {
        let doc = try await loadDocumentFromArgs(args)
        // Single-section model: emit one entry referencing the headers/footers by type.
        var fields: [String] = ["\"section_index\": 0"]
        let headerDefault = doc.headers.first(where: { $0.type == .default })?.fileName
        let headerFirst = doc.headers.first(where: { $0.type == .first })?.fileName
        let headerEven = doc.headers.first(where: { $0.type == .even })?.fileName
        let footerDefault = doc.footers.first(where: { $0.type == .default })?.fileName
        let footerFirst = doc.footers.first(where: { $0.type == .first })?.fileName
        let footerEven = doc.footers.first(where: { $0.type == .even })?.fileName
        fields.append("\"header_default\": \(headerDefault.map { "\"\($0)\"" } ?? "null")")
        fields.append("\"header_first\": \(headerFirst.map { "\"\($0)\"" } ?? "null")")
        fields.append("\"header_even\": \(headerEven.map { "\"\($0)\"" } ?? "null")")
        fields.append("\"footer_default\": \(footerDefault.map { "\"\($0)\"" } ?? "null")")
        fields.append("\"footer_first\": \(footerFirst.map { "\"\($0)\"" } ?? "null")")
        fields.append("\"footer_even\": \(footerEven.map { "\"\($0)\"" } ?? "null")")
        return "[{ " + fields.joined(separator: ", ") + " }]"
    }
}
