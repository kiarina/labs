// Drives echo.html in headless Chrome. mDNS host candidates are turned off:
// the app's native libwebrtc (flutter_webrtc) does not hide host addresses.
//   node run.mjs ws://127.0.0.1:8899 answer
import puppeteer from 'puppeteer-core';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const [signal = 'ws://127.0.0.1:8899', role = 'answer'] = process.argv.slice(2);
const chrome = process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const browser = await puppeteer.launch({
  executablePath: chrome,
  headless: true,
  // ECHO_ALL_IFACES=1: --use-fake-ui-for-media-stream grants media access,
  // and Chrome then gathers host candidates on every interface (as native
  // libwebrtc does). Without it, only on the default-route interface.
  args: ['--disable-features=WebRtcHideLocalIpsWithMdns', ...(process.env.ECHO_ALL_IFACES ? ['--use-fake-ui-for-media-stream'] : [])],
});
console.log('chrome', await browser.version());
const page = await browser.newPage();
page.on('console', (m) => {
  const t = m.text();
  console.log(t);
  if (t === 'echo KILL') { browser.process().kill('SIGKILL'); process.exit(0); }
  if (t === 'echo closed') setTimeout(() => browser.close().then(() => process.exit(0)), 3000);
  if (t === 'echo pc failed' || t === 'echo pc disconnected') setTimeout(() => browser.close().then(() => process.exit(0)), 1000);
});
// Served from http://127.0.0.1.
const file = path.join(path.dirname(fileURLToPath(import.meta.url)), 'echo.html');
const server = http.createServer((_, res) => { res.setHeader('content-type', 'text/html'); res.end(fs.readFileSync(file)); });
await new Promise((r) => server.listen(0, '127.0.0.1', r));
await page.goto(`http://127.0.0.1:${server.address().port}/echo.html?signal=${encodeURIComponent(signal)}&role=${role}${process.env.ECHO_VERBOSE ? '&verbose=1' : ''}`);
