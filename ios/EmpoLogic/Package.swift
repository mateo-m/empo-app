// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EmpoLogic",
    platforms: [
        .macOS(.v13),
        .iOS(.v13),
    ],
    products: [
        .library(name: "EmpoLogic", targets: ["EmpoLogic"]),
    ],
    dependencies: [
        .package(url: "https://github.com/tsolomko/SWCompression.git", from: "4.9.0"),
    ],
    targets: [
        .target(
            name: "EmpoLogic",
            dependencies: [
                .product(
                    name: "SWCompression",
                    package: "SWCompression",
                    condition: .when(platforms: [.linux])
                ),
            ]
        ),
        .testTarget(
            name: "EmpoLogicTests",
            dependencies: ["EmpoLogic"],
            path: "Tests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
