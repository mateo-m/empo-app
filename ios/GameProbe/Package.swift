// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GameProbe",
    platforms: [
        .macOS(.v13),
        .iOS(.v13),
    ],
    products: [
        .library(name: "GameProbe", targets: ["GameProbe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/tsolomko/SWCompression.git", from: "4.9.0"),
    ],
    targets: [
        .target(
            name: "GameProbe",
            dependencies: [
                .product(
                    name: "SWCompression",
                    package: "SWCompression",
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
