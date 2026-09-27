import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import puppeteer from 'puppeteer-core';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const run=process.env.BLINK_RUN||'continuous-blink-obstacle';
const angles=(process.env.PROBE_ANGLES||'0,45,90').split(',').map(Number);
const weights=(process.env.PROBE_WEIGHTS||'0,.25,.5,.75,1').split(',').map(Number);
if(!angles.every(Number.isFinite)||!weights.every(w=>Number.isFinite(w)&&w>=0&&w<=1))throw new Error('Invalid capture values');
if(!/^[a-z0-9-]+$/.test(run))throw new Error('Invalid run directory');
const output=path.join(root,'artifacts',run,'viewer');await fs.mkdir(output,{recursive:true});
// Fail before launching Chrome if the dependent export has not completed.
await fs.access(path.join(root,'artifacts',run,'continuous-blink.vrm'));
const mime={'.html':'text/html','.js':'text/javascript','.png':'image/png','.json':'application/json','.vrm':'model/gltf-binary'};
const server=http.createServer(async(req,res)=>{
 try{let pathname=decodeURIComponent(new URL(req.url,'http://localhost').pathname);if(pathname==='/favicon.ico'){res.statusCode=204;res.end();return;}if(pathname==='/')pathname='/viewer.html';const file=path.resolve(root,'.'+pathname);
 if(!file.startsWith(root+path.sep))throw new Error('outside root');const bytes=await fs.readFile(file);res.setHeader('Content-Type',mime[path.extname(file)]||'application/octet-stream');res.end(bytes);
 }catch{res.statusCode=404;res.end('Not found');}
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
let browser;
try{
 browser=await puppeteer.launch({executablePath:process.env.CHROME_BIN||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--hide-scrollbars']});
 const page=await browser.newPage();await page.setViewport({width:900,height:1000,deviceScaleFactor:1});
 const errors=[],warnings=[];page.on('pageerror',e=>errors.push(String(e)));page.on('console',m=>{if(['warn','error'].includes(m.type()))warnings.push(m.text());});
 await page.goto(`http://127.0.0.1:${server.address().port}/?model=${run}`);
 await page.waitForFunction(()=>window.ready,{timeout:60000});
 const report={chrome:await browser.version(),errors,warnings,states:[]};
 const canvas=await page.$('canvas');
 for(const a of angles){
  await page.evaluate(a=>probe.set({w:0,a,visible:false}),a);await canvas.screenshot({path:path.join(output,`source-${a}.png`)});
  for(const w of weights){
   await page.evaluate(({w,a})=>probe.set({w,a,visible:true}),{w,a});
   report.states.push({w,a,lids:await page.evaluate(()=>probe.stats())});
   await canvas.screenshot({path:path.join(output,`blink-${w}-${a}.png`)});
  }
 }
 for(const e of ['blinkLeft','blinkRight']){
  for(const w of [.5,1]){
   await page.evaluate(({e,w})=>probe.set({w,a:0,e}),{e,w});
   report.states.push({w,a:0,e,lids:await page.evaluate(()=>probe.stats())});
   await canvas.screenshot({path:path.join(output,w===1?`${e}.png`:`${e}-${w}.png`)});
  }
 }
 if(await page.evaluate(()=>probe.hasRelaxed)){
  report.relaxedComposition=await page.evaluate(async()=>{
   const baseline=(await probe.loader.loadAsync('/artifacts/continuous-fresh/continuous-blink.vrm')).userData.vrm;
   probe.scene.add(baseline.scene);baseline.scene.visible=false;
   const gl=probe.renderer.getContext(),width=gl.drawingBufferWidth,height=gl.drawingBufferHeight;
   const pixels=()=>{const p=new Uint8Array(width*height*4);gl.readPixels(0,0,width,height,gl.RGBA,gl.UNSIGNED_BYTE,p);return p;};
   const cases=[];
   for(const r of [0,.35,.7,1])for(const w of [0,.5,1])for(const e of ['blink','blinkLeft','blinkRight']){
    baseline.scene.visible=false;probe.set({r,w,e,a:0,visible:true});const candidate=pixels();
    probe.vrm.scene.visible=false;baseline.scene.visible=true;
    baseline.expressionManager.setValue('blink',0);
    baseline.expressionManager.setValue('blinkLeft',r+(e!=='blinkRight'?(1-r)*w:0));
    baseline.expressionManager.setValue('blinkRight',r+(e!=='blinkLeft'?(1-r)*w:0));
    baseline.update(0);probe.renderer.render(probe.scene,probe.camera);const expected=pixels();
    let max=0,total=0,changed=0;for(let i=0;i<candidate.length;i++){if(i%4===3)continue;const d=Math.abs(candidate[i]-expected[i]);max=Math.max(max,d);total+=d;if(d>2)changed++;}
    cases.push({r,w,e,maxChannelDifference:max,meanChannelDifference:total/(width*height*3),channelsAbove2:changed});
   }
   probe.scene.remove(baseline.scene);probe.set({r:0,w:0,e:'blink',visible:true});return cases;
  });
  if(report.relaxedComposition.some(c=>c.maxChannelDifference>2))errors.push('Relaxed/blink composition differs from selected baseline');
  for(const [r,w,label] of [[.35,0,'relaxed'],[.35,.5,'relaxed-half-blink'],[.35,1,'relaxed-full-blink']]){
   await page.evaluate(({r,w})=>probe.set({r,w,a:0,e:'blink'}),{r,w});await canvas.screenshot({path:path.join(output,`${label}.png`)});
  }
 }
 if(process.env.PROBE_UI==='1'){
  await page.evaluate(()=>{probe.setMotion(null);probe.set({r:0,w:0,e:'blink',a:0,visible:true});});
  await page.click('#natural');
  report.naturalPlayback=await page.evaluate(async()=>{
   const samples=[];const start=performance.now();
   while(performance.now()-start<1500){await new Promise(requestAnimationFrame);samples.push(probe.vrm.expressionManager.getValue('blink'));}
   return {maximum:Math.max(...samples),first:samples[0],last:samples.at(-1),frames:samples.length};
  });
  if(report.naturalPlayback.maximum<.95||report.naturalPlayback.last>.01)errors.push('Natural playback did not close and reopen');
  await page.click('#natural');
  await page.click('#lids');
  await page.select('#angle','45');
  report.originalTogglePersists=await page.evaluate(()=>!probe.vrm.scene.visible&&probe.reference.scene.visible&&!document.querySelector('#lids').checked);
  if(!report.originalTogglePersists)errors.push('Original toggle changed when changing angle');
  await page.click('#lids');await page.select('#angle','0');
  await page.evaluate(()=>{const input=document.querySelector('#relaxed');input.value='0.35';input.dispatchEvent(new Event('input',{bubbles:true}));});
  await page.screenshot({path:path.join(output,'controls.png')});
  await page.setViewport({width:600,height:900,deviceScaleFactor:1});
  await page.waitForFunction(()=>document.querySelector('canvas').clientHeight>200);
  report.compactLayout=await page.evaluate(()=>({scrollWidth:document.documentElement.scrollWidth,width:innerWidth,canvasHeight:document.querySelector('canvas').clientHeight}));
  if(report.compactLayout.scrollWidth>report.compactLayout.width)errors.push('Horizontal overflow in compact viewer');
  await page.screenshot({path:path.join(output,'controls-compact.png')});
  await page.setViewport({width:900,height:1000,deviceScaleFactor:1});
 }
 await fs.writeFile(path.join(output,'report.json'),JSON.stringify(report,null,2)+'\n');
 if(errors.length)throw new Error(errors.join('\n'));
 console.log(JSON.stringify({output,errors,warnings,states:report.states.length}));
}finally{if(browser)await browser.close();await new Promise(resolve=>server.close(resolve));}
