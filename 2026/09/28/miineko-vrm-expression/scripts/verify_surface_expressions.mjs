import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
import puppeteer from 'puppeteer-core';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const style=process.env.EXPRESSION_STYLE||'original',balanced=style==='balanced',crescent=style==='crescent',rounded=['rounded','crescent','balanced'].includes(style),candidate=balanced?'balanced':crescent?'crescent':rounded?'rounded':'expressions',modelFolder=balanced?'balanced-smile':crescent?'crescent-smile':rounded?'rounded-smile':'surface-expressions',variants=balanced?['balanced','crescent']:crescent?['crescent','rounded']:rounded?['rounded','expressions']:['expressions','source-normals'];
const out=path.join(root,balanced?'artifacts/balanced-smile-review':crescent?'artifacts/crescent-smile-review':rounded?'artifacts/rounded-smile-review':'artifacts/expression-study');await fs.mkdir(out,{recursive:true});
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
let browser;try{
 browser=await puppeteer.launch({executablePath:process.env.CHROME_BIN||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--hide-scrollbars']});const page=await browser.newPage(),errors=[];page.on('pageerror',e=>errors.push(String(e)));await page.setViewport({width:1100,height:1100});
 await page.goto(`http://127.0.0.1:${server.address().port}/expression-study.html?variant=${candidate}&opening=0`);await page.waitForFunction(()=>window.ready);
 const canvas=await page.$('canvas'),angles=['0','45','90','-45','-90'];
 if(balanced)await canvas.screenshot({path:path.join(out,'neutral-0.png')});
 const pixels=(key=null)=>page.evaluate(key=>{const gl=study.renderer.getContext(),p=new Uint8Array(gl.drawingBufferWidth*gl.drawingBufferHeight*4);gl.readPixels(0,0,gl.drawingBufferWidth,gl.drawingBufferHeight,gl.RGBA,gl.UNSIGNED_BYTE,p);if(key){window.__readbackFrames??={};window.__readbackFrames[key]=p;}return crypto.subtle.digest('SHA-256',p).then(b=>Array.from(new Uint8Array(b),v=>v.toString(16).padStart(2,'0')).join(''));},key);
 const equal=[];
 for(const variant of variants)for(const vowel of ['aa','ih','ou','ee','oh']){
  await page.select('#variant',variant);await page.waitForFunction(()=>window.ready);await page.select('#vowel',vowel);await page.evaluate(()=>{study.setEyes({});study.setOpening(.75);});const frames=[];for(const angle of angles){await page.select('#angle',angle);frames.push(await pixels('neutral-'+angle));}
  await page.select('#variant','vowels');await page.waitForFunction(()=>window.ready);for(const [i,angle] of angles.entries()){await page.select('#angle',angle);const actual=await pixels();let drift={changedPixels:0,maxChannelDifference:0};if(actual!==frames[i]&&balanced&&variant==='balanced'){drift=await page.evaluate(angle=>{const gl=study.renderer.getContext(),before=window.__readbackFrames['neutral-'+angle],after=new Uint8Array(before.length);gl.readPixels(0,0,gl.drawingBufferWidth,gl.drawingBufferHeight,gl.RGBA,gl.UNSIGNED_BYTE,after);let changedPixels=0,maxChannelDifference=0;for(let j=0;j<before.length;j+=4){let d=0;for(let k=0;k<4;k++)d=Math.max(d,Math.abs(before[j+k]-after[j+k]));if(d){changedPixels++;maxChannelDifference=Math.max(maxChannelDifference,d);}}return {changedPixels,maxChannelDifference};},angle);assert.ok(drift.changedPixels<=2&&drift.maxChannelDifference<=1,JSON.stringify({variant,vowel,angle,...drift}));}else assert.deepEqual(actual,frames[i]);equal.push({variant,vowel,angle,exact:actual===frames[i],...drift});}
 }
 const states=[];
 for(const variant of variants){
  await page.select('#variant',variant);await page.waitForFunction(()=>window.ready);
  for(const expression of ['happy','blink','relaxed'])for(const amount of (crescent?[.25,.5,.75,.92,1]:rounded?[.25,.5,.75,1]:[.5,1]))for(const angle of angles){await page.evaluate(({expression,amount})=>{study.setEyes({[expression]:amount});study.setOpening(.6);},{expression,amount});await page.select('#angle',angle);const name=`${variant}-${expression}-${amount}-${angle}`;await canvas.screenshot({path:path.join(out,name+'.png')});states.push({variant,expression,amount,angle});}
 }
 await page.select('#variant',candidate);await page.waitForFunction(()=>window.ready);await page.select('#angle','0');
 const mixtures=[];for(const h of [0,.5,1])for(const r of [0,.5,1])for(const b of [0,.5,1]){const result=await page.evaluate(({h,r,b})=>{study.setEyes({happy:h,relaxed:r,blink:b});const weights=['happy','relaxed','blink'].map(n=>study.current.expressionManager.getValue(n));const textures=[];study.current.scene.traverse(o=>{for(const m of [o.material].flat().filter(Boolean))if(m.name.startsWith('Surface Lid')&&m.map)textures.push([...m.map.repeat.toArray(),...m.map.offset.toArray()]);});return {weights,textures,mouthTotal:['aa','ih','ou','ee','oh'].reduce((sum,n)=>sum+study.current.expressionManager.getValue(n),0)};},{h,r,b});assert.ok(result.weights.reduce((a,b)=>a+b,0)<=1.000001);assert.ok(result.textures.flat().every(Number.isFinite));assert.ok(result.mouthTotal>0);mixtures.push({h,r,b,...result});}
 await page.click('#eyesPlay');const animation=await page.evaluate(async()=>{let frames=0;const maxima={happy:0,blink:0,relaxed:0},start=performance.now();while(performance.now()-start<9000){await new Promise(requestAnimationFrame);for(const n of Object.keys(maxima))maxima[n]=Math.max(maxima[n],study.current.expressionManager.getValue(n));frames++;}return {frames,maxima};});assert.ok(animation.frames>30&&Object.values(animation.maxima).every(w=>w>.95));
 await page.click('#neutral');assert.deepEqual(await page.evaluate(()=>['happy','blink','relaxed','aa','ih','ou','ee','oh'].map(n=>study.current.expressionManager.getValue(n))),[0,0,0,0,0,0,0,0]);const neutral=await pixels();await page.select('#variant','vowels');await page.waitForFunction(()=>window.ready);assert.deepEqual(await pixels(),neutral);
 await page.select('#variant',candidate);await page.waitForFunction(()=>window.ready);await page.evaluate(()=>{study.setEyes({happy:1});study.setOpening(.6);});const layouts=[];
 for(const width of [1280,600,390]){await page.setViewport({width,height:1000});await page.waitForFunction(()=>document.querySelector('canvas').height===document.querySelector('canvas').clientHeight);const layout=await page.evaluate(()=>({width:innerWidth,scrollWidth:document.documentElement.scrollWidth,canvasHeight:document.querySelector('canvas').clientHeight}));assert.ok(layout.scrollWidth<=width&&layout.canvasHeight>200);layouts.push(layout);await page.screenshot({path:path.join(out,`controls-${width}.png`)});}
 const bytes=await fs.readFile(path.join(root,`artifacts/${modelFolder}/continuous-blink.vrm`));assert.deepEqual(bytes,await fs.readFile(path.join(root,`artifacts/${modelFolder}-repeat/continuous-blink.vrm`)));assert.deepEqual(errors,[]);assert.equal(await sha(),expected);
 const report={framebufferComparison:'SHA-256 of RGBA readback',expressionStyle:style,date:new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Tokyo'}).format(new Date()),scope:'expression feasibility and source-preserving zero state; not artistic acceptance; eye color/edge artifacts remain',neutralVowelMatches:equal,states,mixtures,animation,layouts,errors,repeatByteIdentical:true,outputSha256:createHash('sha256').update(bytes).digest('hex')};await fs.writeFile(path.join(root,balanced?'results/balanced-smile-evaluation.json':crescent?'results/crescent-smile-evaluation.json':rounded?'results/rounded-smile-evaluation.json':'results/surface-expressions-evaluation.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({neutralVowelMatches:equal.length,states:states.length,mixtures:mixtures.length,animation,layouts,errors}));
}finally{if(browser)await browser.close();server.closeAllConnections();await new Promise(r=>server.close(r));}process.exit(0);
