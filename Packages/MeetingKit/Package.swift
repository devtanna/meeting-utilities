// swift-tools-version: 6.2
// Host-side modules. No MLX here: the host process never links inference runtimes (§4.1).
import PackageDescription

let package = Package(
    name: "MeetingKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MeetingCore", targets: ["MeetingCore"]),
        .library(name: "MeetingData", targets: ["MeetingData"]),
        .library(name: "MeetingAudio", targets: ["MeetingAudio"]),
        .library(name: "InferenceProtocol", targets: ["InferenceProtocol"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.12.0"),
    ],
    targets: [
        .target(name: "MeetingCore"),
        .target(name: "InferenceProtocol"),
        .target(name: "MeetingData", dependencies: [
            "MeetingCore",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .target(name: "MeetingAudio", dependencies: ["MeetingCore"], resources: [.copy("Resources/silero-vad.mlmodelc")]),
        .testTarget(name: "MeetingCoreTests", dependencies: ["MeetingCore"]),
        .testTarget(name: "MeetingDataTests", dependencies: ["MeetingData", "MeetingCore"]),
        .testTarget(name: "MeetingAudioTests", dependencies: ["MeetingAudio", "MeetingCore", "InferenceProtocol"]),
        .testTarget(name: "InferenceProtocolTests", dependencies: ["InferenceProtocol"]),
    ]
)
