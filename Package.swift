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
        // A developer sample, not a product: no library consumer can depend
        // on it, and it stays out of every dependency closure but this
        // repository's own.
        .executableTarget(
            name: "BackendGallery",
            dependencies: ["IndicateAppleDisplay"],
            path: "Examples/BackendGallery"
        ),
        .executableTarget(
            name: "PanelBenchmark",
            dependencies: ["IndicateAppleDisplay"],
            path: "Benchmarks/PanelBenchmark"
        ),
        .testTarget(
            name: "IndicateAppleDisplayTests",
            dependencies: ["IndicateAppleDisplay"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
