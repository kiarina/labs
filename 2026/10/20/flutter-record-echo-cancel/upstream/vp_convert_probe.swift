// Repro for record_macos: voice processing input (multi-channel Float32) converted
// to mono Int16 with AVAudioConverter comes out as all zeros.
//
//   swift vp_convert_probe.swift            # voice processing on
//   swift vp_convert_probe.swift novp       # voice processing off (control)
//
// Prints, per mode, the peak of the tap buffer (channel 0) and of the converted output.
import AVFoundation

let useVP = !CommandLine.arguments.contains("novp")
let seconds = 3.0

let engine = AVAudioEngine()
if useVP { try! engine.inputNode.setVoiceProcessingEnabled(true) }
let src = engine.inputNode.inputFormat(forBus: 0)
print("voiceProcessing=\(useVP) input=\(src)")

let dst = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: src.sampleRate, channels: 1, interleaved: false)!

// A: what record_macos 2.1.1 does: convert the whole tap buffer.
let convA = AVAudioConverter(from: src, to: dst)!
// B: same converter, but with an explicit channel map (take input channel 0).
let convB = AVAudioConverter(from: src, to: dst)!
convB.channelMap = [0]
// C: copy channel 0 into a mono buffer, then convert (what #523 did).
let convC = AVAudioConverter(from: mono, to: dst)!

func convert(_ c: AVAudioConverter, _ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
  let cap = AVAudioFrameCount(Double(b.frameLength) * dst.sampleRate / b.format.sampleRate) + 1
  let out = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: cap)!
  var given = false
  var err: NSError?
  c.convert(to: out, error: &err) { _, status in
    if given { status.pointee = .noDataNow; return nil }
    given = true; status.pointee = .haveData; return b
  }
  if let err { print("convert error: \(err)") }
  return out
}
func firstChannel(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
  let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: b.frameLength)!
  out.frameLength = b.frameLength
  out.floatChannelData![0].update(from: b.floatChannelData![0], count: Int(b.frameLength))
  return out
}
func peak(_ b: AVAudioPCMBuffer) -> Float {
  var p: Float = 0
  if let f = b.floatChannelData?[0] { for i in 0..<Int(b.frameLength) { p = max(p, abs(f[i])) } }
  if let s = b.int16ChannelData?[0] { for i in 0..<Int(b.frameLength) { p = max(p, Float(s[i].magnitude) / 32767) } }
  return p
}

let lock = NSLock()
var tapPeak: Float = 0, peakA: Float = 0, peakB: Float = 0, peakC: Float = 0
engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: src) { buffer, _ in
  let t = peak(buffer)
  let a = peak(convert(convA, buffer))
  let b = peak(convert(convB, buffer))
  let c = peak(convert(convC, firstChannel(buffer)))
  lock.lock(); tapPeak = max(tapPeak, t); peakA = max(peakA, a); peakB = max(peakB, b); peakC = max(peakC, c); lock.unlock()
}
engine.prepare()
try! engine.start()
print("recording \(seconds)s, please make some sound...")
RunLoop.main.run(until: Date().addingTimeInterval(seconds))
engine.stop()

print(String(format: "tap ch0 peak             %.4f", tapPeak))
print(String(format: "A convert whole buffer   %.4f", peakA))
print(String(format: "B channelMap = [0]       %.4f", peakB))
print(String(format: "C copy ch0, then convert %.4f", peakC))
