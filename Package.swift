// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Still",
    platforms: [.macOS("15.4")],
    products: [.library(name: "StorageCore", targets: ["StorageCore"]),
               .library(name: "NTFSBridgeCore", targets: ["NTFSBridgeCore"]),
               .executable(name: "NTFSBridgeHelper", targets: ["NTFSBridgeHelper"])],
    targets: [
        .target(name: "StorageCore"),
        .testTarget(name: "StorageCoreTests", dependencies: ["StorageCore"]),
        .target(name: "NTFSBridgeCore", linkerSettings: [.linkedFramework("DiskArbitration"), .linkedFramework("IOKit")]),
        .executableTarget(name: "NTFSBridgeHelper", dependencies: ["NTFSBridgeCore"]),
        .testTarget(name: "NTFSBridgeCoreTests", dependencies: ["NTFSBridgeCore"])
    ]
)
