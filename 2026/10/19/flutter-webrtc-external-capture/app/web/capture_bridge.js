// PCM capture remains owned by record; this is only a bounded playback sink.
globalThis.createExternalCaptureBridge = async function () {
  const context = new AudioContext({sampleRate: 48000});
  const workletCode = `class PcmSink extends AudioWorkletProcessor {
    constructor() { super(); this.q=[]; this.offset=0; this.length=0;
      this.port.onmessage=e=>{const a=e.data; if(a.flush){this.q=[];this.offset=0;this.length=0;return;} if(this.length+a.length>24000){this.q=[];this.offset=0;this.length=0;} this.q.push(a);this.length+=a.length;}; }
    process(inputs,outputs){const out=outputs[0][0]; for(let i=0;i<out.length;i++){
      if(!this.q.length){out[i]=0;continue;} out[i]=this.q[0][this.offset++];this.length--;
      if(this.offset===this.q[0].length){this.q.shift();this.offset=0;}}
      return true;}}
    registerProcessor('pcm-sink',PcmSink);`;
  const url = URL.createObjectURL(new Blob([workletCode], {type:'application/javascript'}));
  try { await context.audioWorklet.addModule(url); } finally { URL.revokeObjectURL(url); }
  const sink = new AudioWorkletNode(context, 'pcm-sink', {numberOfInputs:0,numberOfOutputs:1,outputChannelCount:[1]});
  const destination = context.createMediaStreamDestination();
  sink.connect(destination);
  await context.resume();
  const canvas = document.createElement('canvas');
  canvas.width=640; canvas.height=480;
  const drawing = canvas.getContext('2d');
  const videoStream = canvas.captureStream(0);
  const videoTrack = videoStream.getVideoTracks()[0];
  const stream = new MediaStream([...destination.stream.getAudioTracks(), videoTrack]);
  let cameraStream, timer, video;
  return {
    stream,
    pushAudio(bytes) {
      const view = new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength);
      const samples = new Float32Array(Math.floor(bytes.byteLength/2));
      for(let i=0;i<samples.length;i++) samples[i]=view.getInt16(i*2,true)/32768;
      sink.port.postMessage(samples,[samples.buffer]);
    },
    pushVideo(bgra,width,height) {
      if(canvas.width!==width || canvas.height!==height){canvas.width=width;canvas.height=height;}
      const rgba = new Uint8ClampedArray(bgra.length);
      for(let i=0;i<bgra.length;i+=4){rgba[i]=bgra[i+2];rgba[i+1]=bgra[i+1];rgba[i+2]=bgra[i];rgba[i+3]=255;}
      drawing.putImageData(new ImageData(rgba,width,height),0,0);
      videoTrack.requestFrame();
    },
    async startCamera(onFrame) {
      cameraStream = await navigator.mediaDevices.getUserMedia({video:{width:{ideal:640},height:{ideal:480}},audio:false});
      video=document.createElement('video');video.muted=true;video.playsInline=true;video.srcObject=cameraStream;
      await video.play();
      const capture=document.createElement('canvas');const ctx=capture.getContext('2d',{willReadFrequently:true});
      timer=setInterval(()=>{
        if(!video.videoWidth)return;
        capture.width=video.videoWidth;capture.height=video.videoHeight;
        ctx.drawImage(video,0,0);
        const pixels=ctx.getImageData(0,0,capture.width,capture.height).data;
        const bgra=new Uint8Array(pixels.length);
        for(let i=0;i<pixels.length;i+=4){bgra[i]=pixels[i+2];bgra[i+1]=pixels[i+1];bgra[i+2]=pixels[i];bgra[i+3]=255;}
        onFrame(bgra,capture.width,capture.height,Math.round(performance.now()*1000));
      },1000/15);
    },
    flush() { sink.port.postMessage({flush:true}); },
    async dispose() {
      clearInterval(timer);cameraStream?.getTracks().forEach(t=>t.stop());
      if(video){video.pause();video.srcObject=null;}
      stream.getTracks().forEach(t=>t.stop());sink.disconnect();await context.close();
    }
  };
};
