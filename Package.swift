// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "xanewm",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "XaneWM", targets: ["XaneWM"]),
        .executable(name: "xanectl", targets: ["xanectl"]),
        .library(name: "XaneCore", targets: ["XaneCore"]),
    ],
    targets: [
        // Pure logic: geometry, layout, state, commands. No AppKit, no AX. Builds and tests on Linux.
        .target(name: "XaneCore"),
        // The compositor process (macOS only; on other platforms it builds to a stub).
        .executableTarget(
            name: "XaneWM",
            dependencies: ["XaneCore"],
            linkerSettings: [
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("ApplicationServices", .when(platforms: [.macOS])),
                .linkedFramework("Carbon", .when(platforms: [.macOS])),
                .linkedFramework("QuartzCore", .when(platforms: [.macOS])),
            ]
        ),
        // IPC client, in the spirit of swaymsg / riverctl.
        .executableTarget(name: "xanectl"),
        .testTarget(name: "XaneCoreTests", dependencies: ["XaneCore"]),
    ]
)
