importScripts('decoder.js');
let ack;
onmessage=async(e)=>{
 if(e.data.ack){ack?.();return;}
 if(!e.data.file)return;
 let m;
 try{
  const started=performance.now();m=await createMediaDecoder({print:()=>{},printErr:()=>{}});
  m.FS.mkdir('/input');m.FS.mount(m.WORKERFS,{files:[e.data.file]},'/input');
  const code=m.ccall('open_decoder','number',['string','number'],['/input/'+e.data.file.name,e.data.seconds]);if(code<0)throw Error('open: '+code);
  let count=0,maxPayload=0,firstRead=null;self.stats={events:0,audio_s:0};
  for(;;){
   const kind=m.ccall('next_event','number',[],[]);if(kind===0)break;if(kind<0)throw Error('decode: '+kind);
   const ptr=m.ccall('event_ptr','number',[],[]),size=m.ccall('event_size','number',[],[]),pts=m.ccall('event_pts','number',[],[]);
   firstRead??=m.ccall('input_bytes_read','number',[],[]);self.stats.events=count;self.stats.audio_s=pts;
   const data=m.HEAPU8.slice(ptr,ptr+size);count++;maxPayload=Math.max(maxPayload,size);
   await new Promise(resolve=>{ack=resolve;postMessage({kind,pts,data:data.buffer},[data.buffer]);});ack=null;
  }
  postMessage({done:true,events:count,first_output_read_bytes:firstRead,total_input_read_bytes:m.ccall('input_bytes_read','number',[],[]),max_payload_bytes:maxPayload,wasm_heap_bytes:m.HEAPU8.byteLength,input_bytes:e.data.file.size,elapsed_ms:performance.now()-started,license:m.ccall('decoder_license','string',[],[])});
 }catch(e){postMessage({error:String(e)});}finally{if(m)m.ccall('close_decoder',null,[],[]);}
};
