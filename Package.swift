// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Panewright",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PanewrightCore", targets: ["PanewrightCore"]),
        .executable(name: "panewright", targets: ["PanewrightApp"]),
        .executable(name: "panewright-dev", targets: ["PanewrightDev"]),
    ],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.5.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "PanewrightCore",
            dependencies: ["TOMLKit"]
        ),
        .executableTarget(
            name: "PanewrightApp",
            dependencies: [
                "PanewrightCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .executableTarget(
            name: "PanewrightDev",
            dependencies: ["PanewrightCore"]
        ),
        .testTarget(
            name: "PanewrightCoreTests",
            dependencies: ["PanewrightCore"]
        ),
    ]
)
