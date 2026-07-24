// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sillage",
    platforms: [.macOS("26.0")],   // SpeechAnalyzer/SpeechTranscriber = macOS 26
    targets: [
        .executableTarget(
            name: "Sillage",
            path: "Sources/Sillage",
            swiftSettings: [
                // Mode langage 5 : évite le bruit de concurrence stricte de Swift 6
                // sur les callbacks AVFoundation / ScreenCaptureKit pendant le prototype.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
