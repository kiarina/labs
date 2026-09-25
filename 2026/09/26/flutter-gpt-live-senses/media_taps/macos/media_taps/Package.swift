// swift-tools-version: 5.9
import PackageDescription

// Depends on flutter_webrtc the same way Flutter's generated plugin package
// does (sibling directory under ephemeral/Packages/.packages), so the taps can
// import flutter_webrtc's public headers and the WebRTC framework.
let package = Package(
    name: "media_taps",
    platforms: [
        .macOS("12.0")
    ],
    products: [
        .library(name: "media-taps", targets: ["media_taps"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        .package(name: "flutter_webrtc", path: "../flutter_webrtc-1.6.2+hotfix.3"),
    ],
    targets: [
        .target(
            name: "media_taps",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "flutter-webrtc", package: "flutter_webrtc"),
                .product(name: "WebRTC", package: "flutter_webrtc"),
            ]
        )
    ]
)
