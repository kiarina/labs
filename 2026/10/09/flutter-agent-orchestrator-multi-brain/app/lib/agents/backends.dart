import 'dart:async';
import 'dart:convert';

import '../rpc/rpc_client.dart';
import '../state/thread_view.dart';
import 'agent_thread.dart';

/// A tool the orchestrator can call: {name, description, inputSchema}.
typedef ToolSpec = Map<String, dynamic>;

/// What an orchestrator tool call returns: text, success, and images
/// (`{mime, data}` with base64 data) for the model to look at.
class ToolResult {
  const ToolResult(this.text, this.ok, [this.images = const []]);

  final String text;
  final bool ok;
  final List<Map<String, dynamic>> images;
}

/// Runs an orchestrator tool call.
typedef ToolHandler = Future<ToolResult> Function(
  AgentThread caller,
  String tool,
  Map<String, dynamic> args,
);

/// What a thread is for: the orchestrator gets the tools and a read-only
/// sandbox; workers run with full access and no prompts.
class AgentRole {
  const AgentRole.worker() : tools = const [], instructions = null;

  const AgentRole.orchestrator({
    required this.tools,
    required this.instructions,
  });

  final List<ToolSpec> tools;
  final String? instructions;

  bool get isOrchestrator => instructions != null;
}

// ---- Codex (`codex app-server`) ---------------------------------------------

class CodexBackend {
  CodexBackend(
    this.client, {
    required this.onTool,
    this.workerType = 'codex',
  });

  final RpcClient client;

  /// The worker type this app-server runs: `codex`, or a custom one whose
  /// model provider is another server.
  final String workerType;

  /// Per-thread settings for workers (`thread/start`'s `config`): which
  /// tools they get. Null: everything the app-server has.
  Json? workerConfig;
  final ToolHandler onTool;
  final _threads = <String, CodexAgent>{};
  List<Json> models = const [];
  Json? account;
  Json? rateLimits;
  void Function()? onChanged;

  Future<void> start() async {
    await client.start();
    client.notifications.listen(_onNotification);
    client.requests.listen(_onRequest);
    await client.request('initialize', {
      'clientInfo': {
        'name': 'agent_orchestrator',
        'title': 'Agent Orchestrator (lab)',
        'version': '0.1.0',
      },
      // Dynamic tools (the orchestrator's tools) are experimental.
      'capabilities': {'experimentalApi': true, 'requestAttestation': false},
    });
    client.notify('initialized');
    final r = await client.request('model/list', {}) as Map;
    models = (r['data'] as List).cast<Map>().map((m) {
      return <String, dynamic>{
        'id': m['id'],
        'displayName': m['displayName'],
        'isDefault': m['isDefault'],
        'supportedEffortLevels': [
          for (final e
              in (m['supportedReasoningEfforts'] as List? ?? const [])
                  .cast<Map>())
            e['reasoningEffort'],
        ],
        'defaultEffort': m['defaultReasoningEffort'],
      };
    }).toList();
    final a = await client.request('account/read', {}) as Map;
    account = (a['account'] as Map?)?.cast<String, dynamic>();
    try {
      final rl = await client.request('account/rateLimits/read') as Map;
      rateLimits = (rl['rateLimits'] as Map?)?.cast<String, dynamic>();
    } on RpcError {
      // API-key auth has none.
    }
  }

  String? get defaultModel =>
      (models.where((m) => m['isDefault'] == true).firstOrNull ??
              models.firstOrNull)?['id']
          as String?;

  CodexAgent create({
    required String label,
    required String cwd,
    required AgentRole role,
    String? title,
    String? model,
    String? effort,
  }) => CodexAgent(
    this,
    label: label,
    cwd: cwd,
    role: role,
    title: title,
    model: model,
    effort: effort,
  );

  void _register(CodexAgent agent) => _threads[agent.backendId!] = agent;

  void _onNotification(ServerNotification n) {
    if (n.method == 'account/rateLimits/updated') {
      final update = (n.params['rateLimits'] as Map).cast<String, dynamic>();
      rateLimits = {
        ...?rateLimits,
        for (final e in update.entries)
          if (e.value != null) e.key: e.value,
      };
      onChanged?.call();
      return;
    }
    final id =
        n.params['threadId'] as String? ??
        (n.params['thread'] as Map?)?['id'] as String?;
    final agent = id == null ? null : _threads[id];
    if (agent == null) return;
    agent.view.handleCodexNotification(n);
    if (n.method == 'turn/completed') agent.onTurnFinished();
  }

