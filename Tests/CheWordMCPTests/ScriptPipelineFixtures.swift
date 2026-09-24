// ScriptPipelineFixtures.swift
// #227 — fixtures shared by the script-pipeline tests (ungated tool tests in
// Issue227ScriptCoverageReasonsTests and the gated CLI cross-check in
// ScriptPipelineParityTests).

import Foundation
import OOXMLSwift

enum ScriptPipelineFixtures {

    /// Body paragraphs of `writeParagraphsWithoutParaId`, in document order
    /// (text, pStyle). The table between the second and third paragraph is
    /// not listed: paragraphs-only export omits it.
    static let paragraphsWithoutParaId: [(text: String, style: String?)] = [
        ("Assignment 02", "Heading1"),
        ("第一段「引號」與 \"quotes\" 與反斜線 \\ 結尾", nil),
        ("表格之後的段落", nil),
        ("", nil),
    ]

    /// Text inside the table cell — must NOT survive a paragraphs-only export.
    static let tableCellText = "表格裡的文字"

    /// A docx whose paragraphs carry no `w14:paraId` — the shape Word 2010 and
    /// many converters produce (PsychQuant/macdoc#181). Direct body mutation
    /// bypasses the authoring chokepoints, so nothing is stamped and
    /// ReverseExtractor keeps document.xml on the raw channel with the
    /// `paragraph-no-paraId` reason. A table and an empty paragraph are
    /// included so paragraphs-only omission and synthesized ids get exercised.
    static func writeParagraphsWithoutParaId(to url: URL) throws {
        var doc = WordDocument()
        func paragraph(_ entry: (text: String, style: String?)) -> BodyChild {
            var p = entry.text.isEmpty ? Paragraph() : Paragraph(runs: [Run(text: entry.text)])
            p.properties.style = entry.style
            return .paragraph(p)
        }
        doc.body.children.append(paragraph(paragraphsWithoutParaId[0]))
        doc.body.children.append(paragraph(paragraphsWithoutParaId[1]))
        var cell = TableCell()
        cell.paragraphs = [Paragraph(runs: [Run(text: tableCellText)])]
        doc.body.children.append(.table(Table(rows: [TableRow(cells: [cell])])))
        doc.body.children.append(paragraph(paragraphsWithoutParaId[2]))
        doc.body.children.append(paragraph(paragraphsWithoutParaId[3]))
        try DocxWriter.write(doc, to: url)
    }

    /// A pure-paragraph authoring docx (every paragraph stamped with a
    /// paraId), so document.xml rides the DSL channel.
    static func writeAuthoredParagraphs(to url: URL) throws {
        var doc = WordDocument.emptyAuthoringDocument()
        try doc.apply(operations: [
            .appendParagraph(in: nil, paragraph: ParagraphPayload(
                text: "標題", styleId: "Heading1", paraId: "A1")),
            .appendParagraph(in: nil, paragraph: ParagraphPayload(
                text: "本文", paraId: "A2")),
        ])
        try doc.writeAuthoringPackage(to: url)
    }

    /// Top-level body paragraphs of a docx as (text, pStyle), in order.
    static func bodyParagraphs(of url: URL) throws -> [(text: String, style: String?)] {
        let document = try DocxReader.read(from: url)
        return document.body.children.compactMap { child in
            if case .paragraph(let p) = child { return (p.text, p.properties.style) }
            return nil
        }
    }
}
