// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentLinkKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "AgentLinkKit", targets: ["AgentLinkKit"])
    ],
    targets: [
        .target(name: "AgentLinkKit"),
        .testTarget(name: "AgentLinkKitTests", dependencies: ["AgentLinkKit"])
    ]
)
