# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.15.2] - 2026-03-07

### Improved
- **list_all_formatted_text** — clarify tool description to explicitly list required `format_type` parameter values, reducing LLM misuse

## [1.15.1] - 2026-03-01

### Fixed
- **Heading Heuristic style fallback** — resolve fontSize and bold from paragraph style inheritance chain when runs don't have explicit formatting (fixes heuristic not triggering on real-world Word documents)

### Changed
- Upgrade `word-to-md-swift` 0.3.0 → 0.3.1

## [1.15.0] - 2026-03-01

### Added
- **Practical Mode: EMF→PNG auto-conversion** — non web-friendly image formats (EMF/WMF/TIFF/BMP) are automatically converted to PNG via AppKit during `export_markdown`
- **Practical Mode: Heading Heuristic** — statistically infers heading levels from font size distribution when documents lack Word Heading Styles (bold + short + larger-than-body → H1~H6)

### Changed
- Upgrade `word-to-md-swift` 0.2.0 → 0.3.0 (Practical Mode features)
- Upgrade `doc-converter-swift` 0.2.0 → 0.3.0 (`preserveOriginalFormat`, `headingHeuristic` options)
- Upgrade `ooxml-swift` 0.5.0 → 0.5.1 (EMF/WMF MIME type support)

## [1.14.0] - 2026-03-01

### Changed
- `export_markdown` switched from macdoc CLI delegation to embedded `word-to-md-swift` library
  - No external binary dependency (`~/bin/macdoc` no longer required)
  - Restored `doc_id` parameter: convert in-memory documents without saving to disk first
  - `source_path` still supported: direct .docx → Markdown conversion
  - Removed `marker` parameter (use macdoc CLI directly for Marker format)
  - Binary size impact: +1MB (32MB → 33MB)

### Added
- `word-to-md-swift` v0.2.0 as direct dependency (with `doc-converter-swift`, `markdown-swift`)

### Removed
- `MACDOC_PATH` environment variable support (no longer needed)
- macdoc CLI Process() delegation code

## [1.13.0] - 2026-03-01

### Changed
- Upgrade `ooxml-swift` 0.4.0 → 0.5.0 (parallel `parseBody` with multi-core)
  - Large documents parsed in parallel using `DispatchQueue.concurrentPerform`
  - 976K docx: ~1.8s → **~0.64s** (2.8x speedup, 47x vs original XPath)
  - Small documents (<200 elements) unaffected (serial path)

## [1.12.1] - 2026-03-01

### Changed
- Upgrade `ooxml-swift` 0.3.0 → 0.4.0 (XPath → children traversal performance fix)
  - Large documents (11K+ runs, e.g. 976K .docx) go from >30s hang to ~2.3s
  - Eliminates O(n²) XPath evaluation in `parseRun`, `parseDrawing`, `parseInlineDrawing`, `parseAnchorDrawing`

## [1.12.0] - 2026-02-28

### Changed
- `export_markdown` now uses `source_path` for direct .docx → Markdown conversion
  - No need to call `open_document` first — pass the file path directly
  - Removed `doc_id` parameter (was used for in-memory documents)
  - Added Word lock file (`~$`) detection — refuses conversion if file is open in Microsoft Word

## [1.11.1] - 2026-02-28

### Fixed
- Fix `export_markdown` stdout mode failing due to `fsync()` on pipe
  - Use temp file with `-o` flag instead of reading stdout pipe directly

## [1.11.0] - 2026-02-28

### Changed
- `export_markdown` now delegates to `macdoc` CLI instead of embedding `word-to-md-swift` library
  - Removes API mirroring burden (ConversionOptions changes no longer require MCP updates)
  - CLI uses streaming O(1) memory for large documents
  - Simplified parameters: `doc_id`, `path`, `marker`, `include_frontmatter`, `hard_line_breaks`
  - Removed `fidelity`, `figures_directory`, `metadata_output`, `use_html_extensions` (handled by macdoc)
  - Supports `MACDOC_PATH` environment variable for custom binary location

### Removed
- `word-to-md-swift` dependency (replaced by macdoc CLI delegation)
- `doc-converter-swift` transitive dependency

## [1.10.0] - 2026-02-28

### Changed
- Upgrade `export_markdown` with Tier 1-3 fidelity support:
  - `fidelity` parameter: `markdown` (default), `markdown_with_figures`, `marker`
  - `figures_directory`: image extraction for Tier 2+
  - `metadata_output`: lossless YAML sidecar for Tier 3
  - `include_frontmatter`, `use_html_extensions`, `hard_line_breaks` options
- Update MCP Swift SDK 0.10.2 → 0.11.0 (tool annotations, HTTP transport)
- Update `ooxml-swift` 0.2.0 → 0.3.0 (Equatable conformance, 179 tests)
- Update `word-to-md-swift` 0.1.0 → 0.2.0 (FigureExtractor, MetadataCollector, Tier 2/3)
- Update `doc-converter-swift` 0.1.0 → 0.2.0 (FidelityTier, extended ConversionOptions)

## [1.9.0] - 2026-02-28

### Changed
- `export_markdown` now uses `word-to-md-swift` library for significantly better Markdown output
  - Streaming architecture (O(1) memory)
  - Proper heading detection via semantic annotations
  - List detection (bullet + numbered) with nesting support
  - Table formatting with alignment
  - Inline styling (bold, italic, strikethrough, code)
  - Special character escaping
  - Optional YAML frontmatter
- Switched all dependencies from `path:` to `url:` remote dependencies
- Updated `ooxml-swift` to v0.2.0 (removed built-in `toMarkdown()`, now a clean OOXML parser)
- Updated description to reflect 145 tools

### Added
- `word-to-md-swift` v0.1.0 as new dependency for high-quality Word→Markdown conversion

## [1.8.0] - 2026-02-03

### Changed
- Remove `maxDiffs = 50` hard limit in `compare_documents` — full results returned by default (no irreversible truncation)
- Add `max_results` optional parameter (default 0 = unlimited) for caller-controlled diff limiting
- Add `heading_styles` optional parameter for custom heading style recognition in structure mode
- Improve structure mode heading detection with heuristic fallback (`keepNext` + short text, marked with `(?)`)
- Increase `truncateText` default from 200 to 500 characters

### Removed
- Hard-coded `maxDiffs = 50` truncation logic
- Old `.mcpb` and `.mcpb.zip` release artifacts from repository

## [1.7.0] - 2026-02-03

### Added
- `compare_documents` - Server-side document comparison with paragraph-level diff (total 105 tools)
  - Hash-based LCS algorithm for paragraph alignment
  - Four modes: `text` (default), `formatting`, `structure`, `full`
  - Smart MODIFIED detection via word-level Jaccard similarity (>50% threshold)
  - Context lines support (0-3 unchanged paragraphs around diffs)
  - ~90% token savings vs client-side diff with two `get_text_with_formatting` calls

### Changed
- Updated tool count from 104 to 105

## [1.6.0] - 2026-01-27

### Added
- New academic document analysis tools (total 104 tools):
  - `search_text_with_formatting` - Search text and display formatting at match positions (bold, italic, color markers)
  - `list_all_formatted_text` - List all text with specific formatting (e.g., all italic text, all bold text, specific color)
  - `get_word_count_by_section` - Word count by section with customizable markers (e.g., Abstract, Methods, References) and exclusion support

### Changed
- Updated tool count from 101 to 104

### Use Cases
- Academic paper review: quickly verify italic formatting for statistical terms
- Anonymization check: search for specific text and verify no highlighting remains
- Journal submission: count main text words excluding References section

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
