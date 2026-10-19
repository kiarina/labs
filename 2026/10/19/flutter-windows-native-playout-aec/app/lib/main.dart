import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:record/record.dart';
import 'native_bridge.dart';

void main() => runApp(const MaterialApp(home: Probe()));
class Probe extends StatefulWidget {
  const Probe({super.key});
  @override State<Probe> createState()=>_Probe();
}
class _Probe extends State<Probe>{
  String status='マイクを選んで開始してください',instruction='';int remaining=0;bool started=false;
  List<InputDevice> inputs=[];String? inputId;double liveDb=-120;String inputName='';
  static const aec=MethodChannel('aec_audio');
  @override void initState(){super.initState();unawaited(loadInputs());}
  Future<void> loadInputs()async{
    final discovery=AudioRecorder();
    try{
      final devices=await discovery.listInputDevices();
      String? wanted=Platform.environment['AEC_MIC_ID'];
      final saved=File('${Directory.systemTemp.path}/native_aec_input.json');
      if(wanted==null&&saved.existsSync())wanted=(jsonDecode(saved.readAsStringSync()) as Map<String,dynamic>)['id'] as String?;
      final selected=devices.where((d)=>d.id==wanted).firstOrNull??devices.where((d)=>d.label.contains('DualSense')).firstOrNull??devices.first;
      if(mounted)setState((){inputs=devices;inputId=selected.id;inputName=selected.label;});
      if(Platform.environment['AEC_AUTO_START']!='0')unawaited(run());
    }catch(e){if(mounted)setState(()=>status='入力一覧エラー: $e');}finally{await discovery.dispose();}
  }
  Future<Map<String,dynamic>> request(String method,String path,[Map<String,dynamic>? body])async{
    final client=HttpClient();try{final req=await client.openUrl(method,Uri.parse('${Platform.environment['AEC_PEER']??'http://127.0.0.1:18794'}$path'));
      if(body!=null){req.headers.contentType=ContentType.json;req.write(jsonEncode(body));}final res=await req.close();final text=await utf8.decoder.bind(res).join();if(res.statusCode!=200)throw StateError('peer ${res.statusCode}: $text');return jsonDecode(text) as Map<String,dynamic>;
    }finally{client.close();}
  }
  Future<void> run()async{
    if(started)return;started=true;
    final human=Platform.environment['AEC_HUMAN']=='1';final session=Platform.environment['AEC_SESSION']??'synthetic-1';
    final recorder=AudioRecorder(),bridge=CaptureBridge(),clock=Stopwatch()..start();
    final raw=BytesBuilder(copy:false),near=BytesBuilder(copy:false),mixed=BytesBuilder(copy:false);
    final outputs={'baseline':BytesBuilder(copy:false),'clockDrift':BytesBuilder(copy:false),'conditioned':BytesBuilder(copy:false)};
    final captureGaps=<Map<String,dynamic>>[];
    final selectedOutput=Platform.environment['AEC_OUTPUT']??'baseline';
    final errors=<String>[],phases=<Map<String,dynamic>>[],timeline=<Map<String,dynamic>>[];
    StreamSubscription<Uint8List>? sub;Timer? camera;RTCPeerConnection? pc;MediaStream? stream;
    Future<void> chain=Future.value();bool send=false,synthNear=false;int rawBytes=0,cleanBytes=0,videoFrames=0,injected=0,lastAudio=0,gap=0,videoSent=0;int sampleIndex=0;double rawEnergy=0;int rawSamples=0;
    Map<String,dynamic>? finalStats,stoppedStats,peerResult;String selectedMic='',selectedSpeaker='',selectedSpeakerId='';
    final report=<String,dynamic>{'kind':'normal-native-playout-aec','humanNear':human,'syntheticNearInjection':!human,'session':session,'phases':phases,'timeline':timeline,'errors':errors,'normalNativePlayout':true,'selectedOutput':selectedOutput,'captureGaps':captureGaps,'videoSource':'synthetic; physical camera unvalidated'};
    void mark(String stage){timeline.add({'stage':stage,'utc':DateTime.now().toUtc().toIso8601String(),'clockUs':clock.elapsedMicroseconds,'rawBytes':rawBytes});}
    Map<String,dynamic> counts()=>{'rawBytes':rawBytes,'cleanBytes':cleanBytes,'cameraFrames':videoFrames,'injectedAudioBytes':injected,'injectedVideoFrames':videoSent};
    Future<void> gate(bool enabled)async{if(enabled)await bridge.flush();send=enabled;stream?.getAudioTracks().single.enabled=enabled;mark(enabled?'send-on':'send-off');}
    Future<void> phase(String name,int seconds,{bool far=false,bool nearSignal=false,bool gateOn=true,String cue=''})async{
      synthNear=nearSignal&&!human;await gate(gateOn);final peerStart=await request('POST','/state',{'far':far,'phase':name});
      final startEnergy=rawEnergy,startSamples=rawSamples;
      final row=<String,dynamic>{'name':name,'far':far,'nearExpected':nearSignal,'start':counts(),'peerStart':peerStart};mark(name);
      for(var t=seconds;t>0;t--){if(mounted)setState((){status=name;instruction=cue;remaining=t;});await Future<void>.delayed(const Duration(seconds:1));}
      await chain;row['rawLevelDbfs']=rawSamples>startSamples?10*math.log((rawEnergy-startEnergy)/(rawSamples-startSamples)+1e-24)/math.ln10:-120;row['end']=counts();row['peerEnd']=await request('GET','/stats');row['stats']=await aec.invokeMapMethod<String,dynamic>('stats');phases.add(row);
    }
    try{
      final bytes=await rootBundle.load('assets/far_speech.pcm');final speech=bytes.buffer.asInt16List(bytes.offsetInBytes,bytes.lengthInBytes~/2);
      await WebRTC.initialize(options:{'externalAudioInputOnly':Platform.environment['AEC_EXTERNAL_ONLY']!='0'});
      stream=await bridge.create();pc=await createPeerConnection({'iceServers':[],'sdpSemantics':'unified-plan'});
      final devices=await navigator.mediaDevices.enumerateDevices();final speaker=devices.firstWhere((d)=>d.kind=='audiooutput'&&d.label.contains('EDIFIER'));
      selectedSpeaker=speaker.label;selectedSpeakerId=speaker.deviceId;await Helper.selectAudioOutput(speaker.deviceId);
      report['aecStart']=await aec.invokeMapMethod<String,dynamic>('configure',{'deviceId':speaker.deviceId,'delayMs':20});
      report['sdkIdentity']=await const MethodChannel('external_capture').invokeMapMethod<String,dynamic>('candidateIdentity');
      if(!await recorder.hasPermission())throw StateError('microphone permission');
      final input=(await recorder.listInputDevices()).firstWhere((d)=>d.id==inputId);selectedMic=input.label;
      File('${Directory.systemTemp.path}/native_aec_input.json').writeAsStringSync(jsonEncode({'id':input.id,'label':input.label}));
      sub=(await recorder.startStream(RecordConfig(encoder:AudioEncoder.pcm16bits,sampleRate:48000,numChannels:1,device:input,echoCancel:false,autoGain:false,noiseSuppress:false))).listen((data){
        final now=clock.elapsedMicroseconds;if(lastAudio>0){gap=math.max(gap,now-lastAudio);if(now-lastAudio>30000)captureGaps.add({'rawSample':rawBytes~/2,'gapUs':now-lastAudio,'clockUs':now});}lastAudio=now;rawBytes+=data.length;raw.add(data);
        double chunkEnergy=0;final measured=ByteData.sublistView(data);for(var i=0;i<data.length~/2;i++){final v=measured.getInt16(i*2,Endian.little)/32768;chunkEnergy+=v*v;}rawEnergy+=chunkEnergy;rawSamples+=data.length~/2;liveDb=10*math.log(chunkEnergy/(data.length~/2)+1e-24)/math.ln10;
        final useNear=synthNear;final values=ByteData.sublistView(data);final inputBytes=Uint8List(data.length),knownNear=Uint8List(data.length);final inView=ByteData.sublistView(inputBytes),nearView=ByteData.sublistView(knownNear);
        for(var i=0;i<data.length~/2;i++){
          final position=((sampleIndex++*.93+speech.length/2).floor())%speech.length;
          final n=useNear?(speech[position]*(double.tryParse(Platform.environment['AEC_NEAR_GAIN']??'')??(2/3))).round():0;
          nearView.setInt16(i*2,n,Endian.little);inView.setInt16(i*2,(values.getInt16(i*2,Endian.little)+n).clamp(-32768,32767),Endian.little);
        }
        near.add(knownNear);mixed.add(inputBytes);
        chain=chain.then((_)async{
          final result=(await aec.invokeMapMethod<String,dynamic>('captureCompare',{'bytes':inputBytes}))!;
          for(final name in outputs.keys)outputs[name]!.add(result[name] as Uint8List);
          final clean=result[selectedOutput] as Uint8List;cleanBytes+=clean.length;
          if(send&&clean.isNotEmpty){await bridge.pushAudio(clean);injected+=clean.length;}
        }).catchError((Object e){errors.add('$e');});
      });
      final image=Uint8List(320*240*4);for(var i=0;i<image.length;i+=4){image[i]=40;image[i+1]=100;image[i+2]=150;image[i+3]=255;}
      bool vb=false;camera=Timer.periodic(const Duration(milliseconds:33),(_){videoFrames++;if(send&&!vb){vb=true;bridge.pushVideo(image,320,240,clock.elapsedMicroseconds).then((_){videoSent++;}).catchError((Object e){errors.add('$e');}).whenComplete(()=>vb=false);}});
      for(final track in stream.getTracks())await pc.addTrack(track,stream);
      await pc.setLocalDescription(await pc.createOffer());for(var i=0;i<100&&pc.iceGatheringState!=RTCIceGatheringState.RTCIceGatheringStateComplete;i++){await Future<void>.delayed(const Duration(milliseconds:100));}
      final local=(await pc.getLocalDescription())!;final answer=await request('POST','/offer',{'session':session,'sdp':local.sdp,'type':local.type});await pc.setRemoteDescription(RTCSessionDescription(answer['sdp'] as String,answer['type'] as String));
      for(var i=0;i<100&&pc.connectionState!=RTCPeerConnectionState.RTCPeerConnectionStateConnected;i++){await Future<void>.delayed(const Duration(milliseconds:100));}
      if(pc.connectionState!=RTCPeerConnectionState.RTCPeerConnectionStateConnected)throw StateError('peer not connected');
      if(Platform.environment['AEC_CONTROL']=='1'){
        await phase('positive-capture-control',8,gateOn:true,cue:'SDK capture positive control');
      }else{
      if(human)await phase('mic-check',8,nearSignal:true,cue:'マイク確認：「こんにちは、マイクの確認です」と話してください。入力レベルが上がるか見てください');
      await phase('quiet',4,gateOn:false,cue:'声を出さず待ってください');
      if(human){final check=(phases.firstWhere((p)=>p['name']=='mic-check')['rawLevelDbfs'] as num).toDouble();final quiet=(phases.firstWhere((p)=>p['name']=='quiet')['rawLevelDbfs'] as num).toDouble();report['micCheck']={'speechDbfs':check,'quietDbfs':quiet,'snrDb':check-quiet};if(check-quiet<6)throw StateError('声の入力を十分に検出できません。選んだマイクと位置を確認してください。');}

      await phase('near-only',10,nearSignal:true,cue:human?'「今日はよい天気です。カメラとマイクは動き続けています。」と繰り返してください':'capture-only known near speech');
      await phase('far-warmup',12,far:true,gateOn:false,cue:'相手の声を聞き、声を出さず待ってください');
      await phase('far-1',8,far:true,cue:'声を出さず待ってください');
      await phase('doubletalk-1',8,far:true,nearSignal:true,cue:human?'相手の声に重ねて「私は今、同時に話しています。声が欠けずに届くか確認します。」と繰り返してください':'recorded near + physical far echo');
      await phase('doubletalk-gate-off',2,far:true,nearSignal:true,gateOn:false,cue:human?'そのまま話し続けてください':'sender gated, acquisition/DSP continues');
      await phase('doubletalk-2',8,far:true,nearSignal:true,cue:human?'そのまま相手の声に重ねて話し続けてください':'recorded near + physical far echo');
      await phase('quiet-after',3,gateOn:false,cue:'声を出さず待ってください');
      await phase('far-2',6,far:true,cue:'声を出さず待ってください');
      await phase('near-recovery',8,nearSignal:true,cue:human?'最初と同じ「今日はよい天気です。カメラとマイクは動き続けています。」と繰り返してください':'near recovery');
      await phase('final-quiet',3,gateOn:false,cue:'終了します');
      }
      report['inboundStats']=[for(final s in await pc.getStats())if(s.type=='inbound-rtp'){'id':s.id,...s.values}];
      peerResult=await request('POST','/finish',{});finalStats=await aec.invokeMapMethod<String,dynamic>('stats');
    }catch(e,st){errors.add('$e');report['stack']='$st';}
    finally{
      send=false;camera?.cancel();await sub?.cancel();await chain;await recorder.dispose();
      if(stream!=null){await pc?.close();await pc?.dispose();await bridge.dispose();}
      await aec.invokeMethod<void>('freeze');
      final render=await aec.invokeMethod<Uint8List>('renderTrace');
      final events=await aec.invokeMethod<Uint8List>('dspEvents');
      stoppedStats=await aec.invokeMapMethod<String,dynamic>('dispose');
      final folder=Directory('${Directory.systemTemp.path}/native_aec_$session')..createSync(recursive:true);
      File('${folder.path}/dsp-events.bin').writeAsBytesSync(events??Uint8List(0));
      for(final entry in {'raw':raw.takeBytes(),'near':near.takeBytes(),'mixed':mixed.takeBytes(),for(final e in outputs.entries)e.key:e.value.takeBytes(),'actual_render':render??Uint8List(0)}.entries){File('${folder.path}/${entry.key}.pcm').writeAsBytesSync(entry.value);}
      report.addAll({'selectedMic':selectedMic,'selectedSpeaker':selectedSpeaker,'selectedSpeakerId':selectedSpeakerId,'captureStarts':{'record':sub==null?0:1,'camera':camera==null?0:1},'totals':counts(),'maxAudioGapMs':gap/1000,'finalStats':finalStats,'stoppedStats':stoppedStats,'peer':peerResult,'elapsedMs':clock.elapsedMilliseconds});
      File('${folder.path}/report.json').writeAsStringSync(jsonEncode(report));
      File('${Directory.systemTemp.path}/native_aec_latest.json').writeAsStringSync(jsonEncode({'session':session,'folder':folder.path,'errors':errors}));
      if(mounted)setState((){status=errors.isEmpty?'DONE':'ERROR: $errors';instruction='録音を終了しました';remaining=0;});
      if(Platform.environment['AEC_EXIT']!='0'){if(human)await Future<void>.delayed(const Duration(seconds:5));exit(errors.isEmpty?0:1);}
    }
  }
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('Native speaker AEC / continuous record')),body:Padding(padding:const EdgeInsets.all(24),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(status,style:const TextStyle(fontSize:30)),if(!started&&inputs.isNotEmpty)DropdownButton<String>(isExpanded:true,value:inputId,items:inputs.map((d)=>DropdownMenuItem(value:d.id,child:Text(d.label))).toList(),onChanged:(id){if(id!=null)setState((){inputId=id;inputName=inputs.firstWhere((d)=>d.id==id).label;});}),Text('入力: $inputName\nマイクレベル: ${started?'${liveDb.toStringAsFixed(1)} dBFS':'未開始（開始後に動きます）'}',style:const TextStyle(fontSize:22)),Text('$remaining',style:const TextStyle(fontSize:54)),Text(instruction,style:const TextStyle(fontSize:28)),if(!started&&inputs.isNotEmpty)ElevatedButton(onPressed:run,child:const Text('開始'))])));
}
