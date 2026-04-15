// swift-tools-version: 5.9
import PackageDescription

// NOTE (manuscript-review-markdown-export): ooxml-swift, markdown-swift, and
// word-to-md-swift are temporarily declared as path: dependencies for local
// development. Before publishing a new che-word-mcp release, revert all three
// to url: with appropriate from: version constraints once each upstream has
// been tagged and pushed. word-to-md-swift must be path: too because it
// transitively depends on ooxml-swift and markdown-swift; mixing url: and
// path: for the same package identity raises a SwiftPM conflict warning that
// will become an error in future SwiftPM versions.
// See macdoc CLAUDE.md "swift-package-update.md" rules.
let package = Package(
    name: "CheWordMCP",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        .package(name: "ooxml-swift", path: "../../packages/ooxml-swift"),
        .package(name: "markdown-swift", path: "../../packages/markdown-swift"),
        .package(name: "word-to-md-swift", path: "../../packages/word-to-md-swift"),
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
