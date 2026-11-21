// swift-tools-version: 6.2
import Foundation
import PackageDescription

let irohBinary: Target = if ProcessInfo.processInfo.environment["REPOPROMPT_IROH_USE_LOCAL_ARTIFACT"] == "1" {
    .binaryTarget(name: "IrohTransportFFI", path: "Artifacts/IrohTransportFFI.xcframework")
} else {
    .binaryTarget(
        name: "IrohTransportFFI",
        url: "https://github.com/bobtheitguy31337/repoprompt-ce/releases/download/iroh-ffi-v0.1.0/IrohTransportFFI.xcframework.zip",
        checksum: "02dfc51f930e8bd7eaa67536363264b1e7a36026f21b2a7ed5322b6b46fc4764"
    )
}

let package = Package(
    name: "RepoPromptIrohTransport",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "RepoPromptIrohTransport", targets: ["RepoPromptIrohTransport"]),
    ],
    targets: [
        irohBinary,
        .target(
            name: "RepoPromptIrohTransport",
            dependencies: ["IrohTransportFFI"],
            path: "Sources/RepoPromptIrohTransport",
            linkerSettings: [
                .linkedFramework("CoreWLAN", .when(platforms: [.macOS])),
                .linkedFramework("Network"),
                .linkedFramework("SystemConfiguration")
            ]
        ),
        .testTarget(
            name: "RepoPromptIrohTransportTests",
            dependencies: ["RepoPromptIrohTransport"],
            path: "Tests/RepoPromptIrohTransportTests"
        ),
    ]
)
