// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DustWatch",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DustWatch", targets: ["DustWatch"])
    ],
    targets: [
        // Note: Info.plist and entitlements live under Sources/Resources/ but
        // are NOT included as SPM resources. They are assembled into the .app
        // bundle by build.sh — macOS reads Contents/Info.plist at launch and
        // codesign consumes the entitlements file directly.
        .executableTarget(
            name: "DustWatch",
            path: "Sources",
            exclude: [
                "Resources/Info.plist",
                "Resources/DustWatch.entitlements",
                "Resources/AppIcon.icns",
                "Resources/AppIcon.iconset",
                "Resources/icon_1024.png",
                "Diagnostic",
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .testTarget(
            name: "DustWatchTests",
            dependencies: ["DustWatch"]
        )
    ]
)
