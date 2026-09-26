// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "news-capture",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "news-capture", targets: ["news-capture"]),
    ],
    targets: [
        .executableTarget(
            name: "news-capture",
            path: ".",
            sources: ["main.swift"],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
    ]
)
