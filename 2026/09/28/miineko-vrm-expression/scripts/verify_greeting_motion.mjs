import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
import puppeteer from 'puppeteer-core';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const out=path.join(root,'artifacts/greeting-motion');await fs.mkdir(out,{recursive:true});
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
const report={date:new Date().toISOString().slice(0,10),scope:'continuous sentence with authored approximate timing; not phoneme inference',modelSha256:expected,errors:[],layouts:[]};
try{
 browser=await puppeteer.launch({executablePath:process.env.CHROME_BIN||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--hide-scrollbars','--mute-audio']});
 report.chrome=await browser.version();
 const page=await browser.newPage();await page.setViewport({width:1280,height:900,deviceScaleFactor:1});
 page.on('pageerror',e=>report.errors.push(String(e)));
 await page.goto(`http://127.0.0.1:${server.address().port}/viewer.html?model=mouth-aa-aligned&motion=1&audio=greeting`);
 await page.waitForFunction(()=>window.probe?.audioReady||window.probe?.audioError);assert.equal(await page.evaluate(()=>probe.audioError),undefined);
 const manifest=JSON.parse(await fs.readFile(path.join(root,'artifacts/speech-greeting/manifest.json'),'utf8'));
 const repeat=JSON.parse(await fs.readFile(path.join(root,'artifacts/speech-greeting-repeat/manifest.json'),'utf8'));
 assert.deepEqual(manifest,repeat);report.repeatedManifestIdentical=true;report.audioSha256=manifest.audioSha256;report.duration=manifest.duration;report.source=manifest.source;
 const weights=()=>page.evaluate(()=>Object.fromEntries(['aa','ih','ou','ee','oh'].map(v=>[v,probe.vrm.expressionManager.getValue(v)])));
 const input=(id,value)=>page.evaluate(({id,value})=>{const el=document.querySelector(id);el.value=value;el.dispatchEvent(new Event('input',{bubbles:true}));},{id,value});
 const seek=async t=>{await input('#mouth-progress',t*1000);await page.waitForFunction(()=>!probe.audioPlayback.media.seeking);};
 const sum=w=>Object.values(w).reduce((a,b)=>a+b,0);
 report.sampledStates=0;report.maxSum=0;report.blendedStates=0;
 for(let t=0;t<manifest.duration;t+=.02){
  await seek(t);const w=await weights();assert.ok(Object.values(w).every(x=>Number.isFinite(x)&&x>=0));assert.ok(sum(w)<=.8+1e-6);
  report.maxSum=Math.max(report.maxSum,sum(w));if(Object.values(w).filter(x=>x>.01).length>1)report.blendedStates++;report.sampledStates++;
 }
 assert.ok(report.blendedStates>0);
 await seek(1.30);assert.equal(sum(await weights()),0);report.phrasePauseCloses=true;
 await seek(2.55);assert.equal(sum(await weights()),0);report.endingCloses=true;
 await seek(1.64);const blend=await weights();assert.ok(blend.ih>.1&&blend.ee>.1);report.knownBlend=blend;
 for(const angle of ['0','45','90','-90']){
  await page.select('#angle',angle);await page.screenshot({path:path.join(out,`speech-${angle}.png`)});
 }
 await page.select('#angle','0');await input('#relaxed',.35);await page.click('#natural');await page.click('#mouth-stop');await page.click('#mouth-play');
 report.live=await page.evaluate(async()=>{
  const p=probe.audioPlayback,start=performance.now();let frames=0,overlap=false,maxSum=0;const vowels=new Set();
  while(!p.media.ended&&performance.now()-start<7000){
   await new Promise(requestAnimationFrame);const w=['aa','ih','ou','ee','oh'].map(v=>[v,probe.vrm.expressionManager.getValue(v)]);const sum=w.reduce((a,[,b])=>a+b,0);
   maxSum=Math.max(maxSum,sum);if(probe.vrm.expressionManager.getValue('blink')>.2&&sum>.03)overlap=true;
   for(const [v,x] of w)if(x>.01)vowels.add(v);frames++;
  }
  return {frames,overlap,maxSum,visited:[...vowels],ended:p.media.ended};
 });
 assert.ok(report.live.ended&&report.live.frames>20&&report.live.overlap&&report.live.maxSum<=.8+1e-6);assert.equal(sum(await weights()),0);
 await page.click('#natural');await input('#weight',0);await seek(1.55);await page.click('#mouth-play');await page.click('#mouth-play');
 const paused=await page.evaluate(()=>probe.audioPlayback.media.currentTime);const frozen=await weights();await new Promise(r=>setTimeout(r,150));
 assert.equal(await page.evaluate(()=>probe.audioPlayback.media.currentTime),paused);assert.deepEqual(await weights(),frozen);report.pauseFreezes=true;
 await page.select('#mouth-speed','0.5');await page.click('#mouth-play');await page.waitForFunction(t=>probe.audioPlayback.media.currentTime>t+.07,{},paused);await page.click('#mouth-play');report.halfSpeedResume=true;
 await page.click('#mouth-stop');assert.equal(sum(await weights()),0);
 await page.select('#mouth-speed','1');await seek(1.64);
 for(const [width,height] of [[1280,900],[600,900],[390,900]]){
  await page.setViewport({width,height,deviceScaleFactor:1});await page.waitForFunction(()=>document.querySelector('canvas').height===document.querySelector('canvas').clientHeight);
  const layout=await page.evaluate(()=>({width:innerWidth,scrollWidth:document.documentElement.scrollWidth,canvasHeight:document.querySelector('canvas').clientHeight}));
  assert.ok(layout.scrollWidth<=width&&layout.canvasHeight>120);report.layouts.push(layout);await page.screenshot({path:path.join(out,`controls-${width}.png`)});
 }
 await Promise.all([page.waitForNavigation(),page.select('#audio-clip','1')]);await page.waitForFunction(()=>window.probe?.audioReady);assert.equal(await page.$eval('#audio-clip',el=>el.value),'1');report.vowelComparisonAvailable=true;
 assert.equal(await sha(),expected);assert.deepEqual(report.errors,[]);
 await fs.writeFile(path.join(out,'report.json'),JSON.stringify(report,null,2)+'\n');await fs.writeFile(path.join(root,'results/greeting-motion-evaluation.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report));
}finally{
 if(browser){let timer;try{await Promise.race([browser.close(),new Promise(r=>{timer=setTimeout(r,5000);})]);}finally{clearTimeout(timer);browser.disconnect();const child=browser.process();if(child?.exitCode===null)child.kill('SIGTERM');}}
 server.closeAllConnections();await new Promise(resolve=>server.close(resolve));
}
process.exit(0);
