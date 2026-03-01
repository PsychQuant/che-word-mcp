# che-word-mcp

A Swift-native MCP (Model Context Protocol) server for Microsoft Word document (.docx) manipulation. This is the **first Swift OOXML library** that directly manipulates Office Open XML without any third-party Word dependencies.

[中文說明](README_zh-TW.md)

## Features

- **Pure Swift Implementation**: No Node.js, Python, or external runtime required
- **Direct OOXML Manipulation**: Works directly with XML, no Microsoft Word installation needed
- **Single Binary**: Just one executable file
- **145 MCP Tools**: Comprehensive document manipulation capabilities
- **Complete OOXML Support**: Full support for tables, styles, images, headers/footers, comments, footnotes, and more
- **Cross-platform**: Works on macOS (and potentially other platforms supporting Swift)

## Version History

| Version | Date | Changes |
|---------|------|---------|
| v1.14.0 | 2026-03-01 | Embed `word-to-md-swift` library: no external macdoc binary needed, restore `doc_id` support |
| v1.13.0 | 2026-03-01 | Upgrade ooxml-swift to v0.5.0: parallel multi-core parsing (~0.64s for large docs) |
| v1.12.1 | 2026-03-01 | Upgrade ooxml-swift to v0.4.0: large document performance fix (>30s → ~2.3s) |
| v1.12.0 | 2026-02-28 | `export_markdown` uses `source_path` only, removes `doc_id`, adds lock file check |
| v1.11.1 | 2026-02-28 | Fix `export_markdown` stdout mode (pipe fsync issue) |
| v1.11.0 | 2026-02-28 | `export_markdown` delegates to `macdoc` CLI; removed `word-to-md-swift` dependency |
| v1.9.0 | 2026-02-28 | `export_markdown` upgraded to use `word-to-md-swift` for high-quality output (145 total) |
| v1.8.0 | 2026-02-03 | Remove hard diff limit, add `max_results` & `heading_styles` params to `compare_documents` |
| v1.7.0 | 2026-02-03 | Add `compare_documents` tool for server-side document diff (105 total) |
| v1.2.1 | 2026-01-16 | Fix MCP SDK compatibility (actor→class, add capabilities) |
| v1.2.0 | 2026-01-16 | Add 12 new tools (95 total): search, hyperlinks, bookmarks, footnotes, endnotes, revisions, properties |
| v1.1.0 | 2026-01-16 | Fix MCPB manifest.json format for Claude Desktop |
| v1.0.0 | 2026-01-16 | Initial release with 83 tools, refactored to use ooxml-swift |

## Installation

### Option 1: Download from Release (Recommended)

Download the latest release from [GitHub Releases](https://github.com/kiki830621/che-word-mcp/releases):

- **CheWordMCP** - Universal Binary (arm64 + x86_64)
- **che-word-mcp.mcpb** - MCPB package

```bash
# Download and install
curl -L https://github.com/kiki830621/che-word-mcp/releases/latest/download/CheWordMCP -o ~/bin/CheWordMCP
chmod +x ~/bin/CheWordMCP
```

### Option 2: Build from Source

#### Prerequisites

- macOS 13.0+ (Ventura or later)
- Swift 5.9+

```bash
git clone https://github.com/kiki830621/che-word-mcp.git
cd che-word-mcp
swift build -c release
```

The binary will be located at `.build/release/CheWordMCP`

### Add to Claude Code

```bash
claude mcp add che-word-mcp /path/to/che-word-mcp/.build/release/CheWordMCP
```

### Add to Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "che-word-mcp": {
      "command": "/path/to/che-word-mcp/.build/release/CheWordMCP"
    }
  }
}
```

## Usage with AI Agents

### Just ask the agent

The simplest approach - just tell your agent to use it:

```
Use che-word-mcp to create a new Word document with title "Report" and save it to ~/Documents/report.docx
```

The agent will automatically use the MCP tools if che-word-mcp is configured.

### AGENTS.md / CLAUDE.md

For more consistent results, add to your project or global instructions file:

```markdown
## Word Document Manipulation

Use `che-word-mcp` for reading and writing Microsoft Word (.docx) files.

Core workflow:
1. `open_document` - Open an existing .docx file
2. `get_text` / `get_paragraphs` - Read document content
3. `insert_paragraph` / `format_text` - Modify content
4. `save_document` - Save changes

Creating new documents:
1. `create_document` - Create new document
2. Add content with `insert_paragraph`, `insert_table`, etc.
3. `save_document` - Save to .docx file

Export options:
- `export_text` - Export as plain text
- `export_markdown` - Export as Markdown
```

### Claude Code Skill

For Claude Code, a skill provides richer context:

```bash
# Download the skill
mkdir -p .claude/skills/che-word-mcp
curl -o .claude/skills/che-word-mcp/SKILL.md \
  https://raw.githubusercontent.com/kiki830621/che-word-mcp/main/skills/che-word-mcp/SKILL.md
