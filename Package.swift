// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DynamicCursors",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DynamicCursors", targets: ["DynamicCursors"])],
    targets: [.executableTarget(name: "DynamicCursors")]
)
