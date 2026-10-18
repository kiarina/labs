// swift-tools-version: 5.9
import PackageDescription
let package = Package(
 name: "aec_audio", platforms: [.macOS("12.0")],
 products: [.library(name: "aec-audio", targets: ["aec_audio"])],
 dependencies: [.package(name: "FlutterFramework", path: "../FlutterFramework")],
 targets: [
 .target(name: "AecCore", path: "Sources/AecCore", publicHeadersPath: "include", cxxSettings: [
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
 .target(name: "aec_audio", dependencies: ["AecCore", .product(name: "FlutterFramework", package: "FlutterFramework")], publicHeadersPath: "include")
 ], cxxLanguageStandard: .cxx20)