```

Or copy from the repository:

```bash
cp -r /path/to/che-word-mcp/skills/che-word-mcp .claude/skills/
```

## Available Tools (83 Total)

### Document Management (6 tools)

| Tool | Description |
|------|-------------|
| `create_document` | Create a new Word document |
| `open_document` | Open an existing .docx file |
| `save_document` | Save document to .docx file |
| `close_document` | Close an open document |
| `list_open_documents` | List all open documents |
| `get_document_info` | Get document statistics |

### Content Operations (6 tools)

| Tool | Description |
|------|-------------|
| `get_text` | Get plain text content |
| `get_paragraphs` | Get all paragraphs with formatting |
| `insert_paragraph` | Insert a new paragraph |
| `update_paragraph` | Update paragraph content |
| `delete_paragraph` | Delete a paragraph |
| `replace_text` | Search and replace text |

### Formatting (3 tools)

| Tool | Description |
|------|-------------|
| `format_text` | Apply text formatting (bold, italic, color, font) |
| `set_paragraph_format` | Set paragraph formatting (alignment, spacing) |
| `apply_style` | Apply built-in or custom styles |

### Tables (6 tools)

| Tool | Description |
|------|-------------|
| `insert_table` | Insert a table with optional data |
| `get_tables` | Get all tables information |
| `update_cell` | Update cell content |
| `delete_table` | Delete a table |
| `merge_cells` | Merge cells horizontally or vertically |
| `set_table_style` | Set table borders and shading |

### Style Management (4 tools)

| Tool | Description |
|------|-------------|
| `list_styles` | List all available styles |
| `create_style` | Create custom style |
| `update_style` | Update style definition |
| `delete_style` | Delete custom style |

### Lists (3 tools)

| Tool | Description |
|------|-------------|
| `insert_bullet_list` | Insert bullet list |
| `insert_numbered_list` | Insert numbered list |
| `set_list_level` | Set list indentation level |

### Page Setup (5 tools)

| Tool | Description |
|------|-------------|
| `set_page_size` | Set page size (A4, Letter, etc.) |
| `set_page_margins` | Set page margins |
| `set_page_orientation` | Set portrait or landscape |
| `insert_page_break` | Insert page break |
| `insert_section_break` | Insert section break |

### Headers & Footers (5 tools)

| Tool | Description |
|------|-------------|
| `add_header` | Add header content |
| `update_header` | Update header content |
| `add_footer` | Add footer content |
| `update_footer` | Update footer content |
| `insert_page_number` | Insert page number field |

### Images (6 tools)

| Tool | Description |
|------|-------------|
| `insert_image` | Insert inline image (PNG, JPEG) |
| `insert_floating_image` | Insert floating image with text wrap |
| `update_image` | Update image properties |
| `delete_image` | Delete image |
| `list_images` | List all images |
| `set_image_style` | Set image border and effects |

### Export (2 tools)

| Tool | Description |
|------|-------------|
| `export_text` | Export as plain text |
| `export_markdown` | Export as Markdown |

### Hyperlinks & Bookmarks (6 tools)

| Tool | Description |
|------|-------------|
| `insert_hyperlink` | Insert external hyperlink |
| `insert_internal_link` | Insert link to bookmark |
| `update_hyperlink` | Update hyperlink |
| `delete_hyperlink` | Delete hyperlink |
| `insert_bookmark` | Insert bookmark |
| `delete_bookmark` | Delete bookmark |

### Comments & Revisions (10 tools)

| Tool | Description |
|------|-------------|
| `insert_comment` | Insert comment |
| `update_comment` | Update comment text |
| `delete_comment` | Delete comment |
| `list_comments` | List all comments |
| `reply_to_comment` | Reply to existing comment |
| `resolve_comment` | Mark comment as resolved |
| `enable_track_changes` | Enable track changes |
| `disable_track_changes` | Disable track changes |
| `accept_revision` | Accept revision |
| `reject_revision` | Reject revision |

### Footnotes & Endnotes (4 tools)

| Tool | Description |
|------|-------------|
| `insert_footnote` | Insert footnote |
| `delete_footnote` | Delete footnote |
| `insert_endnote` | Insert endnote |
| `delete_endnote` | Delete endnote |

### Field Codes (7 tools)

| Tool | Description |
|------|-------------|
| `insert_if_field` | Insert IF conditional field |
| `insert_calculation_field` | Insert calculation (SUM, AVERAGE, etc.) |
| `insert_date_field` | Insert date/time field |
| `insert_page_field` | Insert page number field |
| `insert_merge_field` | Insert mail merge field |
| `insert_sequence_field` | Insert auto-numbering sequence |
| `insert_content_control` | Insert SDT content control |

### Repeating Sections (1 tool)

| Tool | Description |
|------|-------------|
| `insert_repeating_section` | Insert repeating section (Word 2012+) |

### Advanced Features (9 tools)

| Tool | Description |
|------|-------------|
| `insert_toc` | Insert table of contents |
| `insert_text_field` | Insert form text field |
| `insert_checkbox` | Insert form checkbox |
| `insert_dropdown` | Insert form dropdown |
| `insert_equation` | Insert math equation |
| `set_paragraph_border` | Set paragraph border |
| `set_paragraph_shading` | Set paragraph background color |
| `set_character_spacing` | Set character spacing |
| `set_text_effect` | Set text animation effect |

## Usage Examples

### Create a Document with Headings and Text

```
Create a new Word document called "report" with:
- Title: "Quarterly Report"
- Heading: "Introduction"
- A paragraph explaining the report purpose
Save it to ~/Documents/report.docx
```

### Create a Document with Table and Images

```
Create a document with:
- A title "Product Catalog"
- Insert an image from ~/images/logo.png
- A 4x3 table with product information
- Apply borders to the table
Save it to ~/Documents/catalog.docx
```

### Create a Professional Report

```
Create a document with:
- Custom page margins (1 inch all around)
- A header with company name
- A footer with page numbers
- Table of contents
- Multiple sections with headings
- Footnotes for references
Save it as ~/Documents/annual_report.docx
```

## Technical Details

### OOXML Structure

The server generates valid Office Open XML documents with complete structure:

```
document.docx (ZIP)
├── [Content_Types].xml
├── _rels/
│   └── .rels
├── word/
│   ├── document.xml      # Main content
│   ├── styles.xml        # Style definitions
│   ├── settings.xml      # Document settings
│   ├── fontTable.xml     # Font definitions
│   ├── numbering.xml     # List definitions
│   ├── comments.xml      # Comments
│   ├── footnotes.xml     # Footnotes
│   ├── endnotes.xml      # Endnotes
│   ├── header1.xml       # Header content
│   ├── footer1.xml       # Footer content
│   ├── media/            # Embedded images
│   │   └── image*.{png,jpeg}
│   └── _rels/
│       └── document.xml.rels
└── docProps/
    ├── core.xml          # Metadata
    └── app.xml           # Application info
