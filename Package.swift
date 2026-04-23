// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CheWordMCP",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        .package(url: "https://github.com/PsychQuant/ooxml-swift.git", from: "0.12.0"),
        .package(url: "https://github.com/PsychQuant/markdown-swift.git", from: "0.2.0"),
        .package(url: "https://github.com/PsychQuant/word-to-md-swift.git", from: "0.4.0"),
        .package(url: "https://github.com/PsychQuant/latex-math-swift.git", from: "0.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "CheWordMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "OOXMLSwift", package: "ooxml-swift"),
                .product(name: "MarkdownSwift", package: "markdown-swift"),
                .product(name: "WordToMDSwift", package: "word-to-md-swift"),
                .product(name: "LaTeXMathSwift", package: "latex-math-swift"),
            ]
        ),
        .testTarget(
            name: "CheWordMCPTests",
            dependencies: [
                "CheWordMCP",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "OOXMLSwift", package: "ooxml-swift"),
                .product(name: "MarkdownSwift", package: "markdown-swift"),
                .product(name: "LaTeXMathSwift", package: "latex-math-swift"),
            ]
        )
    ]
)
