// Grades results/<runtime>.json against the expected next actions.
//   node src/grade.ts codex|claude

import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { expected } from './fixture.ts';
import { resultsDir, type RunResult } from './common.ts';

const runtime = process.argv[2];
const r: RunResult = JSON.parse(readFileSync(join(resultsDir, `${runtime}.json`), 'utf8'));
const calls = r.steps.filter((s) => s.type === 'tool_call') as any[];
const messages = r.steps.filter((s) => s.type === 'message') as any[];
const sameSet = (a: string[] = [], b: string[]) => JSON.stringify([...a].map((x) => x.toLowerCase()).sort()) === JSON.stringify(b);

const ev = calls.find((c) => c.name === 'create_event')?.args;
const msg = calls.find((c) => c.name === 'send_message')?.args;
const finalText = messages.at(-1)?.text ?? '';
const e = expected.create_event;
const s = expected.send_message;
const to: string[] = (msg?.to ?? []).map((x: string) => x.toLowerCase());

const checks: Record<string, boolean> = {
  'called tools natively (no XML/JSON tool calls written as text)': !messages.some((m) => /<tool_call|"name"\s*:\s*"create_event"/.test(m.text)),
  'no built-in tools used': !r.steps.some((s) => s.type === 'other'),
  'create_event called': !!ev,
  'create_event before send_message': !!ev && !!msg && calls.indexOf(calls.find((c) => c.name === 'create_event')) < calls.indexOf(calls.find((c) => c.name === 'send_message')),
  'start is 2026-10-23T19:30': typeof ev?.start === 'string' && ev.start.startsWith(e.start),
  'duration is 120 minutes': ev?.duration_minutes === e.duration_minutes,
  'place_id is plc_0417': ev?.place_id === e.place_id,
  'attendees are exactly the 9 people': sameSet(ev?.attendees, e.attendees),
  'send_message called': !!msg,
  'message goes to the other 8 (the user optional)': s.must_include.every((x) => to.includes(x)) && to.every((x) => s.must_include.includes(x) || s.may_include.includes(x)),
  'message mentions the date, time and place': s.body_mentions.every((w) => String(msg?.body ?? '').includes(w)),
  'no stale facts (16th, 19:00, other places, 田中)': ![JSON.stringify(ev ?? {}), JSON.stringify(msg ?? {})].some(
    (t) => expected.wrong.dates.some((d) => t.includes(d)) || expected.wrong.place_ids.some((p) => t.includes(p)) || expected.wrong.attendees.some((a) => t.includes(a)) || /"start":"[^"]*T19:00/.test(t),
  ),
  'ends with a message to the user': !!finalText,
};
const passed = Object.values(checks).filter(Boolean).length;
const report = { runtime, model: r.model, passed: `${passed}/${Object.keys(checks).length}`, checks, toolCalls: calls.map((c) => ({ name: c.name, args: c.args })), finalText };
writeFileSync(join(resultsDir, `${runtime}-grade.json`), JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));
