// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BandalCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "BandalCore", targets: ["BandalCore"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "BandalCore", dependencies: ["CSQLite"]),
        .testTarget(name: "BandalCoreTests", dependencies: ["BandalCore"])
    ]
)
