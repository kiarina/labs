import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
import puppeteer from 'puppeteer-core';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const out=path.join(root,'artifacts/mouth-flush');await fs.mkdir(out,{recursive:true});
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
 const errors=[];const page=await browser.newPage();page.on('pageerror',e=>errors.push(String(e)));const states=[];await page.setViewport({width:900,height:1000,deviceScaleFactor:1});
 await page.goto(`http://127.0.0.1:${server.address().port}/feature-study.html?variant=mouth-flush&angle=90`);await page.waitForFunction(()=>window.ready);
 for(const variant of ['eyes','eyes-mouth','mouth-flush']){
  await page.select('#variant',variant);await page.waitForFunction(()=>window.ready);
  for(const angle of ['0','45','90','-45','-90']){await page.select('#angle',angle);await page.screenshot({path:path.join(out,`${variant}-${angle}.png`)});states.push({variant,angle});}
 }
 const url=`http://127.0.0.1:${server.address().port}/feature-study.html`;
 for(const variant of ['eyes','mouth-flush']){
  await page.goto(url+`?variant=${variant}&angle=0`);await page.waitForFunction(()=>window.ready);
  await page.evaluate(async()=>{
   const THREE=await import('three');study.current.scene.traverse(o=>{if(o.isMesh){const replace=m=>new THREE.MeshBasicMaterial({map:m.map,color:m.color,side:m.side,transparent:m.transparent,opacity:m.opacity,alphaTest:m.alphaTest,vertexColors:m.vertexColors,toneMapped:false});o.material=Array.isArray(o.material)?o.material.map(replace):replace(o.material);}});study.renderer.render(study.scene,study.camera);
  });
  await page.screenshot({path:path.join(out,`${variant}-flat-color.png`)});
 }
 await page.goto(url+'?variant=mouth-flush&angle=45');await page.waitForFunction(()=>window.ready);
 const layouts=[];
 for(const width of [1280,600,390]){
  await page.setViewport({width,height:900,deviceScaleFactor:1});await page.waitForFunction(()=>document.querySelector('canvas').height===document.querySelector('canvas').clientHeight);
  const layout=await page.evaluate(()=>({width:innerWidth,scrollWidth:document.documentElement.scrollWidth,canvasHeight:document.querySelector('canvas').clientHeight}));assert.ok(layout.scrollWidth<=width&&layout.canvasHeight>200);layouts.push(layout);await page.screenshot({path:path.join(out,`controls-${width}.png`)});
 }
 const candidate=await fs.readFile(path.join(root,'artifacts/feature-mouth-flush/continuous-blink.vrm'));assert.deepEqual(candidate,await fs.readFile(path.join(root,'artifacts/feature-mouth-flush-repeat/continuous-blink.vrm')));
 assert.equal(await sha(),expected);assert.deepEqual(errors,[]);
 const build=JSON.parse(await fs.readFile(path.join(root,'artifacts/feature-mouth-flush/report.json'),'utf8'));
 const report={date:new Date().toISOString().slice(0,10),scope:'mouth depth only; original stroke width; authorized joining band and stem',states,layouts,errors,repeatByteIdentical:true,build};
 await fs.writeFile(path.join(root,'results/mouth-flush-evaluation.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({states:states.length,layouts,errors}));

}finally{if(browser)await browser.close();server.closeAllConnections();await new Promise(r=>server.close(r));}
process.exit(0);
