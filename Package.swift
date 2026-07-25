// swift-tools-version:6.0
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
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0")
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
        .testTarget(
            name: "RunShortcutsCoreTests",
            dependencies: ["RunShortcutsCore"]
        )
    ]
)
