// A stand-in for the model endpoint. It records what the runtime would send
// (instructions, tools, input) and answers with an error, so nothing reaches a
// real model and no tokens are used.

import { createServer } from 'node:http';
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { resultsDir } from './common.ts';

export async function startMock(name: string) {
  const requests: { method?: string; path?: string; body: unknown }[] = [];
  const server = createServer((req, res) => {
    let raw = '';
    req.on('data', (d) => (raw += d));
    req.on('end', () => {
      let body: unknown = raw;
      try {
        body = JSON.parse(raw);
      } catch {}
      requests.push({ method: req.method, path: req.url, body });
      writeFileSync(join(resultsDir, `${name}-mock-requests.json`), JSON.stringify(requests, null, 2));
      res.writeHead(400, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ type: 'error', error: { type: 'invalid_request_error', message: 'mock: captured' } }));
    });
  });
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  const port = (server.address() as { port: number }).port;
  return { url: `http://127.0.0.1:${port}`, requests, close: () => server.close() };
}
