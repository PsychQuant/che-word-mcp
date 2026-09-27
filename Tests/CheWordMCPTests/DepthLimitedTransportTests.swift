import XCTest
import Foundation
import Logging
import MCP
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#116 R2 (`review-cwm450.md` C1) — unit tests for
/// `DepthLimitedTransport`, the `Transport` wrapper that rejects
/// excessively nested JSON-RPC messages BEFORE swift-sdk's own decoder
/// ever sees them. See that type's own doc comment for the full rationale
/// (the crash lives inside the `swift-sdk` dependency's `Value.init(from:)`
/// / request re-encoding, reachable via any tool call with a deep enough
/// argument — the original #116 fix, `parseMathComponent`'s own depth
/// guard, never runs early enough to stop it).
///
/// These tests exercise the wrapper in-process against a `MockTransport`
/// (below) — no real stdio, no real subprocess. The real-binary,
/// real-process-survival proof (RED: crash reproduced with the check
/// disabled; GREEN: same input survives with it enabled) lives in
/// `wave1-crash.md`'s "R2" section, using the real `CheWordMCP` release
/// binary over real stdio — that is the evidence this fix actually stops
/// the SIGBUS crash `swift test` cannot itself reproduce (an in-process
/// XCTest run that triggered the real swift-sdk decode crash would take
/// the whole test binary down with it, the same class of problem #116's
/// own R1 test-depth correction ran into).
final class DepthLimitedTransportTests: XCTestCase {

    // MARK: - Test 1: over-limit message is intercepted, never forwarded, and an error is sent back

