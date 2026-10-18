// Opens a page in headless Chrome and prints `window.result` (or the JSON
// text in `window.resultJson`) once its `done` or `error` is set. Uses only Node built-ins
// (fetch + WebSocket, Node >= 22) and the Chrome DevTools Protocol.
//
//   CHROME=<path to chrome> node run_headless.mjs <url> [timeoutSec]
//
// On macOS CHROME defaults to the standard Google Chrome app location.
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const url = process.argv[2];
const timeoutSec = +(process.argv[3] || 600);
const chrome = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const port = 9300 + Math.floor(Math.random() * 500);
const profile = mkdtempSync(join(tmpdir(), 'wjs-chrome-'));
const proc = spawn(chrome, [
  '--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`,
  '--no-first-run', '--no-default-browser-check', 'about:blank',
], { stdio: 'ignore' });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let ws;
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
  await send('Page.navigate', { url });
  const t0 = Date.now();
  let result = null;
  while (Date.now() - t0 < timeoutSec * 1000) {
    await sleep(500);
    const r = await send('Runtime.evaluate', { expression: 'window.resultJson ?? JSON.stringify(window.result ?? null)', returnByValue: true });
    const v = r.result?.result?.value;
    if (v && v !== 'null') {
      const o = JSON.parse(v);
      if (o.done || o.error) { result = o; break; }
    }
  }
  console.log(JSON.stringify({ browser: version.product, url, result }, null, 2));
} finally {
  ws?.close();
  proc.kill();
  await sleep(300);
  rmSync(profile, { recursive: true, force: true });
}
process.exit(0);
