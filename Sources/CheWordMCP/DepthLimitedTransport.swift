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

        pumpTask = Task {
            do {
                for try await message in inboundStream {
                    let scan = DepthLimitedTransport.scanJSONRPCEnvelope(message)
                    if scan.maxDepth > cap {
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

    func send(_ data: Data) async throws {
        try await wrapped.send(data)
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
