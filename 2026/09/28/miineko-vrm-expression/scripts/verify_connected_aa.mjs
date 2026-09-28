import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
import puppeteer from 'puppeteer-core';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const out=path.join(root,'artifacts/connected-aa');await fs.mkdir(out,{recursive:true});
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
 browser=await puppeteer.launch({executablePath:process.env.CHROME_BIN||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--hide-scrollbars']});const errors=[];const page=await browser.newPage();page.on('pageerror',e=>errors.push(String(e)));const states=[];await page.setViewport({width:900,height:1000});
 await page.goto(`http://127.0.0.1:${server.address().port}/mouth-study.html`);await page.waitForFunction(()=>window.ready);
 for(const w of [0,.1,.25,.4,.5,.65,.75,.9,1])for(const angle of ['0','45','90','-45','-90']){await page.evaluate(w=>study.setOpening(w),w);await page.select('#angle',angle);await page.screenshot({path:path.join(out,`aa-${w}-${angle}.png`)});states.push({w,angle});}
 const pixels=()=>page.evaluate(()=>{const gl=study.renderer.getContext(),p=new Uint8Array(gl.drawingBufferWidth*gl.drawingBufferHeight*4);gl.readPixels(0,0,gl.drawingBufferWidth,gl.drawingBufferHeight,gl.RGBA,gl.UNSIGNED_BYTE,p);return Array.from(p);});
 const closed=[];const closedPixels=[];
 await page.evaluate(()=>study.setOpening(0));
 for(const angle of ['0','45','90','-45','-90']){await page.select('#angle',angle);closedPixels.push(await pixels());}
 await page.select('#variant','base');await page.waitForFunction(()=>window.ready);
 for(const [i,angle] of ['0','45','90','-45','-90'].entries()){
  await page.select('#angle',angle);assert.deepEqual(await pixels(),closedPixels[i]);closed.push({angle,identical:true});await page.screenshot({path:path.join(out,`base-${angle}.png`)});
 }
 await page.select('#variant','connected');await page.waitForFunction(()=>window.ready);await page.select('#angle','0');await page.click('#play');
 const animation=await page.evaluate(async()=>{let frames=0,min=1,max=0;const start=performance.now();while(performance.now()-start<5200){await new Promise(requestAnimationFrame);const value=study.current.expressionManager.getValue('aa');min=Math.min(min,value);max=Math.max(max,value);frames++;}return {frames,min,max};});
 assert.ok(animation.frames>30&&animation.min<.01&&animation.max>.99);
 await page.click('#close');assert.equal(await page.evaluate(()=>study.current.expressionManager.getValue('aa')),0);assert.deepEqual(await pixels(),closedPixels[0]);
 await page.evaluate(()=>study.setOpening(.75));const layouts=[];
 for(const width of [1280,600,390]){await page.setViewport({width,height:900});await page.waitForFunction(()=>document.querySelector('canvas').height===document.querySelector('canvas').clientHeight);const layout=await page.evaluate(()=>({width:innerWidth,scrollWidth:document.documentElement.scrollWidth,canvasHeight:document.querySelector('canvas').clientHeight}));assert.ok(layout.scrollWidth<=width&&layout.canvasHeight>200);layouts.push(layout);await page.screenshot({path:path.join(out,`controls-${width}.png`)});}
 const source=await fs.readFile(path.join(root,'artifacts/feature-mouth-flush/continuous-blink.vrm'));assert.equal(createHash('sha256').update(source).digest('hex'),'989f33cb81f91a99e2112fb9ce7df47e2734096d649519950f371cdddbc99665');
 const bytes=await fs.readFile(path.join(root,'artifacts/mouth-connected-aa/continuous-blink.vrm'));assert.deepEqual(bytes,await fs.readFile(path.join(root,'artifacts/mouth-connected-aa-repeat/continuous-blink.vrm')));assert.deepEqual(errors,[]);
 const report={date:new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Tokyo'}).format(new Date()),scope:'AA-only opening on the revised head; other expressions not restored',states,closed,animation,layouts,errors,repeatByteIdentical:true,outputSha256:createHash('sha256').update(bytes).digest('hex')};await fs.writeFile(path.join(root,'results/connected-aa-evaluation.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({states:states.length,closed,animation,layouts,errors}));

}finally{if(browser)await browser.close();server.closeAllConnections();await new Promise(r=>server.close(r));}process.exit(0);
