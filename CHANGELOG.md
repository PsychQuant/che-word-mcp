# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.5.0] - 2026-01-19

### Added
- `insert_image_from_path` - Insert image from file path (recommended for large images, avoids base64 transfer overhead)

### Changed
- Updated tool count from 100 to 101

### Fixed
- Fixed crash when inserting large images via base64 - now users can use file path instead

## [1.4.0] - 2026-01-18

### Added
- New image export tools (total 100 tools):
  - `export_image` - Export a single image to file by image ID
  - `export_all_images` - Export all images to a directory

### Changed
- Updated tool count from 98 to 100

## [1.3.0] - 2026-01-18

### Added
- New formatting inspection tools (total 98 tools):
  - `get_paragraph_runs` - Get all runs (text fragments) in a paragraph with formatting info (color, bold, italic, font size, etc.)
  - `get_text_with_formatting` - Get document text with Markdown-style format markers (**bold**, *italic*, {{color:red}}, etc.)
  - `search_by_formatting` - Search for text with specific formatting (e.g., find all red text, all bold text)
- Added `mcpb/PRIVACY.md` - Privacy policy documentation

### Changed
- Updated tool count from 95 to 98

## [1.2.1] - 2026-01-16

### Fixed
- Added missing `capabilities: .init(tools: .init())` to Server initialization
- This fixes the "Failed to connect" issue in Claude Code

## [1.2.0] - 2026-01-16

### Added
- New tools for enhanced document manipulation (total 95 tools):
  - `insert_text` - Insert text at specific position in paragraph
  - `get_document_text` - Alias for `get_text` with more intuitive naming
  - `search_text` - Search text and return all matching positions
  - `list_hyperlinks` - List all hyperlinks in document
  - `list_bookmarks` - List all bookmarks in document
  - `list_footnotes` - List all footnotes in document
  - `list_endnotes` - List all endnotes in document
  - `get_revisions` - Get all revision tracking records
  - `accept_all_revisions` - Accept all tracked changes at once
  - `reject_all_revisions` - Reject all tracked changes at once
  - `set_document_properties` - Set document metadata (title, author, etc.)
  - `get_document_properties` - Get document metadata

## [1.1.0] - 2026-01-16

### Fixed
- Fixed MCPB manifest.json format to comply with 0.3 specification
- Changed `author` from string to object format
- Changed `repository` from string to object format
- Removed unsupported fields: `id`, `platforms`, `capabilities`

## [1.0.0] - 2026-01-16

### Added
- Initial release with 83 MCP tools for Word document manipulation
- Complete OOXML support without Microsoft Word dependency
- Pure Swift implementation as single binary
- MCPB package for easy distribution

### Changed
- Refactored to use [ooxml-swift](https://github.com/kiki830621/ooxml-swift) as external dependency
- Updated MCP SDK to 0.10.2

### Document Management
- `create_document`, `open_document`, `save_document`, `close_document`
- `list_open_documents`, `get_document_info`

### Content Operations
- `get_text`, `get_paragraphs`, `insert_paragraph`, `update_paragraph`
- `delete_paragraph`, `replace_text`

### Formatting
- `format_text`, `set_paragraph_format`, `apply_style`

### Tables
- `insert_table`, `get_tables`, `update_cell`, `delete_table`
- `merge_cells`, `set_table_style`

### Style Management
- `list_styles`, `create_style`, `update_style`, `delete_style`

### Lists
- `insert_bullet_list`, `insert_numbered_list`, `set_list_level`

### Page Setup
- `set_page_size`, `set_page_margins`, `set_page_orientation`
- `insert_page_break`, `insert_section_break`

### Headers & Footers
- `add_header`, `update_header`, `add_footer`, `update_footer`
- `insert_page_number`

### Images
- `insert_image`, `insert_floating_image`, `update_image`
- `delete_image`, `list_images`, `set_image_style`

### Export
- `export_text`, `export_markdown`

### Hyperlinks & Bookmarks
- `insert_hyperlink`, `insert_internal_link`, `update_hyperlink`
- `delete_hyperlink`, `insert_bookmark`, `delete_bookmark`

### Comments & Revisions
- `insert_comment`, `update_comment`, `delete_comment`, `list_comments`
- `reply_to_comment`, `resolve_comment`
- `enable_track_changes`, `disable_track_changes`
- `accept_revision`, `reject_revision`

### Footnotes & Endnotes
- `insert_footnote`, `delete_footnote`
- `insert_endnote`, `delete_endnote`

### Field Codes
- `insert_if_field`, `insert_calculation_field`, `insert_date_field`
- `insert_page_field`, `insert_merge_field`, `insert_sequence_field`
- `insert_content_control`

### Advanced Features
- `insert_repeating_section`, `insert_toc`
- `insert_text_field`, `insert_checkbox`, `insert_dropdown`
- `insert_equation`, `set_paragraph_border`, `set_paragraph_shading`
- `set_character_spacing`, `set_text_effect`
