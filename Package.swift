// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CheWordMCP",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        // Temporarily path: deps for coordinated ooxml-swift 0.8.0 release
        // (word-mcp-insertion-primitives Spectra change). Switch back to url:
        // with v0.8.0+ in release commit.
        .package(path: "../../packages/ooxml-swift"),
        .package(path: "../../packages/markdown-swift"),
        .package(path: "../../packages/word-to-md-swift"),
    ],
    targets: [
        .executableTarget(
            name: "CheWordMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "OOXMLSwift", package: "ooxml-swift"),
                .product(name: "MarkdownSwift", package: "markdown-swift"),
                .product(name: "WordToMDSwift", package: "word-to-md-swift"),
            ]
        ),
        .testTarget(
            name: "CheWordMCPTests",
            dependencies: [
                "CheWordMCP",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "OOXMLSwift", package: "ooxml-swift"),
                .product(name: "MarkdownSwift", package: "markdown-swift"),
            ]
        )
    ]
)
