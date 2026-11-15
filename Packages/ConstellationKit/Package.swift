// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "ConstellationKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ConstellationCore", targets: ["ConstellationCore"]),
        .library(name: "ConstellationProcess", targets: ["ConstellationProcess"]),
        .library(name: "ConstellationProviders", targets: ["ConstellationProviders"]),
        .library(name: "ConstellationMCP", targets: ["ConstellationMCP"]),
        .library(name: "ConstellationGit", targets: ["ConstellationGit"]),
        .library(name: "ConstellationGitHub", targets: ["ConstellationGitHub"]),
        .library(name: "ConstellationStore", targets: ["ConstellationStore"]),
        .executable(name: "constellation-mcp", targets: ["constellation-mcp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .target(name: "ConstellationCore"),
        .target(name: "ConstellationProcess"),
        .target(name: "ConstellationProviders", dependencies: ["ConstellationCore", "ConstellationProcess"]),
        .target(name: "ConstellationMCP", dependencies: ["ConstellationCore"]),
        .target(name: "ConstellationGit", dependencies: ["ConstellationCore", "ConstellationProcess"]),
        .target(name: "ConstellationGitHub", dependencies: ["ConstellationCore", "ConstellationProcess"]),
        .target(
            name: "ConstellationStore",
            dependencies: ["ConstellationCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .executableTarget(name: "constellation-mcp", dependencies: ["ConstellationMCP", "ConstellationProcess"]),

        .testTarget(name: "ConstellationCoreTests", dependencies: ["ConstellationCore"]),
        .testTarget(name: "ConstellationProcessTests", dependencies: ["ConstellationProcess"]),
        .testTarget(name: "ConstellationProvidersTests", dependencies: ["ConstellationProviders"]),
        .testTarget(name: "ConstellationMCPTests", dependencies: ["ConstellationMCP"]),
        .testTarget(name: "ConstellationGitTests", dependencies: ["ConstellationGit"]),
        .testTarget(name: "ConstellationGitHubTests", dependencies: ["ConstellationGitHub"]),
        .testTarget(name: "ConstellationStoreTests", dependencies: ["ConstellationStore"]),
    ]
)
