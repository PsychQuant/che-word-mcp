# che-word-mcp MCPB Package

This directory contains the MCPB (MCP Bundle) package files for distribution.

## Structure

```
mcpb/
├── manifest.json    # Package metadata
├── server/          # Binary files (Universal Binary)
│   └── CheWordMCP   # The MCP server executable
└── README.md        # This file
```

## Building the Package

```bash
# Build Universal Binary
swift build -c release --arch arm64
swift build -c release --arch x86_64
lipo -create \
  .build/arm64-apple-macosx/release/CheWordMCP \
  .build/x86_64-apple-macosx/release/CheWordMCP \
  -output mcpb/server/CheWordMCP

# Create .mcpb package
cd mcpb && zip -r ../che-word-mcp.mcpb . && cd ..
```

## Installation

The `.mcpb` file can be installed via:

1. **Claude Desktop**: Drag and drop the `.mcpb` file
2. **Manual**: Extract and configure in `claude_desktop_config.json`
