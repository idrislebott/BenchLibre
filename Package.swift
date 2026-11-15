// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "BenchLibre",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "BenchLibre", targets: ["BenchLibre"])],
    targets: [
        .target(name: "BenchKernels", publicHeadersPath: "include", cSettings: [.unsafeFlags(["-O3"])]),
        .target(name: "BenchCore", dependencies: ["BenchKernels"], resources: [.copy("Shaders")], linkerSettings: [.linkedFramework("Metal"), .linkedFramework("IOKit")]),
        .executableTarget(name: "BenchLibre", dependencies: ["BenchCore"], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI")]),
        .testTarget(name: "BenchCoreTests", dependencies: ["BenchCore"])
    ],
    swiftLanguageModes: [.v5]
)
