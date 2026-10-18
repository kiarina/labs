// A small CDP runner using Node's built-in WebSocket (no browser dependency).
const tabs=await (await fetch('http://127.0.0.1:9797/json')).json();
const tab=tabs.find(t=>t.type==='page');
const ws=new WebSocket(tab.webSocketDebuggerUrl);await new Promise(r=>ws.onopen=r);
let id=0;const pending=new Map();ws.onmessage=e=>{const m=JSON.parse(e.data);if(m.id){pending.get(m.id)?.(m);pending.delete(m.id);}};
const call=(method,params={})=>new Promise(resolve=>{const n=++id;pending.set(n,resolve);ws.send(JSON.stringify({id:n,method,params}));});
const expression=process.argv[2]||'localStorage.getItem("stream-report")';
const r=await call('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});console.log(JSON.stringify(r.result));ws.close();
