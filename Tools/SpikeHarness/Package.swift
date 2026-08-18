// swift-tools-version: 5.9
import PackageDescription

// SpikeHarness — standalone driver for the Spike-1 matrix
// (docs/spikes/spike1.md, SPEC §4.1/§7). Depends on MeetingKitCore's
// CaptureKit ONLY (path dependency): the engine under test is the same code
// the app ships. No WhisperKit — this tool never transcribes.
let package = Package(
    name: "SpikeHarness",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../Packages/MeetingKitCore"),
    ],
    targets: [
        .executableTarget(
            name: "SpikeHarness",
            dependencies: [
                .product(name: "CaptureKit", package: "MeetingKitCore"),
            ],
            path: "Sources/SpikeHarness"
        ),
    ]
)
