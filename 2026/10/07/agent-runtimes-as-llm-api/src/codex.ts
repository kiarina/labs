// One request to codex app-server, used like an LLM API:
// a fresh ephemeral thread, our own instructions and tools, the whole history in
// one user message. Tool calls are answered by the app (tools.ts) until the
// turn ends.
//
//   node src/codex.ts --mock   # send to the capture server instead (no tokens)
//   node src/codex.ts          # the real run (uses the ChatGPT subscription)

import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildPrompt } from './fixture.ts';
import { systemPrompt, tools, handle } from './tools.ts';
import { startMock } from './mock.ts';
import { resultsDir, type Step, type RunResult } from './common.ts';

const mock = process.argv.includes('--mock');
const modelSlug = 'gpt-6.1-sol';
const capture = mock ? await startMock('codex') : null;

// Built-in tools and host integrations we do not want in an "API" call.
const features = Object.fromEntries(
  [
    'shell_tool', 'unified_exec', 'code_mode_host', 'multi_agent', 'apps', 'plugins', 'image_generation',
    'computer_use', 'browser_use', 'browser_use_external', 'in_app_browser', 'view_image', 'sleep_tool',
    'goals', 'tool_suggest', 'skill_search', 'hooks', 'workspace_dependencies', 'memories',
  ].map((f) => [f, false]),
);

// Process-level overrides (thread/start `config` does not reach these).
function codexArgs(): string[] {
  const args = Object.keys(features).flatMap((f) => ['--disable', f]);
  args.push('-c', 'web_search="disabled"');
  // Context Codex adds around the prompt (cwd, shell, sandbox, apps, modes).
  for (const k of ['include_environment_context', 'include_permissions_instructions', 'include_apps_instructions', 'include_collaboration_mode_instructions']) {
    args.push('-c', `${k}=false`);
  }
  // The list of skills (bundled system skills).
  args.push('-c', 'skills.include_instructions=false');
  // MCP servers from the user's config.toml.
  const toml = readFileSync(join(homedir(), '.codex', 'config.toml'), 'utf8');
  for (const [, name] of toml.matchAll(/^\[mcp_servers\.([^.\]]+)\]/gm)) {
    args.push('-c', `mcp_servers.${name}.enabled=false`);
  }
  // Newer models are marked "code_mode_only" in Codex's model catalog: the
  // app's tools are then only reachable from inside a JavaScript cell (`exec`).
  // A catalog of our own turns that and the multi-agent tools off.
  if (!process.argv.includes('--default-catalog')) {
    const cache = JSON.parse(readFileSync(join(homedir(), '.codex', 'models_cache.json'), 'utf8'));
    const base = cache.models.find((m: any) => m.slug === modelSlug);
    const entry = {
      ...base,
      tool_mode: null,
      multi_agent_version: null,
      apply_patch_tool_type: null,
      supports_search_tool: false,
      experimental_supported_tools: [],
      include_skills_usage_instructions: false,
      include_apps_usage_instructions: false,
      include_plugin_usage_instructions: false,
      node_repl_disabled: true,
    };
    const catalog = join(mkdtempSync(join(tmpdir(), 'llm-api-probe-catalog-')), 'models.json');
    writeFileSync(catalog, JSON.stringify({ models: [entry] }));
    args.push('-c', `model_catalog_json="${catalog}"`);
  }
  return args;
}

const proc = spawn(process.env.CODEX_BIN ?? 'codex', ['app-server', ...codexArgs()], { stdio: ['pipe', 'pipe', 'inherit'] });
let nextId = 0;
const pending = new Map<number, (m: any) => void>();
const send = (m: unknown) => proc.stdin.write(JSON.stringify(m) + '\n');
const request = (method: string, params: unknown) =>
  new Promise<any>((resolve) => {
    const id = ++nextId;
    pending.set(id, resolve);
    send({ id, method, params });
  });

const t0 = Date.now();
const steps: Step[] = [];
let usage: unknown = null;
let rateLimits: unknown = null;
let firstEventMs: number | null = null;
let model: string | null = null;
let turnError: unknown = null;
let resolveDone!: () => void;
const done = new Promise<void>((r) => (resolveDone = r));

