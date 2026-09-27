import Foundation
import Logging
import MCP

/// R2 (#116 follow-up, `review-cwm450.md` finding C1) — a `Transport`
/// wrapper that rejects excessively nested JSON-RPC messages BEFORE handing
/// them to swift-sdk's decoder.
///
/// ## Why this exists — the root cause is NOT in this repo
///
/// #116's original fix added a recursion-depth cap to `parseMathComponent`
/// (`insert_equation`'s `components:` JSON-tree parser, see that function's
/// own doc comment in `Server.swift`). An independent review proved with a
/// real release binary over real stdio JSON-RPC (`drive_mcp.py`, newline-
/// delimited JSON-RPC over a subprocess) that this did NOT close the
/// vulnerability #116 described: a sufficiently deep JSON argument crashes
/// the whole server process with SIGBUS **before `parseMathComponent` — or
/// any che-word-mcp handler code at all — ever runs**, because swift-sdk's
/// own `Value.init(from: Decoder)` (`Sources/MCP/Base/Value.swift` inside
/// the `swift-sdk` dependency, NOT this repo) and its request re-encoding
/// on dispatch (`TypedRequestHandler.callAsFunction` → `JSONEncoder.encode`)
/// both recurse into `[Value]`/`[String: Value]` with no depth limit of
/// their own. The crash is reachable via ANY tool call (not just
/// `insert_equation`) carrying a deep enough JSON argument anywhere in its
/// arguments — it has nothing to do with which tool or handler is named.
///
/// Empirically (real `CheWordMCP` release binary, real stdio, this repo's
/// own `insert_equation`/`components:` argument shape as the payload): the
/// process survives at raw JSON structural nesting depth 178 and dies at
/// 180 — see `wave1-crash.md`'s "R2" section for the probe transcript this
/// was measured with. Because the vulnerable code lives in the `swift-sdk`
/// DEPENDENCY, `parseMathComponent`'s own guard cannot fix this — by the
/// time it runs, the `Value` tree has ALREADY survived decode (or already
/// crashed trying to). The fix has to sit in front of that decode.
///
/// ## What this does
///
/// Wraps an underlying `Transport` (in production, `StdioTransport`). Once
/// connected, a background task consumes the wrapped transport's raw
/// message stream and scans every message with a linear, non-recursive
/// byte scanner (`scanJSONRPCEnvelope`) BEFORE it is ever handed to this
/// wrapper's own outward-facing stream (the one swift-sdk actually
/// consumes via `receive()`). A message whose structural nesting exceeds
/// `maxRawJSONDepth` is never forwarded — instead, this wrapper sends a
/// JSON-RPC error response directly back over the underlying transport
/// (bypassing swift-sdk's decode/dispatch entirely for that one message)
/// and continues to the next message. The server process never sees the
/// oversized message reach a decoder, does not crash, and keeps serving
/// every other in-flight session.
///
/// ## Why a byte scanner, not `Value`/`JSONSerialization`/any tree parser
///
/// Any general-purpose JSON parser that builds a tree — `JSONSerialization
/// .jsonObject`, `Value.init(from:)` itself, a hand-rolled recursive
/// descent parser — is exactly the class of thing being guarded against:
/// running one on attacker-controlled deep input reintroduces the same
/// stack-overflow risk one layer up, just with different code doing the
/// recursing. `scanJSONRPCEnvelope` never builds a tree and never
/// recurses: it is a single forward pass over the raw bytes with one
/// integer depth counter, safe to run on input of any nesting depth.
///
/// ## Relationship to `maxMathComponentDepth`
///
/// See `WordMCPServer.maxMathComponentDepth`'s own doc comment (near
/// `parseMathComponent` in `Server.swift`) for the measured numeric
/// relationship between this transport-level cap (raw `{`/`[` bracket
/// depth counted across the WHOLE JSON-RPC message, envelope included) and
/// that handler-level cap (logical `MathComponent` tree levels, counted
/// only within the `components:` argument's own value).
actor DepthLimitedTransport: Transport {
    let logger: Logger

    private let wrapped: any Transport
    private let maxRawJSONDepth: Int
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var pumpTask: Task<Void, Never>?

    /// #242 R2 (independent review, `review-cwm-misc.md` finding #242-1,
    /// HIGH) — a batch containing both over-depth/invalid-shape items and
    /// legal items used to produce TWO independent wire messages: the
    /// illegal items' error array, sent immediately by this wrapper, and
    /// the legal sub-batch's response array, sent later by swift-sdk's own
    /// `handleBatch` via `send(_:)` — violating JSON-RPC 2.0's "respond
    /// with an Array" (singular) contract for one batch request.
    ///
    /// Fix: don't send the illegal items' responses immediately when a
    /// legal sub-batch is ALSO being forwarded (and is expected to
    /// eventually produce a response). Stage them here, keyed by the set
    /// of ids that forwarded sub-batch's own request items (not
    /// notifications) are expected to answer. `send(_:)` checks this
    /// dictionary on every outgoing message; when an outgoing array's own
    /// id set exactly matches a staged entry, the staged responses are
    /// merged into that SAME array before it goes out — one message,
    /// covering every id from the original batch.
    ///
    /// **Correctness precondition (documented, not new)**: this only
    /// works if the caller does not reuse an id across batches
    /// concurrently in flight — exactly the id-uniqueness JSON-RPC 2.0
    /// itself already requires of in-flight requests. Two batches whose
    /// legal sub-batches happen to share the exact same id set (only
    /// possible if the caller violates that requirement) could have their
    /// staged entries cross-matched. Not enforced defensively here because
    /// enforcing it would mean tracking every id ever seen for the life of
    /// the connection — out of scope for a depth-limit guard.
    ///
    /// **Technical-debt note**: this mechanism's correctness depends on an
    /// implementation detail of the `swift-sdk` dependency that is not
    /// part of its own documented API contract — that `Server.handleBatch`
    /// calls `Transport.send(_:)` (this actor) exactly once, with exactly
    /// one JSON array containing one `Response` per request item (no
    /// partial/streamed sends). If a future `swift-sdk` version changes
    /// `handleBatch` to send per-item or to skip `send(_:)` for some other
    /// reason, staged entries could go unmatched — see `send(_:)`'s own
    /// safety net (the "no legal request items" / "all elements
    /// non-object-or-over-depth" cases send immediately rather than
    /// deferring) for the one mitigation already in place; there is no
    /// general timeout-based flush (a short one would risk misfiring
    /// during a legitimately slow tool call inside a batch, degrading the
    /// COMMON case from one message to two just to protect an already-rare
    /// edge case — worse trade than leaving the documented dependency).
    private var pendingIllegalByIDSet: [Set<String>: [String]] = [:]

    /// - Parameters:
    ///   - wrapped: The underlying transport to guard. Production callers
    ///     pass `StdioTransport()`; tests pass a mock conforming to
    ///     `Transport` to exercise this wrapper without real stdio.
    ///   - maxRawJSONDepth: Messages whose structural nesting exceeds this
    ///     are rejected before decode. See the type's own doc comment for
    ///     the empirical basis of the value `WordMCPServer` passes.
    ///   - logger: Optional; defaults to a no-op logger, matching
    ///     `StdioTransport`'s own default.
    init(wrapping wrapped: any Transport, maxRawJSONDepth: Int, logger: Logger? = nil) {
        self.wrapped = wrapped
        self.maxRawJSONDepth = maxRawJSONDepth
        self.logger =
            logger
            ?? Logger(
                label: "mcp.transport.depth-limited",
                factory: { _ in SwiftLogNoOpLogHandler() })

        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        self.messageStream = AsyncThrowingStream { continuation = $0 }
        self.messageContinuation = continuation
    }

    func connect() async throws {
        try await wrapped.connect()

        // Capture Sendable locals (not `self`) before spawning the pump
        // task — `wrapped` (an actor reference, inherently Sendable),
        // `maxRawJSONDepth` (`Int`), `logger` (`Logger`, Sendable), and the
        // continuation (documented Sendable by `AsyncThrowingStream`) are
        // all safe to hand into a detached `Task` without crossing back
        // into THIS actor's isolation on every message.
        let inboundStream = await wrapped.receive()
        let wrapped = self.wrapped
        let cap = self.maxRawJSONDepth
        let logger = self.logger
        let continuation = self.messageContinuation

        pumpTask = Task { [weak self] in
            do {
                for try await message in inboundStream {
                    let scan = DepthLimitedTransport.scanJSONRPCEnvelope(message)
                    if scan.maxDepth > cap {
                        // #242: `scan.maxDepth` is the WHOLE message's max
                        // bracket depth, envelope included. For a JSON-RPC
                        // batch (top-level `[...]`), that is always at least
                        // 1 deeper than any individual item's own depth
                        // (the wrapping array itself), so a batch whose
                        // items are all individually fine can still land
                        // here. Try to salvage per-item before falling back
                        // to rejecting the whole message: split the batch's
                        // top-level elements and re-scan each on its own —
                        // an element's own depth (and its own "id", now
                        // correctly read at THAT element's depth 1, not the
                        // whole message's depth 2) is what actually matters
                        // per JSON-RPC batch semantics.
                        if let elements = DepthLimitedTransport.splitTopLevelBatchElements(message),
                            !elements.isEmpty
                        {
                            var legalElements: [Data] = []
                            var directResponses: [String] = []
                            for element in elements {
                                // #242 R2: a non-object item (bare number,
                                // string, array, true/false/null) can never
                                // decode as a `Server.Batch.Item`, and per
                                // swift-sdk's `Server.Batch.init(from:)`
                                // any ONE item's decode failure fails the
                                // WHOLE reconstructed batch's decode — so a
                                // stray non-object item left in
                                // `legalElements` would poison every
                                // genuinely legal sibling forwarded
                                // alongside it (and permanently strand any
                                // deferred entry staged against that
                                // sub-batch's expected ids, since swift-sdk
                                // would never call `send(_:)` with the
                                // expected array shape for it). Route it
                                // into the same directly-answered bucket as
                                // an over-depth item instead — see
                                // `isJSONObjectShaped`'s own doc comment.
                                guard DepthLimitedTransport.isJSONObjectShaped(element) else {
                                    logger.warning(
                                        "Rejected non-object JSON-RPC batch item before decode",
                                        metadata: ["byte_count": "\(element.count)"]
                                    )
                                    directResponses.append(DepthLimitedTransport.invalidBatchItemErrorResponse())
                                    continue
                                }
                                let elementScan = DepthLimitedTransport.scanJSONRPCEnvelope(element)
                                if elementScan.maxDepth > cap {
                                    logger.warning(
                                        "Rejected over-depth JSON-RPC batch item before decode",
                                        metadata: [
                                            "observed_depth": "\(elementScan.maxDepth)",
                                            "max_depth": "\(cap)",
                                            "byte_count": "\(element.count)",
                                        ]
                                    )
                                    directResponses.append(
                                        DepthLimitedTransport.depthLimitErrorResponse(
                                            idToken: elementScan.topLevelIDToken,
                                            observedDepth: elementScan.maxDepth, maxDepth: cap
                                        )
                                    )
                                } else {
                                    legalElements.append(element)
                                }
                            }
                            // Illegal/invalid items: named by their own id
                            // (never forwarded to decode), packaged as one
                            // JSON array. #242 R2: WHETHER that array is
                            // sent right now, or merged into the legal
                            // sub-batch's own later response, depends on
                            // whether anything will actually call
                            // `send(_:)` on this batch's behalf — see each
                            // branch below.
                            if !directResponses.isEmpty {
                                if legalElements.isEmpty {
                                    // No sub-batch is being forwarded at
                                    // all — nothing will ever call
                                    // `send(_:)` for this batch. This
                                    // direct array IS the batch's whole
                                    // (single) response.
                                    let combined = "[" + directResponses.joined(separator: ",") + "]"
                                    try? await wrapped.send(Data(combined.utf8))
                                } else {
                                    let expectedIDs = Set(
                                        legalElements.compactMap {
                                            DepthLimitedTransport.scanJSONRPCEnvelope($0).topLevelIDToken
                                        })
                                    if expectedIDs.isEmpty {
                                        // Every legal element is a
                                        // notification (no "id" at all) —
                                        // swift-sdk's `handleBatch` calls
                                        // `handleMessage` for each and its
                                        // own `responses` array stays
                                        // empty, so it never calls
                                        // `connection.send(...)` for this
                                        // sub-batch. Deferring would wait
                                        // for a `send(_:)` that will never
                                        // come — send now instead.
                                        let combined = "[" + directResponses.joined(separator: ",") + "]"
                                        try? await wrapped.send(Data(combined.utf8))
                                    } else if let self {
                                        // Defer — see `pendingIllegalByIDSet`'s
                                        // own doc comment and `send(_:)`'s
                                        // merge logic.
                                        await self.stagePendingIllegal(ids: expectedIDs, responses: directResponses)
                                    } else {
                                        // Transport already torn down —
                                        // best effort, matches this file's
                                        // existing `try?`-everywhere
                                        // philosophy for a gone transport.
                                        let combined = "[" + directResponses.joined(separator: ",") + "]"
                                        try? await wrapped.send(Data(combined.utf8))
                                    }
                                }
                            }
                            // Legal items: reassembled into a smaller batch
                            // and forwarded on to swift-sdk's own decode +
                            // `handleBatch`, which already produces a
                            // correct response array for a batch whose
                            // items are all within its own depth limits —
                            // this is not reimplementing batch dispatch,
                            // only removing the over-depth items before
                            // swift-sdk ever sees them.
                            if !legalElements.isEmpty {
                                let joined =
                                    "["
                                    + legalElements.map { String(decoding: $0, as: UTF8.self) }
                                        .joined(separator: ",") + "]"
                                continuation.yield(Data(joined.utf8))
                            }
                            continue
                        }

                        logger.warning(
                            "Rejected over-depth JSON-RPC message before decode",
                            metadata: [
                                "observed_depth": "\(scan.maxDepth)",
                                "max_depth": "\(cap)",
                                "byte_count": "\(message.count)",
                            ]
                        )
                        let response = DepthLimitedTransport.depthLimitErrorResponse(
                            idToken: scan.topLevelIDToken, observedDepth: scan.maxDepth, maxDepth: cap
                        )
                        // Best-effort: if the underlying transport itself is
                        // gone, there is nothing more useful to do than move
                        // on to the next (if any) message.
                        try? await wrapped.send(Data(response.utf8))
                        continue
                    }
                    continuation.yield(message)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func disconnect() async {
        pumpTask?.cancel()
        pumpTask = nil
        await wrapped.disconnect()
        messageContinuation.finish()
    }

    /// #242 R2: before forwarding, check whether `data` is the (array-
    /// shaped) response swift-sdk owes some deferred `pendingIllegalByIDSet`
    /// entry — if so, merge that entry's responses in so the caller
    /// (swift-sdk, on behalf of the ORIGINAL batch) still ends up sending
    /// exactly one message covering every id, instead of the deferred
    /// entry going out as its own second message later (or never).
    func send(_ data: Data) async throws {
        if !pendingIllegalByIDSet.isEmpty, let merged = mergeMatchingPendingIllegal(into: data) {
            try await wrapped.send(merged)
            return
        }
        try await wrapped.send(data)
    }

    /// Called by the pump loop (`connect()`'s Task) to stage a batch's
    /// over-depth/invalid-shape items' pre-built error responses, keyed by
    /// the id set the legal sub-batch forwarded alongside them is expected
    /// to answer. Actor-isolated so this dictionary write is naturally
    /// synchronized against concurrent `send(_:)` calls (swift-sdk may be
    /// dispatching several in-flight non-batch requests on their own
    /// `Task`s at the same time) — see the property's own doc comment for
    /// why the pump loop needs to hop into actor isolation for this one
    /// call rather than touching the dictionary directly.
    private func stagePendingIllegal(ids: Set<String>, responses: [String]) {
        pendingIllegalByIDSet[ids] = responses
    }

    /// If `data` is a JSON-RPC batch response array whose own id set
    /// EXACTLY matches a staged `pendingIllegalByIDSet` entry, returns the
    /// combined array (that entry's responses appended) and removes the
    /// entry so it is consumed at most once. Returns `nil` for anything
    /// else — not an array, or an array whose id set doesn't match any
    /// staged entry — and the caller sends `data` unchanged in that case.
    ///
    /// Reuses `splitTopLevelBatchElements`/`scanJSONRPCEnvelope` — the same
    /// non-recursive byte-scanning machinery used on the REQUEST side — to
    /// read each response element's own id, so request-side and
    /// response-side id extraction stay textually consistent (both are the
    /// verbatim raw JSON token for that id, never re-parsed/re-encoded).
    private func mergeMatchingPendingIllegal(into data: Data) -> Data? {
        guard let elements = DepthLimitedTransport.splitTopLevelBatchElements(data), !elements.isEmpty else {
            return nil
        }
        let ids = Set(elements.compactMap { DepthLimitedTransport.scanJSONRPCEnvelope($0).topLevelIDToken })
        guard !ids.isEmpty, let pendingResponses = pendingIllegalByIDSet[ids] else { return nil }
        pendingIllegalByIDSet.removeValue(forKey: ids)
        let combinedInner =
            (elements.map { String(decoding: $0, as: UTF8.self) } + pendingResponses).joined(separator: ",")
        return Data("[\(combinedInner)]".utf8)
    }

    /// Returns the SAME stream on every call, matching `StdioTransport`'s
    /// own contract — the actual message pump lives in `connect()`, not
    /// here; this is a cheap, synchronous accessor (the protocol
    /// requirement is deliberately not `async`).
    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        messageStream
    }

    // MARK: - Byte-level scanning (no tree, no recursion — see type doc comment)

    struct EnvelopeScan: Equatable {
        let maxDepth: Int
        let topLevelIDToken: String?
    }

    /// Computes the maximum `{`/`[` structural nesting depth of `data` and,
    /// best-effort, the raw JSON-RPC `id` token attached directly to the
    /// OUTERMOST object (depth 1) — a single forward, non-recursive byte
    /// scan. Bracket/brace characters and colons inside JSON string
    /// literals (including escaped quotes and escaped backslashes) are
    /// correctly treated as opaque content, never as structure.
    ///
    /// `topLevelIDToken` is the id's raw JSON text verbatim (e.g. `42`,
    /// `"abc"`, `null`) — copied byte-for-byte from the input, never
    /// re-escaped or reinterpreted — or `nil` if no depth-1 `"id"` key was
    /// found (a notification with no `id` at all, a batch/array-at-top-
    /// level message, or malformed input). `depthLimitErrorResponse`
    /// independently re-validates this token's shape before splicing it
    /// into a hand-built JSON string — this scanner does not itself
    /// guarantee well-formedness beyond "copied verbatim from the input".
    static func scanJSONRPCEnvelope(_ data: Data) -> EnvelopeScan {
        let bytes = [UInt8](data)
        let count = bytes.count
        var i = 0
        var depth = 0
        var maxDepth = 0
        var idToken: String?
        let idKeyToken: [UInt8] = Array("\"id\"".utf8)

        // Returns the index just PAST the closing quote of the string that
        // starts at `start` (which must point at the opening `"`), or
        // `count` if the string is unterminated. `\` + the next byte is
        // always treated as one opaque escaped pair, regardless of which
        // character follows — this does not fully validate `\uXXXX`
        // escapes, but it is sufficient to never mistake an escaped `\"`
        // for the real closing quote, which is the only property this
        // scanner needs from string handling.
        func skipString(from start: Int) -> Int {
            var k = start + 1
            while k < count {
                if bytes[k] == UInt8(ascii: "\\") {
                    k += 2
                    continue
                }
                if bytes[k] == UInt8(ascii: "\"") {
                    return k + 1
                }
                k += 1
            }
            return count
        }

        func isJSONWhitespace(_ byte: UInt8) -> Bool {
            byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\n")
                || byte == UInt8(ascii: "\r")
        }

        func isJSONValueDelimiter(_ byte: UInt8) -> Bool {
            byte == UInt8(ascii: ",") || byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]")
                || isJSONWhitespace(byte)
        }

        while i < count {
            let byte = bytes[i]
            if byte == UInt8(ascii: "\"") {
                let stringStart = i
                let stringEnd = skipString(from: i)
                if depth == 1, idToken == nil, stringEnd - stringStart == idKeyToken.count,
                    Array(bytes[stringStart..<stringEnd]) == idKeyToken
                {
                    var j = stringEnd
                    while j < count, isJSONWhitespace(bytes[j]) { j += 1 }
                    if j < count, bytes[j] == UInt8(ascii: ":") {
                        j += 1
                        while j < count, isJSONWhitespace(bytes[j]) { j += 1 }
                        if j < count {
                            if bytes[j] == UInt8(ascii: "\"") {
                                let valueEnd = skipString(from: j)
                                idToken = String(decoding: bytes[j..<valueEnd], as: UTF8.self)
                            } else {
                                var k = j
                                while k < count, !isJSONValueDelimiter(bytes[k]) { k += 1 }
                                if k > j {
                                    idToken = String(decoding: bytes[j..<k], as: UTF8.self)
                                }
                            }
                        }
                    }
                }
                i = stringEnd
                continue
            }
            switch byte {
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
                if depth > maxDepth { maxDepth = depth }
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
            default:
                break
            }
            i += 1
        }
        return EnvelopeScan(maxDepth: maxDepth, topLevelIDToken: idToken)
    }

    /// #242: splits a JSON-RPC batch message's top-level array into its
    /// immediate elements' raw byte ranges, copied verbatim from `data` —
    /// same non-recursive, single-pass, string-aware style as
    /// `scanJSONRPCEnvelope` (reuses its exact `skipString` logic so a `]`
    /// or `,` inside a string literal is never mistaken for a top-level
    /// array boundary). Each returned slice, scanned again on its own via
    /// `scanJSONRPCEnvelope`, yields that element's OWN depth (not
    /// inflated by the wrapping `[` the whole-message scan counts) and its
    /// OWN `"id"` (read at the element's depth 1, matching what a
    /// standalone non-batch message with the same content would report) —
    /// exactly the two things `handleOverDepthMessage` needs to decide,
    /// per batch item, whether to salvage it or reject it by name.
    ///
    /// Returns `nil` when the outermost non-whitespace byte is not `[`
    /// (not a batch at all — the single-message path handles that), or
    /// when the array never closes (malformed input — same fallback).
    /// Returns `[]` for an empty array (`[]`); callers get no elements to
    /// salvage and fall through to the single-message path, which lets
    /// swift-sdk's own "batch array must not be empty" error apply as
    /// before (this function's job is splitting, not validating batch
    /// semantics).
    static func splitTopLevelBatchElements(_ data: Data) -> [Data]? {
        let bytes = [UInt8](data)
        let count = bytes.count

        func isJSONWhitespace(_ byte: UInt8) -> Bool {
            byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\n")
                || byte == UInt8(ascii: "\r")
        }

        var i = 0
        while i < count, isJSONWhitespace(bytes[i]) { i += 1 }
        guard i < count, bytes[i] == UInt8(ascii: "[") else { return nil }
        i += 1

        func skipString(from start: Int) -> Int {
            var k = start + 1
            while k < count {
                if bytes[k] == UInt8(ascii: "\\") {
                    k += 2
                    continue
                }
                if bytes[k] == UInt8(ascii: "\"") {
                    return k + 1
                }
                k += 1
            }
            return count
        }

        var elements: [Data] = []
        // Nesting depth WITHIN the element currently being scanned; 0 means
        // "sitting directly inside the array, between elements" — that is
        // the only level at which `,`/`]`/whitespace are treated as
        // structure rather than opaque element content.
        var depth = 0
        var elementStart: Int? = nil
        var sawClose = false

        while i < count {
            let byte = bytes[i]
            if byte == UInt8(ascii: "\"") {
                if depth == 0, elementStart == nil { elementStart = i }
                i = skipString(from: i)
                continue
            }
            if depth == 0, isJSONWhitespace(byte) {
                i += 1
                continue
            }
            if depth == 0, byte == UInt8(ascii: "]") {
                if let start = elementStart {
                    elements.append(data.subdata(in: start..<i))
                    elementStart = nil
                }
                sawClose = true
                i += 1
                break
            }
            if depth == 0, byte == UInt8(ascii: ",") {
                if let start = elementStart {
                    elements.append(data.subdata(in: start..<i))
                    elementStart = nil
                }
                i += 1
                continue
            }
            if elementStart == nil { elementStart = i }
            switch byte {
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
            default:
                break
            }
            i += 1
        }
        guard sawClose else { return nil }
        return elements
    }

    /// #242 R2: true when, after skipping leading JSON whitespace, `data`'s
    /// first byte is `{` — i.e. this batch element at least LOOKS like a
    /// JSON-RPC request/notification object. A non-object top-level batch
    /// item (a bare number, string, array, `true`/`false`/`null`) can
    /// never decode into `Server.Batch.Item`
    /// (`.build/checkouts/swift-sdk/Sources/MCP/Server/Server.swift`'s
    /// `container(keyedBy:)` throws on a non-keyed value) — and per
    /// `Server.Batch.init(from:)`, ANY single item's decode failure fails
    /// the WHOLE reconstructed batch's decode, not just that one item.
    /// Left in the "legal, forward it" bucket, a stray non-object item
    /// would poison decode for every genuinely legal sibling in the same
    /// reconstructed sub-batch AND — worse — leave any
    /// `pendingIllegalByIDSet` entry staged against that sub-batch's ids
    /// permanently unmatched, since swift-sdk falls through to its own
    /// generic parse-error fallback (a bare object, not an array, with a
    /// null/random id — see `Server.swift`'s final `else` branch in its
    /// message loop) instead of ever calling `send(_:)` with the array
    /// shape `mergeMatchingPendingIllegal` looks for. Routing non-object
    /// items into the SAME directly-answered bucket as over-depth items
    /// (never forwarded at all) avoids that failure mode entirely — at the
    /// cost of not fully replicating swift-sdk's own `Request<AnyMethod>`
    /// schema validation (an object-shaped-but-otherwise-malformed item,
    /// e.g. missing `method`, can still poison a reconstructed sub-batch;
    /// re-implementing that whole validation here was rejected as scope
    /// creep — see this file's `connect()` doc comment on the "next
    /// simplest" alternative design considered and not taken).
    static func isJSONObjectShaped(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            if byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\n")
                || byte == UInt8(ascii: "\r")
            {
                i += 1
                continue
            }
            return byte == UInt8(ascii: "{")
        }
        return false
    }

    /// #242 R2: error for a batch element that isn't even a JSON object —
    /// it cannot carry an `"id"` (JSON scalars/arrays have no keys), so
    /// `null` is the only honest id, same fallback `depthLimitErrorResponse`
    /// uses for an unidentifiable message.
    static func invalidBatchItemErrorResponse() -> String {
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"Invalid Request: batch item must be a JSON object\"}}"
    }

    /// Builds a JSON-RPC 2.0 error response for a rejected over-depth
    /// message, WITHOUT running `JSONEncoder`/`JSONSerialization` on any
    /// part of the original (still-untrusted, still-deep) message — only
    /// the already-extracted `idToken` is spliced in, and only after
    /// `validatedIDToken` re-checks its shape.
    ///
    /// Error code **-32600 (Invalid Request)**, not -32700 (Parse error):
    /// the message IS syntactically valid JSON (every bracket closes, no
    /// truncation) — it is refused by SERVER POLICY (too deeply nested),
    /// not malformed. The JSON-RPC 2.0 spec describes -32700 specifically
    /// as "invalid JSON was received by the server", which this is not.
    static func depthLimitErrorResponse(idToken: String?, observedDepth: Int, maxDepth: Int) -> String {
        let safeID = validatedIDToken(idToken) ?? "null"
        let message = "Invalid Request: JSON nesting depth \(observedDepth) exceeds server limit \(maxDepth)"
        return "{\"jsonrpc\":\"2.0\",\"id\":\(safeID),\"error\":{\"code\":-32600,\"message\":\"\(message)\"}}"
    }

    /// Defends the hand-built response above against a malformed/partial
    /// `idToken` (should not happen given `scanJSONRPCEnvelope`'s own
    /// extraction logic, but this is a security boundary — verify, don't
    /// assume it's always well-formed). Accepts only: the literal `null`;
    /// a JSON string literal (`"..."`, no embedded raw quote or control
    /// character); or a bare numeric token (digits, at most one leading
    /// `-`, one `.`, and exponent characters). Anything else returns `nil`
    /// so the caller falls back to `null`.
    static func validatedIDToken(_ token: String?) -> String? {
        guard let token, !token.isEmpty else { return nil }
        if token == "null" { return token }
        if token.hasPrefix("\""), token.hasSuffix("\""), token.count >= 2 {
            let inner = token.dropFirst().dropLast()
            guard !inner.contains("\"") else { return nil }
            guard !inner.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return nil }
            return token
        }
        let numericCharacters = Set("0123456789-+.eE")
        guard token.allSatisfy({ numericCharacters.contains($0) }) else { return nil }
        return token
    }
}
