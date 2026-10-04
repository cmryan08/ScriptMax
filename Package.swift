// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ScriptMax",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7", traits: [])
    ],
    targets: [
        .executableTarget(name: "ScriptMax", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
        .executableTarget(name: "StreamingProbe", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")], path: "Tests/StreamingProbe")
    ],
    swiftLanguageModes: [.v5]
)
