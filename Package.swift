// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScanSnap",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ScanSnapKit", targets: ["ScanSnapKit"]),
        .executable(name: "sscan", targets: ["sscan"]),
        .executable(name: "ScanSnapNative", targets: ["ScanSnapNative"]),
    ],
    targets: [
        .target(
            name: "ScanSnapKit",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("IOUSBHost")]
        ),
        .executableTarget(name: "sscan", dependencies: ["ScanSnapKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "ScanSnapNative", dependencies: ["ScanSnapKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ScanSnapKitTests", dependencies: ["ScanSnapKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
