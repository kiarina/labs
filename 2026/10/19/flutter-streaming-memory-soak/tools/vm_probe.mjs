import fs from 'node:fs';
const logfile=process.argv[2],output=process.argv[3],doGc=process.argv.includes('--gc');
const text=fs.readFileSync(logfile,'utf8');const match=text.match(/MEMORY_VM_SERVICE=(http[^\s]+)/);if(!match)throw Error('No VM service in log');
const url=match[1].replace('http:','ws:')+'ws';const ws=new WebSocket(url);await new Promise((r,j)=>{ws.onopen=r;ws.onerror=j;});let n=0;const p=new Map();ws.onmessage=e=>{const x=JSON.parse(e.data);if(x.id){p.get(x.id)?.(x);p.delete(x.id);}};
const call=(method,params={})=>new Promise((resolve,reject)=>{const id=String(++n);const timer=setTimeout(()=>reject(Error(method+' timeout')),10000);p.set(id,x=>{clearTimeout(timer);resolve(x);});ws.send(JSON.stringify({jsonrpc:'2.0',id,method,params}));});
const vm=await call('getVM');const isolate=vm.result.isolates.find(i=>i.name==='main')||vm.result.isolates[0];
const usage=await call('getMemoryUsage',{isolateId:isolate.id});const profile=await call('getAllocationProfile',{isolateId:isolate.id,gc:doGc});
const result={utc:new Date().toISOString(),gc_requested:doGc,usage:usage.result||usage.error,allocation_error:profile.error,top:profile.result?.members?.sort((a,b)=>(b.bytesCurrent||0)-(a.bytesCurrent||0)).slice(0,25).map(x=>({class:x.class?.name,bytes:x.bytesCurrent,instances:x.instancesCurrent})),interesting:profile.result?.members?.filter(x=>/PcmAnalysis|VoiceDetector|SileroVad|FrameAnalysis|_Context$|_Closure$|Float32|Uint8|FFmpegSession/.test(x.class?.name||'')).map(x=>({class:x.class?.name,bytes:x.bytesCurrent,instances:x.instancesCurrent})),heap:profile.result?.memoryUsage};
const klass=profile.result?.members?.find(x=>x.class?.name==='PcmAnalysis');
if(klass&&klass.instancesCurrent>0){
 const objects=await call('getInstances',{isolateId:isolate.id,objectId:klass.class.id,limit:1});result.instances_error=objects.error;const target=(objects.result?.instances||objects.result?.samples)?.[0]?.id;
 if(target){const path=await call('getRetainingPath',{isolateId:isolate.id,targetId:target,limit:32});result.retaining_path={root:path.result?.gcRootType,length:path.result?.length,elements:path.result?.elements?.map(e=>({class:e.value?.class?.name,field:typeof e.parentField==='string'?e.parentField:e.parentField?.name,name:e.value?.name,index:e.parentListIndex,map_key:e.parentMapKey?.valueAsString}))};}
}
fs.writeFileSync(output,JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify({gc:doGc,usage:result.usage,error:result.allocation_error}));ws.close();
