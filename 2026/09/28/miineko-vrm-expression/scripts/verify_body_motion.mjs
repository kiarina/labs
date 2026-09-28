import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
import puppeteer from 'puppeteer-core';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const model=path.join(root,'artifacts/blink-aligned/continuous-blink.vrm'),sourceSha256=JSON.parse(await fs.readFile(path.join(root,'artifacts/blink-aligned/report.json'),'utf8')).outputSha256;assert.equal(createHash('sha256').update(await fs.readFile(model)).digest('hex'),sourceSha256);
const out=path.join(root,'artifacts/body-motion-review');await fs.mkdir(out,{recursive:true});
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
 browser=await puppeteer.launch({executablePath:process.env.CHROME_BIN||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--hide-scrollbars']});const page=await browser.newPage(),errors=[];page.on('pageerror',e=>errors.push(String(e)));await page.setViewport({width:1100,height:1000});
 await page.goto(`http://127.0.0.1:${server.address().port}/body-study.html`);await page.waitForFunction(()=>window.ready||bodyStudy.error);assert.equal(await page.evaluate(()=>bodyStudy.error),undefined);const canvas=await page.$('canvas');const samples=[];
 for(const motion of ['neutral','arms','squat','kick','twist','jump','samba']){
  await page.evaluate(m=>bodyStudy.select(m),motion);const duration=await page.evaluate(()=>bodyStudy.duration);
  for(const t of (motion==='neutral'?[0]:motion==='samba'?Array.from({length:12},(_,i)=>i*duration/12):[.5,1,1.5,2,2.5])){
   await page.evaluate(t=>bodyStudy.seek(t),t);const audit=await page.evaluate(()=>bodyStudy.audit());assert.ok(audit.meshes.every(m=>m.finite),JSON.stringify({motion,t,audit,retarget:await page.evaluate(()=>bodyStudy.retarget)}));assert.ok(audit.bones.every(b=>b.position.every(Number.isFinite)));samples.push({motion,time:t,meshes:audit.meshes});
   for(const angle of ['0','45','90','180']){await page.select('#angle',angle);await canvas.screenshot({path:path.join(out,`${motion}-${t.toFixed(3)}-${angle}.png`)});}
  }
 }
 const combined=[];for(const [motion,t] of [['twist',1.5],['samba',4.55]]){await page.evaluate(m=>bodyStudy.select(m),motion);for(const face of ['happy','blink','surprised']){await page.select('#face',face);await page.evaluate(t=>bodyStudy.seek(t),t);for(const angle of ['0','45']){await page.select('#angle',angle);await canvas.screenshot({path:path.join(out,`${motion}-${face}-${angle}.png`)});combined.push({motion,t,face,angle});}}}await page.select('#face','neutral');const retarget=await page.evaluate(()=>bodyStudy.retarget);const layouts=[];for(const width of [1280,600,390]){await page.setViewport({width,height:1000});await page.waitForFunction(()=>document.querySelector('canvas').height===document.querySelector('canvas').clientHeight);const l=await page.evaluate(()=>({width:innerWidth,scrollWidth:document.documentElement.scrollWidth,canvasHeight:document.querySelector('canvas').clientHeight}));assert.ok(l.scrollWidth<=width&&l.canvasHeight>200);layouts.push(l);}assert.equal(createHash('sha256').update(await fs.readFile(model)).digest('hex'),sourceSha256);await fs.writeFile(path.join(root,'results/body-motion-evaluation.json'),JSON.stringify({scope:'first deformation inspection, not a pass for all poses',sourceSha256,layouts,retarget,samples,combined,errors},null,2)+'\n');assert.deepEqual(errors,[]);console.log(JSON.stringify({samples:samples.length,retarget,errors}));
}finally{if(browser)await browser.close();server.closeAllConnections();await new Promise(r=>server.close(r));}process.exit(0);