createInterface({ input: proc.stdout }).on('line', (line) => {
  const m = JSON.parse(line);
  if ('id' in m && !('method' in m)) {
    pending.get(m.id)?.(m);
    pending.delete(m.id);
    return;
  }
  const p = m.params ?? {};
  switch (m.method) {
    case 'item/tool/call': {
      firstEventMs ??= Date.now() - t0;
      const args = p.arguments ?? {};
      steps.push({ type: 'tool_call', name: p.tool, args, ms: Date.now() - t0 });
      const out = handle(p.tool, args);
      send({ id: m.id, result: { contentItems: [{ type: 'inputText', text: JSON.stringify(out) }], success: true } });
      break;
    }
    case 'item/completed': {
      const it = p.item;
      if (it.type === 'agentMessage') {
        firstEventMs ??= Date.now() - t0;
        steps.push({ type: 'message', text: it.text, ms: Date.now() - t0 });
      } else if (it.type !== 'userMessage' && it.type !== 'dynamicToolCall' && it.type !== 'reasoning') {
        // Anything else (commands, file changes, web search) means a built-in leaked in.
        steps.push({ type: 'other', item: it.type, detail: JSON.stringify(it).slice(0, 500), ms: Date.now() - t0 });
      }
      break;
    }
    case 'thread/tokenUsage/updated':
      usage = p.tokenUsage ?? p;
      break;
    case 'account/rateLimits/updated':
      rateLimits = p.rateLimits ?? p;
      break;
    case 'error':
      turnError = p;
      break;
    case 'turn/completed':
      if (p.turn?.error) turnError = p.turn.error;
      resolveDone();
      break;
    default:
      if ('id' in m) send({ id: m.id, error: { code: -32601, message: 'not supported' } });
  }
});

await request('initialize', {
  clientInfo: { name: 'llm-api-probe', title: null, version: '0' },
  capabilities: { experimentalApi: true },
});
send({ method: 'initialized' });

const rl0 = mock ? null : await request('account/rateLimits/read', {});

const cwd = mkdtempSync(join(tmpdir(), 'llm-api-probe-'));
const config: Record<string, unknown> = {};
if (capture) {
  config.model_providers = { mock: { name: 'mock', base_url: `${capture.url}/v1`, wire_api: 'responses' } };
}
const started = await request('thread/start', {
  cwd,
  ephemeral: true,
  approvalPolicy: 'never',
  sandbox: 'read-only',
  baseInstructions: systemPrompt,
  dynamicTools: tools.map((t) => ({ type: 'function', ...t })),
  model: modelSlug,
  config,
  ...(capture ? { modelProvider: 'mock' } : {}),
});
if (started.error) throw new Error(JSON.stringify(started.error));
const threadId = started.result.thread.id;
model = started.result.model ?? null;

const prompt = buildPrompt();
const t1 = Date.now();
const turn = await request('turn/start', { threadId, input: [{ type: 'text', text: prompt, text_elements: [] }] });
if (turn.error) throw new Error(JSON.stringify(turn.error));
await Promise.race([done, new Promise((r) => setTimeout(r, mock ? 20_000 : 300_000))]);

const rl1 = mock ? null : await request('account/rateLimits/read', {});
proc.kill();
capture?.close();

const result: RunResult = {
  runtime: 'codex',
  mock,
  model,
  startupMs: t1 - t0,
  firstEventMs,
  totalMs: Date.now() - t0,
  steps,
  usage,
  rateLimitsBefore: rl0?.result ?? null,
  rateLimitsAfter: rl1?.result ?? rateLimits,
  error: turnError,
};
const out = join(resultsDir, mock ? 'codex-mock.json' : 'codex.json');
writeFileSync(out, JSON.stringify(result, null, 2) + '\n');
console.log(`wrote ${out}`);
console.log(JSON.stringify({ steps: steps.length, error: turnError }, null, 1));
process.exit(0);
