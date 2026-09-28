import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
import puppeteer from 'puppeteer-core';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const out=path.join(root,'artifacts/straight-sad-review');await fs.mkdir(out,{recursive:true});
const model=path.join(root,'artifacts/eye-emotions/continuous-blink.vrm');
const sha=()=>fs.readFile(model).then(b=>createHash('sha256').update(b).digest('hex'));
const expected=JSON.parse(await fs.readFile(path.join(root,'artifacts/eye-emotions/report.json'),'utf8')).outputSha256;
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
let browser;try{
 browser=await puppeteer.launch({executablePath:process.env.CHROME_BIN||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--hide-scrollbars']});const page=await browser.newPage(),errors=[];page.on('pageerror',e=>errors.push(String(e)));await page.setViewport({width:1100,height:1100});
 await page.goto(`http://127.0.0.1:${server.address().port}/expression-study.html?variant=straight-sad&opening=0`);await page.waitForFunction(()=>window.ready);const canvas=await page.$('canvas'),angles=['0','45','90','-45','-90'];
 for(const name of ['happy','angry','sad','relaxed']){await page.click('#pose-'+name);const weights=await page.evaluate(()=>['happy','angry','sad','relaxed','blink'].map(n=>study.current.expressionManager.getValue(n)));assert.deepEqual(weights,['happy','angry','sad','relaxed','blink'].map(n=>n===name?1:0));}await page.click('#neutral');
 const pixels=()=>page.evaluate(()=>{const g=study.renderer.getContext(),a=new Uint8Array(g.drawingBufferWidth*g.drawingBufferHeight*4);g.readPixels(0,0,g.drawingBufferWidth,g.drawingBufferHeight,g.RGBA,g.UNSIGNED_BYTE,a);return crypto.subtle.digest('SHA-256',a).then(b=>Array.from(new Uint8Array(b),v=>v.toString(16).padStart(2,'0')).join(''));});
 const preserved=[];const poses=[{},{happy:.13},{happy:.5},{happy:1},{angry:.5},{angry:1},{blink:1},{happy:.6,angry:.3,blink:.4}];
 for(const pose of poses){await page.select('#variant','straight-sad');await page.waitForFunction(()=>window.ready);await page.evaluate(pose=>{study.setEyes(pose);study.setOpening(.75);},pose);const frames=[];for(const angle of angles){await page.select('#angle',angle);frames.push(await pixels());}await page.select('#variant','emotions');await page.waitForFunction(()=>window.ready);for(const [i,angle] of angles.entries()){await page.select('#angle',angle);assert.equal(await pixels(),frames[i]);preserved.push({pose,angle});}}
 const remapped=[];for(const strength of [.25,.5,.75,1]){await page.select('#variant','straight-sad');await page.waitForFunction(()=>window.ready);await page.evaluate(w=>{study.setEyes({relaxed:w});study.setOpening(0);},strength);const frames=[];for(const angle of angles){await page.select('#angle',angle);frames.push(await pixels());}await page.select('#variant','emotions');await page.waitForFunction(()=>window.ready);await page.evaluate(w=>study.setEyes({sad:w}),strength);for(const [i,angle] of angles.entries()){await page.select('#angle',angle);assert.equal(await pixels(),frames[i]);remapped.push({strength,angle});}}
 for(const vowel of ['aa','ih','ou','ee','oh']){await page.select('#variant','straight-sad');await page.waitForFunction(()=>window.ready);await page.select('#vowel',vowel);await page.select('#angle','0');await page.evaluate(()=>{study.setEyes({happy:1});study.setOpening(1);});const frame=await pixels();await page.select('#variant','emotions');await page.waitForFunction(()=>window.ready);assert.equal(await pixels(),frame);preserved.push({vowel,happy:1,opening:1,angle:'0'});}
 await page.select('#variant','straight-sad');await page.waitForFunction(()=>window.ready);await page.select('#vowel','aa');const states=[];
 for(const emotion of ['relaxed','sad'])for(const strength of [0,.13,.25,.5,.75,1])for(const mouth of [0,.7])for(const angle of angles){await page.evaluate(({emotion,strength,mouth})=>{study.setEyes({[emotion]:strength});study.setOpening(mouth);},{emotion,strength,mouth});await page.select('#angle',angle);await canvas.screenshot({path:path.join(out,`${emotion}-${strength}-${mouth}-${angle}.png`)});states.push({emotion,strength,mouth,angle});}
 const mixtures=[];await page.select('#angle','0');await page.evaluate(()=>study.setOpening(.6));
 for(const happy of [0,.5,1])for(const angry of [0,.5,1])for(const sad of [0,.5,1])for(const blink of [0,.5,1]){
  const result=await page.evaluate(values=>{study.setEyes({...values,relaxed:.3});const weights=['happy','angry','sad','relaxed','blink'].map(n=>study.current.expressionManager.getValue(n));const textures=[];study.current.scene.traverse(o=>{for(const m of [o.material].flat().filter(Boolean))if(m.name.startsWith('Surface Lid')&&m.map)textures.push([...m.map.repeat.toArray(),...m.map.offset.toArray()]);});return {weights,textures,mouth:study.current.expressionManager.getValue('aa')};},{happy,angry,sad,blink});
  assert.ok(result.weights.every(w=>Number.isFinite(w)&&w>=0)&&result.weights.reduce((a,b)=>a+b,0)<=1.000001);assert.ok(result.textures.flat().every(Number.isFinite));assert.ok(result.textures.every(t=>t[0]>0&&t[1]>0));assert.ok(Math.abs(result.mouth-Math.pow(.6,.6))<1e-7);mixtures.push({happy,angry,sad,blink,weights:result.weights});
 }
 await page.click('#eyesPlay');const animation=await page.evaluate(async()=>{let frames=0;const maxima={happy:0,angry:0,relaxed:0,sad:0},start=performance.now();while(performance.now()-start<11200){await new Promise(requestAnimationFrame);for(const n of Object.keys(maxima))maxima[n]=Math.max(maxima[n],study.current.expressionManager.getValue(n));frames++;}return {frames,maxima};});assert.ok(animation.frames>30&&Object.values(animation.maxima).every(v=>v>.95));
 await page.click('#neutral');assert.deepEqual(await page.evaluate(()=>['happy','angry','sad','relaxed','blink','aa','ih','ou','ee','oh'].map(n=>study.current.expressionManager.getValue(n))),Array(10).fill(0));const neutral=await pixels();await page.select('#variant','emotions');await page.waitForFunction(()=>window.ready);assert.equal(await pixels(),neutral);
 await page.select('#variant','straight-sad');await page.waitForFunction(()=>window.ready);await page.evaluate(()=>study.setEyes({sad:1}));const layouts=[];for(const width of [1280,600,390]){await page.setViewport({width,height:1000});await page.waitForFunction(()=>document.querySelector('canvas').height===document.querySelector('canvas').clientHeight);const layout=await page.evaluate(()=>({width:innerWidth,scrollWidth:document.documentElement.scrollWidth,canvasHeight:document.querySelector('canvas').clientHeight}));assert.ok(layout.scrollWidth<=width&&layout.canvasHeight>200);layouts.push(layout);await page.screenshot({path:path.join(out,`controls-${width}.png`)});}
 assert.equal(await sha(),expected);assert.deepEqual(errors,[]);const report={date:new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Tokyo'}).format(new Date()),scope:'curved sad reassigned to relaxed; straighter sad candidate; accepted smile/anger and mouth preserved',framebufferComparison:'SHA-256 of RGBA readback',preserved,remapped,states,mixtures,animation,layouts,errors,sourceSha256:expected};await fs.writeFile(path.join(root,'results/straight-sad-evaluation.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({preserved:preserved.length,remapped:remapped.length,states:states.length,mixtures:mixtures.length,animation,layouts,errors}));
}finally{if(browser)await browser.close();server.closeAllConnections();await new Promise(r=>server.close(r));}process.exit(0);
