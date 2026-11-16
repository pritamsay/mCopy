// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "myCopy",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MoverCore", targets: ["MoverCore"]),
        .executable(name: "myCopy", targets: ["myCopy"])
    ],
    targets: [
        .target(name: "MoverCore"),
        .executableTarget(name: "myCopy", dependencies: ["MoverCore"]),
        .testTarget(name: "MoverCoreTests", dependencies: ["MoverCore"])
    ]
)
