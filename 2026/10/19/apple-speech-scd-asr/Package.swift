// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "segment-asr", platforms: [.macOS(.v26)], products: [.executable(name: "segment-asr",targets:["SegmentASR"])], targets:[.executableTarget(name:"SegmentASR")])
