// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CheWordMCP",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        // Draft integration for PsychQuant/ooxml-swift#115. Replace this
        // exact revision with the released version constraint before merge.
        .package(
            url: "https://github.com/PsychQuant/ooxml-swift.git",
            revision: "4a26b6d96d6da04703c84f2ca3c5b9d318fa4dff"
        ),
        .package(url: "https://github.com/PsychQuant/markdown-swift.git", from: "0.2.0"),
        .package(url: "https://github.com/PsychQuant/word-to-md-swift.git", from: "1.0.0"),
        .package(url: "https://github.com/PsychQuant/latex-math-swift.git", from: "0.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "CheWordMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "OOXMLSwift", package: "ooxml-swift"),
                .product(name: "MarkdownSwift", package: "markdown-swift"),
                .product(name: "WordToMD", package: "word-to-md-swift"),
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
