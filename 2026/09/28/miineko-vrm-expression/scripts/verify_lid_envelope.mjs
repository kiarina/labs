import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
import puppeteer from 'puppeteer-core';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const out=path.join(root,'artifacts/lid-gap-review');await fs.mkdir(out,{recursive:true});
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
 browser=await puppeteer.launch({executablePath:process.env.CHROME_BIN||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--hide-scrollbars']});const page=await browser.newPage(),errors=[];page.on('pageerror',e=>errors.push(String(e)));await page.setViewport({width:1400,height:1600});await page.goto(`http://127.0.0.1:${server.address().port}/expression-study.html?variant=lid-rim-clean&opening=0`);await page.waitForFunction(()=>window.ready);const canvas=await page.$('canvas'),states=[];
 for(const variant of ['lid-rim-clean','lid-envelope']){await page.select('#variant',variant);await page.waitForFunction(()=>window.ready);for(const pose of ['neutral','half','reference86','blink','happy','angry','sad','relaxed','surprised'])for(const angle of ['0','15','30','45','60','75','90','-15','-30','-45','-60','-75','-90']){await page.evaluate(p=>{study.setEyes(p==='neutral'?{}:p==='half'?{blink:.25}:p==='reference86'?{blink:.86}:{[p]:1});study.setOpening(0);},pose);await page.select('#angle',angle);await canvas.screenshot({path:path.join(out,`${variant}-${pose}-${angle}.png`)});states.push({variant,pose,angle});}}
 await page.select('#angle','0');await page.evaluate(()=>study.setEyes({}));for(const variant of ['lid-rim-clean','lid-envelope']){await page.select('#variant',variant);await page.waitForFunction(()=>window.ready);await page.evaluate(()=>{study.camera.zoom=1.5;study.camera.updateProjectionMatrix();study.renderer.render(study.scene,study.camera);});await canvas.screenshot({path:path.join(out,`${variant}-detail.png`)});}
 const neutralChecks=[];await page.evaluate(()=>{study.camera.zoom=1;study.camera.updateProjectionMatrix();});
 const pixels=()=>page.evaluate(()=>{const g=study.renderer.getContext(),a=new Uint8Array(g.drawingBufferWidth*g.drawingBufferHeight*4);g.readPixels(0,0,g.drawingBufferWidth,g.drawingBufferHeight,g.RGBA,g.UNSIGNED_BYTE,a);return crypto.subtle.digest('SHA-256',a).then(b=>Array.from(new Uint8Array(b),v=>v.toString(16).padStart(2,'0')).join(''));});
 for(const angle of ['0','15','30','45','60','75','90','-15','-30','-45','-60','-75','-90']){await page.select('#variant','lid-rim-clean');await page.waitForFunction(()=>window.ready);await page.evaluate(()=>{study.setEyes({surprised:1});study.setOpening(.65);});await page.select('#angle',angle);const before=await pixels();await page.evaluate(()=>{const g=study.renderer.getContext();window.referenceRGBA=new Uint8Array(g.drawingBufferWidth*g.drawingBufferHeight*4);g.readPixels(0,0,g.drawingBufferWidth,g.drawingBufferHeight,g.RGBA,g.UNSIGNED_BYTE,window.referenceRGBA);});await page.select('#variant','lid-envelope');await page.waitForFunction(()=>window.ready);const exact=before===await pixels();const drift=await page.evaluate(()=>{const g=study.renderer.getContext(),a=new Uint8Array(referenceRGBA.length);g.readPixels(0,0,g.drawingBufferWidth,g.drawingBufferHeight,g.RGBA,g.UNSIGNED_BYTE,a);let pixels=0,max=0;for(let i=0;i<a.length;i+=4){let changed=false;for(let j=0;j<4;j++){const d=Math.abs(a[i+j]-referenceRGBA[i+j]);max=Math.max(max,d);changed||=d!==0;}if(changed)pixels++;}return {pixels,max};});assert.ok(drift.pixels<=12&&drift.max<=53,JSON.stringify({angle,drift}));neutralChecks.push({angle,exact,...drift});}
 const layouts=[];for(const width of [1280,600,390]){await page.setViewport({width,height:1100});await page.waitForFunction(()=>document.querySelector('canvas').height===document.querySelector('canvas').clientHeight);const layout=await page.evaluate(()=>({width:innerWidth,scrollWidth:document.documentElement.scrollWidth,canvasHeight:document.querySelector('canvas').clientHeight}));assert.ok(layout.scrollWidth<=width&&layout.canvasHeight>200);layouts.push(layout);}
 assert.deepEqual(errors,[]);await fs.writeFile(path.join(root,'results/lid-envelope-evaluation.json'),JSON.stringify({states,neutralChecks,layouts,errors,scope:'front envelope of fixed lids; all source head geometry and closure binds retained; 13 viewing angles'},null,2)+'\n');console.log(JSON.stringify({states:states.length,errors}));
}finally{if(browser)await browser.close();server.closeAllConnections();await new Promise(r=>server.close(r));}process.exit(0);
