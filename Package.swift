// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CleanNotificationMac",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CleanNotificationMac", targets: ["CleanNotificationMac"])
    ],
    targets: [
        // Note: Info.plist and entitlements live under Sources/Resources/ but
        // are NOT included as SPM resources. They are assembled into the .app
        // bundle by build.sh — macOS reads Contents/Info.plist at launch and
        // codesign consumes the entitlements file directly.
        .executableTarget(
            name: "CleanNotificationMac",
            path: "Sources",
            exclude: [
                "Resources/Info.plist",
                "Resources/CleanNotificationMac.entitlements",
                "Diagnostic",
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .testTarget(
            name: "CleanNotificationMacTests",
            dependencies: ["CleanNotificationMac"]
        )
    ]
)