    func testOverLimitMessageIsInterceptedAndErrorReturned() async throws {
        let mock = MockTransport()
        let sut = DepthLimitedTransport(wrapping: mock, maxRawJSONDepth: 4)
        try await sut.connect()

        // Structural depth 5 (outer{, params{, then three nested arrays):
        // one level over the cap of 4.
        let deepMessage = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"a":[[[1]]]}}"#.utf8)
        // Sanity-check this fixture is ACTUALLY depth 5 under the same scanner
        // the wrapper uses, so this test is pinned to a real over-limit input,
        // not an assumption about the literal's shape.
        let selfCheck = DepthLimitedTransport.scanJSONRPCEnvelope(deepMessage)
        XCTAssertEqual(selfCheck.maxDepth, 5, "fixture must be depth 5 to exercise the cap=4 boundary")

        await mock.enqueue(deepMessage)
        await mock.finishStream()

        var forwarded: [Data] = []
        for try await message in await sut.receive() {
            forwarded.append(message)
        }

        XCTAssertTrue(forwarded.isEmpty, "an over-limit message must never reach the outward stream swift-sdk consumes")

        let sent = await mock.sentMessages
        XCTAssertEqual(sent.count, 1, "exactly one error response must be sent back over the underlying transport")
        let responseText = String(decoding: sent[0], as: UTF8.self)
        let response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sent[0]) as? [String: Any]
        )
        XCTAssertEqual(response["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(response["id"] as? Int, 1, "the rejected message's own id must be echoed back — got: \(responseText)")
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32600)
        XCTAssertTrue(
            (error["message"] as? String)?.contains("5") == true,
            "error message should name the observed depth; got: \(responseText)"
        )
    }

    // MARK: - Test 2: a normal, shallow message passes through byte-for-byte unchanged

    func testNormalMessageIsForwardedUnmodified() async throws {
        let mock = MockTransport()
        let sut = DepthLimitedTransport(wrapping: mock, maxRawJSONDepth: 64)
        try await sut.connect()

        let normalMessage = Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"get_document_info","arguments":{"doc_id":"d"}}}"#.utf8)
        await mock.enqueue(normalMessage)
        await mock.finishStream()

        var forwarded: [Data] = []
        for try await message in await sut.receive() {
            forwarded.append(message)
        }

        XCTAssertEqual(forwarded, [normalMessage], "a within-limit message must be forwarded byte-for-byte, unchanged")
        let sent = await mock.sentMessages
        XCTAssertTrue(sent.isEmpty, "no error response should be sent for a within-limit message")
    }

    // MARK: - Test 3: a string VALUE containing many bracket characters must not be misjudged as structural nesting

    func testStringContentWithManyBracketsIsNotMisjudged() async throws {
        // The string value itself contains far more than 4 levels' worth of
        // `{`/`[` characters, but they are content, not structure — the
        // message's REAL structural depth is only 2 (outer object, "text"
        // is a plain string value).
        let bracketyString = String(repeating: "{[{[{[{[{[", count: 5)
        let message: [String: Any] = ["jsonrpc": "2.0", "id": 9, "method": "notifications/x",
                                       "params": ["text": bracketyString]]
        let data = try JSONSerialization.data(withJSONObject: message)

        let scan = DepthLimitedTransport.scanJSONRPCEnvelope(data)
        XCTAssertEqual(scan.maxDepth, 2, "bracket characters inside a JSON string value must not count as structural nesting")

        let mock = MockTransport()
        let sut = DepthLimitedTransport(wrapping: mock, maxRawJSONDepth: 4)
        try await sut.connect()
        await mock.enqueue(data)
        await mock.finishStream()

        var forwarded: [Data] = []
        for try await forwardedMessage in await sut.receive() {
            forwarded.append(forwardedMessage)
        }
        XCTAssertEqual(forwarded, [data], "a message whose ONLY deep-looking content is inside a string must still be forwarded")
        let noErrorsSent = await mock.sentMessages.isEmpty
        XCTAssertTrue(noErrorsSent)
    }

    // MARK: - Test 4: escaped quotes inside a string must not be mistaken for the string's closing quote

    func testEscapedQuotesDoNotConfuseStringBoundaryDetection() async throws {
        // The string value is: a quote, a backslash, and a bracket — i.e.
        // the literal characters `"`, `\`, `[`. If the scanner mishandled
        // the escaped quote (`\"`) as a real closing quote, it would exit
        // "in string" mode early and then see the un-escaped `[` and `{`
        // that follow as STRUCTURAL, inflating the measured depth well
        // past this message's real structural depth of 2.
        let trickyString = "a quote: \" backslash: \\\\ bracket: ["
        let message: [String: Any] = ["jsonrpc": "2.0", "id": 3, "method": "notifications/x",
                                       "params": ["text": trickyString]]
        let data = try JSONSerialization.data(withJSONObject: message)
        // Sanity: JSONSerialization really did escape the quote/backslash —
        // confirms this fixture exercises the escape path at all.
        let raw = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(raw.contains(#"\""#), "fixture must contain an escaped quote to exercise this case")

        let scan = DepthLimitedTransport.scanJSONRPCEnvelope(data)
        XCTAssertEqual(scan.maxDepth, 2, "an escaped quote inside a string must not end the string early; got depth \(scan.maxDepth) for: \(raw)")

        let mock = MockTransport()
        let sut = DepthLimitedTransport(wrapping: mock, maxRawJSONDepth: 4)
        try await sut.connect()
        await mock.enqueue(data)
        await mock.finishStream()

        var forwarded: [Data] = []
        for try await forwardedMessage in await sut.receive() {
            forwarded.append(forwardedMessage)
        }
        XCTAssertEqual(forwarded, [data])
        let noErrorsSent = await mock.sentMessages.isEmpty
        XCTAssertTrue(noErrorsSent)
    }

    // MARK: - Test 5: multiple messages in one batch — over-limit ones are skipped, others still processed (process keeps running)

    func testProcessingContinuesAfterRejectingOneMessage() async throws {
        let mock = MockTransport()
        let sut = DepthLimitedTransport(wrapping: mock, maxRawJSONDepth: 4)
        try await sut.connect()

        let deepMessage = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"a":[[[1]]]}}"#.utf8)
        let normalMessage = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"a":1}}"#.utf8)
        await mock.enqueue(deepMessage)
        await mock.enqueue(normalMessage)
        await mock.finishStream()

        var forwarded: [Data] = []
        for try await message in await sut.receive() {
            forwarded.append(message)
        }

        XCTAssertEqual(forwarded, [normalMessage], "rejecting an over-limit message must not stop later messages from being processed")
        let sent = await mock.sentMessages
        XCTAssertEqual(sent.count, 1, "only the over-limit message gets an error response")
    }

    // MARK: - Test 6: idToken extraction and validation

    func testTopLevelIDTokenExtractionCoversStringNumberAndNull() {
        let numeric = Data(#"{"jsonrpc":"2.0","id":42,"method":"m","params":{"deep":[[[[[1]]]]]}}"#.utf8)
        XCTAssertEqual(DepthLimitedTransport.scanJSONRPCEnvelope(numeric).topLevelIDToken, "42")

        let stringID = Data(#"{"jsonrpc":"2.0","id":"abc-123","method":"m"}"#.utf8)
        XCTAssertEqual(DepthLimitedTransport.scanJSONRPCEnvelope(stringID).topLevelIDToken, "\"abc-123\"")

        let nullID = Data(#"{"jsonrpc":"2.0","id":null,"method":"m"}"#.utf8)
        XCTAssertEqual(DepthLimitedTransport.scanJSONRPCEnvelope(nullID).topLevelIDToken, "null")

        let noID = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        XCTAssertNil(DepthLimitedTransport.scanJSONRPCEnvelope(noID).topLevelIDToken)

        // A NESTED "id" (inside "params", at depth > 1) must NOT be picked up
        // as the top-level id.
        let nestedID = Data(#"{"jsonrpc":"2.0","method":"m","params":{"id":999}}"#.utf8)
        XCTAssertNil(DepthLimitedTransport.scanJSONRPCEnvelope(nestedID).topLevelIDToken)
    }

    func testValidatedIDTokenRejectsMalformedInput() {
        XCTAssertEqual(DepthLimitedTransport.validatedIDToken("42"), "42")
        XCTAssertEqual(DepthLimitedTransport.validatedIDToken("\"abc\""), "\"abc\"")
        XCTAssertEqual(DepthLimitedTransport.validatedIDToken("null"), "null")
        XCTAssertNil(DepthLimitedTransport.validatedIDToken(nil))
        XCTAssertNil(DepthLimitedTransport.validatedIDToken(""))
        // Embedded raw quote — would break out of the hand-built response's own string.
        XCTAssertNil(DepthLimitedTransport.validatedIDToken("\"a\"b\""))
        // Not a valid string/number/null shape at all.
        XCTAssertNil(DepthLimitedTransport.validatedIDToken("{}"))
        XCTAssertNil(DepthLimitedTransport.validatedIDToken("true"))
    }

    func testDepthLimitErrorResponseFallsBackToNullOnUnvalidatableToken() {
        let response = DepthLimitedTransport.depthLimitErrorResponse(idToken: "{}", observedDepth: 90, maxDepth: 64)
        let parsed = try? JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
        XCTAssertNotNil(parsed, "response must itself be valid JSON even when the extracted id token was rejected")
        XCTAssertTrue(parsed?["id"] is NSNull, "an unvalidatable id token must fall back to JSON null, not be spliced in raw")
    }
}

/// Mock `Transport` for unit-testing `DepthLimitedTransport` without real
/// stdio. Test code drives its inbound stream via `enqueue`/`finishStream`
/// and inspects everything it was asked to `send()`.
actor MockTransport: Transport {
    let logger = Logger(label: "mock-transport", factory: { _ in SwiftLogNoOpLogHandler() })
    private(set) var sentMessages: [Data] = []
    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0

    private let stream: AsyncThrowingStream<Data, Swift.Error>
    private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    init() {
        var cont: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        self.stream = AsyncThrowingStream { cont = $0 }
        self.continuation = cont
    }

    func connect() async throws { connectCallCount += 1 }
    func disconnect() async {
        disconnectCallCount += 1
        continuation.finish()
    }
    func send(_ data: Data) async throws { sentMessages.append(data) }
    func receive() -> AsyncThrowingStream<Data, Swift.Error> { stream }

    /// Test-only: feed one message into the stream `receive()` exposes.
    func enqueue(_ data: Data) {
        continuation.yield(data)
    }

    /// Test-only: signals no more messages are coming, so a `for try await`
    /// consumer of the WRAPPED transport's outward stream terminates
    /// cleanly instead of needing an arbitrary timeout.
    func finishStream() {
        continuation.finish()
    }
}
