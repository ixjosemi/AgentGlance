// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AgentGlance",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "agentglance", targets: ["AgentGlance"]),
        .executable(name: "AgentGlanceApp", targets: ["AgentGlanceApp"]),
        .executable(name: "agentglance-tests", targets: ["AgentGlanceTests"]),
    ],
    targets: [
        .target(
            name: "AgentGlanceCore",
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "AgentGlance",
            dependencies: ["AgentGlanceCore"]
        ),
        .executableTarget(
            name: "AgentGlanceApp",
            dependencies: ["AgentGlanceCore"]
        ),
        .executableTarget(
            name: "AgentGlanceTests",
            dependencies: ["AgentGlanceCore"],
            path: "Tests/AgentGlanceCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
