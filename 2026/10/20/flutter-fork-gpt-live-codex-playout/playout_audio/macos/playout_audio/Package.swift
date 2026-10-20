// swift-tools-version: 5.9
import PackageDescription
let package = Package(
 name: "playout_audio", platforms: [.macOS("12.0")],
 products: [.library(name: "playout-audio", targets: ["playout_audio"])],
 dependencies: [
 .package(name: "FlutterFramework", path: "../FlutterFramework"),
 .package(name: "flutter_webrtc", path: "../flutter_webrtc")],
 targets: [
 .target(name: "PlayoutCore", path: "Sources/PlayoutCore", publicHeadersPath: "include", cxxSettings: [
 .define("WEBRTC_POSIX"), .define("WEBRTC_MAC"), .define("AEC_ENGINE_BUILD"),
 .headerSearchPath("third_party/src/"),
 .headerSearchPath("third_party/src/api"),
 .headerSearchPath("third_party/src/base/rtc_base"),
 .headerSearchPath("third_party/src/base"),
 .headerSearchPath("third_party/src/base/system_wrappers/include"),
 .headerSearchPath("third_party/src/audio_processing"),
 .headerSearchPath("third_party/src/absl"),
 .headerSearchPath("third_party/src/base/jsoncpp/include"),
 .headerSearchPath("third_party/src/audio_processing/aec3"),
 .headerSearchPath("third_party/src/audio_processing/resampler"),
 .headerSearchPath("third_party/src/audio_processing/logging"),
 .headerSearchPath("third_party/src/audio_processing/include"),
 .headerSearchPath("third_party/src/audio_processing/utility"),
 .headerSearchPath("third_party/src/rtc_base/experiments"),
 .headerSearchPath("third_party/src/common_audio"),
 .headerSearchPath("third_party/src/common_audio/third_party/ooura/fft_size_128")
 ], linkerSettings: [.linkedFramework("CoreFoundation")]),
 .target(name: "playout_audio", dependencies: ["PlayoutCore",
  .product(name: "FlutterFramework", package: "FlutterFramework"),
  .product(name: "flutter-webrtc", package: "flutter_webrtc"),
  .product(name: "WebRTC", package: "flutter_webrtc")],
  publicHeadersPath: "include", linkerSettings: [.linkedFramework("AVFoundation")])
 ], cxxLanguageStandard: .cxx20)
