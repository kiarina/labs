import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
import puppeteer from 'puppeteer-core';
import {VOWELS,clipDuration} from './mouth_motion.mjs';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const out=path.join(root,'artifacts/mouth-motion');await fs.mkdir(out,{recursive:true});
const model=path.join(root,'artifacts/mouth-aa-aligned/continuous-blink.vrm');
const sha=()=>fs.readFile(model).then(b=>createHash('sha256').update(b).digest('hex'));
const expected='cc8ca99d04f671b3df7a0489bdb17cabb6847e00dbf01ca94d72bc2ff5681e31';
assert.equal(await sha(),expected);
const server=http.createServer(async(req,res)=>{
 try{
  const pathname=decodeURIComponent(new URL(req.url,'http://localhost').pathname);
  if(pathname==='/favicon.ico'){res.writeHead(204);res.end();return;}
  const file=path.resolve(root,'.'+pathname);if(!file.startsWith(root+path.sep))throw Error('outside root');
  res.setHeader('Content-Type',({'.html':'text/html','.js':'text/javascript','.mjs':'text/javascript','.png':'image/png','.vrm':'model/gltf-binary'})[path.extname(file)]||'application/octet-stream');
  res.end(await fs.readFile(file));
 }catch{res.writeHead(404);res.end();}
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
let browser;
const report={scope:'silent keyframed motion, not audio synchronization',modelSha256:expected,errors:[],warnings:[],samples:[],layouts:[]};
try{
 browser=await puppeteer.launch({executablePath:process.env.CHROME_BIN||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--hide-scrollbars']});
 const page=await browser.newPage();await page.setViewport({width:900,height:1000,deviceScaleFactor:1});
 page.on('pageerror',e=>report.errors.push(String(e)));page.on('console',m=>{if(['error','warn'].includes(m.type()))report.warnings.push(m.text());});
 await page.goto(`http://127.0.0.1:${server.address().port}/viewer.html?model=mouth-aa-aligned&motion=1`);
 await page.waitForFunction(()=>window.ready);
 const weights=()=>page.evaluate(()=>Object.fromEntries(['aa','ih','ou','ee','oh'].map(v=>[v,probe.vrm.expressionManager.getValue(v)])));
 const pixels=()=>page.evaluate(()=>{const gl=probe.renderer.getContext(),p=new Uint8Array(gl.drawingBufferWidth*gl.drawingBufferHeight*4);gl.readPixels(0,0,gl.drawingBufferWidth,gl.drawingBufferHeight,gl.RGBA,gl.UNSIGNED_BYTE,p);return Array.from(p);});
 const seek=ms=>page.evaluate(ms=>{const input=document.querySelector('#mouth-progress');input.value=ms;input.dispatchEvent(new Event('input',{bubbles:true}));},ms);
 await page.waitForFunction(()=>document.querySelector('canvas').height===document.querySelector('canvas').clientHeight);
 const neutral=await pixels();
 for(const mode of ['vowels','conversation']){
  await page.select('#mouth-sequence',mode);
  for(let t=0;t<=clipDuration(mode);t+=80){
   await seek(t);const w=await weights();const total=Object.values(w).reduce((a,b)=>a+b,0);
   assert.ok(total<=.8+1e-6);assert.ok(Object.values(w).every(v=>Number.isFinite(v)&&v>=0));
   report.samples.push({mode,t,weights:w});
  }
  await seek(clipDuration(mode));assert.ok(Object.values(await weights()).every(v=>v===0));
 }
 await seek(240);const crossfade=await weights();
 assert.ok(Math.abs(crossfade.aa-.26)<1e-6&&Math.abs(crossfade.ih-.2)<1e-6);
 report.knownCrossfade=crossfade;
 await page.screenshot({path:path.join(out,'crossfade-front.png')});
 await page.select('#angle','45');assert.deepEqual(await weights(),crossfade);
 await page.click('#lids');await page.select('#angle','-45');
 assert.equal(await page.evaluate(()=>probe.reference.scene.visible&&!probe.vrm.scene.visible),true);
 await page.click('#lids');await page.select('#angle','0');
 // Both clocks run in the same render loop, while the export supplies the binds.
 await seek(240);await page.click('#mouth-play');await page.click('#natural');
 report.livePlayback=await page.evaluate(async()=>{
  let maxBlink=0,maxSum=0,overlap=false;const start=performance.now();
  while(performance.now()-start<1500){
   await new Promise(requestAnimationFrame);
   const b=probe.vrm.expressionManager.getValue('blink');
   const m=['aa','ih','ou','ee','oh'].reduce((s,v)=>s+probe.vrm.expressionManager.getValue(v),0);
   maxBlink=Math.max(maxBlink,b);maxSum=Math.max(maxSum,m);if(b>.5&&m>.03)overlap=true;
  }
  return {maxBlink,maxSum,overlap};
 });
 assert.ok(report.livePlayback.maxBlink>.95&&report.livePlayback.maxSum<=.8+1e-6&&report.livePlayback.overlap);
 await page.click('#mouth-play');const paused=await weights();
 await new Promise(resolve=>setTimeout(resolve,150));assert.deepEqual(await weights(),paused);
 await page.click('#natural');await page.click('#mouth-stop');
 await page.evaluate(()=>probe.set({w:0,r:0,a:0}));
 assert.ok(Object.values(await weights()).every(v=>v===0));
 const closed=await pixels();assert.deepEqual(closed,neutral);report.stopRestoresNeutralExactly=true;
 await page.click('#mouth-play');
 await page.evaluate(()=>{const input=document.querySelector('#mouth');input.value='.45';input.dispatchEvent(new Event('input',{bubbles:true}));});
 assert.equal(await page.evaluate(()=>probe.mouthPlayback.playing),false);
 await page.select('#vowel','ih');assert.ok(Math.abs((await weights()).ih-.45)<1e-6);
 await page.click('#mouth-stop');await page.select('#mouth-sequence','conversation');await seek(240);
 // Frozen mixes coexist with relaxation and a half blink without reselecting a vowel.
 await page.evaluate(()=>probe.set({r:.35,w:.5}));assert.deepEqual(await weights(),crossfade);
 for(const [width,height] of [[1280,900],[600,900],[390,900]]){
  await page.setViewport({width,height,deviceScaleFactor:1});
  await page.waitForFunction(()=>document.querySelector('canvas').height===document.querySelector('canvas').clientHeight);
  const layout=await page.evaluate(()=>({width:innerWidth,scrollWidth:document.documentElement.scrollWidth,canvasHeight:document.querySelector('canvas').clientHeight}));
  assert.ok(layout.scrollWidth<=width&&layout.canvasHeight>120);report.layouts.push(layout);
  await page.screenshot({path:path.join(out,`controls-${width}.png`)});
 }
 assert.equal(await sha(),expected);assert.deepEqual(report.errors,[]);
 await fs.writeFile(path.join(out,'report.json'),JSON.stringify(report,null,2)+'\n');
 console.log(JSON.stringify({samples:report.samples.length,live:report.livePlayback,neutral:report.stopRestoresNeutralExactly,layouts:report.layouts,errors:report.errors}));
}finally{
 if(browser){let timer;try{await Promise.race([browser.close(),new Promise(r=>{timer=setTimeout(r,5000);})]);}finally{clearTimeout(timer);browser.disconnect();const child=browser.process();if(child?.exitCode===null)child.kill('SIGTERM');}}
 server.closeAllConnections();await new Promise(resolve=>server.close(resolve));
}
process.exit(0);
