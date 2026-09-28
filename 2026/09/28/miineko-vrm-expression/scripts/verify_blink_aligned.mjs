import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
import puppeteer from 'puppeteer-core';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const out=path.join(root,'artifacts/blink-aligned-review');await fs.mkdir(out,{recursive:true});
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
 await page.goto(`http://127.0.0.1:${server.address().port}/expression-study.html?variant=blink-aligned&opening=0`);await page.waitForFunction(()=>window.ready);const canvas=await page.$('canvas'),angles=['0','45','90','-45','-90'];
 const pixels=()=>page.evaluate(()=>{const g=study.renderer.getContext(),a=new Uint8Array(g.drawingBufferWidth*g.drawingBufferHeight*4);g.readPixels(0,0,g.drawingBufferWidth,g.drawingBufferHeight,g.RGBA,g.UNSIGNED_BYTE,a);return crypto.subtle.digest('SHA-256',a).then(b=>Array.from(new Uint8Array(b),v=>v.toString(16).padStart(2,'0')).join(''));});
 const preserved=[];
 for(const pose of [{},{happy:1},{angry:1},{sad:1},{relaxed:1},{surprised:1}])for(const angle of angles){
  await page.select('#variant','surprise-ears');await page.waitForFunction(()=>window.ready);await page.evaluate(p=>{study.setEyes(p);study.setOpening(.65);},pose);await page.select('#angle',angle);const ref=await pixels();
  await page.select('#variant','blink-aligned');await page.waitForFunction(()=>window.ready);assert.equal(await pixels(),ref);preserved.push({pose,angle});
 }
 const samples=[];for(const variant of ['surprise-ears','blink-aligned']){
  await page.select('#variant',variant);await page.waitForFunction(()=>window.ready);await page.evaluate(()=>study.setOpening(0));
  for(const weight of [0,.02,.04,.06,.08,.1,.13,.25,.5,.75,.92,1])for(const angle of (weight===0||weight===.5||weight===1?angles:['0'])){
   await page.evaluate(b=>study.setEyes({blink:b}),weight);await page.select('#angle',angle);await canvas.screenshot({path:path.join(out,`${variant}-${weight}-${angle}.png`)});samples.push({variant,weight,angle});
  }
 }
 await page.select('#variant','blink-aligned');await page.waitForFunction(()=>window.ready);
 const combinations=[];for(const emotion of ['happy','angry','sad','relaxed','surprised'])for(const blink of [.25,.5,1]){
  await page.evaluate(({emotion,blink})=>{study.setEyes({[emotion]:1,blink});study.setOpening(.65);},{emotion,blink});await page.select('#angle','45');await canvas.screenshot({path:path.join(out,`${emotion}-blink-${blink}.png`)});if(emotion==='surprised')assert.equal(await page.evaluate(()=>study.current.expressionManager.getValue('surprised')),1);combinations.push({emotion,blink});
 }
 await page.select('#angle','0');await page.evaluate(()=>{study.setEyes({});study.setOpening(0);});const neutral=await pixels(),sideChecks=[];
 for(const name of ['blinkLeft','blinkRight']){await page.evaluate(name=>{study.current.expressionManager.setValue(name,1);study.current.update(0);study.renderer.render(study.scene,study.camera);},name);assert.notEqual(await pixels(),neutral);await canvas.screenshot({path:path.join(out,`${name}.png`)});await page.evaluate(name=>{study.current.expressionManager.setValue(name,0);study.current.update(0);study.renderer.render(study.scene,study.camera);},name);assert.equal(await pixels(),neutral);sideChecks.push(name);}
 const pulses=[];for(const [id,duration] of [['blink-once',500],['blink-slow',2950]]){
  await page.evaluate(()=>{study.setEyes({surprised:1});study.setOpening(.65);});await page.click('#'+id);const pulse=await page.evaluate(async duration=>{let frames=0,peak=0,earMin=1,mouthMin=1;const start=performance.now();while(performance.now()-start<duration){await new Promise(requestAnimationFrame);const e=study.current.expressionManager;peak=Math.max(peak,e.getValue('blink'));earMin=Math.min(earMin,e.getValue('surprised'));mouthMin=Math.min(mouthMin,e.getValue('aa'));frames++;}return {frames,peak,earMin,mouthMin,end:study.current.expressionManager.getValue('blink')};},duration);assert.ok(pulse.frames>4&&pulse.peak>.85&&pulse.earMin===1&&pulse.mouthMin>.7&&pulse.end===0);pulses.push({id,...pulse});
 }
 await page.click('#blink-slow');await page.click('#neutral');await new Promise(r=>setTimeout(r,200));assert.equal(await page.evaluate(()=>study.current.expressionManager.getValue('blink')),0);
 await page.evaluate(()=>{study.setEyes({blink:1});study.setOpening(0);});const layouts=[];for(const width of [1280,600,390]){await page.setViewport({width,height:1100});await page.waitForFunction(()=>document.querySelector('canvas').height===document.querySelector('canvas').clientHeight);const l=await page.evaluate(()=>({width:innerWidth,scrollWidth:document.documentElement.scrollWidth,canvasHeight:document.querySelector('canvas').clientHeight}));assert.ok(l.scrollWidth<=width&&l.canvasHeight>200);layouts.push(l);await page.screenshot({path:path.join(out,`controls-${width}.png`)});}
 assert.deepEqual(errors,[]);await fs.writeFile(path.join(root,'results/blink-aligned-evaluation.json'),JSON.stringify({preserved,samples,combinations,sideChecks,pulses,layouts,errors},null,2)+'\n');console.log(JSON.stringify({preserved:preserved.length,samples:samples.length,combinations:combinations.length,pulses,layouts,errors}));
}finally{if(browser)await browser.close();server.closeAllConnections();await new Promise(r=>server.close(r));}process.exit(0);
