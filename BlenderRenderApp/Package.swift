// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BlenderRender",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "BlenderRender", path: "Sources")]
)
