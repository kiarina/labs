// swift-tools-version: 5.9
import PackageDescription
let package = Package(
 name: "external_capture", platforms: [.macOS("12.0")],
 products: [.library(name: "external-capture", targets: ["external_capture"])],
 dependencies: [.package(name: "FlutterFramework", path: "../FlutterFramework"), .package(name: "flutter_webrtc", path: "../flutter_webrtc")],
 targets: [.target(name: "external_capture", dependencies: [.product(name: "FlutterFramework", package: "FlutterFramework"), .product(name: "flutter-webrtc", package: "flutter_webrtc"), .product(name: "WebRTC", package: "flutter_webrtc")])])
