importScripts('decoder.js');
onmessage=async(e)=>{
 try{
 const m=await createMediaDecoder({print:()=>{},printErr:s=>console.log(s)});
 m.FS.writeFile('/input.mp4',new Uint8Array(e.data));
 postMessage({stage:'decoding'});
 const start=performance.now();const code=m.ccall('decode_file','number',[],[]);
 if(code<0)throw Error('decoder error '+code);
 const pcm=m.FS.readFile('/audio.pcm');const frames=m.FS.readFile('/frames.jsonl',{encoding:'utf8'}).trim().split('\n').filter(Boolean).map(JSON.parse);
 for(const f of frames){const b=m.FS.readFile(f.file);if(b[0]!==255||b[1]!==216)throw Error('invalid JPEG');f.jpeg=b;}
 postMessage({pcm:pcm.buffer,frames,decode_ms:performance.now()-start,license:m.ccall('decoder_license','string',[],[]),config:m.ccall('decoder_config','string',[],[])},[pcm.buffer]);
 }catch(e){postMessage({error:String(e)});}
};
