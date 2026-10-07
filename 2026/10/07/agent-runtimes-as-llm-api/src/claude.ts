// One request to the Claude Agent SDK, used like an LLM API:
// a fresh unsaved session, our own system prompt and tools only, the whole
// history in one user message. Tool calls are answered by the app (tools.ts)
// until the turn ends.
//
//   node src/claude.ts --mock   # send to the capture server instead (no tokens)
//   node src/claude.ts          # the real run (uses the Claude subscription)

import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { query, createSdkMcpServer, tool } from '@anthropic-ai/claude-agent-sdk';
import { z } from 'zod';
import { buildPrompt } from './fixture.ts';
import { systemPrompt, tools, handle } from './tools.ts';
import { startMock } from './mock.ts';
import { resultsDir, type Step, type RunResult } from './common.ts';

const mock = process.argv.includes('--mock');
const capture = mock ? await startMock('claude') : null;

// Do not inherit a host Claude Code session (this may run inside one).
const env: Record<string, string> = Object.fromEntries(
  Object.entries(process.env).filter(
    ([k, v]) =>
      v !== undefined &&
      !(k === 'CLAUDECODE' || k.startsWith('CLAUDE_CODE_') || k.startsWith('ANTHROPIC_') || k === 'CLAUDE_AGENT_SDK_VERSION'),
  ) as [string, string][],
);
if (capture) {
  env.ANTHROPIC_BASE_URL = capture.url;
  env.ANTHROPIC_API_KEY = 'mock';
}

const t0 = Date.now();
const steps: Step[] = [];

const server = createSdkMcpServer({
  name: 'app',
  version: '0',
  tools: tools.map((t) =>
    tool(
      t.name,
      t.description,
      (z.fromJSONSchema(t.inputSchema as any) as any).shape ?? {},
      async (args: Record<string, any>) => {
        firstEventMs ??= Date.now() - t0;
        steps.push({ type: 'tool_call', name: t.name, args, ms: Date.now() - t0 });
        return { content: [{ type: 'text', text: JSON.stringify(handle(t.name, args)) }] };
      },
      { alwaysLoad: true },
    ),
  ),
});

let firstEventMs: number | null = null;
let model: string | null = null;
let usage: unknown = null;
let costUsd: number | null = null;
let error: unknown = null;
let rateLimits: unknown = null;
let startupMs = 0;

const q = query({
  prompt: buildPrompt(),
  options: {
    cwd: mkdtempSync(join(tmpdir(), 'llm-api-probe-')),
    env,
    systemPrompt,
    tools: [],
    mcpServers: { app: server },
    strictMcpConfig: true,
    settingSources: [],
    allowedTools: tools.map((t) => `mcp__app__${t.name}`),
    permissionMode: 'bypassPermissions',
    allowDangerouslySkipPermissions: true,
    persistSession: false,
    // Otherwise Claude Code sends the whole prompt once more to name the session.
    title: 'llm-api-probe',
    maxTurns: 10,
  },
});

try {
for await (const m of q as AsyncIterable<any>) {
  switch (m.type) {
    case 'system':
      if (m.subtype === 'init') {
        model = m.model;
        startupMs = Date.now() - t0;
      }
      break;
    case 'assistant':
      for (const c of m.message.content ?? []) {
        if (c.type === 'text' && c.text.trim()) {
          firstEventMs ??= Date.now() - t0;
          steps.push({ type: 'message', text: c.text, ms: Date.now() - t0 });
        } else if (c.type === 'tool_use' && !String(c.name).startsWith('mcp__app__')) {
          steps.push({ type: 'other', item: c.name, detail: JSON.stringify(c.input).slice(0, 500), ms: Date.now() - t0 });
        }
      }
      break;
    case 'rate_limit_event':
      rateLimits = m.rate_limit_info ?? m;
      break;
    case 'result':
      usage = { usage: m.usage, modelUsage: m.modelUsage, num_turns: m.num_turns, duration_api_ms: m.duration_api_ms };
      costUsd = m.total_cost_usd ?? null;
      if (m.is_error || m.subtype !== 'success') error = { subtype: m.subtype, result: m.result, errors: m.errors };
      break;
  }
}
} catch (e) {
  error ??= String(e).slice(0, 2000);
}
capture?.close();

const result: RunResult = {
  runtime: 'claude',
  mock,
  model,
  startupMs,
  firstEventMs,
  totalMs: Date.now() - t0,
  steps,
  usage,
  rateLimitsAfter: rateLimits,
  costUsd,
  error,
};
const out = join(resultsDir, mock ? 'claude-mock.json' : 'claude.json');
writeFileSync(out, JSON.stringify(result, null, 2) + '\n');
console.log(`wrote ${out}`);
console.log(JSON.stringify({ steps: steps.length, error }, null, 1).slice(0, 1500));
process.exit(0);
