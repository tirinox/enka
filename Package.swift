// swift-tools-version: 6.0
import PackageDescription

// The manifest sits at the repository root rather than inside `macos/`, because
// the code below it is no longer only the Mac's. `shared/Enka` — the API client,
// the models, the study session — is compiled into the macOS app by this
// package and into the iOS app by `ios/Enka.xcodeproj`, from the one copy.
//
// Compiled into both, not linked as a library. A library would mean a module
// boundary, and a module boundary across forty types means `public` on every
// declaration and a hand-written initialiser for every struct a view builds.
// That is a large, permanent tax on a seam that has one consumer on each side.
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
            // Two source roots under one target. `path` is where the target
            // begins and `sources` are the directories inside it that are
            // actually compiled, so naming both keeps the rest of the
            // repository — backend, web, ios — out of the build.
            path: ".",
            // Everything the target must not look at. SwiftPM walks the whole
            // of `path` to find files it was not told about and warns for each
            // one, so without this it reports the entire repository — 1834
            // files, most of them web/node_modules, restated on every build.
            //
            // A new top-level directory belongs on this list unless it holds
            // Swift the apps compile. `ios/` is here for that reason: Xcode
            // builds it, this package does not.
            exclude: [
                "LICENSE",
                "Makefile",
                "README.md",
                "backend",
                "docker-compose.override.yml",
                "docker-compose.yml",
                "ios",
                "web",
                "macos/README.md",
                "macos/Resources",
                "macos/Scripts",
                "macos/build",
            ],
            sources: ["macos/Sources/Enka", "shared/Enka"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
