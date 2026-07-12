// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "SquatCoach",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "SquatCoach", targets: ["SquatCoach"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/supabase/supabase-swift.git",
            exact: "2.50.0"
        ),
    ],
    targets: [
        .executableTarget(
            name: "SquatCoach",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift"),
            ],
            path: "Sources",
            swiftSettings: [
                .unsafeFlags(["-warn-concurrency", "-strict-concurrency=complete"]),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("Vision"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
