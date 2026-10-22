// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BrightSync",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "DDCKit",
            cSettings: [
                .define("MAX_DISPLAYS", to: "8"),
                // The vendored m1ddc sources predate ARC and are kept verbatim.
                .unsafeFlags(["-fno-objc-arc"]),
            ],
            linkerSettings: [
                .linkedFramework("CoreDisplay"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .executableTarget(
            name: "BrightSync",
            dependencies: ["DDCKit"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "BrightSyncTests",
            dependencies: ["BrightSync"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
