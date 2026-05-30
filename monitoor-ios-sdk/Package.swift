// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MonitoorSDK",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "MonitoorSDK", targets: ["MonitoorSDK"]),
    ],
    targets: [
        .target(
            name: "MonitoorSDK",
            dependencies: [],
            path: "Sources/MonitoorSDK",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "MonitoorSDKTests",
            dependencies: ["MonitoorSDK"],
            path: "Tests/MonitoorSDKTests"
        ),
    ]
)
