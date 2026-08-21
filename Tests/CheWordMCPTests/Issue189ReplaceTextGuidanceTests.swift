import XCTest
@testable import CheWordMCP

/// #189 deliverable 1: the replace tools must tell callers which tick character
/// to use, because choosing the wrong one produces a document whose text layer
/// is completely correct and whose appearance is wrong — `get_tables` compares
/// clean, and only a human opening the file sees the emoji-styled checkbox.
///
/// The assertions below are deliberately about *content*, not phrasing, so the
/// wording can be improved without breaking them. The one thing they pin down
/// is the scope: the guidance must not be narrowed to CJK fonts later, because
/// the measurement behind it found U+2611 missing from Times New Roman and
/// Arial too. A CJK-only phrasing would read as "Latin forms are fine", which
/// is false.
final class Issue189ReplaceTextGuidanceTests: XCTestCase {

    private func description(ofToolNamed name: String) async throws -> String {
        let server = await WordMCPServer()
        let tools = await server.allTools
        let tool = try XCTUnwrap(tools.first { $0.name == name }, "\(name) is not registered")
        return try XCTUnwrap(tool.description, "\(name) has no description")
    }

    func testReplaceTextRecommendsBlackSquare() async throws {
        let d = try await description(ofToolNamed: "replace_text")
        XCTAssertTrue(d.contains("U+25A0"), "must name the recommended tick by code point")
        XCTAssertTrue(d.contains("■"), "must show the recommended tick itself")
    }

    func testReplaceTextWarnsAgainstBallotBoxCharacters() async throws {
        let d = try await description(ofToolNamed: "replace_text")
        XCTAssertTrue(d.contains("U+2611"), "must name the character that triggers emoji fallback")
    }

    func testReplaceTextGuidanceIsNotScopedToCJKFonts() async throws {
        let d = try await description(ofToolNamed: "replace_text")
        XCTAssertTrue(
            d.contains("Times New Roman") || d.contains("Arial"),
            "The guidance must cite a non-CJK font. U+2611 is absent from Times New Roman "
            + "and Arial as well, so scoping this advice to CJK fonts would tell callers "
            + "that Latin-font forms are safe when they are not.")
    }

    func testReplaceTextBatchCarriesTheSameGuidance() async throws {
        let d = try await description(ofToolNamed: "replace_text_batch")
        XCTAssertTrue(d.contains("U+25A0"),
                      "batch replacement is the likelier path for filling a form, so it "
                      + "must not be the one without the guidance")
        XCTAssertTrue(d.contains("U+2611"))
    }
}
