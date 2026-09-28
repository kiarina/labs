import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
import puppeteer from 'puppeteer-core';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const out=path.join(root,'artifacts/happy-arc/viewer');await fs.mkdir(out,{recursive:true});
const model=path.join(root,'artifacts/mouth-aa-aligned/continuous-blink.vrm');
const sha=()=>fs.readFile(model).then(b=>createHash('sha256').update(b).digest('hex'));
const expected='cc8ca99d04f671b3df7a0489bdb17cabb6847e00dbf01ca94d72bc2ff5681e31';
assert.equal(await sha(),expected);
const server=http.createServer(async(req,res)=>{
 try{
  const pathname=decodeURIComponent(new URL(req.url,'http://localhost').pathname);
  if(pathname==='/favicon.ico'){res.writeHead(204);res.end();return;}
  const file=path.resolve(root,'.'+pathname);if(!file.startsWith(root+path.sep))throw Error('outside root');
  res.setHeader('Content-Type',({'.html':'text/html','.js':'text/javascript','.mjs':'text/javascript','.wav':'audio/wav','.json':'application/json','.png':'image/png','.vrm':'model/gltf-binary'})[path.extname(file)]||'application/octet-stream');
  res.end(await fs.readFile(file));
 }catch{res.writeHead(404);res.end();}
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
let browser;
const report={date:new Date().toISOString().slice(0,10),sourceSha256:expected,errors:[],zeroComparisons:[],compositionStates:0};
try{
 browser=await puppeteer.launch({executablePath:process.env.CHROME_BIN||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--hide-scrollbars','--mute-audio']});
 report.chrome=await browser.version();
 const page=await browser.newPage();page.on('pageerror',e=>report.errors.push(String(e)));await page.setViewport({width:900,height:1000,deviceScaleFactor:1});
 await page.goto(`http://127.0.0.1:${server.address().port}/viewer.html?model=happy-arc&motion=1&audio=greeting`);await page.waitForFunction(()=>window.probe?.audioReady||window.probe?.audioError);
 for(const h of [0,.35,.65,1])for(const a of [0,45,90,-90]){
  await page.evaluate(({h,a})=>probe.set({h,a,w:0,r:0,m:0}),{h,a});await page.screenshot({path:path.join(out,`happy-${h}-${a}.png`)});
 }
 const configurations=[{a:0,w:0,r:0,h:0,m:0},{a:90,w:0,r:0,h:0,m:0}];
 for(const a of [0,45,-90])for(const w of [0,.5,1])configurations.push({a,w,r:.35,h:0,m:0});
 for(const a of [0,90,-90])for(const v of ['aa','ih','ou','ee','oh'])configurations.push({a,w:0,r:0,h:0,v,m:.6});
 const hashes=async()=>{
  const result=[];
  for(const state of configurations){
   await page.evaluate(state=>probe.set(state),state);
   result.push(await page.evaluate(async()=>{const gl=probe.renderer.getContext(),p=new Uint8Array(gl.drawingBufferWidth*gl.drawingBufferHeight*4);gl.readPixels(0,0,gl.drawingBufferWidth,gl.drawingBufferHeight,gl.RGBA,gl.UNSIGNED_BYTE,p);return {width:gl.drawingBufferWidth,height:gl.drawingBufferHeight,hash:Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',p)),x=>x.toString(16).padStart(2,'0')).join('')};}));
  }
  return result;
 };
 const candidate=await hashes();
 await page.goto(`http://127.0.0.1:${server.address().port}/viewer.html?model=mouth-aa-aligned&motion=1&audio=greeting`);await page.waitForFunction(()=>window.probe?.audioReady);
 await page.evaluate(()=>{document.querySelector('#happy-control').hidden=false;});
 await page.waitForFunction(()=>document.querySelector('canvas').height===document.querySelector('canvas').clientHeight);
 const original=await hashes();
 report.zeroComparisons=configurations.map((state,i)=>({state,identical:JSON.stringify(candidate[i])===JSON.stringify(original[i])}));
 assert.ok(report.zeroComparisons.every(x=>x.identical),'Happy zero changed the accepted face');
 await page.goto(`http://127.0.0.1:${server.address().port}/viewer.html?model=happy-arc&motion=1&audio=greeting`);await page.waitForFunction(()=>window.probe?.audioReady);
 const closedOffsets=await page.evaluate(()=>{probe.set({h:0,r:0,w:1,m:0});return probe.lids.map(o=>o.material.map.offset.y);});
 for(const h of [0,.35,.65,1])for(const r of [0,.5,1])for(const w of [0,.5,1]){
  const actual=await page.evaluate(({h,r,w})=>{
   probe.set({h,r,w,m:.5});
   const e=probe.vrm.expressionManager;
   return {h:e.getValue('happy'),r:e.getValue('relaxed'),mouth:e.getValue('aa'),lids:probe.lids.map(o=>({morphs:o.morphTargetInfluences,offset:o.material.map.offset.y}))};
  },{h,r,w});
  const closure=h+(1-h)*r+(1-h)*(1-r)*w;
  assert.ok(actual.lids.every((l,i)=>Math.abs(l.offset-closedOffsets[i]*closure)<1e-6));
  if(h===.65&&r===.5&&w===1)await page.screenshot({path:path.join(out,'happy-relaxed-blink.png')});
  assert.ok(actual.h+actual.r<=1+1e-7);assert.equal(actual.mouth,.5);
  assert.ok(actual.lids.every(l=>l.morphs.every(x=>Number.isFinite(x)&&x>=0&&x<=1+1e-7)&&Number.isFinite(l.offset)));
  report.compositionStates++;
 }
 await page.evaluate(()=>probe.set({h:.65,r:.35,w:0,m:0}));await page.click('#natural');await page.click('#mouth-play');
 report.speech=await page.evaluate(async()=>{
  let frames=0,maxMouth=0,overlap=false;const start=performance.now(),p=probe.audioPlayback;
  while(!p.media.ended&&performance.now()-start<7000){await new Promise(requestAnimationFrame);const e=probe.vrm.expressionManager;const m=['aa','ih','ou','ee','oh'].reduce((a,v)=>a+e.getValue(v),0);maxMouth=Math.max(maxMouth,m);if(m>.05&&e.getValue('blink')>.3&&e.getValue('happy')===.65)overlap=true;frames++;}
  return {frames,maxMouth,overlap,ended:p.media.ended};
 });
 assert.ok(report.speech.ended&&report.speech.overlap&&report.speech.maxMouth<=.8+1e-6);
 await page.click('#natural');await page.click('#mouth-stop');await page.evaluate(()=>probe.set({h:1,r:0,w:0,m:.65,v:'aa',a:0}));
 await page.screenshot({path:path.join(out,'happy-speaking.png')});
 report.layouts=[];
 for(const [width,height] of [[1280,900],[600,900],[390,900]]){
  await page.setViewport({width,height,deviceScaleFactor:1});await page.waitForFunction(()=>document.querySelector('canvas').height===document.querySelector('canvas').clientHeight);
  const layout=await page.evaluate(()=>({width:innerWidth,scrollWidth:document.documentElement.scrollWidth,canvasHeight:document.querySelector('canvas').clientHeight}));assert.ok(layout.scrollWidth<=width&&layout.canvasHeight>120);report.layouts.push(layout);
  await page.screenshot({path:path.join(out,`controls-${width}.png`)});
 }
 const candidateBytes=await fs.readFile(path.join(root,'artifacts/happy-arc/continuous-blink.vrm'));
 assert.deepEqual(candidateBytes,await fs.readFile(path.join(root,'artifacts/happy-arc-repeat/continuous-blink.vrm')));report.repeatByteIdentical=true;
 report.outputSha256=createHash('sha256').update(candidateBytes).digest('hex');assert.equal(await sha(),expected);assert.deepEqual(report.errors,[]);
 await fs.writeFile(path.join(root,'results/happy-evaluation.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report));

}finally{
 if(browser){await browser.close();browser.disconnect();}
 server.closeAllConnections();await new Promise(resolve=>server.close(resolve));
}
process.exit(0);
