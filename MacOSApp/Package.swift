// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AI-Balance-Whale-MacOS",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CodexCore", targets: ["CodexCore"]),
        .executable(name: "AIBalanceWhale", targets: ["AIBalanceWhale"]),
    ],
    targets: [
        .target(name: "CodexCore"),
        .executableTarget(name: "AIBalanceWhale", dependencies: ["CodexCore"]),
        .testTarget(name: "CodexCoreTests", dependencies: ["CodexCore"]),
        .testTarget(name: "WidgetWebViewTests", dependencies: ["CodexCore"]),
    ]
)
