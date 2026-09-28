import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
import puppeteer from 'puppeteer-core';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const out=path.join(root,'artifacts/feature-study');await fs.mkdir(out,{recursive:true});
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
 await page.goto(`http://127.0.0.1:${server.address().port}/feature-study.html`);await page.waitForFunction(()=>window.ready);
 const errors=[];page.on('pageerror',e=>errors.push(String(e)));const states=[];
 for(const variant of ['original','eyes','eyes-mouth']){
  await page.select('#variant',variant);await page.waitForFunction(()=>window.ready);
  for(const angle of ['0','45','90','-45','-90']){await page.select('#angle',angle);await page.screenshot({path:path.join(out,`${variant}-${angle}.png`)});const key=await page.evaluate(()=>study.key);assert.equal(key,variant==='original'?'mouth-aa-aligned':`feature-${variant}`);states.push({variant,angle,key});}
 }
 const layouts=[];await page.select('#angle','45');
 for(const width of [1280,600,390]){
  await page.setViewport({width,height:900,deviceScaleFactor:1});await page.waitForFunction(()=>document.querySelector('canvas').height===document.querySelector('canvas').clientHeight);
  const layout=await page.evaluate(()=>({width:innerWidth,scrollWidth:document.documentElement.scrollWidth,canvasHeight:document.querySelector('canvas').clientHeight}));assert.ok(layout.scrollWidth<=width&&layout.canvasHeight>200);layouts.push(layout);await page.screenshot({path:path.join(out,`controls-${width}.png`)});
 }
 const models=[];
 for(const name of ['eyes','eyes-mouth']){
  const folder=path.join(root,`artifacts/feature-${name}`),bytes=await fs.readFile(path.join(folder,'continuous-blink.vrm'));
  assert.deepEqual(bytes,await fs.readFile(path.join(root,`artifacts/feature-${name}-repeat/continuous-blink.vrm`)));
  const build=JSON.parse(await fs.readFile(path.join(folder,'report.json'),'utf8'));assert.equal(createHash('sha256').update(bytes).digest('hex'),build.outputSha256);models.push({...build,repeatByteIdentical:true});
 }
 assert.deepEqual(errors,[]);assert.equal(await sha(),expected);
 const report={date:new Date().toISOString().slice(0,10),scope:'normal face only; protected pink geometry and nose; artistic review pending',states,layouts,errors,models};
 await fs.writeFile(path.join(root,'results/feature-depth-evaluation.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({states:states.length,layouts,errors}));

}finally{if(browser)await browser.close();server.closeAllConnections();await new Promise(r=>server.close(r));}
process.exit(0);
