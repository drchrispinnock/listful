// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Listful",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Listful", targets: ["Listful"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6"),
    ],
    targets: [
        .target(name: "ListfulCore"),
        .executableTarget(
            name: "Listful",
            dependencies: ["ListfulCore", .product(name: "Sparkle", package: "Sparkle")],
            resources: [.copy("Resources/AppIcon.png")]
        ),
        .testTarget(name: "ListfulCoreTests", dependencies: ["ListfulCore"]),
    ]
)
