// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MogoPrint",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MogoPrint", targets: ["MogoPrint"]),
        .executable(name: "mogo-cli", targets: ["mogo-cli"]),
    ],
    targets: [
        .target(name: "MogoCore"),
        .executableTarget(name: "MogoPrint", dependencies: ["MogoCore"]),
        .executableTarget(name: "mogo-cli", dependencies: ["MogoCore"]),
        .testTarget(name: "MogoCoreTests", dependencies: ["MogoCore"]),
    ]
)
