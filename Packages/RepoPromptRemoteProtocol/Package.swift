// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RepoPromptRemoteProtocol",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "RepoPromptRemoteProtocol",
            targets: ["RepoPromptRemoteProtocol"]
        )
    ],
    targets: [
        .target(
            name: "RepoPromptRemoteProtocol"
        ),
        .testTarget(
            name: "RepoPromptRemoteProtocolTests",
            dependencies: ["RepoPromptRemoteProtocol"],
            resources: [.process("Fixtures")]
        )
    ]
)
