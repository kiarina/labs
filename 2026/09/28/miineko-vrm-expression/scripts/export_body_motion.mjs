import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
import puppeteer from 'puppeteer-core';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
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
 browser=await puppeteer.launch({executablePath:process.env.CHROME_BIN||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--hide-scrollbars']});const page=await browser.newPage();await page.setViewport({width:960,height:1000});await page.goto(`http://127.0.0.1:${server.address().port}/body-study.html?motion=samba&angle=45`);await page.waitForFunction(()=>window.ready);const duration=await page.evaluate(()=>bodyStudy.duration),fps=15,frames=Math.ceil(duration*fps),folder=path.join(out,'samba-frames');await fs.mkdir(folder,{recursive:true});const canvas=await page.$('canvas');
 for(let i=0;i<frames;i++){await page.evaluate(t=>bodyStudy.seek(t),i/fps);await canvas.screenshot({path:path.join(folder,String(i).padStart(5,'0')+'.jpg'),type:'jpeg',quality:92});if(i%60===0)console.log(`frames ${i}/${frames}`);}
 // Repeatability after seeking backwards, and the user-facing recording control.
 const pixel=()=>page.evaluate(()=>bodyStudy.renderer.domElement.toDataURL());await page.evaluate(()=>bodyStudy.seek(4.55));const first=await pixel();await page.evaluate(()=>{bodyStudy.seek(bodyStudy.duration);bodyStudy.seek(0);bodyStudy.seek(4.55);});assert.equal(await pixel(),first);
 await page.evaluate(()=>bodyStudy.select('arms'));await page.click('#record');await page.waitForFunction(()=>!document.querySelector('#download').hidden,{timeout:15000});const video=await page.evaluate(async()=>{const blob=await(await fetch(document.querySelector('#download').href)).blob();return Array.from(new Uint8Array(await blob.arrayBuffer()));});assert.ok(video.length>1000);await fs.writeFile(path.join(out,'arms-recording.webm'),Buffer.from(video));
 await fs.writeFile(path.join(root,'results/body-motion-recording.json'),JSON.stringify({fps,frames,sourceDuration:duration,frameSampling:'absolute time i/15, no wall-clock timing dependency',seekRepeatable:true,uiRecordingBytes:video.length},null,2)+'\n');console.log(JSON.stringify({fps,frames,duration,uiRecordingBytes:video.length}));
}finally{if(browser)await browser.close();server.closeAllConnections();await new Promise(r=>server.close(r));}process.exit(0);
