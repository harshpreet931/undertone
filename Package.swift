// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Undertone",
    platforms: [
        // SwiftData / @Observable need 14.0; Core Audio process taps (meeting
        // recording, ARCHITECTURE.md §4.2) need 14.4 — checked at runtime.
        .macOS(.v14)
    ],
    dependencies: [
        // On-device Whisper via Core ML (ARCHITECTURE.md §3)
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.0.0"),
        // Parakeet TDT v3 on the Neural Engine — primary dictation engine:
        // ~110x realtime, built-in punctuation/capitalization, 25 languages.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.9.0"),
        // Global shortcut recording + persistence (ARCHITECTURE.md §6.2)
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "1.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Undertone",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources"
        )
    ]
)
