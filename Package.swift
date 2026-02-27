// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CheWordMCP",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.10.2"),
        .package(url: "https://github.com/kiki830621/ooxml-swift.git", from: "0.2.0"),
        .package(url: "https://github.com/kiki830621/word-to-md-swift.git", from: "0.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "CheWordMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "OOXMLSwift", package: "ooxml-swift"),
                .product(name: "WordToMDSwift", package: "word-to-md-swift"),
            ]
        )
    ]
)
