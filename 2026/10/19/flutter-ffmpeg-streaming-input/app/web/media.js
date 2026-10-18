const source=document.getElementById('video-source');
let filePromise;
window.waitForVideo = ()=>source.files[0]?Promise.resolve(source.files[0]):(filePromise??=new Promise(resolve=>{source.onchange=()=>resolve(source.files[0]);}));
window.streamMedia = async (seconds,delay,cancelAt,onEvent)=>{
 const file=await window.waitForVideo();
 window.streamProgress={duration:seconds,audio_s:0,frames:0};
 return new Promise((resolve,reject)=>{
  const worker=new Worker('decoder/worker.js');const clock=performance.now();let firstPcm,firstImage,samples=0,frames=0,active=0,maxActive=0,maxPayload=0,settled=false;
  const finish=r=>{if(settled)return;settled=true;worker.terminate();resolve({...r,first_pcm_ms:firstPcm,first_image_ms:firstImage,audio_samples:samples,frames,max_pending_analysis_calls:maxActive,max_payload_bytes:maxPayload,elapsed_ms:performance.now()-clock,input_bytes:file.size});};
  worker.onerror=e=>{worker.terminate();reject(Error(e.message));};
  worker.onmessage=async e=>{
   if(settled)return;const r=e.data;
   if(r.error){worker.terminate();reject(Error(r.error));return;}
   if(r.done){finish({...r,cancelled:false});return;}
   active++;maxActive=Math.max(maxActive,active);
   try{
    const bytes=new Uint8Array(r.data);maxPayload=Math.max(maxPayload,bytes.length);
    if(r.kind===1)firstPcm??=performance.now()-clock;else firstImage??=performance.now()-clock;
    await onEvent(r.kind,bytes,r.pts);
    if(r.kind===1)samples+=bytes.length/2;else frames++;window.streamProgress.audio_s=samples/16000;window.streamProgress.frames=frames;
    if(delay>0&&r.kind===1)await new Promise(res=>setTimeout(res,delay*bytes.length/3200));
    if(cancelAt>0&&samples>=cancelAt*16000){const start=performance.now();finish({cancelled:true,cancel_latency_ms:performance.now()-start});return;}
    worker.postMessage({ack:true});
   }catch(error){worker.terminate();reject(error);}finally{active--;}
  };
  worker.postMessage({file,seconds});
 });
};
