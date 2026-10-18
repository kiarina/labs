// Runs the Flutter probe through its Start callback with a browser user gesture.
// Default: fake camera/microphone, headless Chrome and muted audio output.
// AEC_REAL=1: visible Chrome, real default devices and audible speaker output.
// AEC_ARTIFACT_DIR: explicitly export local PCM only with URL labtest=true.
// Prints `window.result` (or the JSON
// text in `window.resultJson`) once its `done` or `error` is set. Uses only Node built-ins
// (fetch + WebSocket, Node >= 22) and the Chrome DevTools Protocol.
//
//   CHROME=<path to chrome> node run_headless.mjs <url> [timeoutSec]
//
// On macOS CHROME defaults to the standard Google Chrome app location.
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const url = process.argv[2];
const timeoutSec = +(process.argv[3] || 600);
const chrome = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const port = 9300 + Math.floor(Math.random() * 500);
const profile = mkdtempSync(join(tmpdir(), 'wjs-chrome-'));
const real=process.env.AEC_REAL==='1';
const proc = spawn(chrome, [
  ...(real?[]:['--headless=new','--mute-audio']), `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`,
  '--autoplay-policy=no-user-gesture-required', ...(real?[]:['--use-fake-device-for-media-stream']), '--use-fake-ui-for-media-stream',
  '--no-first-run', '--no-default-browser-check', 'about:blank',
], { stdio: 'ignore' });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let ws;
let success = false;
try {
  let targets;
  for (let i = 0; i < 100; i++) {
    try { targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json(); break; } catch { await sleep(100); }
  }
  const page = targets.find((t) => t.type === 'page');
  ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((r) => ws.addEventListener('open', r));
  let id = 0; const pend = new Map();
  ws.addEventListener('message', (e) => {
    const m = JSON.parse(e.data);
    if (m.method === 'Runtime.consoleAPICalled') {
      process.stderr.write(`[console.${m.params.type}] ${m.params.args.map((a) => a.value ?? a.description).join(' ')}\n`);
    }
    if (m.id && pend.has(m.id)) { pend.get(m.id)(m); pend.delete(m.id); }
  });
  const send = (method, params = {}) => new Promise((r) => { const i = ++id; pend.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
  await send('Runtime.enable');
  const version = (await send('Browser.getVersion')).result;
  await send('Browser.grantPermissions',{origin:new URL(url).origin,permissions:['audioCapture','videoCapture']});
  await send('Page.navigate', { url });
  const t0 = Date.now();
  let result = null,started=false;
  while (Date.now() - t0 < timeoutSec * 1000) {
    await sleep(500);
    if(!started){const ready=await send('Runtime.evaluate',{expression:'typeof window.startAecProbe === \"function\"',returnByValue:true});if(ready.result?.result?.value){await send('Runtime.evaluate',{expression:'window.startAecProbe()',userGesture:true});started=true;}}
    const r = await send('Runtime.evaluate', { expression: 'window.resultJson ?? JSON.stringify(window.result ?? null)', returnByValue: true });
    const v = r.result?.result?.value;
    if (v && v !== 'null') {
      const o = JSON.parse(v);
      if (o.done || o.error || typeof o.pass === 'boolean') { result = o; break; }
    }
  }
  const artifacts=process.env.AEC_ARTIFACT_DIR;
  if(artifacts&&new URL(url).searchParams.get('labtest')==='true'&&result){
    mkdirSync(artifacts,{recursive:true});writeFileSync(join(artifacts,'report.json'),JSON.stringify(result,null,2));
    for(const name of ['raw','clean','mixed','near','reference','actual_render']){
      const size=await send('Runtime.evaluate',{expression:`window.aecDiagnostics['${name}'].length`,returnByValue:true});
      const length=size.result.result.value;const chunks=[];
      for(let offset=0;offset<length;offset+=65536){const response=await send('Runtime.evaluate',{expression:`Array.from(window.aecDiagnostics['${name}'].subarray(${offset},${offset+65536}))`,returnByValue:true});chunks.push(Buffer.from(response.result.result.value));}
      writeFileSync(join(artifacts,name+'.pcm'),Buffer.concat(chunks));
    }
  }
  console.log(JSON.stringify({ browser: version.product, realDevices:real, url, result }, null, 2));
  success = (!!result?.done || typeof result?.pass === 'boolean') && !result?.error && result?.pass === true;
} finally {
  ws?.close();
  proc.kill();
  await sleep(300);
  rmSync(profile, { recursive: true, force: true });
}
process.exit(success ? 0 : 1);
