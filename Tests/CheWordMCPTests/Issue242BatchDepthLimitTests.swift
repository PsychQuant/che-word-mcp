import XCTest
import Foundation
import Logging
import MCP
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#242 — `DepthLimitedTransport` (#116 R2) checked
/// the WHOLE JSON-RPC message's structural depth as one unit. For a
/// JSON-RPC batch (top-level `[...]`), that means a single over-deep item
/// anywhere in the batch rejected the entire message: the response was one
/// bare error object (not the array shape a batch response takes), its
/// `id` was always `null` (`scanJSONRPCEnvelope` only reads a depth-1 `id`
/// key, and a batch item's own `id` sits at depth 2 in the WHOLE-message
/// scan), and every other — otherwise perfectly legal — item in the same
/// batch got no response at all.
///
/// The fix (`splitTopLevelBatchElements`) reuses the same non-recursive,
/// string-aware byte scanner to split a batch's top-level elements into
/// their own raw byte ranges, then re-runs `scanJSONRPCEnvelope` on EACH
/// element standalone — giving that element's own depth and own `id`,
/// exactly matching what a non-batch message with the same content would
/// report. Over-depth elements get a named error sent directly (bypassing
/// decode, same as the single-message path); the remaining legal elements
/// are reassembled into a smaller batch and handed to swift-sdk's own
/// decode + `Server.handleBatch`, which already produces a correct
/// response array for a batch whose items are all within limits (verified
/// by reading `.build/checkouts/swift-sdk/Sources/MCP/Server/Server.swift`
/// — `decoder.decode(Server.Batch.self, from:)` followed by `handleBatch`,
/// which collects one `Response` per item and encodes the whole
/// `[Response]` array in one `connection.send()`).
///
/// Reuses `MockTransport` from `DepthLimitedTransportTests.swift` (same
/// target, no import needed).
final class Issue242BatchDepthLimitTests: XCTestCase {

    // MARK: - Test 1: issue's own repro — one over-deep item + one normal item (id: 101)

