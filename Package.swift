// swift-tools-version:6.0
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

let package = Package(
    name: "RunShortcutsMCP",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "RunShortcutsMCP", targets: ["RunShortcutsMCP"]),
        .library(name: "RunShortcutsCore", targets: ["RunShortcutsCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.12.1")),
        // Build-time only: used by the `md2html` tool to render the manual.
        // Never linked into the shipped RunShortcutsMCP executable.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", .upToNextMinor(from: "0.8.0"))
    ],
    targets: [
        .target(
            name: "RunShortcutsCore"
        ),
        .executableTarget(
            name: "RunShortcutsMCP",
            dependencies: [
                "RunShortcutsCore",
                .product(name: "MCP", package: "swift-sdk")
            ]
        ),
        // Build-time doc tooling. Kept in a separate library/executable so the
        // swift-markdown dependency stays out of the distributed binary.
        .target(
            name: "MarkdownHTML",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown")
            ]
        ),
        .executableTarget(
            name: "md2html",
            dependencies: ["MarkdownHTML"]
        ),
        .testTarget(
            name: "RunShortcutsCoreTests",
            dependencies: ["RunShortcutsCore"]
        ),
        .testTarget(
            name: "MarkdownHTMLTests",
            dependencies: ["MarkdownHTML"]
        )
    ]
)
