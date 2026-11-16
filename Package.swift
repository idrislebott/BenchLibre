// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BenchLibre",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.library(name: "BenchCore", targets: ["BenchCore"])],
    targets: [
        .target(name: "BenchKernels", publicHeadersPath: "include"),
        .target(name: "BenchCore", dependencies: ["BenchKernels"], resources: [.copy("Shaders"), .process("Localization")],
                linkerSettings: [.linkedFramework("Metal"), .linkedFramework("IOKit"), .linkedFramework("CryptoKit")]),
        .testTarget(name: "BenchCoreTests", dependencies: ["BenchCore"])
    ],
    swiftLanguageModes: [.v6]
)
