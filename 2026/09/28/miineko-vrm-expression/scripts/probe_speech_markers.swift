import AVFoundation
import Foundation
let synth=AVSpeechSynthesizer()
let voice=AVSpeechSynthesisVoice.speechVoices().first{$0.name=="Kyoko" && $0.language=="ja-JP"}!
let utterance=AVSpeechUtterance(string:"こんにちは、みぃねこです。")
utterance.voice=voice
var done=false
var frames:UInt64=0
var events:[[String:Any]]=[]
synth.write(utterance,toBufferCallback:{ buffer in
 guard let pcm=buffer as? AVAudioPCMBuffer else{return}
 frames += UInt64(pcm.frameLength)
 if pcm.frameLength==0{done=true}
},toMarkerCallback:{ markers in
 for m in markers{events.append(["mark":m.mark.rawValue,"phoneme":m.phoneme,"offset":m.byteSampleOffset,"range":[m.textRange.location,m.textRange.length]])}
})
let end=Date().addingTimeInterval(25)
while !done && Date()<end{RunLoop.current.run(until:Date().addingTimeInterval(0.05))}
let data=try! JSONSerialization.data(withJSONObject:["voice":voice.identifier,"frames":frames,"done":done,"events":events],options:[.prettyPrinted,.sortedKeys])
print(String(data:data,encoding:.utf8)!)
