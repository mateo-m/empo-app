// swift-tools-version: 6.0
import PackageDescription

// The Json5 package wraps the engine's JSON5 parser (json5pp) for
// Swift callers. The json5cpp target holds a byte-identical copy of
// mkxp-z-apple-mobile/src/util/json5pp.hpp behind a C shim. The
// Json5 target gives it a Swift API. A test compares the vendored
// header against the engine submodule copy.
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
