# Paragraph Index Conventions

> **Status — current behavior, canonical pick pending.**
> This document describes the *current* `paragraph_index` conventions across
> MCP tools, which differ between insert / mutate / readback families. The
> canonical convention pick (so callers can rely on one universal index
> family) is tracked in
> [PsychQuant/ooxml-swift#10](https://github.com/PsychQuant/ooxml-swift/issues/10)
> and a future macdoc Spectra change. Until that lands, callers should
> consult the per-tool inventory below rather than assume one universal
> index family. Schema descriptions in `Server.swift` are being updated
> incrementally — if a tool's schema text says only `段落索引（從 0 開始）`
> without specifying which family, treat that as stale and look it up here.
> Schema-audit follow-up: [#138](https://github.com/PsychQuant/che-word-mcp/issues/138).

`paragraph_index` and `index` are historical names in this project. They do
not always count the same thing, because inserting a new OOXML block and
mutating an existing paragraph use different coordinate systems.

## Index Families

| Family | Counts | Skips | Typical use |
| --- | --- | --- | --- |
| `body.children` insertion index | Every top-level child under `w:body`: paragraphs, tables, block-level SDTs, bookmark markers, raw block elements | Nothing at the top level | Insert a new top-level block before/after a body child |
| Top-level paragraph ordinal | Top-level `.paragraph` body children only | Tables, block-level SDTs, bookmark markers, raw block elements | Mutate an existing direct body paragraph |
| `get_paragraphs` readback index | Top-level paragraphs plus paragraphs inside block-level SDTs | Table-cell paragraphs | Read or inspect paragraphs returned by `get_paragraphs` |

The same integer is not portable across these families. For example, in a
document whose body is:

1. Top-level paragraph
2. Table
3. Block-level SDT containing one paragraph
4. Top-level paragraph

`insert_paragraph(index: 1)` inserts before the table, because index `1` is a
`body.children` insertion point. `format_text(paragraph_index: 1)` targets the
second top-level paragraph, because formatting uses top-level paragraph
ordinal. `get_paragraphs()[1]` returns the paragraph inside the block-level
SDT, because `get_paragraphs` descends into block-level SDTs but not tables.

## Tool Inventory

| Tool / parameter | Family | Notes |
| --- | --- | --- |
| `insert_paragraph.index` | `body.children` insertion index | `index == body.children.count` appends at end. |
| `insert_caption.paragraph_index` | `body.children` insertion index | Used with `position` to insert above or below a body child. |
| `insert_equation.paragraph_index`, `display_mode=true` | `body.children` insertion index | Display equations are inserted as a new top-level paragraph. |
| `insert_equation.paragraph_index`, `display_mode=false` | Top-level paragraph ordinal | Inline equations append an OMML run to an existing direct body paragraph. |
| `update_paragraph.index`, `delete_paragraph.index` | Top-level paragraph ordinal | Historical `index` name; not a `body.children` insertion point. |
| `insert_text.paragraph_index` | Top-level paragraph ordinal | Fixed in [#140](https://github.com/PsychQuant/che-word-mcp/issues/140) — previously bounds-checked against the readback index while mutating top-level, which could overwrite a top-level paragraph with an SDT-inner paragraph's text. |
| `format_text.paragraph_index`, `set_paragraph_format.paragraph_index`, `apply_style.paragraph_index` | Top-level paragraph ordinal | Mutates direct body paragraphs. |
| `set_paragraph_border.paragraph_index`, `set_paragraph_shading.paragraph_index`, `set_character_spacing.paragraph_index`, `set_text_effect.paragraph_index` | Top-level paragraph ordinal | Advanced paragraph formatting tools mutate direct body paragraphs. che-word-mcp adds its own top-level bounds check ([#139](https://github.com/PsychQuant/che-word-mcp/issues/139)) before calling into ooxml-swift, whose own bounds check is readback-based and would otherwise let an out-of-top-level-range index through to a mutation loop that silently does nothing. |
| `insert_symbol.paragraph_index`, `insert_drop_cap.paragraph_index`, `insert_horizontal_line.paragraph_index`, `set_widow_orphan.paragraph_index`, `set_keep_with_next.paragraph_index`, `set_keep_lines.paragraph_index`, `set_page_break_before.paragraph_index` | Top-level paragraph ordinal | Bounds-check and mutation both walk the same top-level `.paragraph` list inside the handler; internally consistent (no cross-family gap). |
| `insert_comment.paragraph_index` | Top-level paragraph ordinal | Comment anchors are attached to direct body paragraphs. |
| `insert_if_field.paragraph_index`, `insert_calculation_field.paragraph_index`, `insert_date_field.paragraph_index`, `insert_page_field.paragraph_index`, `insert_merge_field.paragraph_index`, `insert_sequence_field.paragraph_index` | Top-level paragraph ordinal | Field-code family (ooxml-swift `insertFieldCode`). **Fixed in #250**: che-word-mcp now bounds-checks `paragraph_index` on this side against the top-level paragraph list (`0..<topLevelParagraphCount`) BEFORE calling into ooxml-swift, whose own bounds check is readback-based and would otherwise let an index in the readback-vs-top-level gap through to a fallback that silently appends a new paragraph at the document's end. Out-of-range now rejects with `invalidParameter` naming `paragraph_index`; there is no "append" use of an out-of-range index for this family (a field code always attaches to an EXISTING paragraph). |
| `insert_content_control.paragraph_index` | Top-level paragraph ordinal, inclusive of the one-past-the-end append position | Content-control family (ooxml-swift `insertContentControl`). **Fixed in #250**, but with a wider valid range than the field-code family above: `paragraph_index == topLevelParagraphCount` is an established, tested convention for "insert as the new last top-level paragraph" (`ContentControlToolsTests`/`InvoiceTemplateE2ETests` sequentially call this tool with `paragraph_index` equal to the current top-level count to append one control after another), so the valid range is `0...topLevelParagraphCount`. Only an index STRICTLY PAST that — the gap opened up by SDT-inner/table-cell paragraphs in the readback count, or anything further — is rejected with `invalidParameter`. |
| `insert_column_break.paragraph_index` | Top-level paragraph ordinal | **Fixed in #251** (previously mixed-family: bounds-checked against `get_paragraphs()` readback index, but inserted via a `body.children` position one past that raw index — the two could disagree in a document with a table or block-level SDT, landing the break before the wrong paragraph, or before instead of after the intended one). Now both the bounds check and the insertion point derive from the SAME top-level paragraph ordinal: the tool locates the target top-level paragraph's actual `body.children` position, then inserts one past THAT. Out-of-range rejects with `invalidParameter`. |
| `insert_tab_stop.paragraph_index`, `clear_tab_stops.paragraph_index`, `set_outline_level.paragraph_index` | Top-level paragraph ordinal | **Fixed in [#245](https://github.com/PsychQuant/che-word-mcp/issues/245)** — these three tools now really write `<w:tabs>`/`<w:outlineLvl>` (via `ParagraphProperties.rawChildren`, the only public path ooxml-swift exposes for either element — see #245's commit for the full mechanism) and, like #139's fix, bounds-check `paragraph_index` against the SAME top-level `.paragraph` walk the mutation itself uses, not the readback family the pre-fix stub validated against. |
| `get_paragraph_runs.paragraph_index`, `get_text_with_formatting.paragraph_index` | `get_paragraphs` readback index | Use indices from `get_paragraphs`. |
| `list_captions`, `list_equations`, `list_comments` returned `paragraph_index` | Tool-specific readback value | Treat returned values as readback metadata unless the target tool explicitly names the same family. |

### Known stub tools (not paragraph_index family bugs, but worth flagging together)

**Resolved by [#245](https://github.com/PsychQuant/che-word-mcp/issues/245):** `set_row_height`, `set_cell_width`, `insert_tab_stop`, `clear_tab_stops`, `set_outline_level`, and `set_columns` (see below) now really write the OOXML they describe, locked down by "open an existing `.docx` → call → `save_document` → read back `word/document.xml`" tests. `set_page_borders` could not be fixed the same way — ooxml-swift's `SectionProperties` has no field for `<w:pgBorders>` at all (not merely an unmarked-dirty typed mutation, the other five tools' root cause), so there is no public API for this tool to call. It now fails loudly instead: `isError: true`, naming the missing `<w:pgBorders>` element, following the `protect_document` family's disclosure convention (#201/#208/#210) rather than silently returning a success string describing what would happen.

`insert_cross_reference` remains a stub (out of #245's scope — see that issue's own tool list) and still accepts and validates its parameters but never calls `storeDocument` / never writes the described OOXML property.

**`set_columns`'s pre-#245 shape, for history**: it DID call `storeDocument`, and its `columns` parameter DID get written, but only when the target document had never been saved before (`create_document` → `set_columns` → the first `save_document`, a from-scratch typed-model regeneration). Calling it on an already-existing `.docx` opened via `open_document` — the overwhelmingly common pattern — wrote **neither** `columns` **nor** `space`; `space` never wrote in either case. Root cause: the handler set `doc.sectionProperties.columns` directly, bypassing ooxml-swift's `markTypedDirty`/`modifiedParts` tracking (`internal`, not reachable from this module) — in "overlay" mode (an already-open document, `archiveTempDir != nil`), `word/document.xml` is only regenerated from the typed model for parts present in `modifiedParts`, otherwise the original bytes are copied through unchanged. **Fix**: `doc.markPartDirty(_:)` — a `public` wrapper around the same `markTypedDirty` mechanism, added by ooxml-swift specifically for external consumers like che-word-mcp (see that type's own doc comment in `Document.swift`) — plus writing `columnSpacing` (not just `columns`) so `space` round-trips too.

## Agent Guidance

Prefer text/image/table anchors (`after_text`, `before_text`, `after_image_id`,
`after_table_index`, `into_table_cell`) when available. They avoid cross-family
index reuse and are more stable after edits.

If a workflow must reuse an integer index, keep it within the same family. Do
not feed a `get_paragraphs` array offset into an insert tool without first
converting it to a `body.children` position.

Public API renaming or typed wrapper indices would be a breaking change and
should be handled through a separate SDD proposal.
