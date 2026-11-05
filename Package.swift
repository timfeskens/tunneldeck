// swift-tools-version: 6.0
import PackageDescription
import Foundation

// The owner keeps local tests outside version control. A fresh source checkout
// must still build successfully without the optional Tests directory.
let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let localTests: [Target] = FileManager.default.fileExists(atPath: packageDirectory.appendingPathComponent("Tests/TunnelDeckCoreTests").path)
    ? [.testTarget(name: "TunnelDeckCoreTests", dependencies: ["TunnelDeckCore", "CZlib"])] : []

let package = Package(
    name: "TunnelDeck",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TunnelDeck", targets: ["TunnelDeck"]),
        .executable(name: "TunnelDeckHelper", targets: ["TunnelDeckHelper"])
    ],
    targets: [
        .systemLibrary(name: "CZlib"),
        .target(name: "TunnelDeckCore", dependencies: ["CZlib"]),
        .executableTarget(name: "TunnelDeck", dependencies: ["TunnelDeckCore"]),
        .executableTarget(name: "TunnelDeckHelper", dependencies: ["TunnelDeckCore"])
    ] + localTests,
    swiftLanguageModes: [.v5]
)
