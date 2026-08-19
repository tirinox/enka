// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Enka",
    // macOS 14 for `onKeyPress`, the two-parameter `onChange`, and
    // `NSHostingView.sizingOptions` — all three are load-bearing in the panel.
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Enka", targets: ["Enka"])
    ],
    targets: [
        .executableTarget(
            name: "Enka",
            path: "Sources/Enka",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