  Future<void> _onRequest(ServerRequest r) async {
    final agent = _threads[r.params['threadId']];
    if (r.method == 'item/tool/call' && agent != null) {
      final args = (r.params['arguments'] as Map? ?? const {})
          .cast<String, dynamic>();
      try {
        final result = await onTool(agent, r.params['tool'] as String, args);
        client.respond(r.id, {
          'contentItems': [
            {'type': 'inputText', 'text': result.text},
            for (final i in result.images)
              {
                'type': 'inputImage',
                'imageUrl': 'data:${i['mime']};base64,${i['data']}',
              },
          ],
          'success': result.ok,
        });
      } catch (e) {
        client.respond(r.id, {
          'contentItems': [
            {'type': 'inputText', 'text': 'error: $e'},
          ],
          'success': false,
        });
      }
      return;
    }
    // Threads run with approvalPolicy "never"; anything else that asks is
    // declined so the agent does not hang.
    client.respondError(r.id, -32000, 'not supported by this client');
  }
}

/// Codex features turned off for the orchestrator's thread: the shell
/// (`exec_command`, `write_stdin`), Computer Use and browsers, apps and
/// plugins, goals. What stays: its own tools, `apply_patch` (refused by the
/// read-only sandbox), `view_image`, MCP resource reads.
const _orchestratorFeaturesOff = {
  'shell_tool': false,
  'unified_exec': false,
  'computer_use': false,
  'browser_use': false,
  'browser_use_external': false,
  'in_app_browser': false,
  'apps': false,
  'plugins': false,
  'goals': false,
  'image_generation': false,
  'multi_agent': false,
};

class CodexAgent extends AgentThread {
  CodexAgent(
    this.backend, {
    required super.label,
    required super.cwd,
    required this.role,
    super.title,
    super.model,
    super.effort,
  }) : super(workerType: backend.workerType);

  final CodexBackend backend;
  final AgentRole role;

  RpcClient get _c => backend.client;

  Json get _sandboxPolicy => role.isOrchestrator
      ? {'type': 'readOnly', 'networkAccess': false}
      : {'type': 'dangerFullAccess'};

  @override
  Future<void> start(String text) async {
    final r = await _c.request('thread/start', {
      'cwd': cwd,
      'model': ?model,
      'approvalPolicy': 'never',
      'sandbox': role.isOrchestrator ? 'read-only' : 'danger-full-access',
      if (role.isOrchestrator) ...{
        'dynamicTools': [
          for (final t in role.tools) {'type': 'function', ...t},
        ],
        'developerInstructions': role.instructions,
        // The orchestrator has no hands: without these it ran Computer Use on
        // the brain's machine itself instead of starting a worker on the body
        // the user named. Per-thread, so workers on this app-server keep them.
        'config': {'features': _orchestratorFeaturesOff},
      } else
        'config': ?backend.workerConfig,
    }) as Map;
    view.threadId = (r['thread'] as Map)['id'] as String;
    model ??= r['model'] as String?;
    backend._register(this);
    await _turn(text);
  }

  Future<void> _turn(String text) async {
    markRunning();
    final r = await _c.request('turn/start', {
      'threadId': backendId,
      'input': [
        {'type': 'text', 'text': text, 'text_elements': <Object>[]},
      ],
      'model': ?model,
      'effort': ?effort,
      'approvalPolicy': 'never',
      'sandboxPolicy': _sandboxPolicy,
    }) as Map;
    view.startCodexTurn((r['turn'] as Map)['id'] as String);
  }

  @override
  Future<void> send(String text, {bool afterCurrentTurn = false}) async {
    final active = view.activeTurn;
    if (active == null) return _turn(text);
    // Codex adds steer input to the running turn (it does not end it).
    await _c.request('turn/steer', {
      'threadId': backendId,
      'expectedTurnId': active.id,
      'input': [
        {'type': 'text', 'text': text, 'text_elements': <Object>[]},
      ],
    });
  }

  @override
  Future<void> interrupt() async {
    final active = view.activeTurn;
    if (active == null) return;
    await _c.request('turn/interrupt', {
      'threadId': backendId,
      'turnId': active.id,
    });
  }

  @override
  Future<void> close() async {
    if (backendId == null) return;
    try {
      await _c.request('thread/unsubscribe', {'threadId': backendId});
    } on RpcError {
      // Already gone.
    }
  }
}

// ---- Claude (Agent SDK bridge) --------------------------------------------

class ClaudeBackend {
  ClaudeBackend(this.client, {required this.onTool});

  final RpcClient client;
  final ToolHandler onTool;
  final _sessions = <String, ClaudeAgent>{};

  /// What workers get besides files and the shell: Claude in Chrome, and
  /// Mac control through Peekaboo.
  bool workerChrome = false;
  bool workerMac = false;
  List<Json> models = const [];
  Json? account;
  Json? rateLimits;
  void Function()? onChanged;

  /// Permission prompts that need the user (AskUserQuestion of the
  /// orchestrator).
  void Function(ClaudeAgent agent, ServerRequest r)? onUserPrompt;

