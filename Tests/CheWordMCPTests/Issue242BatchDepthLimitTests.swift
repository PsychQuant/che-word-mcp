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
/// `id` was always `null`, and every other — otherwise perfectly legal —
/// item in the same batch got no response at all.
///
/// R1 tried per-item salvage: split the batch, forward the legal remainder
/// to swift-sdk's own decode/dispatch, answer the illegal items directly.
/// That produced TWO independent wire messages for one batch request
/// (violating JSON-RPC 2.0's "respond with an Array", singular) — R2 fixed
/// THAT by staging the illegal items' errors and merging them into
/// swift-sdk's own later response, keyed by the forwarded sub-batch's
/// expected id set.
///
/// Two independent-review rounds later, R3 throws the whole stateful
/// merge mechanism out. Real binary testing found the R2 mechanism itself
/// could (a) let an object-shaped-but-schema-invalid item (e.g. missing
/// `method`) poison `Server.Batch.init(from:)`'s ATOMIC decode of the
/// forwarded sub-batch, causing every id in that batch to get NO response
/// at all AND leaking the staged entry forever, later corrupting a
/// completely unrelated future response that happened to reuse the same
/// id (CRITICAL); and (b) let two concurrent batches whose forwarded
/// sub-batches shared the same id set silently overwrite each other's
/// staged entry, losing one batch's error outright (HIGH). Two review
/// rounds finding two different ways for that dictionary to go stale is
/// itself the signal: no amount of narrower per-item validation closes
/// every way `Server.Batch.init(from:)` can atomically fail without
/// reimplementing swift-sdk's own decode.
///
/// R3's design is STATELESS: `DepthLimitedTransport` no longer keeps any
/// information about a message once it has been forwarded or answered.
/// Per-element depth scanning is kept (still needed so a batch whose items
/// are all individually within cap isn't rejected merely because the
/// wrapping `[` adds one to the whole-message scan), but the outcome is
/// now binary and decided in a single pass with NO partial forwarding:
///
/// - No element is individually over depth → the ORIGINAL message is
///   forwarded byte-for-byte, unmodified — exactly as if this guard did
///   not exist, including swift-sdk's own handling of anything else wrong
///   with the batch (non-object items, missing fields, etc. — genuinely
///   out of this guard's scope, same as for a non-batch message).
/// - At least one element IS over depth → the WHOLE batch is refused
///   right here, nothing is ever forwarded to decode: one JSON array,
///   built entirely from the elements' own (already-in-hand) scans, is
///   sent directly. Every element that could carry an id gets an entry
///   named by that id (the over-depth one(s) get a depth error; the
///   rest get a "batch not executed" error naming which sibling index
///   caused it); notifications (object-shaped, no id) get no entry;
///   non-object elements get `id: null` (JSON-RPC's answer for an
///   unidentifiable malformed item). Since nothing is ever forwarded in
///   this branch, there is nothing for swift-sdk to atomically fail to
///   decode, and nothing left over to stage, leak, or collide with a
///   later message — there is no "later" for a refused batch at all.
///
/// Reuses `MockTransport` from `DepthLimitedTransportTests.swift` (same
/// target, no import needed).
final class Issue242BatchDepthLimitTests: XCTestCase {

    // MARK: - Helpers

    private func jsonArray(_ data: Data) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    /// Runs one batch through `sut`, returns (forwarded messages, sent
    /// messages) after the stream drains.
    private func run(_ sut: DepthLimitedTransport, _ mock: MockTransport, _ batch: Data) async throws -> (forwarded: [Data], sent: [Data]) {
        await mock.enqueue(batch)
        await mock.finishStream()
        var forwarded: [Data] = []
        for try await message in await sut.receive() {
            forwarded.append(message)
        }
        return (forwarded, await mock.sentMessages)
    }

    // MARK: - Test 1: issue's own repro — one over-deep item + one otherwise-legal item (id: 101)

