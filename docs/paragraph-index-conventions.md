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
| `format_text.paragraph_index`, `set_paragraph_format.paragraph_index`, `apply_style.paragraph_index` | Top-level paragraph ordinal | Mutates direct body paragraphs. |
| `set_paragraph_border.paragraph_index`, `set_paragraph_shading.paragraph_index`, `set_character_spacing.paragraph_index`, `set_text_effect.paragraph_index` | Top-level paragraph ordinal | Advanced paragraph formatting tools mutate direct body paragraphs. |
| `insert_comment.paragraph_index` | Top-level paragraph ordinal | Comment anchors are attached to direct body paragraphs. |
| `get_paragraph_runs.paragraph_index`, `get_text_with_formatting.paragraph_index` | `get_paragraphs` readback index | Use indices from `get_paragraphs`. |
| `list_captions`, `list_equations`, `list_comments` returned `paragraph_index` | Tool-specific readback value | Treat returned values as readback metadata unless the target tool explicitly names the same family. |

## Agent Guidance

Prefer text/image/table anchors (`after_text`, `before_text`, `after_image_id`,
`after_table_index`, `into_table_cell`) when available. They avoid cross-family
index reuse and are more stable after edits.

If a workflow must reuse an integer index, keep it within the same family. Do
not feed a `get_paragraphs` array offset into an insert tool without first
converting it to a `body.children` position.

Public API renaming or typed wrapper indices would be a breaking change and
should be handled through a separate SDD proposal.
