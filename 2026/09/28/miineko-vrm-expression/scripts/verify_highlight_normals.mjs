import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
import puppeteer from 'puppeteer-core';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const out=path.join(root,'artifacts/highlight-review');await fs.mkdir(out,{recursive:true});
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
 browser=await puppeteer.launch({executablePath:process.env.CHROME_BIN||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--hide-scrollbars']});const page=await browser.newPage(),errors=[];page.on('pageerror',e=>errors.push(String(e)));await page.setViewport({width:1400,height:1600});await page.goto(`http://127.0.0.1:${server.address().port}/expression-study.html?variant=blink-aligned&opening=0`);await page.waitForFunction(()=>window.ready);const canvas=await page.$('canvas'),states=[];
 for(const variant of ['blink-aligned','highlight-clean-r']){await page.select('#variant',variant);await page.waitForFunction(()=>window.ready);for(const pose of ['neutral','half','blink','happy','angry','sad','relaxed','surprised'])for(const angle of ['0','45','-45','90','-90']){await page.evaluate(p=>{study.setEyes(p==='neutral'?{}:p==='half'?{blink:.25}:{[p]:1});study.setOpening(0);},pose);await page.select('#angle',angle);await canvas.screenshot({path:path.join(out,`${variant}-${pose}-${angle}.png`)});states.push({variant,pose,angle});}}
 await page.select('#angle','0');await page.evaluate(()=>study.setEyes({}));for(const variant of ['blink-aligned','highlight-clean-r']){await page.select('#variant',variant);await page.waitForFunction(()=>window.ready);await page.evaluate(()=>{study.camera.zoom=1.5;study.camera.updateProjectionMatrix();study.renderer.render(study.scene,study.camera);});await canvas.screenshot({path:path.join(out,`${variant}-detail.png`)});}
 assert.deepEqual(errors,[]);await fs.writeFile(path.join(root,'results/highlight-normal-evaluation.json'),JSON.stringify({states,errors,scope:'lighting-normal repair, texture and geometry untouched; no approval of other eye or perimeter cleanup'},null,2)+'\n');console.log(JSON.stringify({states:states.length,errors}));
}finally{if(browser)await browser.close();server.closeAllConnections();await new Promise(r=>server.close(r));}process.exit(0);
