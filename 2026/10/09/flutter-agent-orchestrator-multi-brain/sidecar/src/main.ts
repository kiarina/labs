// A stdio bridge between the Flutter app and the Claude Agent SDK.
//
// The SDK only runs in Node/Python, so the Dart app talks to this process
// with newline-delimited JSON, shaped like JSON-RPC without the "jsonrpc"
// field (the same framing as `codex app-server`):
//
//   app -> bridge   {"id", "method", "params"}     requests
//   bridge -> app   {"id", "result" | "error"}     responses
//   bridge -> app   {"method", "params"}           notifications (SDK messages)
//   bridge -> app   {"id", "method", "params"}     requests (permission prompts)
//   app -> bridge   {"id", "result"}               responses to those
//
// SDK messages are forwarded as they are (`sdk/message`), so the app sees the
// SDK's own shapes. The bridge only owns what Dart cannot do: running `query()`,
// feeding its streaming input, and answering `canUseTool`.

import { randomUUID } from 'node:crypto';
import { createInterface } from 'node:readline';
import { z } from 'zod';
import {
  query,
  tool,
  createSdkMcpServer,
  getSessionInfo,
  listSessions,
  getSessionMessages,
  renameSession,
  tagSession,
  deleteSession,
  type Query,
  type SDKUserMessage,
  type PermissionResult,
  type CanUseTool,
  type PermissionMode,
  type EffortLevel,
} from '@anthropic-ai/claude-agent-sdk';

type Json = Record<string, any>;

// When the app is started from inside a Claude Code host (a terminal in the
// Claude desktop app, or `open` run by an agent), the host's variables leak
// in: CLAUDECODE, CLAUDE_CODE_* (host session, messaging socket, host auth)
// and ANTHROPIC_BASE_URL pointing at the host. Claude Code would then run as
// a child of that host and borrow its auth. Drop them, so the SDK uses the
// user's own `claude auth login`.
const hostedBy = process.env.CLAUDECODE ? process.env.CLAUDE_CODE_ENTRYPOINT ?? 'unknown' : null;
const sdkEnv: Record<string, string | undefined> = Object.fromEntries(
  Object.entries(process.env).filter(
    ([k]) =>
      !(
        k === 'CLAUDECODE' ||
        k.startsWith('CLAUDE_CODE_') ||
        k === 'CLAUDE_AGENT_SDK_VERSION' ||
        k === 'CLAUDE_PID' ||
        k === 'CLAUDE_EFFORT' ||
        k.startsWith('CLAUDE_PREVIEW_') ||
        (hostedBy !== null && k === 'ANTHROPIC_BASE_URL')
      ),
  ),
);

function write(message: Json) {
  process.stdout.write(JSON.stringify(message) + '\n');
}

function notify(method: string, params: Json) {
  write({ method, params });
}

// ---- requests to the app (permission prompts) -------------------------------

let nextOutgoingId = 0;
const outgoing = new Map<number, (result: any) => void>();

function requestApp(method: string, params: Json): Promise<any> {
  const id = ++nextOutgoingId;
  return new Promise((resolve) => {
    outgoing.set(id, resolve);
    write({ id, method, params });
  });
}

// ---- sessions ---------------------------------------------------------------

type SessionConfig = {
  cwd: string;
  model?: string;
  effort?: EffortLevel;
  permissionMode?: PermissionMode;
  /// Claude in Chrome (`claude --chrome`).
  chrome?: boolean;
  /// Mac control through Peekaboo's MCP server (`peekaboo mcp`). Claude
  /// Code's own computer use is not reachable from the SDK.
  /// `--allow-foreground`: without it Peekaboo only acts in the background
  /// and refuses to launch apps; each action still goes through canUseTool.
  peekaboo?: boolean;
  /// Tools the app implements (the orchestrator's start_thread, wait, ...),
  /// as {name, description, inputSchema (JSON Schema)}. Exposed to Claude as
  /// the in-process MCP server "orchestrator"; calls go back to the app as
  /// `tool/call` requests.
  appTools?: { name: string; description: string; inputSchema: Json }[];
  /// Appended to Claude Code's system prompt (the orchestrator's role).
  appendSystemPrompt?: string;
  /// Built-in tools to remove (the orchestrator does not edit files itself).
  disallowedTools?: string[];
  /// The only built-in tools to offer (the orchestrator has no hands: no
  /// Bash, no file tools).
  tools?: string[];
  /// Load MCP servers from [mcpServers] only, not from the user's or the
  /// project's settings (Computer Use, browsers, ...).
  strictMcpConfig?: boolean;
};

