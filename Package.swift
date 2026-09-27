// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CheWordMCP",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        .package(url: "https://github.com/PsychQuant/ooxml-swift.git", from: "3.13.0"),
        .package(url: "https://github.com/PsychQuant/markdown-swift.git", from: "0.2.0"),
        .package(url: "https://github.com/PsychQuant/word-to-md-swift.git", from: "1.0.0"),
        .package(url: "https://github.com/PsychQuant/latex-math-swift.git", from: "0.2.0"),
        // R2 (#116 follow-up): DepthLimitedTransport.swift wraps swift-sdk's
        // `Transport` protocol, whose `logger: Logger` requirement is typed
        // against this package (already an existing transitive dependency
        // of swift-sdk itself — see swift-sdk's own Package.swift — added
        // here as a direct dependency because Swift requires an explicit
        // target dependency to `import Logging`, not just a transitive one).
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
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
                .product(name: "Logging", package: "swift-log"),
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
                .product(name: "Logging", package: "swift-log"),
            ]
        )
    ]
)
