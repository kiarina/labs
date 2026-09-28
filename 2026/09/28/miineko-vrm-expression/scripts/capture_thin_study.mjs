import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
import puppeteer from 'puppeteer-core';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const out=path.join(root,'artifacts/thin-study');await fs.mkdir(out,{recursive:true});
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
try{
 browser=await puppeteer.launch({executablePath:process.env.CHROME_BIN||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--hide-scrollbars']});
 const page=await browser.newPage();await page.setViewport({width:900,height:1000,deviceScaleFactor:1});
 const errors=[];page.on('pageerror',e=>errors.push(String(e)));
 await page.goto(`http://127.0.0.1:${server.address().port}/face-study.html`);await page.waitForFunction(()=>window.ready);
 const states=[];
 for(const variant of ['original','eyes','eyes-mouth'])for(const pose of ['neutral','smile']){
  await page.select('#variant',variant);await page.waitForFunction(()=>window.ready);
  await page.select('#pose',pose);await page.waitForFunction(()=>window.ready);
  for(const angle of ['0','45','90','-45','-90']){
   await page.select('#angle',angle);await page.screenshot({path:path.join(out,`${variant}-${pose}-${angle}.png`)});
   const key=await page.evaluate(()=>study.key);assert.equal(key,variant==='original'?'happy-arc':`thin-${variant}-${pose}`);states.push({variant,pose,angle,key});
  }
 }
 const layouts=[];
 await page.select('#variant','eyes-mouth');await page.select('#pose','smile');await page.waitForFunction(()=>window.ready);await page.select('#angle','0');
 for(const width of [1280,600,390]){
  await page.setViewport({width,height:900,deviceScaleFactor:1});await page.waitForFunction(()=>document.querySelector('canvas').height===document.querySelector('canvas').clientHeight);
  const layout=await page.evaluate(()=>({width:innerWidth,scrollWidth:document.documentElement.scrollWidth,canvasHeight:document.querySelector('canvas').clientHeight}));assert.ok(layout.scrollWidth<=width&&layout.canvasHeight>200);layouts.push(layout);await page.screenshot({path:path.join(out,`controls-${width}.png`)});
 }
 assert.deepEqual(errors,[]);assert.equal(await sha(),expected);
 const models=[];
 for(const variant of ['eyes','eyes-mouth'])for(const pose of ['neutral','smile']){
  const name=`thin-${variant}-${pose}`;const report=JSON.parse(await fs.readFile(path.join(root,`artifacts/${name}/report.json`),'utf8'));const bytes=await fs.readFile(path.join(root,`artifacts/${name}/continuous-blink.vrm`));
  const repeat=await fs.readFile(path.join(root,`artifacts/${name}-repeat/continuous-blink.vrm`));assert.deepEqual(bytes,repeat);assert.equal(createHash('sha256').update(bytes).digest('hex'),report.outputSha256);assert.equal(report.xzUnchanged,true);assert.ok(report.verticesWithDepthChange>0);report.repeatByteIdentical=true;models.push(report);
 }
 const report={date:new Date().toISOString().slice(0,10),scope:'static form study; not animation-ready or artistically accepted',sourceSha256:expected,states,layouts,errors,models};
 await fs.writeFile(path.join(root,'results/thin-face-evaluation.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({states:states.length,layouts,errors}));
}finally{if(browser)await browser.close();server.closeAllConnections();await new Promise(r=>server.close(r));}
process.exit(0);
