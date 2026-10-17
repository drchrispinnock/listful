// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Listful",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Listful", targets: ["Listful"]),
    ],
    targets: [
        .target(name: "ListfulCore"),
        .executableTarget(
            name: "Listful",
            dependencies: ["ListfulCore"],
            resources: [.copy("Resources/AppIcon.png")]
        ),
        .testTarget(name: "ListfulCoreTests", dependencies: ["ListfulCore"]),
    ]
)
