import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
import puppeteer from 'puppeteer-core';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const out=path.join(root,'artifacts/surprise-ears-review');await fs.mkdir(out,{recursive:true});
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
 browser=await puppeteer.launch({executablePath:process.env.CHROME_BIN||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--hide-scrollbars']});
 const page=await browser.newPage(),errors=[];page.on('pageerror',e=>errors.push(String(e)));await page.setViewport({width:1100,height:1100});
 await page.goto(`http://127.0.0.1:${server.address().port}/expression-study.html?variant=surprise-mouth&vowel=oh&opening=.65`);await page.waitForFunction(()=>window.ready);
 const pixels=()=>page.evaluate(()=>{const g=study.renderer.getContext(),a=new Uint8Array(g.drawingBufferWidth*g.drawingBufferHeight*4);g.readPixels(0,0,g.drawingBufferWidth,g.drawingBufferHeight,g.RGBA,g.UNSIGNED_BYTE,a);return crypto.subtle.digest('SHA-256',a).then(b=>Array.from(new Uint8Array(b),v=>v.toString(16).padStart(2,'0')).join(''));});
 const preserved=[],states=[];
 for(const pose of [{},{happy:1},{angry:1},{sad:1},{relaxed:1},{blink:1}])for(const angle of ['0','45','90','-45','-90']){
  await page.select('#variant','steeper-sad');await page.waitForFunction(()=>window.ready);await page.evaluate(p=>{study.setEyes(p);study.setOpening(.65);},pose);await page.select('#angle',angle);const ref=await pixels();await (await page.$('canvas')).screenshot({path:path.join(out,'reference-'+preserved.length+'.png')});
  await page.select('#variant','surprise-ears');await page.waitForFunction(()=>window.ready);const exact=await pixels()===ref;assert.ok(exact,JSON.stringify({pose,angle}));await (await page.$('canvas')).screenshot({path:path.join(out,'candidate-'+preserved.length+'.png')});preserved.push({pose,angle,exact});
 }
 for(const variant of ['surprise-mouth','surprise-ears']){
  await page.select('#variant',variant);await page.waitForFunction(()=>window.ready);
  for(const [id,amount] of [['surprise-mild',.3],['surprise-full',.65]]){await page.click('#'+id);assert.equal(await page.$eval('#vowel',e=>e.value),'oh');assert.equal(await page.$eval('#opening',e=>+e.value),amount);}
  for(const strength of [0,.25,.5,.75,1])for(const angle of ['0','45','90','-45','-90']){
   await page.evaluate(w=>{study.setEyes({surprised:w});study.setOpening(.65);},strength);await page.select('#angle',angle);
   await (await page.$('canvas')).screenshot({path:path.join(out,`${variant}-${strength}-${angle}.png`)});states.push({variant,strength,angle});
  }
 }
 const mixtures=[];for(const happy of [0,.5,1])for(const surprised of [0,.5,1])for(const blink of [0,.5,1]){
  const weights=await page.evaluate(v=>{study.setEyes({...v,relaxed:.3});return ['happy','angry','sad','surprised','relaxed','blink'].map(n=>study.current.expressionManager.getValue(n));},{happy,surprised,blink});assert.ok(weights.every(v=>Number.isFinite(v)&&v>=0)&&weights.filter((_,i)=>i!==3).reduce((a,b)=>a+b,0)<=1.000001&&weights[3]===surprised);mixtures.push(weights);
 }
 await page.click('#surprise-full');await page.click('#cycle');const motion=await page.evaluate(async()=>{const start=performance.now(),max={aa:0,ih:0,ou:0,ee:0,oh:0};while(performance.now()-start<7200){await new Promise(requestAnimationFrame);for(const k in max)max[k]=Math.max(max[k],study.current.expressionManager.getValue(k));}study.pause();return {max,ears:study.current.expressionManager.getValue('surprised')};});assert.ok(Object.values(motion.max).every(v=>v>.7));assert.equal(motion.ears,1);
 await page.click('#neutral');assert.ok((await page.evaluate(()=>['happy','angry','sad','surprised','relaxed','blink','aa','ih','ou','ee','oh'].map(n=>study.current.expressionManager.getValue(n)))).every(v=>v===0));
 await page.select('#angle','0');await page.click('#surprise-full');const layouts=[];
 for(const width of [1280,600,390]){await page.setViewport({width,height:1100});await page.waitForFunction(()=>document.querySelector('canvas').height===document.querySelector('canvas').clientHeight);const l=await page.evaluate(()=>({width:innerWidth,scrollWidth:document.documentElement.scrollWidth,canvasHeight:document.querySelector('canvas').clientHeight}));assert.ok(l.scrollWidth<=width&&l.canvasHeight>200);layouts.push(l);await page.screenshot({path:path.join(out,`controls-${width}.png`)});}
 assert.deepEqual(errors,[]);const a=await fs.readFile(path.join(root,'artifacts/surprise-ears/continuous-blink.vrm')),b=await fs.readFile(path.join(root,'artifacts/surprise-ears-repeat/continuous-blink.vrm'));assert.ok(a.equals(b));
 await fs.writeFile(path.join(root,'results/surprise-ears-evaluation.json'),JSON.stringify({scope:'mouth-only versus raised ear comparison',preserved,states,mixtures,motion,layouts,errors,repeatBytesEqual:true,sha256:createHash('sha256').update(a).digest('hex')},null,2)+'\n');console.log(JSON.stringify({preserved:preserved.length,states:states.length,mixtures:mixtures.length,motion,layouts,errors}));
}finally{if(browser)await browser.close();server.closeAllConnections();await new Promise(r=>server.close(r));}process.exit(0);