// GUI apps do not get the shell PATH; Homebrew's peekaboo by default.
const peekabooBin = process.env.PEEKABOO_BIN ?? '/opt/homebrew/bin/peekaboo';
/// `--no-remote`: Peekaboo acts inside this process tree, so macOS asks this
/// app (which the start screen can grant) instead of Peekaboo's background
/// service, a bare command that System Settings does not list until it
/// asks itself.
const peekabooArgs = ['mcp', 'serve', '--no-remote', '--allow-foreground'];

/// One live `query()` in streaming-input mode. Messages pushed into [input]
/// start a turn when idle, or are injected into the running turn ("steer").
class LiveSession {
  readonly input: SDKUserMessage[] = [];
  private wake?: () => void;
  private closed = false;
  running = false;
  readonly query: Query;
  readonly sessionId: string;

  constructor(sessionId: string, config: SessionConfig, resume: boolean) {
    this.sessionId = sessionId;
    const self = this;
    async function* stream(): AsyncGenerator<SDKUserMessage> {
      while (!self.closed) {
        while (self.input.length) yield self.input.shift()!;
        await new Promise<void>((r) => (self.wake = r));
      }
    }
    this.query = query({
      prompt: stream(),
      options: {
        cwd: config.cwd,
        model: config.model,
        effort: config.effort,
        permissionMode: config.permissionMode ?? 'default',
        // Lets the app switch to bypassPermissions later (its "Full access").
        allowDangerouslySkipPermissions: true,
        includePartialMessages: true,
        // Load ~/.claude and the project's .claude like Claude Code does
        // (CLAUDE.md, permissions, MCP servers, skills).
        settingSources: ['user', 'project', 'local'],
        ...(resume ? { resume: sessionId } : { sessionId }),
        canUseTool: (toolName, input, options) =>
          askPermission(sessionId, toolName, input, options),
        env: sdkEnv,
        ...(config.chrome ? { extraArgs: { chrome: null } } : {}),
        mcpServers: {
          ...(config.peekaboo
            ? { peekaboo: { type: 'stdio' as const, command: peekabooBin, args: peekabooArgs } }
            : {}),
          ...(config.appTools?.length ? { orchestrator: appToolServer(sessionId, config.appTools) } : {}),
        },
        ...(config.disallowedTools ? { disallowedTools: config.disallowedTools } : {}),
        ...(config.tools ? { tools: config.tools } : {}),
        ...(config.strictMcpConfig ? { strictMcpConfig: true } : {}),
        ...(config.appendSystemPrompt
          ? { systemPrompt: { type: 'preset' as const, preset: 'claude_code' as const, append: config.appendSystemPrompt } }
          : {}),
        stderr: (data) => notify('bridge/stderr', { sessionId, data }),
      },
    });
    void this.pump();
  }

  private async pump() {
    try {
      for await (const message of this.query) {
        if (message.type === 'system' && message.subtype === 'session_state_changed') {
          this.running = message.state !== 'idle';
        }
        if (message.type === 'result') this.running = false;
        notify('sdk/message', { sessionId: this.sessionId, message });
      }
    } catch (e) {
      notify('session/error', { sessionId: this.sessionId, message: String(e) });
    } finally {
      this.running = false;
      live.delete(this.sessionId);
      notify('session/closed', { sessionId: this.sessionId });
    }
  }

  send(text: string, priority?: 'now' | 'next' | 'later') {
    const message: SDKUserMessage = {
      type: 'user',
      message: { role: 'user', content: text },
      parent_tool_use_id: null,
      // While a turn runs, "now" injects the message into it (steer); the
      // app may ask for "next" (after the running turn) instead.
      ...(this.running ? { priority: priority ?? ('now' as const) } : {}),
    };
    this.running = true;
    this.input.push(message);
    this.wake?.();
  }

