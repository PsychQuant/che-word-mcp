import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// Phase 2 task 2.6 of the `che-word-mcp-true-byte-preservation` Spectra change.
///
/// Validates the v3.5.0 (#34) `<w15:presenceInfo>` parsing + dual-identity
/// (person_id GUID / display_name_id legacy author) accept-either contract for
/// list_people, update_person, delete_person.
final class PeoplePresenceInfoTests: XCTestCase {

    // MARK: - Fixture builders

    /// Build a fixture .docx with `word/people.xml` containing the supplied
    /// `<w15:person>...</w15:person>` block. Reuses scratch-mode DocxWriter
    /// to bootstrap the rest of the archive then injects people.xml + the
    /// Content_Types Override entry via re-zip.
    private func makeFixture(withPeopleXML peopleXML: String) throws -> URL {
        var doc = WordDocument()
        doc.appendParagraph(Paragraph(text: "Body content"))
        let baseFixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("ppi-base-\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: baseFixture)
        defer { try? FileManager.default.removeItem(at: baseFixture) }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("ppi-staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { ZipHelper.cleanup(staging) }
        try FileManager.default.unzipItem(at: baseFixture, to: staging)

        try peopleXML.write(
            to: staging.appendingPathComponent("word/people.xml"),
            atomically: true, encoding: .utf8
        )
        // Inject Content_Types Override for people.xml so ContentTypesOverlay
        // sees it on round-trip and re-emits it correctly.
        let ctURL = staging.appendingPathComponent("[Content_Types].xml")
        var ctContent = try String(contentsOf: ctURL, encoding: .utf8)
        let peopleOverride = #"<Override PartName="/word/people.xml" ContentType="application/vnd.ms-word.people+xml"/>"#
        ctContent = ctContent.replacingOccurrences(of: "</Types>", with: "\(peopleOverride)</Types>")
        try ctContent.write(to: ctURL, atomically: true, encoding: .utf8)

        // Add a /people relationship so the typed model wires up cleanly.
        let relsURL = staging.appendingPathComponent("word/_rels/document.xml.rels")
        var relsContent = try String(contentsOf: relsURL, encoding: .utf8)
        let peopleRel = #"<Relationship Id="rId99" Type="http://schemas.microsoft.com/office/2011/relationships/people" Target="people.xml"/>"#
        relsContent = relsContent.replacingOccurrences(of: "</Relationships>", with: "\(peopleRel)</Relationships>")
        try relsContent.write(to: relsURL, atomically: true, encoding: .utf8)

        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("ppi-\(UUID().uuidString).docx")
        try ZipHelper.zip(staging, to: fixture)
        return fixture
    }

    private func resultText(_ result: CallTool.Result) -> String {
        guard let first = result.content.first else { return "" }
        if case .text(let text, _, _) = first { return text }
        return ""
    }

    // MARK: - (a) Full presenceInfo with userId triple → dual identity

    func testListPeopleParsesFullPresenceInfoTriple() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w15:people xmlns:w15="http://schemas.microsoft.com/office/word/2012/wordml">
          <w15:person w15:author="Test User">
            <w15:presenceInfo w15:providerId="AD" w15:userId="S::test@example.com::aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"/>
          </w15:person>
        </w15:people>
        """
        let fixture = try makeFixture(withPeopleXML: xml)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("doc")]
        )
        let result = await server.invokeToolForTesting(
            name: "list_people", arguments: ["doc_id": .string("doc")]
        )
        let json = resultText(result)
        XCTAssertTrue(json.contains("\"person_id\":\"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\""),
                      "person_id should be the GUID extracted from userId triple, got: \(json)")
        XCTAssertTrue(json.contains("\"display_name_id\":\"Test User\""),
                      "display_name_id is the v3.4.0 legacy author identifier")
        XCTAssertTrue(json.contains("\"display_name\":\"Test User\""))
        XCTAssertTrue(json.contains("\"email\":\"test@example.com\""))
        XCTAssertTrue(json.contains("\"provider_id\":\"AD\""))

        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )
    }

    // MARK: - (b) presenceInfo without GUID → person_id falls back to author

    func testListPeopleFallsBackToAuthorWhenNoGUID() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w15:people xmlns:w15="http://schemas.microsoft.com/office/word/2012/wordml">
          <w15:person w15:author="Legacy Author">
            <w15:presenceInfo w15:providerId="None" w15:userId="Legacy Author"/>
          </w15:person>
        </w15:people>
        """
        let fixture = try makeFixture(withPeopleXML: xml)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("doc")]
        )
        let result = await server.invokeToolForTesting(
            name: "list_people", arguments: ["doc_id": .string("doc")]
        )
        let json = resultText(result)
        XCTAssertTrue(json.contains("\"person_id\":\"Legacy Author\""),
                      "Without GUID, person_id falls back to author for v3.4.0 backward compat")
        XCTAssertTrue(json.contains("\"display_name_id\":\"Legacy Author\""))
        XCTAssertTrue(json.contains("\"provider_id\":\"None\""))

        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )
    }

    // MARK: - (c) update_person via GUID path

    func testUpdatePersonViaGUIDIdentifier() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w15:people xmlns:w15="http://schemas.microsoft.com/office/word/2012/wordml">
          <w15:person w15:author="Old Name">
            <w15:presenceInfo w15:providerId="AD" w15:userId="S::user@x.com::11111111-2222-3333-4444-555555555555"/>
          </w15:person>
        </w15:people>
        """
        let fixture = try makeFixture(withPeopleXML: xml)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("doc")]
        )
        let updateResult = await server.invokeToolForTesting(
            name: "update_person",
            arguments: [
                "doc_id": .string("doc"),
                "person_id": .string("11111111-2222-3333-4444-555555555555"),
                "display_name": .string("Renamed via GUID")
            ]
        )
        XCTAssertFalse(resultText(updateResult).hasPrefix("Error:"),
                       "update_person via GUID path must succeed")

        let listResult = await server.invokeToolForTesting(
            name: "list_people", arguments: ["doc_id": .string("doc")]
        )
        XCTAssertTrue(resultText(listResult).contains("Renamed via GUID"))

        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )
    }

    // MARK: - (d) update_person via display_name_id path

    func testUpdatePersonViaDisplayNameIdIdentifier() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w15:people xmlns:w15="http://schemas.microsoft.com/office/word/2012/wordml">
          <w15:person w15:author="Author Legacy">
            <w15:presenceInfo w15:providerId="AD" w15:userId="S::a@x.com::cccccccc-dddd-eeee-ffff-000000000000"/>
          </w15:person>
        </w15:people>
        """
        let fixture = try makeFixture(withPeopleXML: xml)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("doc")]
        )
        let updateResult = await server.invokeToolForTesting(
            name: "update_person",
            arguments: [
                "doc_id": .string("doc"),
                "person_id": .string("Author Legacy"),  // legacy form
                "display_name": .string("Renamed via legacy id")
            ]
        )
        XCTAssertFalse(resultText(updateResult).hasPrefix("Error:"),
                       "update_person via display_name_id (legacy author) must also succeed")

        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )
    }

    // MARK: - (e) delete_person via either identifier

    func testDeletePersonViaEitherIdentifier() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w15:people xmlns:w15="http://schemas.microsoft.com/office/word/2012/wordml">
          <w15:person w15:author="Person A">
            <w15:presenceInfo w15:providerId="AD" w15:userId="S::a@x.com::aaaaaaaa-1111-1111-1111-111111111111"/>
          </w15:person>
          <w15:person w15:author="Person B">
            <w15:presenceInfo w15:providerId="AD" w15:userId="S::b@x.com::bbbbbbbb-2222-2222-2222-222222222222"/>
          </w15:person>
        </w15:people>
        """
        let fixture = try makeFixture(withPeopleXML: xml)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("doc")]
        )
        // Delete via GUID
        let r1 = await server.invokeToolForTesting(
            name: "delete_person",
            arguments: ["doc_id": .string("doc"), "person_id": .string("aaaaaaaa-1111-1111-1111-111111111111")]
        )
        XCTAssertTrue(resultText(r1).contains("\"comments_orphaned\""),
                      "delete via GUID path returns standard JSON envelope")

        // Delete remaining via legacy author
        let r2 = await server.invokeToolForTesting(
            name: "delete_person",
            arguments: ["doc_id": .string("doc"), "person_id": .string("Person B")]
        )
        XCTAssertTrue(resultText(r2).contains("\"comments_orphaned\""),
                      "delete via display_name_id (legacy author) path also works")

        let listResult = await server.invokeToolForTesting(
            name: "list_people", arguments: ["doc_id": .string("doc")]
        )
        XCTAssertEqual(resultText(listResult), "[]", "Both people should be removed")

        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )
    }
}
