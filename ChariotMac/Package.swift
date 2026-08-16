// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ChariotMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ChariotCore", targets: ["ChariotCore"])
    ],
    dependencies: [
        .package(path: "../AgentLinkKit")
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
            dependencies: ["ChariotCore", "AgentLinkKit"]
        )
    ]
)
