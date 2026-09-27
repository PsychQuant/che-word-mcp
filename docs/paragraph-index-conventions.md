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
| `insert_if_field.paragraph_index`, `insert_calculation_field.paragraph_index`, `insert_date_field.paragraph_index`, `insert_page_field.paragraph_index`, `insert_merge_field.paragraph_index`, `insert_sequence_field.paragraph_index`, `insert_content_control.paragraph_index` | Top-level paragraph ordinal | Field-code / content-control family (ooxml-swift `insertFieldCode`/`insertContentControl`). **Known residual gap** (out of #138's doc-only scope, tracked for follow-up): the library's own bounds check is readback-based; an index at/past the top-level count but still within the readback count does not error — it silently appends a new paragraph at the document's end instead of targeting the requested position. |
| `insert_column_break.paragraph_index` | `get_paragraphs` readback index (bounds-check); inserts via a `body.children` position one past that | Mixed-family by construction — bounds-checked against readback, but the column break is inserted at `body.children[readback_index + 1]`. Not covered by #139/#140 (out of literal scope); documented here so callers know the acceptance range does not fully describe where the break lands in a document containing block-level SDTs. |
| `insert_tab_stop.paragraph_index`, `clear_tab_stops.paragraph_index`, `set_outline_level.paragraph_index` | `get_paragraphs` readback index | **These three tools are stubs**: `paragraph_index` is bounds-checked but the described change (`<w:tabs>`, `<w:outlineLvl>`) is never written to the document — the handler returns a descriptive success string with no `storeDocument` call. Not a paragraph-index family bug; tracked as a separate stub-disclosure gap (see `set_page_borders`/`set_row_height`/`set_cell_width` below, same shape; `set_columns` is a related but different shape — see the correction below). |
| `get_paragraph_runs.paragraph_index`, `get_text_with_formatting.paragraph_index` | `get_paragraphs` readback index | Use indices from `get_paragraphs`. |
| `list_captions`, `list_equations`, `list_comments` returned `paragraph_index` | Tool-specific readback value | Treat returned values as readback metadata unless the target tool explicitly names the same family. |

### Known stub tools (not paragraph_index family bugs, but worth flagging together)

`set_page_borders`, `set_row_height`, `set_cell_width`, `insert_tab_stop`, `insert_cross_reference` accept and validate their parameters (where validated at all) but never call `storeDocument` / never write the described OOXML property — the handler returns a success string describing what *would* happen. Found while auditing [#235](https://github.com/PsychQuant/che-word-mcp/issues/235)'s "out-of-range values get written to the file" claim: for these specific tools that premise does not hold, because nothing is written regardless of the value. See #235's diagnosis for detail; a stub-disclosure fix (matching the `protect_document` family's `description` disclosure convention from #201/#208/#210) is tracked as a follow-up, not fixed by #138/#139/#140/#235.

**`set_columns` is a different shape — corrected after independent review, do not merge with the list above.** It DOES call `storeDocument`, and its `columns` parameter DOES get written, but only when the target document has never been saved before (`create_document` → `set_columns` → the first `save_document`, a from-scratch typed-model regeneration). Calling it on an already-existing `.docx` opened via `open_document` — the overwhelmingly common pattern — writes **neither** `columns` **nor** `space`; `space` never writes in either case. Root cause: the handler sets `doc.sectionProperties.columns` directly (`Sources/CheWordMCP/Server.swift`'s `setColumns`), bypassing ooxml-swift's `markTypedDirty`/`modifiedParts` tracking (`internal`, not reachable from this module). In "overlay" mode (an already-open document, `archiveTempDir != nil`), `word/document.xml` is only regenerated from the typed model for parts present in `modifiedParts` — otherwise the original bytes are copied through unchanged. A from-scratch document has no original bytes to fall back to, so it always regenerates, which is why `columns` "works" there and nowhere else. Tracked in [#245](https://github.com/PsychQuant/che-word-mcp/issues/245); not fixed by #138/#139/#140/#235.

## Agent Guidance

Prefer text/image/table anchors (`after_text`, `before_text`, `after_image_id`,
`after_table_index`, `into_table_cell`) when available. They avoid cross-family
index reuse and are more stable after edits.

If a workflow must reuse an integer index, keep it within the same family. Do
not feed a `get_paragraphs` array offset into an insert tool without first
converting it to a `body.children` position.

Public API renaming or typed wrapper indices would be a breaking change and
should be handled through a separate SDD proposal.
