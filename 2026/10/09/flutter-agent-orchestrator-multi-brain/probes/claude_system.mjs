// claude_system.mjs <mode> <cwd>: one Agent SDK query against a fake Anthropic API
// (ANTHROPIC_BASE_URL), to record what Claude Code sends as `system` and messages.
//   worker: the lab's worker options (no systemPrompt, settingSources user/project/local)
//   preset: the same with systemPrompt preset claude_code
//   custom: a string systemPrompt and settingSources []
const sdk = new URL('../sidecar/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs', import.meta.url);
const { query } = await import(sdk.href);
const [mode, cwd] = process.argv.slice(2);
const opts = { cwd, model: 'haiku', permissionMode: 'bypassPermissions', allowDangerouslySkipPermissions: true, persistSession: false };
if (mode === 'worker') opts.settingSources = ['user', 'project', 'local'];
if (mode === 'preset') { opts.settingSources = ['user', 'project', 'local']; opts.systemPrompt = { type: 'preset', preset: 'claude_code' }; }
if (mode === 'custom') { opts.settingSources = []; opts.systemPrompt = 'You are a test bot.'; }
for await (const m of query({ prompt: 'hi', options: opts })) { if (m.type === 'result') break; }
