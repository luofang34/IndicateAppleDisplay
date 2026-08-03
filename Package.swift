// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "InstrumentSceneKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "InstrumentSceneKit", targets: ["InstrumentSceneKit"]),
    ],
    targets: [
        .target(name: "InstrumentSceneKit"),
        .testTarget(
            name: "InstrumentSceneKitTests",
            dependencies: ["InstrumentSceneKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
