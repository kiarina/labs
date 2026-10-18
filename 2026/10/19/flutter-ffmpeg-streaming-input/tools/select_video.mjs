import path from 'node:path';
const tabs=await(await fetch('http://127.0.0.1:9797/json')).json();const ws=new WebSocket(tabs.find(t=>t.type==='page').webSocketDebuggerUrl);await new Promise(r=>ws.onopen=r);let n=0;const p=new Map();ws.onmessage=e=>{const r=JSON.parse(e.data);if(r.id){p.get(r.id)(r);p.delete(r.id);}};
const call=(method,params={})=>new Promise(resolve=>{const id=++n;p.set(id,resolve);ws.send(JSON.stringify({id,method,params}));});
const {result:{root}}=await call('DOM.getDocument');const {result:{nodeId}}=await call('DOM.querySelector',{nodeId:root.nodeId,selector:'#video-source'});
console.log(await call('DOM.setFileInputFiles',{nodeId,files:[path.resolve('app/assets/long.mp4')]}));ws.close();