  Future<void> start(String cwd) async {
    await client.start();
    client.notifications.listen(_onNotification);
    client.requests.listen(_onRequest);
    final r = await client.request('initialize', {'cwd': cwd}) as Map;
    account = (r['account'] as Map?)?.cast<String, dynamic>();
    models = (r['models'] as List).cast<Map>().map((m) {
      return <String, dynamic>{
        'id': m['value'],
        'displayName': m['displayName'],
        'supportedEffortLevels': m['supportedEffortLevels'] ?? const [],
      };
    }).toList();
  }

  String? get defaultModel => models.firstOrNull?['id'] as String?;

  ClaudeAgent create({
    required String label,
    required String cwd,
    required AgentRole role,
    String? title,
    String? model,
    String? effort,
  }) => ClaudeAgent(
    this,
    label: label,
    cwd: cwd,
    role: role,
    title: title,
    model: model,
    effort: effort,
  );

  void _onNotification(ServerNotification n) {
    final agent = _sessions[n.params['sessionId']];
    switch (n.method) {
      case 'sdk/message':
        final m = (n.params['message'] as Map).cast<String, dynamic>();
        if (m['type'] == 'rate_limit_event') {
          rateLimits = (m['rate_limit_info'] as Map).cast<String, dynamic>();
          onChanged?.call();
          return;
        }
        if (agent == null) return;
        agent.view.handleSdkMessage(m);
        if (m['type'] == 'result') agent.onTurnFinished();
      case 'permission/cancelled':
        agent?.view.cancelPending(n.params['requestId'] as String);
      case 'session/error':
        agent?.view.addError(n.params['message'] as String);
    }
  }

  Future<void> _onRequest(ServerRequest r) async {
    final agent = _sessions[r.params['sessionId']];
    if (r.method == 'tool/call' && agent != null) {
      final args = (r.params['arguments'] as Map? ?? const {})
          .cast<String, dynamic>();
      try {
        final result = await onTool(agent, r.params['tool'] as String, args);
        client.respond(r.id, {
          'text': result.text,
          'success': result.ok,
          'images': result.images,
        });
      } catch (e) {
        client.respond(r.id, {'text': 'error: $e', 'success': false});
      }
      return;
    }
    if (r.method == 'permission/request' && agent != null) {
      if (r.params['toolName'] == 'AskUserQuestion') {
        if (agent.role.isOrchestrator && onUserPrompt != null) {
          onUserPrompt!(agent, r);
          agent.view.addPending(r);
          return;
        }
        // Workers have no user; the orchestrator talks to them.
        client.respond(r.id, {
          'behavior': 'deny',
          'message': 'No user is available in this thread. Decide yourself, or state the question in your final answer for the orchestrator.',
        });
        return;
      }
      // bypassPermissions: anything still asking is allowed.
      client.respond(r.id, {'behavior': 'allow'});
      return;
    }
    client.respond(r.id, {'behavior': 'deny', 'message': 'unknown session'});
  }
}

class ClaudeAgent extends AgentThread {
  ClaudeAgent(
    this.backend, {
    required super.label,
    required super.cwd,
    required this.role,
    super.title,
    super.model,
    super.effort,
  }) : super(workerType: 'claude');

  final ClaudeBackend backend;
  final AgentRole role;

  RpcClient get _c => backend.client;

  Json get _config => {
    'cwd': cwd,
    'model': ?model,
    'effort': ?effort,
    'permissionMode': 'bypassPermissions',
    if (role.isOrchestrator) ...{
      'appTools': role.tools,
      'appendSystemPrompt': role.instructions,
      // The orchestrator has no hands: no Bash, no file tools, and none of
      // the user's MCP servers (Computer Use, browsers). Only its own tools
      // (the in-process MCP server) and asking the user.
      'tools': ['AskUserQuestion', 'TodoWrite'],
      'strictMcpConfig': true,
      'disallowedTools': ['Edit', 'Write', 'MultiEdit', 'NotebookEdit', 'Bash'],
    } else ...{
      'chrome': backend.workerChrome,
      'peekaboo': backend.workerMac,
    },
  };

  @override
  Future<void> start(String text) async {
    markRunning();
    view.addUserTurn(text);
    final r =
        await _c.request('session/start', {..._config, 'text': text}) as Map;
    view.threadId = r['sessionId'] as String;
    backend._sessions[backendId!] = this;
  }

  @override
  Future<void> send(String text, {bool afterCurrentTurn = false}) async {
    markRunning();
    view.addUserTurn(text);
    await _c.request('session/send', {
      ..._config,
      'sessionId': backendId,
      'text': text,
      if (afterCurrentTurn) 'priority': 'next',
    });
  }

  @override
  Future<void> interrupt() async {
    if (!view.isRunning) return;
    view.requestInterrupt();
    await _c.request('session/interrupt', {'sessionId': backendId});
  }

  @override
  Future<void> close() async {
    if (backendId == null) return;
    await _c.request('session/close', {'sessionId': backendId});
  }
}

String prettyJson(Object? o) => const JsonEncoder.withIndent('  ').convert(o);
