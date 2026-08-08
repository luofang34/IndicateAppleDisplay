// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "IndicateAppleDisplay",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "IndicateAppleDisplay", targets: ["IndicateAppleDisplay"]),
    ],
    targets: [
        .target(name: "IndicateAppleDisplay"),
        .testTarget(
            name: "IndicateAppleDisplayTests",
            dependencies: ["IndicateAppleDisplay"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
