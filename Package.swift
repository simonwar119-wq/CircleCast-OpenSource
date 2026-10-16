// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "CircleCast",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CircleCast", targets: ["CircleCast"])],
    targets: [
        .target(name: "CircleCastCore"),
        .executableTarget(name: "CircleCast", dependencies: ["CircleCastCore"]),
        .testTarget(name: "CircleCastCoreTests", dependencies: ["CircleCastCore"]),
        .testTarget(name: "CircleCastAppTests", dependencies: ["CircleCast"])
    ]
)
