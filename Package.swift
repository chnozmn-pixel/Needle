// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Needle",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Needle", targets: ["NeedleApp"]),
        .library(name: "NeedleCore", targets: ["NeedleCore"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .target(name: "NeedleCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "NeedleApp", dependencies: ["NeedleCore"]),
        .testTarget(name: "NeedleTests", dependencies: ["NeedleCore"])
    ]
)
