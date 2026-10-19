import Cocoa
import FlutterMacOS
import AVFoundation
import CoreMedia
import Speech

class MainFlutterWindow: NSWindow {
  private var speechService: NativeSpeechService?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    speechService = NativeSpeechService(messenger: flutterViewController.engine.binaryMessenger)
    super.awakeFromNib()
  }
}

func elapsed(_ t: ContinuousClock.Instant) -> Double {
 let d=t.duration(to:.now);return Double(d.components.seconds)+Double(d.components.attoseconds)/1e18
}
struct Segment: Codable, Sendable {
 let id:String;let speaker_id:String;let start:Double;let end:Double;let path:String
}
struct Event: Codable, Sendable {
 let text:String;let final:Bool;let at:Double;let start:Double;let end:Double
}
actor Collector {
 let origin:ContinuousClock.Instant;var events:[Event]=[]
 init(_ origin:ContinuousClock.Instant){self.origin=origin}
 func add(_ r:SpeechTranscriber.Result){events.append(Event(text:String(r.text.characters),final:r.isFinal,at:elapsed(origin),start:r.range.start.seconds,end:r.range.end.seconds))}
 func get()->[Event]{events}
}
struct Row:Codable {
 let id:String;let speaker_id:String;let trial:Int;let text:String;let request_seconds:Double
 let prepare_seconds:Double;let decode_finalize_seconds:Double;let events:[Event]
}
struct Output:Codable {
 let engine:String;let locale:String;let asset_status_before:String;let asset_prepare_seconds:Double
 let preset:String;let rows:[Row]
}
func transcribePCM(_ segment:Segment,raw:Data,locale:Locale)async throws->Row {
 let origin=ContinuousClock.now
 let format=AVAudioFormat(commonFormat:.pcmFormatInt16,sampleRate:16000,channels:1,interleaved:false)!
 guard raw.count>0,raw.count%2==0,let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(raw.count/2)),let channel=buffer.int16ChannelData?[0]else{throw NSError(domain:"invalid-pcm",code:1)}
 buffer.frameLength=AVAudioFrameCount(raw.count/2)
 raw.withUnsafeBytes{bytes in UnsafeMutableRawPointer(channel).copyMemory(from:bytes.baseAddress!,byteCount:raw.count)}
 let transcriber=SpeechTranscriber(locale:locale,preset:.transcription)
 guard let format=await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:[transcriber],considering:buffer.format),format.sampleRate==buffer.format.sampleRate,format.channelCount==buffer.format.channelCount,format.commonFormat==buffer.format.commonFormat else {throw NSError(domain:"format",code:2)}
 let analyzer=SpeechAnalyzer(modules:[transcriber],options:.init(priority:.userInitiated,modelRetention:.processLifetime))
 try await analyzer.prepareToAnalyze(in:buffer.format)
 let prepare=elapsed(origin);let collector=Collector(origin)
 let task=Task { for try await result in transcriber.results {await collector.add(result)} }
 let input=AsyncStream<AnalyzerInput>{continuation in
  continuation.yield(AnalyzerInput(buffer:buffer));continuation.finish()
 }
 do {
  if let last=try await analyzer.analyzeSequence(input){try await analyzer.finalizeAndFinish(through:last)}else{await analyzer.cancelAndFinishNow()}
  try await task.value
 }catch{task.cancel();await analyzer.cancelAndFinishNow();throw error}
 let seconds=elapsed(origin);let events=await collector.get();let text=events.filter(\.final).sorted{$0.start<$1.start}.map(\.text).joined()
 return Row(id:segment.id,speaker_id:segment.speaker_id,trial:0,text:text,request_seconds:seconds,prepare_seconds:prepare,decode_finalize_seconds:seconds-prepare,events:events)
}

final class NativeSpeechService {
 let channel:FlutterMethodChannel
 init(messenger:FlutterBinaryMessenger){
  channel=FlutterMethodChannel(name:"apple_asr",binaryMessenger:messenger)
  channel.setMethodCallHandler{call,reply in
   Task { @MainActor in
    do {
     guard SpeechTranscriber.isAvailable,let locale=await SpeechTranscriber.supportedLocale(equivalentTo:Locale(identifier:"ja-JP"))else{throw NSError(domain:"unavailable-ja",code:3)}
     if call.method=="prepare" {
      let t=ContinuousClock.now;let seed=SpeechTranscriber(locale:locale,preset:.transcription)
      _ = try await AssetInventory.reserve(locale:locale)
      if await AssetInventory.status(forModules:[seed]) != .installed,let request=try await AssetInventory.assetInstallationRequest(supporting:[seed]){try await request.downloadAndInstall()}
      reply(["ready":true,"seconds":elapsed(t)]);return
     }
     if call.method=="recognize",let args=call.arguments as? [String:Any],let id=args["id"]as? String,let audio=args["audio"]as? FlutterStandardTypedData {
      let speaker=args["speaker_id"]as? String ?? "unknown"
      let segment=Segment(id:id,speaker_id:speaker,start:0,end:Double(audio.data.count)/32000,path:"")
      let row=try await transcribePCM(segment,raw:audio.data,locale:locale)
      reply(["id":row.id,"speaker_id":row.speaker_id,"text":row.text,"request_seconds":row.request_seconds,"final_results":row.events.filter(\.final).count]);return
     }
     reply(FlutterMethodNotImplemented)
    } catch {reply(FlutterError(code:"native_asr_failed",message:"SpeechAnalyzer could not complete the request",details:String(describing:type(of:error))))}
   }
  }
 }
}
