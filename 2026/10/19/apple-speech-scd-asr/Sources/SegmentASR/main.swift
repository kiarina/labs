import AVFoundation
import CoreMedia
import Foundation
import Speech

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
func transcribe(_ segment:Segment,trial:Int,locale:Locale)async throws->Row {
 let origin=ContinuousClock.now
 let file=try AVAudioFile(forReading:URL(fileURLWithPath:segment.path),commonFormat:.pcmFormatInt16,interleaved:false)
 guard let buffer=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length))else{throw NSError(domain:"buffer",code:1)}
 try file.read(into:buffer)
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
 return Row(id:segment.id,speaker_id:segment.speaker_id,trial:trial,text:text,request_seconds:seconds,prepare_seconds:prepare,decode_finalize_seconds:seconds-prepare,events:events)
}
func main()async throws {
 guard SpeechTranscriber.isAvailable,let locale=await SpeechTranscriber.supportedLocale(equivalentTo:Locale(identifier:"ja-JP"))else{throw NSError(domain:"unsupported-ja",code:3)}
 let seed=SpeechTranscriber(locale:locale,preset:.transcription);let t=ContinuousClock.now
 _ = try await AssetInventory.reserve(locale:locale)
 let status=await AssetInventory.status(forModules:[seed])
 if status != .installed,let request=try await AssetInventory.assetInstallationRequest(supporting:[seed]){try await request.downloadAndInstall()}
 let assetTime=elapsed(t)
 if CommandLine.arguments[1] == "--serve" {
  struct Ready:Codable{let type:String;let asset_prepare_seconds:Double}
  struct Reply:Codable{let type:String;let row:Row}
  func emit<T:Encodable>(_ value:T)throws{let data=try JSONEncoder().encode(value);FileHandle.standardOutput.write(data);FileHandle.standardOutput.write(Data("\n".utf8))}
  try emit(Ready(type:"ready",asset_prepare_seconds:assetTime))
  while let line=readLine(){let segment=try JSONDecoder().decode(Segment.self,from:Data(line.utf8));let row=try await transcribe(segment,trial:0,locale:locale);try emit(Reply(type:"result",row:row))}
  return
 }
 let segments=try JSONDecoder().decode([Segment].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
 var rows:[Row]=[]
 for trial in 0..<3 {
  let order=trial==2 ? Array(segments.reversed()):segments
  for segment in order{rows.append(try await transcribe(segment,trial:trial,locale:locale))}
 }
 let output=Output(engine:"Apple SpeechAnalyzer SpeechTranscriber",locale:locale.identifier,asset_status_before:String(describing:status),asset_prepare_seconds:assetTime,preset:"transcription",rows:rows)
 let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];FileHandle.standardOutput.write(try encoder.encode(output))
}
do {try await main()}catch{FileHandle.standardError.write(Data("SpeechAnalyzer error: \(error)\n".utf8));exit(1)}
