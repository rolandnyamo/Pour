// swift-tools-version: 6.0
import PackageDescription

// Swift 5 language mode on purpose for phase 0 — strict concurrency checking on
// CoreGraphics event taps and AVAudioEngine callbacks is a fight worth having
// later, once the hot path is proven. Tighten to .v6 in phase 1.
let mode: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Pour",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Pour", targets: ["Pour"])
    ],
    dependencies: [
        // Optional second engine (Parakeet, via FluidAudio) — isolated to ParakeetKit.
        // Apple's SpeechAnalyzer path (TranscriptionKit) has no dependency on this at all.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.6")
    ],
    targets: [
        .target(name: "HotkeyKit", swiftSettings: mode),
        .target(name: "PrivacyKit", swiftSettings: mode),
        .target(name: "AudioCapture", swiftSettings: mode),
        .target(name: "TranscriptionKit", swiftSettings: mode),
        .target(name: "RefineKit", swiftSettings: mode),
        .target(
            name: "ParakeetKit",
            dependencies: ["TranscriptionKit", .product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: mode
        ),
        .target(name: "InjectKit", swiftSettings: mode),
        .target(
            name: "DesignKit",
            // build.sh packages these app resources in Contents/Resources. Keeping
            // them out of SwiftPM avoids Bundle.module's command-line bundle layout,
            // which is incompatible with a signed macOS .app.
            exclude: ["Resources"],
            swiftSettings: mode
        ),
        .target(name: "DictionaryKit", dependencies: ["PrivacyKit"], swiftSettings: mode),
        .target(name: "HistoryKit", dependencies: ["DictionaryKit", "PrivacyKit"], swiftSettings: mode),
        .target(
            name: "FlowCore",
            dependencies: ["HotkeyKit", "AudioCapture", "TranscriptionKit", "InjectKit", "DictionaryKit", "RefineKit"],
            swiftSettings: mode
        ),
        .executableTarget(
            name: "Pour",
            dependencies: ["FlowCore", "AudioCapture", "DesignKit", "DictionaryKit", "HistoryKit", "TranscriptionKit", "ParakeetKit", "HotkeyKit", "PrivacyKit", "RefineKit"],
            swiftSettings: mode
        ),
        .executableTarget(
            name: "RiskWarningChecks",
            dependencies: ["DictionaryKit"],
            path: "Tests/RiskWarningChecks",
            swiftSettings: mode
        ),
        .executableTarget(
            name: "PrivacyChecks",
            dependencies: ["HistoryKit", "PrivacyKit"],
            path: "Tests/PrivacyChecks",
            swiftSettings: mode
        ),
        .executableTarget(
            name: "UsageStatsChecks",
            dependencies: ["HistoryKit"],
            path: "Tests/UsageStatsChecks",
            swiftSettings: mode
        ),
        .executableTarget(
            name: "RefineKitChecks",
            dependencies: ["RefineKit"],
            path: "Tests/RefineKitChecks",
            swiftSettings: mode
        ),
        .executableTarget(
            name: "HistoryMigrationChecks",
            dependencies: ["HistoryKit"],
            path: "Tests/HistoryMigrationChecks",
            swiftSettings: mode
        )
    ]
)