    func testBatchWithOneOverDeepItemStillAnswersTheOtherItsOwnId() async throws {
        let mock = MockTransport()
        let sut = DepthLimitedTransport(wrapping: mock, maxRawJSONDepth: 4)
        try await sut.connect()

        let deepItem = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"a":[[[1]]]}}"#
        let normalItem = #"{"jsonrpc":"2.0","id":101,"method":"tools/call","params":{"a":1}}"#
        let batch = Data("[\(deepItem),\(normalItem)]".utf8)

        // Sanity: the WHOLE message is over cap (this is what pre-fix code
        // rejected wholesale), even though the normal item alone is not.
        let wholeScan = DepthLimitedTransport.scanJSONRPCEnvelope(batch)
        XCTAssertGreaterThan(wholeScan.maxDepth, 4, "fixture must exercise the over-cap whole-message path")

        await mock.enqueue(batch)
        await mock.finishStream()

        var forwarded: [Data] = []
        for try await message in await sut.receive() {
            forwarded.append(message)
        }

        // The legal item (id 101) must be forwarded on (as a reassembled
        // batch) for normal decode/dispatch — not silently dropped.
        XCTAssertEqual(forwarded.count, 1, "the legal batch item must be forwarded, reassembled into its own batch")
        let forwardedMessage = try XCTUnwrap(forwarded.first, "no message was forwarded at all")
        let forwardedArray = try XCTUnwrap(
            JSONSerialization.jsonObject(with: forwardedMessage) as? [[String: Any]]
        )
        XCTAssertEqual(forwardedArray.count, 1)
        XCTAssertEqual(forwardedArray.first?["id"] as? Int, 101, "the forwarded sub-batch must contain the legal item, unaltered")

        // The over-deep item (id 1) must get a NAMED error, not silently
        // vanish and not surface as a bare `{"id": null, ...}`.
        let sent = await mock.sentMessages
        XCTAssertEqual(sent.count, 1, "exactly one response message for the illegal item(s)")
        let sentMessage = try XCTUnwrap(sent.first, "no error response was sent at all")
        let errorArray = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sentMessage) as? [[String: Any]]
        )
        XCTAssertEqual(errorArray.count, 1, "the error response must itself be array-shaped, matching batch response shape")
        XCTAssertEqual(errorArray.first?["id"] as? Int, 1, "the over-deep item's OWN id (not null) must be echoed back")
        let error = try XCTUnwrap(errorArray.first?["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32600)
    }

    // MARK: - Test 2: two normal items + one over-deep item

    func testBatchWithTwoNormalItemsAndOneOverDeepItem() async throws {
        let mock = MockTransport()
        let sut = DepthLimitedTransport(wrapping: mock, maxRawJSONDepth: 4)
        try await sut.connect()

        let normalA = #"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"a":1}}"#
        let normalB = #"{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"a":2}}"#
        let deepItem = #"{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"a":[[[1]]]}}"#
        let batch = Data("[\(normalA),\(deepItem),\(normalB)]".utf8)

        await mock.enqueue(batch)
        await mock.finishStream()

        var forwarded: [Data] = []
        for try await message in await sut.receive() {
            forwarded.append(message)
        }

        XCTAssertEqual(forwarded.count, 1)
        let forwardedMessage = try XCTUnwrap(forwarded.first)
        let forwardedArray = try XCTUnwrap(JSONSerialization.jsonObject(with: forwardedMessage) as? [[String: Any]])
        let forwardedIDs = Set(forwardedArray.compactMap { $0["id"] as? Int })
        XCTAssertEqual(forwardedIDs, [10, 20], "both legal items — and only them, in original order intent — must be forwarded")

        let sent = await mock.sentMessages
        XCTAssertEqual(sent.count, 1)
        let sentMessage = try XCTUnwrap(sent.first)
        let errorArray = try XCTUnwrap(JSONSerialization.jsonObject(with: sentMessage) as? [[String: Any]])
        XCTAssertEqual(errorArray.count, 1)
        XCTAssertEqual(errorArray.first?["id"] as? Int, 30)
    }

    // MARK: - Test 3: every item in the batch is over-depth — nothing forwarded, all named

    func testBatchWhereEveryItemIsOverDepth() async throws {
        let mock = MockTransport()
        let sut = DepthLimitedTransport(wrapping: mock, maxRawJSONDepth: 4)
        try await sut.connect()

        let deepA = #"{"jsonrpc":"2.0","id":1,"method":"m","params":{"a":[[[1]]]}}"#
        let deepB = #"{"jsonrpc":"2.0","id":2,"method":"m","params":{"a":[[[2]]]}}"#
        let batch = Data("[\(deepA),\(deepB)]".utf8)

        await mock.enqueue(batch)
        await mock.finishStream()

        var forwarded: [Data] = []
        for try await message in await sut.receive() {
            forwarded.append(message)
        }
        XCTAssertTrue(forwarded.isEmpty, "no item in this batch is legal — nothing should reach decode")

        let sent = await mock.sentMessages
        XCTAssertEqual(sent.count, 1)
        let sentMessage = try XCTUnwrap(sent.first)
        let errorArray = try XCTUnwrap(JSONSerialization.jsonObject(with: sentMessage) as? [[String: Any]])
        let errorIDs = Set(errorArray.compactMap { $0["id"] as? Int })
        XCTAssertEqual(errorIDs, [1, 2], "every over-depth item must be named in the combined error array")
    }

    // MARK: - Test 4: a notification (no "id") that is itself over-depth still falls back to null, doesn't crash the split

    func testOverDepthNotificationWithoutIDFallsBackToNullError() async throws {
        let mock = MockTransport()
        let sut = DepthLimitedTransport(wrapping: mock, maxRawJSONDepth: 4)
        try await sut.connect()

        let deepNotification = #"{"jsonrpc":"2.0","method":"notifications/x","params":{"a":[[[1]]]}}"#
        let normalItem = #"{"jsonrpc":"2.0","id":5,"method":"m","params":{"a":1}}"#
        let batch = Data("[\(deepNotification),\(normalItem)]".utf8)

        await mock.enqueue(batch)
        await mock.finishStream()

        var forwarded: [Data] = []
        for try await message in await sut.receive() {
            forwarded.append(message)
        }
        XCTAssertEqual(forwarded.count, 1)
        let forwardedMessage = try XCTUnwrap(forwarded.first)
        let forwardedArray = try XCTUnwrap(JSONSerialization.jsonObject(with: forwardedMessage) as? [[String: Any]])
        XCTAssertEqual(forwardedArray.count, 1)
        XCTAssertEqual(forwardedArray.first?["id"] as? Int, 5)

        let sent = await mock.sentMessages
        XCTAssertEqual(sent.count, 1)
        let sentMessage = try XCTUnwrap(sent.first)
        let errorArray = try XCTUnwrap(JSONSerialization.jsonObject(with: sentMessage) as? [[String: Any]])
        XCTAssertEqual(errorArray.count, 1)
        XCTAssertTrue(errorArray.first?["id"] is NSNull, "an over-depth notification (no id at all) falls back to null, same as the single-message path")
    }

    // MARK: - Test 5: whole-message depth inflated ONLY by the wrapping array — both items are individually legal

    /// Regression guard for the exact mechanism #242 describes: scanning
    /// the WHOLE message always reads at least 1 deeper than scanning any
    /// one element alone (the wrapping `[` itself). A batch whose items
    /// are ALL individually within cap must still be salvaged in full —
    /// not just "mostly" — even when the whole-message scan alone would
    /// have said "over cap".
    func testBatchWhereWholeMessageDepthExceedsCapButEveryItemAloneDoesNot() async throws {
        let itemA = #"{"jsonrpc":"2.0","id":1,"method":"m","params":{"a":1}}"#
        let itemB = #"{"jsonrpc":"2.0","id":2,"method":"m","params":{"a":2}}"#
        let itemScanA = DepthLimitedTransport.scanJSONRPCEnvelope(Data(itemA.utf8))
        let batch = Data("[\(itemA),\(itemB)]".utf8)
        let wholeScan = DepthLimitedTransport.scanJSONRPCEnvelope(batch)
        // Confirm the fixture actually exercises the "+1 purely from the
        // wrapping array" shape this test is pinning down.
        XCTAssertEqual(wholeScan.maxDepth, itemScanA.maxDepth + 1)

        let mock = MockTransport()
        let sut = DepthLimitedTransport(wrapping: mock, maxRawJSONDepth: itemScanA.maxDepth)
        try await sut.connect()
        await mock.enqueue(batch)
        await mock.finishStream()

        var forwarded: [Data] = []
        for try await message in await sut.receive() {
            forwarded.append(message)
        }
        XCTAssertEqual(forwarded.count, 1, "both items are individually within cap; the batch must be salvaged in full, not rejected wholesale")
        let forwardedMessage = try XCTUnwrap(forwarded.first)
        let forwardedArray = try XCTUnwrap(JSONSerialization.jsonObject(with: forwardedMessage) as? [[String: Any]])
        XCTAssertEqual(Set(forwardedArray.compactMap { $0["id"] as? Int }), [1, 2])

        let sent = await mock.sentMessages
        XCTAssertTrue(sent.isEmpty, "no item was actually over its own cap — no error should be sent")
    }

    // MARK: - splitTopLevelBatchElements: unit-level coverage of the splitter itself

    func testSplitTopLevelBatchElementsReturnsNilForNonArrayInput() {
        let single = Data(#"{"jsonrpc":"2.0","id":1,"method":"m"}"#.utf8)
        XCTAssertNil(DepthLimitedTransport.splitTopLevelBatchElements(single))
    }

    func testSplitTopLevelBatchElementsReturnsEmptyArrayForEmptyBatch() {
        let empty = Data("[]".utf8)
        XCTAssertEqual(DepthLimitedTransport.splitTopLevelBatchElements(empty), [])
    }

    func testSplitTopLevelBatchElementsReturnsNilForUnterminatedArray() {
        let malformed = Data(#"[{"jsonrpc":"2.0","id":1,"method":"m"}"#.utf8)
        XCTAssertNil(DepthLimitedTransport.splitTopLevelBatchElements(malformed))
    }

    /// A comma/bracket character inside a JSON string VALUE of one element
    /// must not be misread as a top-level array separator — same string-
    /// awareness guarantee `scanJSONRPCEnvelope` already has for depth.
    func testSplitTopLevelBatchElementsIsStringAware() throws {
        let trickyItem = #"{"jsonrpc":"2.0","id":1,"method":"m","params":{"text":"a],[b"}}"#
        let normalItem = #"{"jsonrpc":"2.0","id":2,"method":"m"}"#
        let batch = Data("[\(trickyItem),\(normalItem)]".utf8)

        let elements = try XCTUnwrap(DepthLimitedTransport.splitTopLevelBatchElements(batch))
        XCTAssertEqual(elements.count, 2, "the bracket/comma characters inside the string value must not split the array early")
        guard elements.count == 2 else { return }
        let firstParsed = try XCTUnwrap(JSONSerialization.jsonObject(with: elements[0]) as? [String: Any])
        XCTAssertEqual(firstParsed["id"] as? Int, 1)
        let secondParsed = try XCTUnwrap(JSONSerialization.jsonObject(with: elements[1]) as? [String: Any])
        XCTAssertEqual(secondParsed["id"] as? Int, 2)
    }
}