```

### Dependencies

- [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) (v0.10.2+) - Model Context Protocol implementation
- [ooxml-swift](https://github.com/kiki830621/ooxml-swift) (v0.2.0+) - OOXML parsing
- [word-to-md-swift](https://github.com/kiki830621/word-to-md-swift) (v0.1.0+) - Word to Markdown conversion

## Comparison with Other Solutions

| Feature | Anthropic Word MCP | python-docx | docx npm | **che-word-mcp** |
|---------|-------------------|-------------|----------|------------------|
| Language | Node.js | Python | Node.js | **Swift** |
| Backend | AppleScript | OOXML | OOXML | **OOXML** |
| Requires Word | Yes | No | No | **No** |
| Runtime | Node.js | Python | Node.js | **None** |
| Single Binary | No | No | No | **Yes** |
| Tools Count | ~10 | N/A | N/A | **145** |
| Images | Limited | Yes | Yes | **Yes** |
| Comments | No | Limited | Limited | **Yes** |
| Track Changes | No | No | No | **Yes** |
| TOC | No | Limited | No | **Yes** |
| Form Fields | No | No | No | **Yes** |

## Performance

Benchmarks on Apple Silicon (M4 Max, 128GB RAM):

### Read Performance

| File Size | Time |
|-----------|------|
| 40 KB (thesis outline) | **72 ms** |
| 431 KB (complex document) | **31 ms** |

### Write Performance

| Operation | Content | Time |
|-----------|---------|------|
| Basic write | Create + 3 paragraphs + Save | **19 ms** |
| Complex document | Title + Paragraphs + Table + List | **21 ms** |
| Bulk write | **50 paragraphs** + Save | **28 ms** |

### Why So Fast?

- **Native Swift binary** - No interpreter startup overhead
- **Direct OOXML manipulation** - No Microsoft Word process
- **Efficient ZIP handling** - ZIPFoundation for compression
- **In-memory operations** - Only writes to disk on save

Compared to python-docx (~200ms startup) or docx npm (~150ms startup), che-word-mcp is **10-20x faster**.

## License

MIT License

## Author

Che Cheng ([@kiki830621](https://github.com/kiki830621))

## Related Projects

- [che-apple-mail-mcp](https://github.com/kiki830621/che-apple-mail-mcp) - Apple Mail MCP server
- [che-ical-mcp](https://github.com/kiki830621/che-ical-mcp) - macOS Calendar MCP server
