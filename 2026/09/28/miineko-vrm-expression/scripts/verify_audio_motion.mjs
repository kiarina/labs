import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
import puppeteer from 'puppeteer-core';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const out=path.join(root,'artifacts/audio-motion');await fs.mkdir(out,{recursive:true});
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
const report={date:new Date().toISOString().slice(0,10),scope:'known synthesized vowel cues; media-clock alignment, not physical AV latency or phoneme inference',modelSha256:expected,errors:[],layouts:[]};
try{
 browser=await puppeteer.launch({executablePath:process.env.CHROME_BIN||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--hide-scrollbars','--mute-audio']});
 report.chrome=await browser.version();
 const page=await browser.newPage();await page.setViewport({width:1280,height:900,deviceScaleFactor:1});
 page.on('pageerror',e=>report.errors.push(String(e)));
 const url=`http://127.0.0.1:${server.address().port}/viewer.html?model=mouth-aa-aligned&motion=1&audio=1`;
 await page.goto(url);await page.waitForFunction(()=>window.probe?.audioReady||window.probe?.audioError);
 assert.equal(await page.evaluate(()=>probe.audioError),undefined);
 await page.select('#mouth-sequence','audio');
 const state=()=>page.evaluate(()=>({time:probe.audioPlayback.media.currentTime,playing:probe.audioPlayback.playing,weights:Object.fromEntries(['aa','ih','ou','ee','oh'].map(v=>[v,probe.vrm.expressionManager.getValue(v)]))}));
 const input=(id,value)=>page.evaluate(({id,value})=>{const el=document.querySelector(id);el.value=value;el.dispatchEvent(new Event('input',{bubbles:true}));},{id,value});
 const seek=async seconds=>{await input('#mouth-progress',seconds*1000);await page.waitForFunction(()=>!probe.audioPlayback.media.seeking);};
 const closed=s=>Object.values(s.weights).every(v=>v===0);
 const manifest=JSON.parse(await fs.readFile(path.join(root,'artifacts/vowel-audio/manifest.json'),'utf8'));
 report.source={tool:manifest.source.tool,voice:manifest.source.voice,rate:manifest.source.rate,osVersion:manifest.source.osVersion};
 report.audioSha256=manifest.audioSha256;report.duration=manifest.duration;
 const repeat=JSON.parse(await fs.readFile(path.join(root,'artifacts/vowel-audio-repeat/manifest.json'),'utf8'));
 report.repeatAudioIdentical=manifest.audioSha256===repeat.audioSha256;
 report.repeatManifestIdentical=JSON.stringify(manifest)===JSON.stringify(repeat);
 report.cueChecks=[];
 for(const cue of manifest.cues){
  const e=manifest.envelope;
  const candidates=e.values.map((v,i)=>({v,t:e.origin+i*e.step})).filter(p=>p.t>=cue.start&&p.t<cue.end).sort((a,b)=>b.v-a.v);
  await seek(candidates[0].t);const s=await state();assert.ok(s.weights[cue.vowel]>.35);
  assert.ok(Object.entries(s.weights).every(([v,x])=>v===cue.vowel||x===0));
  report.cueChecks.push({vowel:cue.vowel,...s});
  await page.screenshot({path:path.join(out,`${cue.vowel}-front.png`)});
  await page.select('#angle','90');await page.screenshot({path:path.join(out,`${cue.vowel}-side.png`)});await page.select('#angle','0');
 }
 await seek(.8);assert.ok(closed(await state()));report.silenceCloses=true;
 await page.click('#mouth-stop');await input('#relaxed',.35);await page.click('#natural');await page.click('#mouth-play');
 report.live=await page.evaluate(async()=>{
  const {sampleAudioMouth}=await import('./scripts/audio_mouth.mjs');
  const player=probe.audioPlayback,start=performance.now();let frames=0,maxError=0,maxSum=0,blinkOverlap=false;const visited=new Set();
  while(!player.media.ended&&performance.now()-start<8000){
   await new Promise(requestAnimationFrame);const expected=sampleAudioMouth(player.manifest,player.media.currentTime,player.amount);
   const actual=Object.fromEntries(['aa','ih','ou','ee','oh'].map(v=>[v,probe.vrm.expressionManager.getValue(v)]));
   for(const v of Object.keys(actual)){maxError=Math.max(maxError,Math.abs(actual[v]-expected[v]));if(actual[v]>.1)visited.add(v);}
   const sum=Object.values(actual).reduce((a,b)=>a+b,0);maxSum=Math.max(maxSum,sum);frames++;
   if(probe.vrm.expressionManager.getValue('blink')>.3&&sum>.03)blinkOverlap=true;
  }
  return {frames,maxError,maxSum,blinkOverlap,visited:[...visited],ended:player.media.ended};
 });
 assert.ok(report.live.ended&&report.live.frames>30&&report.live.maxError<.08&&report.live.maxSum<=.8+1e-6);
 assert.deepEqual(report.live.visited,['aa','ih','ou','ee','oh']);assert.ok(report.live.blinkOverlap);assert.ok(closed(await state()));
 await page.click('#natural');await input('#weight',0);
 await seek(.4);await page.click('#mouth-play');await page.waitForFunction(()=>probe.audioPlayback.media.currentTime>.45);await page.click('#mouth-play');
 const paused=await state();await new Promise(r=>setTimeout(r,180));assert.deepEqual(await state(),paused);report.pauseFreezes=true;
 await page.select('#mouth-speed','1.5');await page.click('#mouth-play');await page.waitForFunction(t=>probe.audioPlayback.media.currentTime>t+.08,{},paused.time);await page.click('#mouth-play');
 assert.equal(await page.evaluate(()=>probe.audioPlayback.media.playbackRate),1.5);report.resumeAndRate=true;
 await seek(1.1);assert.ok((await state()).weights.ih>.05);report.seekUsesMediaTime=true;
 await page.click('#mouth-play');await input('#mouth',.45);await new Promise(r=>setTimeout(r,100));
 const manual=await state();assert.equal(manual.playing,false);assert.ok(Math.abs(Object.values(manual.weights).reduce((a,b)=>a+b,0)-.45)<1e-6);report.manualTakeover=true;
 await page.click('#mouth-stop');assert.equal((await state()).time,0);assert.ok(closed(await state()));report.stopCloses=true;
 await page.click('#mouth-play');await page.select('#mouth-sequence','conversation');assert.equal((await state()).playing,false);report.modeSwitchStopsAudio=true;
 await page.select('#mouth-sequence','audio');await seek(report.cueChecks[0].time);await page.click('#lids');assert.equal(await page.evaluate(()=>probe.reference.scene.visible&&!probe.vrm.scene.visible),true);await page.click('#lids');
 for(const [width,height] of [[1280,900],[600,900],[390,900]]){
  await page.setViewport({width,height,deviceScaleFactor:1});await page.waitForFunction(()=>document.querySelector('canvas').height===document.querySelector('canvas').clientHeight);
  const layout=await page.evaluate(()=>({width:innerWidth,scrollWidth:document.documentElement.scrollWidth,canvasHeight:document.querySelector('canvas').clientHeight}));
  assert.ok(layout.scrollWidth<=width&&layout.canvasHeight>120);report.layouts.push(layout);await page.screenshot({path:path.join(out,`controls-${width}.png`)});
 }
 // A wrong file/cue pairing fails closed; the silent viewer remains usable.
 await page.setRequestInterception(true);page.on('request',req=>{
  if(new URL(req.url()).pathname.endsWith('/manifest.json'))req.respond({status:200,contentType:'application/json',body:JSON.stringify({...manifest,audioSha256:'0'.repeat(64)})});else req.continue();
 });
 await page.reload({waitUntil:'load'});await page.waitForFunction(()=>window.probe?.audioError||window.probe?.audioReady).catch(async error=>{console.log(await page.evaluate(()=>({ready:window.ready,status:document.querySelector('#status')?.textContent,audio:document.querySelector('#audio-status')?.textContent})),report.errors);throw error;});assert.match(await page.evaluate(()=>probe.audioError),/fingerprints/);
 assert.equal(await page.$('option[value="audio"]'),null);assert.equal(await page.evaluate(()=>window.ready),true);report.mismatchRejected=true;
 assert.equal(await sha(),expected);assert.deepEqual(report.errors,[]);
 await fs.writeFile(path.join(out,'report.json'),JSON.stringify(report,null,2)+'\n');
 await fs.writeFile(path.join(root,'results/audio-motion-evaluation.json'),JSON.stringify(report,null,2)+'\n');
 console.log(JSON.stringify(report));
}finally{
 if(browser){let timer;try{await Promise.race([browser.close(),new Promise(r=>{timer=setTimeout(r,5000);})]);}finally{clearTimeout(timer);browser.disconnect();const child=browser.process();if(child?.exitCode===null)child.kill('SIGTERM');}}
 server.closeAllConnections();await new Promise(resolve=>server.close(resolve));
}
process.exit(0);
