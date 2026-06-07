// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceTuT",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "VoiceTuT", targets: ["VoiceTuT"])],
    targets: [
        .executableTarget(name: "VoiceTuT", path: "Sources/VoiceTuT")
    ]
)
