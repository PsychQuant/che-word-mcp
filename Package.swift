// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CheWordMCP",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        .package(url: "https://github.com/PsychQuant/ooxml-swift.git", from: "0.5.2"),
        .package(url: "https://github.com/PsychQuant/word-to-md-swift.git", from: "0.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "CheWordMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "OOXMLSwift", package: "ooxml-swift"),
                .product(name: "WordToMDSwift", package: "word-to-md-swift"),
            ]
        ),
        .testTarget(
            name: "CheWordMCPTests",
            dependencies: [
                "CheWordMCP",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "OOXMLSwift", package: "ooxml-swift"),
            ]
        )
    ]
)
