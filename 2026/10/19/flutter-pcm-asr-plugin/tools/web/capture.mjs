import puppeteer from 'puppeteer-core';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const url = process.argv[2];
const browser = await puppeteer.launch({
  executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  headless: 'new',
  userDataDir: mkdtempSync(join(tmpdir(), 'pcm-asr-')),
  args: ['--autoplay-policy=no-user-gesture-required', '--no-first-run', '--window-size=1100,700'],
});
const page = await browser.newPage();
let done = false;
page.on('console', (m) => {
  const t = m.text();
  if (t.includes('PCM_ASR')) { console.log(t.slice(t.indexOf('PCM_ASR'))); if (t.includes('"kind":"done"')) done = true; }
  else console.error('console.' + m.type() + ': ' + t.slice(0, 300));
});
page.on('pageerror', (e) => console.error('pageerror: ' + e.message));
page.on('requestfailed', (r) => console.error('requestfailed: ' + r.url()));
page.on('response', (r) => { if (r.status() >= 400) console.error('http ' + r.status() + ': ' + r.url()); });
setTimeout(async () => { try { await page.screenshot({ path: process.env.SHOT || 'work/web.png' }); } catch {} }, 20000);
await page.goto(url, { waitUntil: 'load' });
const deadline = Date.now() + 240000;
while (!done && Date.now() < deadline) await new Promise((r) => setTimeout(r, 500));
await browser.close();
process.exit(done ? 0 : 1);
