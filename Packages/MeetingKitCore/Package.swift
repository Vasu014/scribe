// swift-tools-version: 5.9
import PackageDescription

// MeetingKitCore — local SPM package (SPEC §3.1).
// Module ownership mirrors the work split (§8).
// WhisperKit landed with T3 (SPEC §4.2): attached to TranscribeKit only —
// every other module sees it through the Transcriber/WhisperEngine seams.
let package = Package(
    name: "MeetingKitCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CaptureKit", targets: ["CaptureKit"]),
        .library(name: "TranscribeKit", targets: ["TranscribeKit"]),
        .library(name: "ScratchpadKit", targets: ["ScratchpadKit"]),
        .library(name: "FusionKit", targets: ["FusionKit"]),
        .library(name: "SessionKit", targets: ["SessionKit"]),
        .library(name: "Persistence", targets: ["Persistence"]),
    ],
    dependencies: [
        // GRDB: decided in SPEC §4.6. Explicit schema control + migrations.
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        // WhisperKit: on-device speech-to-text engine (SPEC §4.2).
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0"),
    ],
    targets: [
        // Persistence is the cross-team contract (Spike 3, §7): everything
        // else converges on its types. It depends on nothing local.
        .target(name: "Persistence", dependencies: [
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence"]),

        .target(name: "CaptureKit", dependencies: ["Persistence"]),
        // CaptureKit unit tests cover the pure conversion math only (T4);
        // the SCK/AVAE engine classes are hardware + TCC dependent and stay
        // thin behind the CaptureEngine protocol (manual Spike-1 validation,
        // docs/spikes/spike1.md).
        .testTarget(name: "CaptureKitTests", dependencies: ["CaptureKit"]),
        // TranscribeKit is the ONLY target that links WhisperKit (SPEC §4.2);
        // the WhisperEngine seam keeps the rest of the package import-clean.
        .target(name: "TranscribeKit", dependencies: [
            "Persistence",
            .product(name: "WhisperKit", package: "WhisperKit"),
        ]),
        .testTarget(name: "TranscribeKitTests", dependencies: ["TranscribeKit"]),
        .target(name: "ScratchpadKit", dependencies: ["Persistence"]),
        .target(name: "FusionKit", dependencies: ["Persistence"]),
        .testTarget(name: "FusionKitTests", dependencies: ["FusionKit"]),
        .testTarget(name: "ScratchpadKitTests", dependencies: ["ScratchpadKit"]),
        // SessionKit is the composition root (§3.1): it wires capture →
        // transcription → store; data still flows through the store only.
        .target(name: "SessionKit", dependencies: [
            "Persistence", "CaptureKit", "TranscribeKit", "ScratchpadKit", "FusionKit",
        ]),
        .testTarget(name: "SessionKitTests", dependencies: [
            "SessionKit", "CaptureKit", "TranscribeKit", "ScratchpadKit",
            "FusionKit", "Persistence",
        ]),
    ]
)
