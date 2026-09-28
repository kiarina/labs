import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
import puppeteer from 'puppeteer-core';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const out=path.join(root,'artifacts/connected-vowels');await fs.mkdir(out,{recursive:true});
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
 browser=await puppeteer.launch({executablePath:process.env.CHROME_BIN||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--hide-scrollbars']});
 const page=await browser.newPage(),errors=[],states=[];page.on('pageerror',e=>errors.push(String(e)));await page.setViewport({width:900,height:1000});
 await page.goto(`http://127.0.0.1:${server.address().port}/vowel-study.html?response=raw`);await page.waitForFunction(()=>window.ready);
 const canvas=await page.$('canvas'),vowels=['aa','ih','ou','ee','oh'],angles=['0','45','90','-45','-90'];
 const capture=async(name,weights,angle)=>{await page.evaluate(w=>study.applyWeights(w),weights);await page.select('#angle',angle);await canvas.screenshot({path:path.join(out,name+'.png')});states.push({name,weights,angle});};
 for(const vowel of vowels)for(const weight of [0,.1,.25,.5,1])for(const angle of angles)await capture(`${vowel}-${weight}-${angle}`,{[vowel]:weight},angle);
 for(let i=0;i<5;i++)for(let j=i+1;j<5;j++)for(const t of [.25,.5,.75])for(const angle of ['0','45','-90'])await capture(`mix-${vowels[i]}-${vowels[j]}-${t}-${angle}`,{[vowels[i]]:1-t,[vowels[j]]:t},angle);
 const pixels=()=>page.evaluate(()=>{const gl=study.renderer.getContext(),p=new Uint8Array(gl.drawingBufferWidth*gl.drawingBufferHeight*4);gl.readPixels(0,0,gl.drawingBufferWidth,gl.drawingBufferHeight,gl.RGBA,gl.UNSIGNED_BYTE,p);return Array.from(p);});
 const closed=[];await page.evaluate(()=>study.setOpening(0));for(const angle of angles){await page.select('#angle',angle);closed.push(await pixels());}
 await page.select('#variant','base');await page.waitForFunction(()=>window.ready);
 for(const [i,angle] of angles.entries()){await page.select('#angle',angle);assert.deepEqual(await pixels(),closed[i]);await canvas.screenshot({path:path.join(out,`base-${angle}.png`)});}
 await page.select('#variant','connected');await page.waitForFunction(()=>window.ready);await page.evaluate(()=>study.setOpening(1));await page.select('#angle','0');await canvas.screenshot({path:path.join(out,'accepted-aa.png')});
 await page.select('#variant','vowels');await page.waitForFunction(()=>window.ready);await page.select('#response','early');
 const onset=[];for(const vowel of vowels){await page.select('#vowel',vowel);for(const weight of [.1,.25]){await page.evaluate(w=>study.setOpening(w),weight);await canvas.screenshot({path:path.join(out,`early-${vowel}-${weight}.png`)});onset.push({vowel,input:weight,weight:await page.evaluate(v=>study.current.expressionManager.getValue(v),vowel)});}}
 await page.evaluate(()=>study.setOpening(.8));await page.click('#cycle');
 const animation=await page.evaluate(async()=>{let frames=0,maxSum=0;const seen=new Set(),start=performance.now();while(performance.now()-start<7200){await new Promise(requestAnimationFrame);const weights=['aa','ih','ou','ee','oh'].map(n=>[n,study.current.expressionManager.getValue(n)]);for(const [n,w] of weights)if(w>.4)seen.add(n);maxSum=Math.max(maxSum,weights.reduce((s,[,w])=>s+w,0));frames++;}return {frames,maxSum,seen:[...seen]};});assert.ok(animation.frames>30&&animation.maxSum<=1.000001&&animation.seen.length===5);
 await page.click('#close');assert.deepEqual(await pixels(),closed[0]);
 // Exercise normalization and reject nonfinite/negative driver values.
 await page.evaluate(()=>study.applyWeights({aa:2,ih:2,ou:-1,ee:NaN,oh:Infinity}));const weights=await page.evaluate(()=>['aa','ih','ou','ee','oh'].map(v=>study.current.expressionManager.getValue(v)));assert.deepEqual(weights,[.5,.5,0,0,0]);
 const layouts=[];for(const width of [1280,600,390]){await page.setViewport({width,height:900});await page.waitForFunction(()=>document.querySelector('canvas').height===document.querySelector('canvas').clientHeight);const layout=await page.evaluate(()=>({width:innerWidth,scrollWidth:document.documentElement.scrollWidth,canvasHeight:document.querySelector('canvas').clientHeight}));assert.ok(layout.scrollWidth<=width&&layout.canvasHeight>200);layouts.push(layout);await page.screenshot({path:path.join(out,`controls-${width}.png`)});}
 const bytes=await fs.readFile(path.join(root,'artifacts/mouth-connected-vowels/continuous-blink.vrm'));assert.deepEqual(bytes,await fs.readFile(path.join(root,'artifacts/mouth-connected-vowels-repeat/continuous-blink.vrm')));assert.equal(await sha(),expected);
 const accepted=await fs.readFile(path.join(root,'artifacts/mouth-connected-aa/continuous-blink.vrm'));assert.equal(createHash('sha256').update(accepted).digest('hex'),'2284dd720e3df4428701b819cb4b794a0e345d291340465830938406768d4912');assert.deepEqual(errors,[]);
 const report={date:new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Tokyo'}).format(new Date()),scope:'five pure vowels and normalized mixtures on one fixed surface; raw VRM weights versus optional onset response; no audio/eye expressions',states,onset,closedAnglesExact:angles,animation,layouts,errors,repeatByteIdentical:true,acceptedAAUnchanged:true,outputSha256:createHash('sha256').update(bytes).digest('hex')};await fs.writeFile(path.join(root,'results/connected-vowels-evaluation.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({states:states.length,animation,layouts,errors}));
}finally{if(browser)await browser.close();server.closeAllConnections();await new Promise(r=>server.close(r));}process.exit(0);
