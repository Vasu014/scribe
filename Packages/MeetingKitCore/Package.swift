// swift-tools-version: 5.9
import PackageDescription

// MeetingKitCore — local SPM package (SPEC §3.1).
// Module ownership mirrors the work split (§8).
// WhisperKit is deliberately absent until Spike 2 (§7); TranscribeKit ships
// the Transcriber seam + an unimplemented engine so UI work proceeds in parallel.
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
    ],
    targets: [
        // Persistence is the cross-team contract (Spike 3, §7): everything
        // else converges on its types. It depends on nothing local.
        .target(name: "Persistence", dependencies: [
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence"]),

        .target(name: "CaptureKit", dependencies: ["Persistence"]),
        .target(name: "TranscribeKit", dependencies: ["Persistence"]),
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
