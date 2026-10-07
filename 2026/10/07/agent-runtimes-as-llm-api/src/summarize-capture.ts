// Summarizes a captured request: what the runtime adds around our prompt.
//   node src/summarize-capture.ts codex|claude <out-name>

import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { resultsDir } from './common.ts';

const [runtime, outName] = process.argv.slice(2);
const reqs = JSON.parse(readFileSync(join(resultsDir, `${runtime}-mock-requests.json`), 'utf8'));
const main = reqs.find((r: any) => r.body?.tools?.length || r.body?.input || r.body?.messages) ?? reqs[0];
const b = main.body;
const clip = (s: string, n = 160) => (s.length > n ? s.slice(0, n) + '…' : s).replace(/\n/g, ' ').replace(/\/(private\/)?var\/folders\/[^ ]*/g, '$TMPDIR/…');

function toolNames(ts: any[] = [], prefix = ''): string[] {
  return ts.flatMap((t) => (t.tools ? toolNames(t.tools, `${t.name}.`) : [`${prefix}${t.name ?? t.type}`]));
}

let summary: any;
if (runtime === 'codex') {
  summary = {
    path: main.path,
    model: b.model,
    reasoning: b.reasoning,
    instructionsChars: (b.instructions ?? '').length,
    tools: toolNames(b.tools),
    input: b.input.map((it: any) => ({
      type: it.type,
      role: it.role,
      chars: JSON.stringify(it.content ?? it.tools ?? it).length,
      tools: it.tools ? toolNames(it.tools) : undefined,
      head: it.content ? clip(it.content.map((c: any) => c.text ?? '').join('')) : undefined,
    })),
  };
} else {
  const sys = Array.isArray(b.system) ? b.system.map((s: any) => s.text).join('\n') : (b.system ?? '');
  summary = {
    requests: reqs.map((r: any) => `${r.method} ${r.path} ${r.body?.model ?? ''}`),
    path: main.path,
    model: b.model,
    thinking: b.thinking,
    systemChars: sys.length,
    systemHead: clip(sys, 600),
    tools: (b.tools ?? []).map((t: any) => t.name),
    toolsChars: JSON.stringify(b.tools ?? []).length,
    messages: b.messages.map((m: any) => ({
      role: m.role,
      blocks: (Array.isArray(m.content) ? m.content : [{ type: 'text', text: m.content }]).map((c: any) => ({
        type: c.type,
        chars: (c.text ?? JSON.stringify(c)).length,
        head: clip(c.text ?? ''),
      })),
    })),
  };
}
writeFileSync(join(resultsDir, `${outName}.json`), JSON.stringify(summary, null, 2) + '\n');
console.log(JSON.stringify(summary, null, 1).slice(0, 4000));
