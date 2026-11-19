// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Yomi",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "YomiKit", targets: ["YomiKit"]),
        .executable(name: "yomi", targets: ["yomi"]),
        .executable(name: "yomi-ocr", targets: ["yomi-ocr"]),
        .executable(name: "YomiApp", targets: ["YomiApp"]),
    ],
    targets: [
        .target(
            name: "YomiKit",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("IOUSBHost")]
        ),
        .executableTarget(name: "yomi", dependencies: ["YomiKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "yomi-ocr", dependencies: ["YomiKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "YomiApp", dependencies: ["YomiKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "YomiAppTests", dependencies: ["YomiApp"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "YomiKitTests",
            dependencies: ["YomiKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
