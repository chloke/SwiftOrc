// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftOrc",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "SwiftOrc",
            targets: ["SwiftOrc"]
        ),
        .library(
            name: "SwiftOrcFoundationModels",
            targets: ["SwiftOrcFoundationModels"]
        ),
        .library(
            name: "SwiftOrcHTTP",
            targets: ["SwiftOrcHTTP"]
        ),
        .library(
            name: "SwiftOrcOpenAICompatible",
            targets: ["SwiftOrcOpenAICompatible"]
        ),
        .library(
            name: "SwiftOrcResponsesCompatible",
            targets: ["SwiftOrcResponsesCompatible"]
        ),
        .library(
            name: "SwiftOrcAnthropic",
            targets: ["SwiftOrcAnthropic"]
        ),
        .library(
            name: "SwiftOrcTesting",
            targets: ["SwiftOrcTesting"]
        ),
    ],
    targets: [
        .target(
            name: "SwiftOrc"
        ),
        .target(
            name: "SwiftOrcFoundationModels",
            dependencies: ["SwiftOrc"]
        ),
        .target(
            name: "SwiftOrcHTTP"
        ),
        .target(
            name: "SwiftOrcOpenAICompatible",
            dependencies: [
                "SwiftOrc",
                "SwiftOrcHTTP",
            ]
        ),
        .target(
            name: "SwiftOrcResponsesCompatible",
            dependencies: [
                "SwiftOrc",
                "SwiftOrcHTTP",
            ]
        ),
        .target(
            name: "SwiftOrcAnthropic",
            dependencies: [
                "SwiftOrc",
                "SwiftOrcHTTP",
            ]
        ),
        .target(
            name: "SwiftOrcTesting",
            dependencies: ["SwiftOrc"]
        ),
        .testTarget(
            name: "SwiftOrcTests",
            dependencies: ["SwiftOrc"]
        ),
        .testTarget(
            name: "SwiftOrcOpenAICompatibleTests",
            dependencies: [
                "SwiftOrc",
                "SwiftOrcHTTP",
                "SwiftOrcOpenAICompatible",
            ]
        ),
        .testTarget(
            name: "SwiftOrcResponsesCompatibleTests",
            dependencies: [
                "SwiftOrc",
                "SwiftOrcHTTP",
                "SwiftOrcResponsesCompatible",
            ]
        ),
        .testTarget(
            name: "SwiftOrcAnthropicTests",
            dependencies: [
                "SwiftOrc",
                "SwiftOrcHTTP",
                "SwiftOrcAnthropic",
            ]
        ),
        .testTarget(
            name: "SwiftOrcFoundationModelsTests",
            dependencies: [
                "SwiftOrc",
                "SwiftOrcFoundationModels",
            ]
        ),
        .testTarget(
            name: "SwiftOrcTestingTests",
            dependencies: [
                "SwiftOrc",
                "SwiftOrcTesting",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
