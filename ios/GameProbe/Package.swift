// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

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