  close() {
    this.closed = true;
    this.wake?.();
    this.query.close();
  }
}

const live = new Map<string, LiveSession>();

async function askPermission(
  sessionId: string,
  toolName: string,
  input: Record<string, unknown>,
  options: Parameters<CanUseTool>[2],
): Promise<PermissionResult> {
  const pending = requestApp('permission/request', {
    sessionId,
    toolName,
    input,
    suggestions: options.suggestions ?? [],
    decisionReason: options.decisionReason,
    blockedPath: options.blockedPath,
    toolUseID: options.toolUseID,
    requestId: options.requestId,
  });
  // An interrupt aborts the prompt; tell the app to drop its card.
  const aborted = new Promise<PermissionResult>((resolve) => {
    options.signal.addEventListener('abort', () => {
      notify('permission/cancelled', { sessionId, requestId: options.requestId });
      resolve({ behavior: 'deny', message: 'Interrupted' });
    });
  });
  const answer = await Promise.race([pending, aborted]);
  if (answer.behavior === 'allow') {
    return {
      behavior: 'allow',
      updatedInput: answer.updatedInput ?? input,
      updatedPermissions: answer.updatedPermissions,
    };
  }
  return { behavior: 'deny', message: answer.message ?? 'Declined by the user' };
}

/// The app's tools as an in-process MCP server. The JSON Schemas come from
/// the app (one definition for both the Codex and the Claude orchestrator)
/// and are turned into zod shapes, which `tool()` requires.
function appToolServer(sessionId: string, specs: NonNullable<SessionConfig['appTools']>) {
  return createSdkMcpServer({
    name: 'orchestrator',
    tools: specs.map((spec) => {
      const schema = z.fromJSONSchema(spec.inputSchema as any) as unknown as z.ZodObject<any>;
      return tool(spec.name, spec.description, schema.shape, async (args) => {
        const r = await requestApp('tool/call', { sessionId, tool: spec.name, arguments: args });
        const images = (r?.images ?? []) as { mime: string; data: string }[];
        return {
          content: [
            { type: 'text' as const, text: String(r?.text ?? '') },
            ...images.map((i) => ({ type: 'image' as const, data: i.data, mimeType: i.mime })),
          ],
          isError: r?.success === false,
        };
        // Load up front; otherwise Claude first spends a ToolSearch call.
      }, { alwaysLoad: true });
    }),
  });
}

function liveOrStart(sessionId: string, config: SessionConfig): LiveSession {
  let s = live.get(sessionId);
  if (!s) {
    s = new LiveSession(sessionId, config, true);
    live.set(sessionId, s);
  }
  return s;
}

// ---- request handlers -------------------------------------------------------

