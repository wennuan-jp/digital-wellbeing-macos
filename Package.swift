// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "lol-guard",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "GuardCore", targets: ["GuardCore"]),
        .executable(name: "lol-guard", targets: ["lol-guard"]),
        .executable(name: "LolGuardApp", targets: ["LolGuardApp"])
    ],
    targets: [
        .target(
            name: "GuardCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Foundation")
            ]
        ),
        .executableTarget(
            name: "lol-guard",
            dependencies: ["GuardCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Foundation")
            ]
        ),
        .executableTarget(
            name: "LolGuardApp",
            dependencies: ["GuardCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
