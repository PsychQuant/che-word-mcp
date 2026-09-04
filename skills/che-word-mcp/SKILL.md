# che-word-mcp

A Swift-native MCP server for Microsoft Word (.docx) document manipulation. Provides 83 tools for reading, writing, and modifying Word documents without requiring Microsoft Word installation.

## When to Use

Use `che-word-mcp` when you need to:

- Read content from existing .docx files
- Create new Word documents programmatically
- Modify document content, formatting, or structure
- Convert .docx to plain text or Markdown
- Work with tables, images, comments, and other Word features

## Core Workflows

### Reading Documents

```text
1. open_document(path: "/path/to/document.docx")
   → Returns document ID

2. get_text(documentId: "...")
   → Returns plain text content

   OR

   get_paragraphs(documentId: "...")
   → Returns paragraphs with formatting info

3. close_document(documentId: "...")
   → Clean up when done
```

### Creating Documents

```text
1. create_document(name: "my_document")
   → Returns document ID

2. insert_paragraph(documentId: "...", text: "Hello World", style: "Heading1")
   insert_table(documentId: "...", rows: 3, cols: 4, data: [...])
   insert_image(documentId: "...", path: "/path/to/image.png")

3. save_document(documentId: "...", path: "/path/to/output.docx")
```

### Modifying Documents

```text
1. open_document(path: "/path/to/document.docx")

2. update_paragraph(documentId: "...", index: 0, text: "New content")
   format_text(documentId: "...", paragraphIndex: 0, bold: true)
   insert_comment(documentId: "...", paragraphIndex: 0, author: "Claude", text: "Review needed")

3. save_document(documentId: "...", path: "/path/to/output.docx")
```

### Exporting

```text
export_text(documentId: "...")
→ Returns plain text

export_markdown(documentId: "...")
→ Returns Markdown format
```

## Tool Categories

### Document Management

- `create_document` - Create new document
- `open_document` - Open existing .docx
- `save_document` - Save to file
- `close_document` - Close document
- `list_open_documents` - List all open
- `get_document_info` - Get statistics

### Content

- `get_text` - Get plain text
- `get_paragraphs` - Get with formatting
- `insert_paragraph` - Add paragraph
- `update_paragraph` - Modify paragraph
- `delete_paragraph` - Remove paragraph
- `replace_text` - Find and replace

### Formatting

- `format_text` - Bold, italic, color, font
- `set_paragraph_format` - Alignment, spacing
- `apply_style` - Apply Word styles
- `set_character_spacing` - Letter spacing
- `set_text_effect` - Text effects

### Tables

- `insert_table` - Create table
- `get_tables` - List tables
- `update_cell` - Modify cell
- `delete_table` - Remove table
- `merge_cells` - Merge cells
- `set_table_style` - Borders, shading

### Images

- `insert_image` - Inline image
- `insert_floating_image` - With text wrap
- `update_image` - Modify properties
- `delete_image` - Remove image
- `list_images` - list images with body-reference status (`referenced: yes / NO (orphan) / unknown`; orphans named with ⚠, #199)
- `set_image_style` - Border, effects

### Headers & Footers

- `add_header` / `update_header`
- `add_footer` / `update_footer`
- `insert_page_number`

### Comments & Revisions

- `insert_comment` / `update_comment` / `delete_comment`
- `list_comments` - Get all comments
- `reply_to_comment` - Add reply
- `resolve_comment` - Mark resolved
- `enable_track_changes` / `disable_track_changes`
- `accept_revision` / `reject_revision`

### Lists

- `insert_bullet_list`
- `insert_numbered_list`
- `set_list_level`

### Page Setup

- `set_page_size` - A4, Letter, etc.
- `set_page_margins`
- `set_page_orientation`
- `insert_page_break`
- `insert_section_break`

### Advanced

- `insert_toc` - Table of contents
- `insert_footnote` / `insert_endnote`
- `insert_hyperlink` / `insert_bookmark`
- `insert_equation` - Math equations
- `insert_checkbox` / `insert_dropdown` - Form fields
- `insert_if_field` / `insert_date_field` - Field codes

## Tips

1. **Always save after modifications** - Changes are in-memory until saved
2. **Close documents when done** - Free up resources
3. **Use styles for consistency** - `apply_style` instead of manual formatting
4. **Check document info first** - Use `get_document_info` to understand structure
5. **Export for AI processing** - Use `export_markdown` for easier text analysis

## Examples

### Create a Report

```text
Create a Word document with:
- Title "Monthly Report" (Heading1)
- Date field that auto-updates
- Executive summary paragraph
- A table with 3 columns: Metric, Value, Change
- Page numbers in footer
Save to ~/Documents/report.docx
```

### Extract and Analyze

```text
Open ~/Documents/thesis.docx
Get all paragraphs with formatting
List all comments
Export as Markdown for analysis
Close the document
```

### Batch Edit Comments

```text
Open the document
List all comments
Reply to each comment with analysis
Mark resolved comments as done
Save the updated document
```
