import XCTest
@testable import CheWordMCP

final class AuthorAliasMapTests: XCTestCase {

    func testCanonicalizeMapped() {
        let map = AuthorAliasMap(["kllay's PC": "Lay", "Lay": "Lay"])
        XCTAssertEqual(map.canonicalize("kllay's PC"), "Lay")
        XCTAssertEqual(map.canonicalize("Lay"), "Lay")
    }

    func testCanonicalizeUnmapped() {
        let map = AuthorAliasMap(["kllay's PC": "Lay"])
        XCTAssertEqual(map.canonicalize("Tatsuma"), "Tatsuma",
                       "Unmapped raw author must pass through unchanged")
    }

    func testEmptyMap() {
        let map = AuthorAliasMap([:])
        XCTAssertEqual(map.canonicalize("Anyone"), "Anyone",
                       "Empty map must pass through every input unchanged")
    }
}