const handlers: Record<string, (p: Json) => Promise<any>> = {
  /// Models and the signed-in account. Both need a running Claude Code, so a
  /// throwaway query is started without sending anything.
  async initialize(p) {
    const q = query({
      prompt: (async function* () {})(),
      options: { cwd: p.cwd, settingSources: ['user', 'project', 'local'], env: sdkEnv },
    });
    try {
      const [models, account] = await Promise.all([q.supportedModels(), q.accountInfo()]);
      return { models, account, hostedBy };
    } finally {
      q.close();
    }
  },

  /// Whether the optional tools a worker may get start here, without
  /// sending anything (no tokens): Claude in Chrome (`--chrome`, the Chrome
  /// extension) and Peekaboo's MCP server. Returns each server's status as
  /// Claude Code reports it (`connected`, `failed`, `pending`, ...).
  async 'check/tools'(p) {
    // Keep the input open until the check is done: an input that ends at
    // once shuts Claude Code down before the servers report.
    let done!: () => void;
    const finished = new Promise<void>((r) => (done = r));
    const q = query({
      prompt: (async function* () {
        await finished;
      })(),
      options: {
        cwd: p.cwd,
        settingSources: ['user', 'project', 'local'],
        env: sdkEnv,
        ...(p.chrome ? { extraArgs: { chrome: null } } : {}),
        mcpServers: p.peekaboo
          ? { peekaboo: { type: 'stdio' as const, command: peekabooBin, args: peekabooArgs } }
          : {},
      },
    });
    try {
      // Servers connect after start: ask until none is pending (10 s).
      let servers = await q.mcpServerStatus();
      for (let i = 0; i < 20 && servers.some((x) => x.status === 'pending'); i++) {
        await new Promise((r) => setTimeout(r, 500));
        servers = await q.mcpServerStatus();
      }
      return { servers: servers.map((x) => ({ name: x.name, status: x.status, error: (x as any).error })) };
    } finally {
      done();
      q.close();
    }
  },

  async 'session/start'(p) {
    const sessionId = randomUUID();
    const s = new LiveSession(sessionId, p as SessionConfig, false);
    live.set(sessionId, s);
    s.send(p.text);
    return { sessionId };
  },

  /// Sends a message to a session, resuming it in a new Claude Code process
  /// when none is running for it.
  async 'session/send'(p) {
    const s = liveOrStart(p.sessionId, p as SessionConfig);
    const steer = s.running;
    s.send(p.text, p.priority);
    return { steer };
  },

  async 'session/interrupt'(p) {
    await live.get(p.sessionId)?.query.interrupt();
    return {};
  },

  async 'session/close'(p) {
    live.get(p.sessionId)?.close();
    return {};
  },

  async 'session/setModel'(p) {
    await live.get(p.sessionId)?.query.setModel(p.model);
    return {};
  },

  async 'session/setEffort'(p) {
    await live.get(p.sessionId)?.query.applyFlagSettings({ effortLevel: p.effort });
    return {};
  },

  async 'session/setPermissionMode'(p) {
    await live.get(p.sessionId)?.query.setPermissionMode(p.mode);
    return {};
  },

  /// Context window use of a live session (what `/context` shows).
  async 'session/contextUsage'(p) {
    const s = live.get(p.sessionId);
    if (!s) return null;
    const u = await s.query.getContextUsage();
    return { totalTokens: u.totalTokens, maxTokens: u.maxTokens, percentage: u.percentage, model: u.model };
  },

  /// Metadata for the sessions the app remembers; null for ones that are gone.
  async 'session/infos'(p) {
    const infos = await Promise.all(
      (p.sessionIds as string[]).map((id) => getSessionInfo(id).catch(() => undefined)),
    );
    return { infos: infos.map((i) => i ?? null) };
  },

  /// Every session under ~/.claude/projects (the sidebar's "All").
  async 'session/list'(p) {
    return { sessions: await listSessions({ limit: p.limit ?? 50 }) };
  },

  async 'session/messages'(p) {
    const messages = await getSessionMessages(p.sessionId, { includeSystemMessages: false });
    return { messages, running: live.get(p.sessionId)?.running ?? false };
  },

  async 'session/rename'(p) {
    await renameSession(p.sessionId, p.title);
    return {};
  },

  /// Sections are session tags (null removes the tag).
  async 'session/tag'(p) {
    await tagSession(p.sessionId, p.tag ?? null);
    return {};
  },

  async 'session/delete'(p) {
    live.get(p.sessionId)?.close();
    await deleteSession(p.sessionId);
    return {};
  },
};

// ---- stdin loop -------------------------------------------------------------

const rl = createInterface({ input: process.stdin });
rl.on('line', async (line) => {
  if (!line.trim()) return;
  let msg: Json;
  try {
    msg = JSON.parse(line);
  } catch {
    return;
  }
  if (msg.method === undefined && msg.id !== undefined) {
    // A response to one of our requests.
    outgoing.get(msg.id)?.(msg.result ?? { behavior: 'deny', message: msg.error?.message });
    outgoing.delete(msg.id);
    return;
  }
  const handler = handlers[msg.method];
  if (!handler) {
    write({ id: msg.id, error: { code: -32601, message: `unknown method ${msg.method}` } });
    return;
  }
  try {
    write({ id: msg.id, result: await handler(msg.params ?? {}) });
  } catch (e: any) {
    write({ id: msg.id, error: { code: -32000, message: e?.message ?? String(e) } });
  }
});
rl.on('close', () => {
  for (const s of live.values()) s.close();
  process.exit(0);
});
