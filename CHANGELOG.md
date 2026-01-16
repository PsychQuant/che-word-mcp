# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
