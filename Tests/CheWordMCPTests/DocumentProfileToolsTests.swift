import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

final class DocumentProfileToolsTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("profile-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func template(in dir: URL) throws -> URL {
        let source = dir.appendingPathComponent("template-parts")
        let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
        let parts = [
            "word/styles.xml": "<w:styles xmlns:w=\"\(w)\"><w:docDefaults><w:rPrDefault><w:rPr><w:sz w:val=\"24\"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr/></w:pPrDefault></w:docDefaults><w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/></w:style></w:styles>",
            "word/document.xml": "<w:document xmlns:w=\"\(w)\"><w:body><w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1440\" w:right=\"1800\" w:bottom=\"1440\" w:left=\"1800\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/></w:sectPr></w:body></w:document>"
        ]
        for (path, xml) in parts {
            let file = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(xml.utf8).write(to: file)
        }
        let url = dir.appendingPathComponent("Normal.dotm")
        try ZipHelper.zipToData(source).write(to: url)
        return url
    }

    private func source(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("source.docx")
        var doc = WordDocument.emptyAuthoringDocument()
        try doc.apply(operations: [.appendParagraph(in: nil, paragraph: ParagraphPayload(text: "既有內容", paraId: "P1"))])
        try doc.writeAuthoringPackage(to: url)
        return url
    }

    private func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { if case .text(let value) = $0 { return value.text }; return nil }.joined()
    }

    func testCreateUsesConfiguredOfficialAndExplicitInherit() async throws {
        let dir = try directory(), config = dir.appendingPathComponent("config.json")
        let store = DocumentProfileStore(configURL: config)
        try store.importOfficial(from: template(in: dir))
        try store.setDefaultProfile(.official)
        let server = await WordMCPServer(documentConfigURL: config)
        for (id, profile) in [("default", nil as Value?), ("override", .string("inherit"))] {
            var args: [String: Value] = ["doc_id": .string(id)]
            args["profile"] = profile
            let created = await server.invokeToolForTesting(name: "create_document", arguments: args)
            XCTAssertFalse(created.isError == true, text(created))
            let dirty = await server.isDocumentDirtyForTesting(id)
            XCTAssertEqual(dirty, id == "default")
            let output = dir.appendingPathComponent("\(id).docx")
            let saved = await server.invokeToolForTesting(name: "save_document", arguments: ["doc_id": .string(id), "path": .string(output.path)])
            XCTAssertFalse(saved.isError == true, text(saved))
            let styles = String(decoding: try XCTUnwrap(RawPartChannel.readAllParts(from: output)["word/styles.xml"]), as: UTF8.self)
            XCTAssertEqual(styles.contains("DFKai-SB"), id == "default")
            if id == "override" { XCTAssertFalse(styles.contains("Calibri")) }
        }
    }

    func testBadProfileArgumentsFailBeforeSessionRegistrationOrOutput() async throws {
        let dir = try directory(), config = dir.appendingPathComponent("config.json"), original = try source(in: dir)
        let server = await WordMCPServer(documentConfigURL: config)
        let script = dir.appendingPathComponent("source.mdocx.swift"), output = dir.appendingPathComponent("output.docx")
        _ = try scriptPipelineExport(sourcePath: original.path, outputPath: script.path)
        let sentinel = Data("existing output".utf8)
        try sentinel.write(to: output)
        for profile in [Value.null, .bool(true), .int(1), .array([]), .object([:]), .string("unknown")] {
            for tool in ["create_document", "open_document", "execute_script"] {
                let result = await server.invokeToolForTesting(name: tool, arguments: [
                    "doc_id": .string("failed"), "path": .string(original.path), "profile": profile,
                    "script_path": .string(script.path), "output_path": .string(output.path), "overwrite": .bool(true)])
                XCTAssertTrue(result.isError == true, "\(tool): \(text(result))")
                XCTAssertTrue(text(result).contains("profile"))
                XCTAssertEqual(try Data(contentsOf: output), sentinel)
            }
        }
        let created = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("failed"), "profile": .string("inherit")])
        XCTAssertFalse(created.isError == true, "failed calls must not reserve doc_id: \(text(created))")
    }

    func testMissingOrCorruptProfileDoesNotRegisterSessions() async throws {
        let dir = try directory(), config = dir.appendingPathComponent("config.json"), original = try source(in: dir)
        try Data(#"{"document":{"defaultProfile":"official","officialSnapshot":"missing.json"}}"#.utf8).write(to: config)
        let server = await WordMCPServer(documentConfigURL: config)
        for tool in ["create_document", "open_document"] {
            let result = await server.invokeToolForTesting(name: tool, arguments: ["doc_id": .string(tool), "path": .string(original.path), "profile": .string("official")])
            XCTAssertTrue(result.isError == true, text(result))
            let inherited = await server.invokeToolForTesting(name: tool, arguments: ["doc_id": .string(tool), "path": .string(original.path), "profile": .string("inherit")])
            XCTAssertFalse(inherited.isError == true, text(inherited))
        }
        try Data("broken configuration".utf8).write(to: config)
        let created = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("bad-default")])
        XCTAssertTrue(created.isError == true, text(created))
        let retry = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("bad-default"), "profile": .string("inherit")])
        XCTAssertFalse(retry.isError == true, text(retry))
    }

    func testOpenNoProfileOrInheritDoesNotReadConfigMarkDirtyOrAutosave() async throws {
        let dir = try directory(), config = dir.appendingPathComponent("config.json"), original = try source(in: dir)
        let before = try Data(contentsOf: original)
        try Data("broken configuration".utf8).write(to: config)
        let server = await WordMCPServer(documentConfigURL: config)
        for (id, profile) in [("absent", nil as Value?), ("inherit", .string("inherit"))] {
            var args: [String: Value] = ["doc_id": .string(id), "path": .string(original.path), "autosave": .bool(true)]
            args["profile"] = profile
            let result = await server.invokeToolForTesting(name: "open_document", arguments: args)
            XCTAssertFalse(result.isError == true, text(result))
            let dirty = await server.isDocumentDirtyForTesting(id)
            XCTAssertFalse(dirty)
            XCTAssertEqual(try Data(contentsOf: original), before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: original.path + ".autosave.docx"))
        }
    }

    func testOpenOfficialMarksDirtyAndHonorsAutosaveAfterSuccessfulApplication() async throws {
        let dir = try directory(), config = dir.appendingPathComponent("config.json"), original = try source(in: dir)
        try DocumentProfileStore(configURL: config).importOfficial(from: template(in: dir))
        let before = try Data(contentsOf: original)
        let server = await WordMCPServer(documentConfigURL: config)
        let opened = await server.invokeToolForTesting(name: "open_document", arguments: ["doc_id": .string("official"), "path": .string(original.path), "profile": .string("official")])
        XCTAssertFalse(opened.isError == true, text(opened))
        let dirty = await server.isDocumentDirtyForTesting("official")
        XCTAssertTrue(dirty)
        XCTAssertEqual(try Data(contentsOf: original), before)
        let saved = await server.invokeToolForTesting(name: "save_document", arguments: ["doc_id": .string("official")])
        XCTAssertFalse(saved.isError == true, text(saved))
        let styles = String(decoding: try XCTUnwrap(RawPartChannel.readAllParts(from: original)["word/styles.xml"]), as: UTF8.self)
        XCTAssertTrue(styles.contains("DFKai-SB"))
        let second = dir.appendingPathComponent("autosave.docx")
        try before.write(to: second)
        let autosaved = await server.invokeToolForTesting(name: "open_document", arguments: ["doc_id": .string("auto"), "path": .string(second.path), "profile": .string("official"), "autosave": .bool(true)])
        XCTAssertFalse(autosaved.isError == true, text(autosaved))
        let autoStyles = String(decoding: try XCTUnwrap(RawPartChannel.readAllParts(from: second)["word/styles.xml"]), as: UTF8.self)
        XCTAssertTrue(autoStyles.contains("DFKai-SB"))
    }

    func testOpenOfficialAutosaveWordLockFailureRollsBackSessionAndAllowsRetry() async throws {
        try await assertOpenAutosaveFailureRollsBack(useWordLock: true)
    }

    func testOpenOfficialAutosaveWriteFailureRollsBackSessionAndAllowsRetry() async throws {
        try await assertOpenAutosaveFailureRollsBack(useWordLock: false)
    }

    private func assertOpenAutosaveFailureRollsBack(useWordLock: Bool) async throws {
        let dir = try directory(), config = dir.appendingPathComponent("config.json")
        let documents = dir.appendingPathComponent("documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let original = try source(in: documents), before = try Data(contentsOf: original)
        try DocumentProfileStore(configURL: config).importOfficial(from: template(in: dir))
        let server = await WordMCPServer(documentConfigURL: config)
        addTeardownBlock {
            for id in ["kept", "retry"] {
                _ = await server.invokeToolForTesting(name: "close_document", arguments: ["doc_id": .string(id), "discard_changes": .bool(true)])
            }
        }
        // Keep an unrelated session open so rollback cannot clear all sessions.
        let kept = await server.invokeToolForTesting(name: "open_document", arguments: [
            "doc_id": .string("kept"), "path": .string(original.path)])
        XCTAssertFalse(kept.isError == true, text(kept))
        let modified = await server.invokeToolForTesting(name: "insert_paragraph", arguments: [
            "doc_id": .string("kept"), "text": .string("保留這個 session 的未存修改")])
        XCTAssertFalse(modified.isError == true, text(modified))
        let keptDocument = await server.openDocuments["kept"]
        let keptArchive = try XCTUnwrap(keptDocument?.archiveTempDir)
        let archiveNamespace = keptArchive.deletingLastPathComponent()
        let archiveNamesBefore = Set(try FileManager.default.contentsOfDirectory(atPath: archiveNamespace.path))
        let lock = WordLock.lockFileURL(for: original)
        if useWordLock {
            try Data("Word lock".utf8).write(to: lock)
        } else {
            // A real filesystem write failure, after successful read/application.
            // Only this test-owned directory is made read-only.
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: documents.path)
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: documents.path) }

        let args: [String: Value] = ["doc_id": .string("retry"), "path": .string(original.path),
                                    "profile": .string("official"), "autosave": .bool(true)]
        let failed = await server.invokeToolForTesting(name: "open_document", arguments: args)
        XCTAssertTrue(failed.isError == true, text(failed))
        let failedDocument = await server.openDocuments["retry"]
        XCTAssertTrue(failedDocument == nil, "a failed open must not register a session")
        let failedDirty = await server.isDocumentDirtyForTesting("retry")
        XCTAssertFalse(failedDirty)
        XCTAssertEqual(try Data(contentsOf: original), before)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: archiveNamespace.path)).subtracting(archiveNamesBefore), [],
                       "a failed open must release its extracted archive")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: documents.path).contains { $0.contains(".tmp.") || $0.contains(".autosave.") })

        // A duplicate-id refusal must not dispose of the pre-existing session.
        var duplicateArgs = args
        duplicateArgs["doc_id"] = .string("kept")
        let duplicate = await server.invokeToolForTesting(name: "open_document", arguments: duplicateArgs)
        XCTAssertTrue(duplicate.isError == true, text(duplicate))
        let keptAfter = await server.openDocuments["kept"]
        XCTAssertEqual(keptAfter, keptDocument)
        let keptDirty = await server.isDocumentDirtyForTesting("kept")
        XCTAssertTrue(keptDirty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptArchive.path))

        if useWordLock { try FileManager.default.removeItem(at: lock) }
        else { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: documents.path) }
        let retried = await server.invokeToolForTesting(name: "open_document", arguments: args)
        XCTAssertFalse(retried.isError == true, text(retried))
        if retried.isError != true {
            let styles = String(decoding: try XCTUnwrap(RawPartChannel.readAllParts(from: original)["word/styles.xml"]), as: UTF8.self)
            XCTAssertTrue(styles.contains("DFKai-SB"), "retry must perform the requested official autosave")
        }
        let retryDirty = await server.isDocumentDirtyForTesting("retry")
        XCTAssertFalse(retryDirty, "successful autosave should clear dirty state")
    }

    func testExecuteIgnoresDefaultAndAppliesBeforeVerificationAndPublication() async throws {
        let dir = try directory(), config = dir.appendingPathComponent("config.json"), original = try source(in: dir)
        let store = DocumentProfileStore(configURL: config)
        try store.importOfficial(from: template(in: dir))
        try store.setDefaultProfile(.official)
        let server = await WordMCPServer(documentConfigURL: config)
        let script = dir.appendingPathComponent("source.mdocx.swift"), output = dir.appendingPathComponent("output.docx")
        _ = try scriptPipelineExport(sourcePath: original.path, outputPath: script.path)
        var args: [String: Value] = ["script_path": .string(script.path), "output_path": .string(output.path), "verify_byte_equal_against": .string(original.path), "overwrite": .bool(true)]
        let unchanged = await server.invokeToolForTesting(name: "execute_script", arguments: args)
        XCTAssertFalse(unchanged.isError == true, text(unchanged))
        let before = try Data(contentsOf: output)
        args["profile"] = .string("official")
        let rejected = await server.invokeToolForTesting(name: "execute_script", arguments: args)
        XCTAssertTrue(rejected.isError == true, text(rejected))
        XCTAssertTrue(text(rejected).contains("驗證失敗"))
        XCTAssertEqual(try Data(contentsOf: output), before)
        args.removeValue(forKey: "verify_byte_equal_against")
        let applied = await server.invokeToolForTesting(name: "execute_script", arguments: args)
        XCTAssertFalse(applied.isError == true, text(applied))
        let expected = dir.appendingPathComponent("direct.docx")
        _ = try scriptPipelineExecute(scriptPath: script.path, outputPath: expected.path, formattingProfile: store.resolve(explicit: .official, context: .existingDocument))
        XCTAssertEqual(try RawPartChannel.readAllParts(from: output), try RawPartChannel.readAllParts(from: expected))
        try Data("broken configuration".utf8).write(to: config)
        args.removeValue(forKey: "profile")
        args["verify_byte_equal_against"] = .string(original.path)
        let ignored = await server.invokeToolForTesting(name: "execute_script", arguments: args)
        XCTAssertFalse(ignored.isError == true, text(ignored))
    }
}
