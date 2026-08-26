// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GameProbe",
    platforms: [
        .macOS(.v13),
        .iOS(.v14),
    ],
    products: [
        .library(name: "GameProbe", targets: ["GameProbe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/tsolomko/SWCompression.git", from: "4.9.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(path: "../Json5"),
    ],
    targets: [
        .target(
            name: "GameProbe",
            dependencies: [
                .product(name: "Json5", package: "Json5"),
                .product(
                    name: "SWCompression",
                    package: "SWCompression",
                    condition: .when(platforms: [.linux])
                ),
                // Apple platforms get SHA-256 from CryptoKit, which
                // is in the OS. Only Linux needs this package.
                .product(
                    name: "Crypto",
                    package: "swift-crypto",
                    condition: .when(platforms: [.linux])
                ),
            ]
        ),
        .testTarget(
            name: "GameProbeTests",
            dependencies: ["GameProbe"],
            path: "Tests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
