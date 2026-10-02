// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AgentHub",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentHub", targets: ["AgentHub"]),
        .executable(name: "agenthubctl", targets: ["agenthubctl"]),
        .library(name: "HubCore", targets: ["HubCore"]),
    ],
    targets: [
        .target(name: "HubCore"),
        .executableTarget(name: "agenthubctl", dependencies: ["HubCore"]),
        .executableTarget(name: "AgentHub", dependencies: ["HubCore"]),
        .testTarget(name: "HubCoreTests", dependencies: ["HubCore"]),
    ]
)
