// swift-tools-version: 6.0
import PackageDescription

// The json5cpp target holds a copy of json5pp.hpp from
// mkxp-z-apple-mobile/src/util, so the app reads mkxp.json the way the
// engine does. Copy it again when the engine's parser changes.
let package = Package(
    name: "Json5",
    platforms: [
        .macOS(.v13),
        .iOS(.v13),
    ],
    products: [
        .library(name: "Json5", targets: ["Json5"]),
    ],
    targets: [
        .target(name: "json5cpp"),
        .target(name: "Json5", dependencies: ["json5cpp"]),
        .testTarget(
            name: "Json5Tests",
            dependencies: ["Json5"],
            path: "Tests"
        ),
    ],
    cxxLanguageStandard: .cxx14
)
