window.decodeMedia = input => new Promise((resolve,reject)=>{
 const worker=new Worker('decoder/worker.js');
 const timer=setTimeout(()=>{worker.terminate();reject(Error('decoder timeout'));},60000);
 worker.onmessage=e=>{if(e.data.stage)return;clearTimeout(timer);worker.terminate();if(e.data.error)reject(Error(e.data.error));else resolve({...e.data,pcm:new Uint8Array(e.data.pcm)});};
 worker.onerror=e=>{clearTimeout(timer);worker.terminate();reject(Error(e.message));};
 const copy=input.slice();worker.postMessage(copy.buffer,[copy.buffer]);
});
