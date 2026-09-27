import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import puppeteer from 'puppeteer-core';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const run=process.env.BLINK_RUN||'continuous-blink-obstacle';
if(!/^[a-z0-9-]+$/.test(run))throw new Error('Invalid run directory');
const output=path.join(root,'artifacts',run,'viewer');await fs.mkdir(output,{recursive:true});
// Fail before launching Chrome if the dependent export has not completed.
await fs.access(path.join(root,'artifacts',run,'continuous-blink.vrm'));
const mime={'.html':'text/html','.js':'text/javascript','.png':'image/png','.json':'application/json','.vrm':'model/gltf-binary'};
const server=http.createServer(async(req,res)=>{
 try{let pathname=decodeURIComponent(new URL(req.url,'http://localhost').pathname);if(pathname==='/favicon.ico'){res.statusCode=204;res.end();return;}if(pathname==='/')pathname='/viewer.html';const file=path.resolve(root,'.'+pathname);
 if(!file.startsWith(root+path.sep))throw new Error('outside root');const bytes=await fs.readFile(file);res.setHeader('Content-Type',mime[path.extname(file)]||'application/octet-stream');res.end(bytes);
 }catch{res.statusCode=404;res.end('Not found');}
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
let browser;
try{
 browser=await puppeteer.launch({executablePath:process.env.CHROME_BIN||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--hide-scrollbars']});
 const page=await browser.newPage();await page.setViewport({width:900,height:1000,deviceScaleFactor:1});
 const errors=[],warnings=[];page.on('pageerror',e=>errors.push(String(e)));page.on('console',m=>{if(['warn','error'].includes(m.type()))warnings.push(m.text());});
 await page.goto(`http://127.0.0.1:${server.address().port}/?model=${run}`);
 await page.waitForFunction(()=>window.ready,{timeout:60000});
 const report={chrome:await browser.version(),errors,warnings,states:[]};
 const canvas=await page.$('canvas');
 for(const a of [0,45,90]){
  await page.evaluate(a=>probe.set({w:0,a,visible:false}),a);await canvas.screenshot({path:path.join(output,`source-${a}.png`)});
  for(const w of [0,.25,.5,.75,1]){
   await page.evaluate(({w,a})=>probe.set({w,a,visible:true}),{w,a});
   report.states.push({w,a,lids:await page.evaluate(()=>probe.stats())});
   await canvas.screenshot({path:path.join(output,`blink-${w}-${a}.png`)});
  }
 }
 for(const e of ['blinkLeft','blinkRight']){
  await page.evaluate(e=>probe.set({w:1,a:0,e}),e);await canvas.screenshot({path:path.join(output,`${e}.png`)});
 }
 await fs.writeFile(path.join(output,'report.json'),JSON.stringify(report,null,2)+'\n');
 if(errors.length)throw new Error(errors.join('\n'));
 console.log(JSON.stringify({output,errors,warnings,states:report.states.length}));
}finally{if(browser)await browser.close();await new Promise(resolve=>server.close(resolve));}
