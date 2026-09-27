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
/// R1 fix (`splitTopLevelBatchElements`): reuse the same non-recursive,
/// string-aware byte scanner to split a batch's top-level elements into
/// their own raw byte ranges, then re-run `scanJSONRPCEnvelope` on EACH
/// element standalone. Over-depth elements get a named error; the rest are
/// reassembled into a smaller batch and handed to swift-sdk's own decode +
/// `Server.handleBatch`.
///
/// R2 fix (independent review, `review-cwm-misc.md` finding #242-1, HIGH):
/// R1's illegal-item error array was sent IMMEDIATELY, and the legal
/// sub-batch's response arrived LATER via swift-sdk's own `handleBatch` →
/// `send(_:)` call — two independent wire messages for one batch request,
/// violating JSON-RPC 2.0's "respond with an Array" (singular) contract.
/// R2 defers the illegal-item error array instead: `pendingIllegalByIDSet`
/// stages it keyed by the id set the forwarded legal sub-batch is expected
/// to answer, and `send(_:)` merges it into that SAME response the first
/// time an outgoing array's own id set matches. Sending immediately still
/// happens in the two cases where nothing will ever call `send(_:)` on the
/// batch's behalf: no legal sub-batch at all, or a legal sub-batch made
/// entirely of notifications (no ids, `handleBatch` never reaches its own
/// `connection.send`). R2 also excludes non-object batch items (bare
/// scalars) from the "legal, forward it" bucket — see
/// `isJSONObjectShaped`'s own doc comment for why a stray one there could
/// poison a whole reconstructed sub-batch's decode and permanently strand
/// a staged entry.
///
/// Reuses `MockTransport` from `DepthLimitedTransportTests.swift` (same
/// target, no import needed). Because `MockTransport` has no real
/// swift-sdk behind it, tests that exercise the DEFERRED path must
/// manually simulate swift-sdk's later `send(_:)` call with a plausible
/// response array for the forwarded sub-batch's ids (`simulateSDKResponse`
/// below) — this is exactly the round trip the real binary test drives end
/// to end (see the R2 report's binary section).
final class Issue242BatchDepthLimitTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a JSON-RPC batch response array for the given ids, the shape
    /// swift-sdk's `handleBatch` would actually send — used to simulate
    /// "swift-sdk finished dispatching the forwarded legal sub-batch and
    /// is now calling `Transport.send(_:)`" without running a real server.
    private func fakeSDKResponse(ids: [Int]) -> Data {
        let items = ids.map { "{\"jsonrpc\":\"2.0\",\"id\":\($0),\"result\":{\"ok\":true}}" }
        return Data(("[" + items.joined(separator: ",") + "]").utf8)
    }

    private func jsonArray(_ data: Data) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    // MARK: - Test 1: issue's own repro — one over-deep item + one normal item (id: 101)

    func testBatchWithOneOverDeepItemStillAnswersTheOtherItsOwnId() async throws {
        let mock = MockTransport()
        let sut = DepthLimitedTransport(wrapping: mock, maxRawJSONDepth: 4)
        try await sut.connect()

        let deepItem = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"a":[[[1]]]}}"#
        let normalItem = #"{"jsonrpc":"2.0","id":101,"method":"tools/call","params":{"a":1}}"#
        let batch = Data("[\(deepItem),\(normalItem)]".utf8)

        // Sanity: the WHOLE message is over cap (this is what pre-R1-fix
        // code rejected wholesale), even though the normal item alone is not.
        let wholeScan = DepthLimitedTransport.scanJSONRPCEnvelope(batch)
        XCTAssertGreaterThan(wholeScan.maxDepth, 4, "fixture must exercise the over-cap whole-message path")

        await mock.enqueue(batch)
        await mock.finishStream()

        var forwarded: [Data] = []
        for try await message in await sut.receive() {
            forwarded.append(message)
        }
        XCTAssertEqual(forwarded.count, 1, "the legal batch item must be forwarded, reassembled into its own batch")
        let forwardedArray = try jsonArray(try XCTUnwrap(forwarded.first))
        XCTAssertEqual(forwardedArray.count, 1)
        XCTAssertEqual(forwardedArray.first?["id"] as? Int, 101, "the forwarded sub-batch must contain the legal item, unaltered")

        // R2: nothing is sent yet — the illegal item's error is DEFERRED,
        // waiting for swift-sdk's own response to the forwarded sub-batch.
        var sent = await mock.sentMessages
        XCTAssertTrue(sent.isEmpty, "the over-deep item's error must not go out before the legal sub-batch's own response does")

        // Simulate swift-sdk finishing dispatch of the forwarded sub-batch.
        try await sut.send(fakeSDKResponse(ids: [101]))

        sent = await mock.sentMessages
        XCTAssertEqual(sent.count, 1, "exactly ONE response message for the whole original batch (JSON-RPC 2.0: respond with an Array, singular)")
        let merged = try jsonArray(try XCTUnwrap(sent.first))
        XCTAssertEqual(merged.count, 2, "the merged array must contain both the legal item's result AND the over-deep item's error")
        let byID = Dictionary(uniqueKeysWithValues: merged.compactMap { entry -> (Int, [String: Any])? in
            guard let id = entry["id"] as? Int else { return nil }
            return (id, entry)
        })
        XCTAssertNotNil(byID[101]?["result"], "id 101's legal result must be present")
        let error1 = try XCTUnwrap(byID[1]?["error"] as? [String: Any], "id 1's over-deep error must be present, named by its own id")
        XCTAssertEqual(error1["code"] as? Int, -32600)
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
        let forwardedArray = try jsonArray(try XCTUnwrap(forwarded.first))
        let forwardedIDs = Set(forwardedArray.compactMap { $0["id"] as? Int })
        XCTAssertEqual(forwardedIDs, [10, 20], "both legal items — and only them — must be forwarded")

        var sent = await mock.sentMessages
        XCTAssertTrue(sent.isEmpty, "deferred until the legal sub-batch's own response arrives")

        try await sut.send(fakeSDKResponse(ids: [10, 20]))

        sent = await mock.sentMessages
        XCTAssertEqual(sent.count, 1, "exactly one response message for the whole batch")
        let merged = try jsonArray(try XCTUnwrap(sent.first))
        XCTAssertEqual(Set(merged.compactMap { $0["id"] as? Int }), [10, 20, 30])
    }

    // MARK: - Test 3: every item in the batch is over-depth — nothing forwarded, all named, sent immediately

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

        // No legal sub-batch was forwarded at all, so nothing will ever
        // call send(_:) on this batch's behalf — the error array must go
        // out RIGHT AWAY, not wait for a send() that will never come.
        let sent = await mock.sentMessages
        XCTAssertEqual(sent.count, 1)
        let errorArray = try jsonArray(try XCTUnwrap(sent.first))
        let errorIDs = Set(errorArray.compactMap { $0["id"] as? Int })
        XCTAssertEqual(errorIDs, [1, 2], "every over-depth item must be named in the combined error array")
    }

    // MARK: - Test 4: legal sub-batch of ONLY notifications — must not wait forever for a send() that never comes

    /// Required scenario per R2's review: a legal-by-depth sub-batch made
    /// entirely of notifications never produces a `handleBatch` response
    /// (`responses` stays empty, `connection.send` is never called for
    /// it) — deferring the illegal item's error against THAT sub-batch's
    /// (empty) id set would strand it forever. Must send immediately.
    func testLegalSubBatchOfOnlyNotificationsSendsImmediatelyNotDeferred() async throws {
        let mock = MockTransport()
        let sut = DepthLimitedTransport(wrapping: mock, maxRawJSONDepth: 4)
        try await sut.connect()

        let deepItem = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"a":[[[1]]]}}"#
        // Legal by depth, but a NOTIFICATION (no "id" key at all).
        let legalNotification = #"{"jsonrpc":"2.0","method":"notifications/x","params":{"a":1}}"#
        let batch = Data("[\(deepItem),\(legalNotification)]".utf8)

        await mock.enqueue(batch)
        await mock.finishStream()

        var forwarded: [Data] = []
        for try await message in await sut.receive() {
            forwarded.append(message)
        }
        XCTAssertEqual(forwarded.count, 1, "the notification is still forwarded — it IS legal by depth")

        // No `sut.send(...)` simulation at all here — that's the point:
        // a real swift-sdk would never call it for a notification-only
        // sub-batch, so the error must already be out without one.
        let sent = await mock.sentMessages
        XCTAssertEqual(sent.count, 1, "must be sent immediately — deferring would wait for a send() that never arrives")
        let errorArray = try jsonArray(try XCTUnwrap(sent.first))
        XCTAssertEqual(errorArray.count, 1)
        XCTAssertEqual(errorArray.first?["id"] as? Int, 1)
    }

    // MARK: - Test 5: a notification that is ITSELF over-depth, alongside a legal item with an id — deferred, merges correctly

    func testOverDepthNotificationWithoutIDMergesIntoTheLegalItemsResponse() async throws {
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
        let forwardedArray = try jsonArray(try XCTUnwrap(forwarded.first))
        XCTAssertEqual(forwardedArray.first?["id"] as? Int, 5)

        var sent = await mock.sentMessages
        XCTAssertTrue(sent.isEmpty, "deferred — the legal item (id 5) DOES expect a response, so this waits for it")

        try await sut.send(fakeSDKResponse(ids: [5]))

        sent = await mock.sentMessages
        XCTAssertEqual(sent.count, 1)
        let merged = try jsonArray(try XCTUnwrap(sent.first))
        XCTAssertEqual(merged.count, 2)
        let nullIDError = merged.first { $0["id"] is NSNull }
        XCTAssertNotNil(nullIDError, "the over-depth notification (no id at all) falls back to null, same as the single-message path")
    }

    // MARK: - Test 6: whole-message depth inflated ONLY by the wrapping array — both items are individually legal

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
        let forwardedArray = try jsonArray(try XCTUnwrap(forwarded.first))
        XCTAssertEqual(Set(forwardedArray.compactMap { $0["id"] as? Int }), [1, 2])

        let sent = await mock.sentMessages
        XCTAssertTrue(sent.isEmpty, "no item was actually over its own cap — no error should be sent, and nothing was deferred either")
    }

    // MARK: - Test 7: two batches in flight simultaneously — independent merges, no cross-contamination

    func testTwoBatchesInFlightMergeIndependently() async throws {
        let mock = MockTransport()
        let sut = DepthLimitedTransport(wrapping: mock, maxRawJSONDepth: 4)
        try await sut.connect()

        let batchA = Data(
            "[\(#"{"jsonrpc":"2.0","id":1,"method":"m","params":{"a":[[[1]]]}}"#),\(#"{"jsonrpc":"2.0","id":101,"method":"m"}"#)]"
                .utf8)
        let batchB = Data(
            "[\(#"{"jsonrpc":"2.0","id":2,"method":"m","params":{"a":[[[1]]]}}"#),\(#"{"jsonrpc":"2.0","id":202,"method":"m"}"#)]"
                .utf8)

        await mock.enqueue(batchA)
        await mock.enqueue(batchB)
        await mock.finishStream()

        var forwarded: [Data] = []
        for try await message in await sut.receive() {
            forwarded.append(message)
        }
        XCTAssertEqual(forwarded.count, 2, "each batch's own legal sub-batch is forwarded independently")

        var sent = await mock.sentMessages
        XCTAssertTrue(sent.isEmpty, "both deferred — neither batch's legal item has answered yet")

        // Respond to B first, THEN A — order must not matter; each must
        // only pick up its OWN staged entry.
        try await sut.send(fakeSDKResponse(ids: [202]))
        sent = await mock.sentMessages
        XCTAssertEqual(sent.count, 1, "B's response must merge with B's staged error only")
        var mergedB = try jsonArray(try XCTUnwrap(sent.last))
        XCTAssertEqual(Set(mergedB.compactMap { $0["id"] as? Int }), [202, 2], "B's merge must NOT include A's id 1 or 101")

        try await sut.send(fakeSDKResponse(ids: [101]))
        sent = await mock.sentMessages
        XCTAssertEqual(sent.count, 2, "A's response arrives later and produces its OWN second message")
        let mergedA = try jsonArray(try XCTUnwrap(sent.last))
        XCTAssertEqual(Set(mergedA.compactMap { $0["id"] as? Int }), [101, 1], "A's merge must NOT include B's id 2 or 202")
        // Re-fetch B's merge to confirm it was untouched by A's later send.
        mergedB = try jsonArray(try XCTUnwrap(sent.first))
        XCTAssertEqual(Set(mergedB.compactMap { $0["id"] as? Int }), [202, 2])
    }

    // MARK: - Test 8: an unrelated send() with a different id set passes through untouched, pending entry stays staged

    func testUnrelatedSendDoesNotConsumeAPendingEntry() async throws {
        let mock = MockTransport()
        let sut = DepthLimitedTransport(wrapping: mock, maxRawJSONDepth: 4)
        try await sut.connect()

        let batch = Data(
            "[\(#"{"jsonrpc":"2.0","id":1,"method":"m","params":{"a":[[[1]]]}}"#),\(#"{"jsonrpc":"2.0","id":101,"method":"m"}"#)]"
                .utf8)
        await mock.enqueue(batch)
        await mock.finishStream()
        _ = try await drain(sut)

        // An unrelated non-batch response for a totally different id (e.g.
        // a concurrent, ordinary single tool call swift-sdk is also
        // answering) must pass through unchanged.
        let unrelated = Data(#"{"jsonrpc":"2.0","id":999,"result":{"ok":true}}"#.utf8)
        try await sut.send(unrelated)
        var sent = await mock.sentMessages
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first, unrelated, "must be forwarded byte-for-byte unchanged — not mistaken for a match")

        // The REAL match still works afterward — proving the unrelated
        // send above did not consume/corrupt the staged entry.
        try await sut.send(fakeSDKResponse(ids: [101]))
        sent = await mock.sentMessages
        XCTAssertEqual(sent.count, 2)
        let merged = try jsonArray(try XCTUnwrap(sent.last))
        XCTAssertEqual(Set(merged.compactMap { $0["id"] as? Int }), [101, 1])
    }

    private func drain(_ sut: DepthLimitedTransport) async throws -> [Data] {
        var forwarded: [Data] = []
        for try await message in await sut.receive() {
            forwarded.append(message)
        }
        return forwarded
    }

    // MARK: - Test 9: a non-object batch item does not poison its legal siblings and gets its own answered error

    /// R2 fix for the gap the id-set-merge design would otherwise have:
    /// a bare scalar batch item (never decodable as `Server.Batch.Item`)
    /// left in the "legal, forward it" bucket would poison the WHOLE
    /// reconstructed sub-batch's decode (per `Server.Batch.init(from:)`,
    /// one item's decode failure fails the whole array), permanently
    /// stranding any deferred entry. `isJSONObjectShaped` routes it into
    /// the directly-answered bucket instead.
    func testNonObjectBatchItemDoesNotPoisonSubBatchAndGetsItsOwnError() async throws {
        let mock = MockTransport()
        let sut = DepthLimitedTransport(wrapping: mock, maxRawJSONDepth: 4)
        try await sut.connect()

        let deepItem = #"{"jsonrpc":"2.0","id":1,"method":"m","params":{"a":[[[1]]]}}"#
        let legalItem = #"{"jsonrpc":"2.0","id":5,"method":"m"}"#
        let batch = Data("[42,\(legalItem),\(deepItem)]".utf8)

        await mock.enqueue(batch)
        await mock.finishStream()

        var forwarded: [Data] = []
        for try await message in await sut.receive() {
            forwarded.append(message)
        }
        XCTAssertEqual(forwarded.count, 1, "only the genuinely legal, object-shaped item is forwarded")
        let forwardedArray = try jsonArray(try XCTUnwrap(forwarded.first))
        XCTAssertEqual(forwardedArray.count, 1, "the bare `42` must NOT ride along in the forwarded sub-batch")
        XCTAssertEqual(forwardedArray.first?["id"] as? Int, 5)

        var sent = await mock.sentMessages
        XCTAssertTrue(sent.isEmpty, "deferred — id 5 does expect a response")

        try await sut.send(fakeSDKResponse(ids: [5]))
        sent = await mock.sentMessages
        XCTAssertEqual(sent.count, 1)
        let merged = try jsonArray(try XCTUnwrap(sent.first))
        XCTAssertEqual(merged.count, 3, "id 5's result + the non-object item's error + the over-depth item's error")
        let nullIDErrors = merged.filter { $0["id"] is NSNull }
        XCTAssertEqual(nullIDErrors.count, 1, "the bare `42` item gets its own null-id error naming it as an invalid batch item")
        XCTAssertTrue(
            (nullIDErrors.first?["error"] as? [String: Any]).flatMap { $0["message"] as? String }?
                .contains("must be a JSON object") == true
        )
    }

    /// Same shape, but EVERY element is non-object or over-depth — no
    /// legal sub-batch at all, so this must send immediately (one
    /// message), exercising the same "nothing to forward" path as
    /// `testBatchWhereEveryItemIsOverDepth` but for the non-object case.
    func testAllNonObjectOrOverDepthItemsSendImmediately() async throws {
        let mock = MockTransport()
        let sut = DepthLimitedTransport(wrapping: mock, maxRawJSONDepth: 4)
        try await sut.connect()

        let deepItem = #"{"jsonrpc":"2.0","id":1,"method":"m","params":{"a":[[[1]]]}}"#
        let batch = Data("[42,\"abc\",\(deepItem)]".utf8)

        await mock.enqueue(batch)
        await mock.finishStream()

        let forwarded = try await drain(sut)
        XCTAssertTrue(forwarded.isEmpty)

        let sent = await mock.sentMessages
        XCTAssertEqual(sent.count, 1, "no legal sub-batch — everything answered directly, right away, in one array")
        let errorArray = try jsonArray(try XCTUnwrap(sent.first))
        XCTAssertEqual(errorArray.count, 3, "two invalid-shape errors (42, \"abc\") plus the one depth error (id 1)")
    }

    // MARK: - isJSONObjectShaped: unit-level coverage

    func testIsJSONObjectShaped() {
        XCTAssertTrue(DepthLimitedTransport.isJSONObjectShaped(Data(#"{"jsonrpc":"2.0"}"#.utf8)))
        XCTAssertTrue(DepthLimitedTransport.isJSONObjectShaped(Data("   {\"a\":1}".utf8)), "leading whitespace must be skipped")
        XCTAssertFalse(DepthLimitedTransport.isJSONObjectShaped(Data("42".utf8)))
        XCTAssertFalse(DepthLimitedTransport.isJSONObjectShaped(Data("\"abc\"".utf8)))
        XCTAssertFalse(DepthLimitedTransport.isJSONObjectShaped(Data("[1,2]".utf8)))
        XCTAssertFalse(DepthLimitedTransport.isJSONObjectShaped(Data("true".utf8)))
        XCTAssertFalse(DepthLimitedTransport.isJSONObjectShaped(Data("null".utf8)))
        XCTAssertFalse(DepthLimitedTransport.isJSONObjectShaped(Data()))
        XCTAssertFalse(DepthLimitedTransport.isJSONObjectShaped(Data("   ".utf8)), "whitespace-only has no object to find")
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
