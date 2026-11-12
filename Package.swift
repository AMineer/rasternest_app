// swift-tools-version: 6.0
import PackageDescription

// RasterNest is one Swift package with layered targets:
//
//   RasterNestCore     Foundation-only model (annotations, geometry, .rasternest format).   macOS · Linux · Windows
//   RasterNestCapture  Headless screen capture, clipboard and OCR with per-OS backends.      macOS · Linux
//   RasterNestRender   Flattens annotations onto an image (CoreGraphics/AppKit).            macOS
//   rnest              Command-line tool.                                                  macOS · Linux
//   RasterNestApp      Native menu-bar app with capture overlay and markup editor.         macOS

var products: [Product] = [
    .executable(name: "rnest", targets: ["rnest"]),
    .library(name: "RasterNestCore", targets: ["RasterNestCore"]),
]

var targets: [Target] = [
    .target(name: "RasterNestCore"),
    .target(name: "RasterNestCapture", dependencies: ["RasterNestCore"]),
    // Sources are wrapped in `#if canImport(AppKit)` so the target is empty off macOS.
    .target(name: "RasterNestRender", dependencies: ["RasterNestCore"]),
    .executableTarget(
        name: "rnest",
        dependencies: [
            "RasterNestCore",
            "RasterNestCapture",
            .target(name: "RasterNestRender", condition: .when(platforms: [.macOS])),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]
    ),
    .testTarget(name: "RasterNestCoreTests", dependencies: ["RasterNestCore"]),
]

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
]

#if os(macOS)
// Sparkle: in-app auto-updates for the DMG build (macOS only).
dependencies.append(.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"))
products.append(.executable(name: "RasterNestApp", targets: ["RasterNestApp"]))
targets.append(
    .executableTarget(
        name: "RasterNestApp",
        dependencies: [
            "RasterNestCore", "RasterNestCapture", "RasterNestRender",
            .product(name: "Sparkle", package: "Sparkle"),
        ]
    )
)
#endif

let package = Package(
    name: "RasterNest",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: dependencies,
    targets: targets,
    swiftLanguageModes: [.v5]
)