    /// R3: the batch is refused WHOLESALE — id 101 is never forwarded to
    /// swift-sdk at all (unlike R1/R2, where it would have been). It gets
    /// a "batch not executed" error naming its own id, not a real result.
    func testBatchWithOneOverDeepItemRefusesWholeBatchInOneMessage() async throws {
        let mock = MockTransport()
        let sut = DepthLimitedTransport(wrapping: mock, maxRawJSONDepth: 4)
        try await sut.connect()

        let deepItem = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"a":[[[1]]]}}"#
        let normalItem = #"{"jsonrpc":"2.0","id":101,"method":"tools/call","params":{"a":1}}"#
        let batch = Data("[\(deepItem),\(normalItem)]".utf8)

        let wholeScan = DepthLimitedTransport.scanJSONRPCEnvelope(batch)
        XCTAssertGreaterThan(wholeScan.maxDepth, 4, "fixture must exercise the over-cap whole-message path")

        let (forwarded, sent) = try await run(sut, mock, batch)

        XCTAssertTrue(forwarded.isEmpty, "R3 never forwards anything from a refused batch")
        XCTAssertEqual(sent.count, 1, "exactly ONE response message for the whole batch")
        let merged = try jsonArray(try XCTUnwrap(sent.first))
        XCTAssertEqual(merged.count, 2)
        let byID = Dictionary(uniqueKeysWithValues: merged.compactMap { entry -> (Int, [String: Any])? in
            guard let id = entry["id"] as? Int else { return nil }
            return (id, entry)
        })
        let error1 = try XCTUnwrap(byID[1]?["error"] as? [String: Any], "the over-depth item's own id must be named")
        XCTAssertEqual(error1["code"] as? Int, -32600)
        let error101 = try XCTUnwrap(byID[101]?["error"] as? [String: Any], "id 101 must get an error (batch not executed), not a real result")
        XCTAssertEqual(error101["code"] as? Int, -32600)
        let message101 = try XCTUnwrap(error101["message"] as? String)
        XCTAssertTrue(message101.contains("not executed"), "must explain the batch as a whole did not run. got: \(message101)")
    }

    // MARK: - Test 2: two normal items + one over-deep item

    func testBatchWithTwoNormalItemsAndOneOverDeepItemAllAnsweredInOneMessage() async throws {
        let mock = MockTransport()
        let sut = DepthLimitedTransport(wrapping: mock, maxRawJSONDepth: 4)
        try await sut.connect()

        let normalA = #"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"a":1}}"#
        let normalB = #"{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"a":2}}"#
        let deepItem = #"{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"a":[[[1]]]}}"#
        let batch = Data("[\(normalA),\(deepItem),\(normalB)]".utf8)

        let (forwarded, sent) = try await run(sut, mock, batch)
        XCTAssertTrue(forwarded.isEmpty)
        XCTAssertEqual(sent.count, 1)
        let merged = try jsonArray(try XCTUnwrap(sent.first))
        XCTAssertEqual(Set(merged.compactMap { $0["id"] as? Int }), [10, 20, 30])
        for entry in merged {
            XCTAssertNotNil(entry["error"], "every id must be answered with an error — none of them actually ran")
        }
    }

    // MARK: - Test 3: every item in the batch is over-depth

    func testBatchWhereEveryItemIsOverDepth() async throws {
        let mock = MockTransport()
        let sut = DepthLimitedTransport(wrapping: mock, maxRawJSONDepth: 4)
        try await sut.connect()

        let deepA = #"{"jsonrpc":"2.0","id":1,"method":"m","params":{"a":[[[1]]]}}"#
        let deepB = #"{"jsonrpc":"2.0","id":2,"method":"m","params":{"a":[[[2]]]}}"#
        let batch = Data("[\(deepA),\(deepB)]".utf8)

        let (forwarded, sent) = try await run(sut, mock, batch)
        XCTAssertTrue(forwarded.isEmpty)
        XCTAssertEqual(sent.count, 1)
        let errorArray = try jsonArray(try XCTUnwrap(sent.first))
        XCTAssertEqual(Set(errorArray.compactMap { $0["id"] as? Int }), [1, 2])
    }

    // MARK: - Test 4: legal sub-batch of ONLY a notification — no response for it, over-depth item still named

    func testNotificationPlusOverDeepItemAnswersOnlyTheOverDeepID() async throws {
        let mock = MockTransport()
        let sut = DepthLimitedTransport(wrapping: mock, maxRawJSONDepth: 4)
        try await sut.connect()

        let deepItem = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"a":[[[1]]]}}"#
        let legalNotification = #"{"jsonrpc":"2.0","method":"notifications/x","params":{"a":1}}"#
        let batch = Data("[\(deepItem),\(legalNotification)]".utf8)

        let (forwarded, sent) = try await run(sut, mock, batch)
        XCTAssertTrue(forwarded.isEmpty, "R3 never forwards anything from a refused batch, notifications included")
        XCTAssertEqual(sent.count, 1)
        let errorArray = try jsonArray(try XCTUnwrap(sent.first))
        XCTAssertEqual(errorArray.count, 1, "the notification gets no response entry at all")
        XCTAssertEqual(errorArray.first?["id"] as? Int, 1)
    }

    // MARK: - Test 5: notification + legal request + deep item (three-way mix, R1's original test shape)

    func testNotificationPlusLegalRequestPlusDeepItemAnswersBothIDsInOneMessage() async throws {
        let mock = MockTransport()
        let sut = DepthLimitedTransport(wrapping: mock, maxRawJSONDepth: 4)
        try await sut.connect()

        let deepNotification = #"{"jsonrpc":"2.0","method":"notifications/x","params":{"a":[[[1]]]}}"#
        let normalItem = #"{"jsonrpc":"2.0","id":5,"method":"m","params":{"a":1}}"#
        let batch = Data("[\(deepNotification),\(normalItem)]".utf8)

        let (forwarded, sent) = try await run(sut, mock, batch)
        XCTAssertTrue(forwarded.isEmpty)
        XCTAssertEqual(sent.count, 1)
        let merged = try jsonArray(try XCTUnwrap(sent.first))
        // The over-depth notification (no id at all) STILL gets an entry —
        // same established precedent as the non-batch single-message path
        // (an over-depth message always gets answered, notification or
        // not) — plus id 5's "batch not executed" entry.
        XCTAssertEqual(merged.count, 2)
        let nullIDEntry = merged.first { $0["id"] is NSNull }
        XCTAssertNotNil(nullIDEntry, "the over-depth notification falls back to a null-id entry")
        XCTAssertTrue(merged.contains { $0["id"] as? Int == 5 })
    }

    // MARK: - Test 6: whole-message depth inflated ONLY by the wrapping array — forwarded unchanged, untouched

    /// Regression guard for the exact mechanism #242 describes: scanning
    /// the WHOLE message always reads at least 1 deeper than scanning any
    /// one element alone. A batch whose items are ALL individually within
    /// cap must be forwarded EXACTLY as received — R3 does not even
    /// reconstruct it (no `continuation.yield` of a rebuilt array; the
    /// original `Data` object is forwarded byte-for-byte).
    func testBatchWhereWholeMessageDepthExceedsCapButEveryItemAloneDoesNotIsForwardedUnchanged() async throws {
        let itemA = #"{"jsonrpc":"2.0","id":1,"method":"m","params":{"a":1}}"#
        let itemB = #"{"jsonrpc":"2.0","id":2,"method":"m","params":{"a":2}}"#
        let itemScanA = DepthLimitedTransport.scanJSONRPCEnvelope(Data(itemA.utf8))
        let batch = Data("[\(itemA),\(itemB)]".utf8)
        let wholeScan = DepthLimitedTransport.scanJSONRPCEnvelope(batch)
        XCTAssertEqual(wholeScan.maxDepth, itemScanA.maxDepth + 1, "fixture must exercise the +1-purely-from-the-wrapping-array shape")

        let mock = MockTransport()
        let sut = DepthLimitedTransport(wrapping: mock, maxRawJSONDepth: itemScanA.maxDepth)
        try await sut.connect()
        let (forwarded, sent) = try await run(sut, mock, batch)

        XCTAssertEqual(forwarded, [batch], "forwarded byte-for-byte, unmodified — not reconstructed, not even reordered")
        XCTAssertTrue(sent.isEmpty, "nothing was over its own cap — no direct response, nothing to answer here at all")
    }

    // MARK: - Test 7 (#242-R2-1 CRITICAL regression guard): a schema-invalid-but-object-shaped item never poisons anything, never gets forwarded

    /// The exact shape the R2 review reproduced: an object-shaped batch
    /// item missing `method` (or any other required field) — R2's
    /// mechanism let this ride into the forwarded sub-batch, where
    /// swift-sdk's `Server.Batch.init(from:)` failed ATOMICALLY on it,
    /// losing every id in that batch and leaking a staged entry forever.
    /// R3 never forwards ANYTHING once one element is over depth, so this
    /// item — schema-invalid or not — is simply answered like any other
    /// non-over-depth, object-shaped, has-an-id element: a "batch not
    /// executed" error naming its own id. It is never handed to swift-sdk
    /// for decode at all in this branch, so there is nothing for it to
    /// poison.
    func testObjectShapedButSchemaInvalidItemNeverPoisonsAnythingAndIsAnsweredDirectly() async throws {
        let mock = MockTransport()
        let sut = DepthLimitedTransport(wrapping: mock, maxRawJSONDepth: 4)
        try await sut.connect()

        let deepItem = #"{"jsonrpc":"2.0","id":1,"method":"m","params":{"a":[[[1]]]}}"#
        // Object-shaped, has an id, but missing "method" — exactly what
        // R2's `isJSONObjectShaped` let through into the forwarded batch.
        let schemaInvalidItem = #"{"jsonrpc":"2.0","id":5,"params":{"x":1}}"#
        let batch = Data("[\(deepItem),\(schemaInvalidItem)]".utf8)

        let (forwarded, sent) = try await run(sut, mock, batch)
        XCTAssertTrue(forwarded.isEmpty, "nothing is ever forwarded once the batch is refused — the schema-invalid item cannot poison a decode that never happens")
        XCTAssertEqual(sent.count, 1, "exactly one message — R2's failure mode (zero messages, permanently lost ids) cannot occur")
        let merged = try jsonArray(try XCTUnwrap(sent.first))
        XCTAssertEqual(Set(merged.compactMap { $0["id"] as? Int }), [1, 5], "both ids answered, including the schema-invalid one")
        XCTAssertTrue(merged.allSatisfy { $0["error"] != nil })
    }

    // MARK: - Test 8 (#242-R2-2 HIGH regression guard): two batches with the SAME id set, run back to back, never cross-contaminate

    /// R2's staging dictionary was keyed by id set and OVERWRITTEN
    /// (`pendingIllegalByIDSet[ids] = responses`) — two concurrent batches
    /// sharing the same legal-sub-batch id set silently lost one batch's
    /// error entirely. R3 has no dictionary to key at all: each batch is
    /// answered synchronously, in the same pump-loop iteration that
    /// received it, using only that batch's own elements. Running two
    /// batches with an identical id set back-to-back must produce two
    /// independent, fully-correct messages.
    func testTwoBatchesWithTheSameIDSetNeverCrossContaminate() async throws {
        let mock = MockTransport()
        let sut = DepthLimitedTransport(wrapping: mock, maxRawJSONDepth: 4)
        try await sut.connect()

        // Both batches' "legal" (non-over-depth) item uses the SAME id
        // (101) — exactly the scenario R2's dictionary collided on. Each
        // batch's own over-depth item has a distinct id (1 vs 2).
        let batchA = Data(
            "[\(#"{"jsonrpc":"2.0","id":1,"method":"m","params":{"a":[[[1]]]}}"#),\(#"{"jsonrpc":"2.0","id":101,"method":"m"}"#)]"
                .utf8)
        let batchB = Data(
            "[\(#"{"jsonrpc":"2.0","id":2,"method":"m","params":{"a":[[[1]]]}}"#),\(#"{"jsonrpc":"2.0","id":101,"method":"m"}"#)]"
                .utf8)

        await mock.enqueue(batchA)
        await mock.enqueue(batchB)
        await mock.finishStream()
        var forwarded: [Data] = []
        for try await message in await sut.receive() {
            forwarded.append(message)
        }
        XCTAssertTrue(forwarded.isEmpty, "both batches are refused — nothing forwarded")

        let sent = await mock.sentMessages
        XCTAssertEqual(sent.count, 2, "each batch gets its OWN message — no merging, no state shared between them")
        guard sent.count == 2 else { return }
        let mergedA = try jsonArray(sent[0])
        let mergedB = try jsonArray(sent[1])
        XCTAssertEqual(Set(mergedA.compactMap { $0["id"] as? Int }), [1, 101], "batch A's message must name exactly batch A's ids")
        XCTAssertEqual(Set(mergedB.compactMap { $0["id"] as? Int }), [2, 101], "batch B's message must name exactly batch B's ids — id 1 from batch A must NEVER appear here")
        XCTAssertFalse(mergedB.contains { $0["id"] as? Int == 1 }, "no cross-contamination from batch A into batch B's message")
        XCTAssertFalse(mergedA.contains { $0["id"] as? Int == 2 }, "no cross-contamination from batch B into batch A's message")
    }

    /// Same shared id (101), but this time followed by an entirely
    /// ORDINARY non-batch request reusing that id after both batches were
    /// refused — proving there is no leftover state anywhere that could
    /// answer (or corrupt) an unrelated later call, the exact #242-R2-1
    /// "leaked entry poisons a future request" failure mode.
    func testOrdinaryRequestAfterARefusedBatchIsNotCorruptedByAnyLeftoverState() async throws {
        let mock = MockTransport()
        let sut = DepthLimitedTransport(wrapping: mock, maxRawJSONDepth: 4)
        try await sut.connect()

        let refusedBatch = Data(
            "[\(#"{"jsonrpc":"2.0","id":1,"method":"m","params":{"a":[[[1]]]}}"#),\(#"{"jsonrpc":"2.0","id":101,"method":"m"}"#)]"
                .utf8)
        await mock.enqueue(refusedBatch)
        // An ordinary, unrelated, non-batch request reusing id 101 —
        // sent directly to `sut.send`-observable territory by simulating
        // what swift-sdk would forward-then-answer for it: since R3 never
        // forwards the refused batch at all, `sut.receive()` yields
        // NOTHING for it — a real swift-sdk never even sees id 101 from
        // the batch, so a later, unrelated single request with the same
        // id is completely ordinary traffic from swift-sdk's perspective.
        // What matters here is that `send(_:)` performs NO inspection or
        // merging at all any more — assert it passes arbitrary data
        // through byte-for-byte regardless of what was refused earlier.
        await mock.finishStream()
        for try await _ in await sut.receive() {
            XCTFail("nothing should ever be forwarded from the refused batch")
        }

        let unrelatedResponse = Data(#"{"jsonrpc":"2.0","id":101,"result":{"ok":true}}"#.utf8)
        try await sut.send(unrelatedResponse)
        let sent = await mock.sentMessages
        XCTAssertEqual(sent.count, 2, "the refused batch's own message, plus this unrelated send")
        XCTAssertEqual(sent.last, unrelatedResponse, "send(_:) must forward byte-for-byte, unmodified — no merge logic left to corrupt it")
    }

    // MARK: - Test 9: non-object batch element (bare scalar) gets id: null, deep item still named

    func testNonObjectBatchItemGetsNullIDInvalidRequest() async throws {
        let mock = MockTransport()
        let sut = DepthLimitedTransport(wrapping: mock, maxRawJSONDepth: 4)
        try await sut.connect()

        let deepItem = #"{"jsonrpc":"2.0","id":1,"method":"m","params":{"a":[[[1]]]}}"#
        let batch = Data("[42,\(deepItem)]".utf8)

        let (forwarded, sent) = try await run(sut, mock, batch)
        XCTAssertTrue(forwarded.isEmpty)
        XCTAssertEqual(sent.count, 1)
        let merged = try jsonArray(try XCTUnwrap(sent.first))
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged.contains { $0["id"] is NSNull }, "the bare `42` item cannot carry an id — must fall back to null")
        XCTAssertTrue(merged.contains { $0["id"] as? Int == 1 })
    }

    // MARK: - batchNotExecutedErrorResponse: unit-level coverage

    func testBatchNotExecutedErrorResponseShape() throws {
        let response = DepthLimitedTransport.batchNotExecutedErrorResponse(idToken: "5", overDepthIndices: [0, 2], maxDepth: 64)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["id"] as? Int, 5)
        let error = try XCTUnwrap(parsed["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32600)
        let message = try XCTUnwrap(error["message"] as? String)
        XCTAssertTrue(message.contains("0") && message.contains("2"), "must name the offending indices. got: \(message)")
        XCTAssertTrue(message.contains("not executed"))
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

    // MARK: - Empty batch `[]` — falls through to the normal-forward path (see #242 R3's own doc comment / CHANGELOG)

    func testEmptyBatchIsForwardedLikeAnyOtherWithinCapMessage() async throws {
        let mock = MockTransport()
        let sut = DepthLimitedTransport(wrapping: mock, maxRawJSONDepth: 4)
        try await sut.connect()
        let empty = Data("[]".utf8)
        let (forwarded, sent) = try await run(sut, mock, empty)
        XCTAssertEqual(forwarded, [empty], "an empty batch is shallow (depth 1) — well within any reasonable cap, forwarded like any other message; swift-sdk's own \"batch array must not be empty\" error applies downstream, unrelated to this guard")
        XCTAssertTrue(sent.isEmpty)
    }
}
