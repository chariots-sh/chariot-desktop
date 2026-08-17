// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ChariotMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ChariotCore", targets: ["ChariotCore"])
    ],
    dependencies: [
        .package(path: "../AgentLinkKit"),
        // GUI-only. ChariotCore and chariotd stay Sparkle-free so the headless
        // daemon and the test targets keep building without it.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6")
    ],
    targets: [
        .target(
            name: "ChariotCore",
            dependencies: ["AgentLinkKit"]
        ),
        .executableTarget(
            name: "chariotd",
            dependencies: ["ChariotCore", "AgentLinkKit"]
        ),
        .executableTarget(
            name: "ChariotDesktopApp",
            dependencies: ["ChariotCore", "AgentLinkKit",
                           .product(name: "Sparkle", package: "Sparkle")]
        ),
        .testTarget(
            name: "ChariotCoreTests",
            dependencies: ["ChariotCore", "AgentLinkKit"]
        )
    ]
)
