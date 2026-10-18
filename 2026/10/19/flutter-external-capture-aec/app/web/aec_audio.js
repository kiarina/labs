import createAecModule from './aec_engine.js';

let modulePromise;
globalThis.installAecCaptureObserver = function() {
  const entries=[];
  const original=navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
  navigator.mediaDevices.getUserMedia=async constraints=>{
    const stream=await original(constraints);
    entries.push({audioTracks:stream.getAudioTracks().length,videoTracks:stream.getVideoTracks().length,
      audioSettings:stream.getAudioTracks().map(track=>{
        const s=track.getSettings();return Object.fromEntries(['sampleRate','channelCount','sampleSize','echoCancellation','noiseSuppression','autoGainControl','latency'].filter(k=>k in s).map(k=>[k,s[k]]));
      })});
    return stream;
  };
  globalThis.aecCaptureInfo=()=>JSON.stringify(entries);
};
globalThis.createAecAudio = async function() {
  const wasm=await (modulePromise ??= createAecModule());
  const context=new AudioContext({sampleRate:48000,latencyHint:'interactive'});
  if(context.sampleRate!==48000)throw Error('AEC prototype requires a 48 kHz output context');
  await context.audioWorklet.addModule(new URL('./aec_playback_worklet.js',import.meta.url));
  const player=new AudioWorkletNode(context,'aec-playback',{numberOfInputs:0,numberOfOutputs:1,outputChannelCount:[1]});
  const input=wasm._malloc(960),output=wasm._malloc(960);
  let handle=0,enabled=true,delayMs=80,carry=new Uint8Array(0),lastReferenceFrame=0;
  let flushId=0;const pendingFlush=new Map();
  let disposed=false;
  const requireLive=()=>{if(disposed)throw Error('AEC backend is disposed');};
  // Bounded trace of the exact consumed samples sent to AEC reverse, zeros included.
  const traceCapacity=48000*120,trace=new Int16Array(traceCapacity);
  let traceLength=0,traceDroppedSamples=0;
  const counters={captureSamples:0,processedSamples:0,renderSubmittedSamples:0,renderedSamples:0,renderedNonzeroSamples:0,reverseFrames:0,underrunSamples:0,droppedRenderSamples:0,captureCalls:0,captureErrors:0};
  const store=pcm=>wasm.HEAP16.set(pcm,input>>1);
  player.port.onmessage=e=>{
    const v=e.data;
    if(v.flushed){pendingFlush.get(v.flushed)?.();pendingFlush.delete(v.flushed);return;}
    const retain=Math.min(v.reference.length,traceCapacity-traceLength);
    trace.set(v.reference.subarray(0,retain),traceLength);traceLength+=retain;
    traceDroppedSamples+=v.reference.length-retain;
    if(handle){store(v.reference);const result=wasm._aec_reverse(handle,input,480);if(result!==0) counters.captureErrors++;}
    counters.reverseFrames++;counters.renderedSamples=v.rendered;counters.renderedNonzeroSamples=v.nonzero;counters.underrunSamples=v.underrun;counters.droppedRenderSamples=v.dropped;lastReferenceFrame=v.frame;
  };
  player.connect(context.destination);await context.resume();
  return {
    configure(options){requireLive();enabled=options.enabled;delayMs=options.delayMs;
      if(handle)wasm._aec_destroy(handle);handle=wasm._aec_create(enabled?1:0);if(!handle)throw Error('AEC create failed');
      carry=new Uint8Array(0);player.port.postMessage({flush:true});},
    render(bytes){
      requireLive();
      if(bytes.byteLength%2)throw Error('Render PCM16 chunk has odd byte length');
      const pcm=new Int16Array(bytes.byteLength/2),view=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength);
      for(let i=0;i<pcm.length;i++)pcm[i]=view.getInt16(i*2,true);
      counters.renderSubmittedSamples+=pcm.length;player.port.postMessage({pcm},[pcm.buffer]);
    },
    stopRender(){requireLive();return new Promise(resolve=>{const id=++flushId;pendingFlush.set(id,resolve);player.port.postMessage({flush:true,id});});},
    renderTrace(){return new Uint8Array(trace.buffer,0,traceLength*2).slice();},
    capture(bytes){
      requireLive();
      if(!handle)throw Error('Call configure before capture');
      counters.captureCalls++;counters.captureSamples+=bytes.byteLength/2;
      const joined=new Uint8Array(carry.length+bytes.length);joined.set(carry);joined.set(bytes,carry.length);
      const frames=Math.floor(joined.length/960),clean=new Uint8Array(frames*960),view=new DataView(joined.buffer);
      for(let f=0;f<frames;f++){
        const pcm=new Int16Array(480);for(let i=0;i<480;i++)pcm[i]=view.getInt16(f*960+i*2,true);
        store(pcm);const rc=wasm._aec_capture(handle,input,output,480,delayMs);
        if(rc!==0){counters.captureErrors++;throw Error('AEC capture failed '+rc);}
        clean.set(wasm.HEAPU8.subarray(output,output+960),f*960);counters.processedSamples+=480;
      }
      carry=joined.slice(frames*960);return clean;
    },
    stats(){return JSON.stringify({...counters,enabled,delayMs,pendingCaptureBytes:carry.length,lastReferenceFrame,renderTraceSamples:traceLength,renderTraceDroppedSamples:traceDroppedSamples,sampleRate:context.sampleRate,baseLatency:context.baseLatency,outputLatency:context.outputLatency,contextState:context.state,backend:'aec3-wasm-main-thread',acousticValidated:false});},
    async dispose(){if(disposed)return;disposed=true;player.disconnect();player.port.onmessage=null;for(const resolve of pendingFlush.values())resolve();pendingFlush.clear();await context.close();if(handle)wasm._aec_destroy(handle);handle=0;wasm._free(input);wasm._free(output);}
  };
};
