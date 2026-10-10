import 'dart:io';

import 'package:flutter/material.dart';

import '../agents/agent_check.dart';
import '../agents/mac_permissions.dart';
import '../agents/worker_types.dart';
import 'theme.dart';

/// The agents of one machine being edited: what `worker-types.json` will
/// say, and what was checked. The start screen edits this machine's
/// ([local]); a console edits a connected body's, its checks run on that
/// machine ([RemoteAgentChecker]) and logging in and granting permissions
/// stay on that machine's start screen.
class AgentsDraft extends ChangeNotifier {
  AgentsDraft(
    this.agents, {
    this.checker = const AgentChecker(),
    this.permissions = const MacPermissions(),
    this.local = true,
    String? projectDirDefault,
  }) : projectDirDefault =
           projectDirDefault ??
           Platform.environment['ORCH_CWD'] ??
           'the home folder';

  final WorkerTypesConfig agents;
  final AgentChecker checker;
  final MacPermissions permissions;

  /// This machine's agents (false: another machine's, through a console).
  final bool local;

  /// Where workers start when the project folder is empty.
  final String projectDirDefault;

  late final projectDir = TextEditingController(text: agents.projectDir ?? '');
  late int maxWorkers = agents.maxWorkers;
  late final codexCwd = TextEditingController(text: agents.codex.cwd ?? '');
  late final claudeCwd = TextEditingController(text: agents.claude.cwd ?? '');
  late final List<CustomDraft> custom = [
    for (final t in agents.custom) CustomDraft.from(t),
  ];

  /// Check results by id (`codex`, `claude`, a custom draft's key).
  final checks = <String, CheckResult?>{};
  final checking = <String>{};

  /// Requirements of the tools that drive the Mac or Chrome, by key
  /// (`codex-cu`, `claude-chrome`, `claude-mac`, `<draft>-cu`); null while
  /// checking.
  final reqs = <String, List<Requirement>?>{};

  /// This app's macOS permissions (null: not macOS).
  Map<String, bool>? perms;
  bool permsRead = false;

  /// Asked for Screen Recording on this run: it applies after a restart.
  bool screenAsked = false;

  bool _disposed = false;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// The ids turned on (custom ones as typed).
  List<String> get ids => [
    if (agents.codex.enabled) 'codex',
    if (agents.claude.enabled) 'claude',
    for (final c in custom)
      if (c.id.text.trim().isNotEmpty) c.id.text.trim(),
  ];

  String? cwd(TextEditingController t) =>
      t.text.trim().isEmpty ? null : t.text.trim();

  Future<void> check(String key, Future<CheckResult> Function() run) async {
    checking.add(key);
    checks[key] = null;
    _changed();
    final r = await run();
    checking.remove(key);
    checks[key] = r;
    _changed();
  }

  void checkCodex() => check('codex', () => checker.codex(cwd(codexCwd)));
  void checkClaude() => check('claude', () => checker.claude(cwd(claudeCwd)));
  void checkCustom(CustomDraft c) {
    final t = c.build();
    if (t.$2 != null) {
      checks[c.key] = CheckResult(false, t.$2!);
      _changed();
      return;
    }
    check(c.key, () => checker.custom(t.$1!));
  }

  void checkAll() {
    if (agents.codex.enabled) checkCodex();
    if (agents.claude.enabled) checkClaude();
    for (final c in custom) {
      checkCustom(c);
    }
    checkTools();
    readPermissions();
  }

  Future<void> require(
    String key,
    Future<List<Requirement>> Function() run,
  ) async {
    reqs[key] = null;
    _changed();
    final r = await run();
    reqs[key] = r;
    _changed();
  }

  void checkTools() {
    if (agents.codex.enabled && agents.codex.computerUse) {
      require('codex-cu', checker.computerUse);
    }
    if (agents.claude.enabled && agents.claude.chrome) {
      require('claude-chrome', checker.chrome);
    }
    if (agents.claude.enabled && agents.claude.mac) {
      require('claude-mac', checker.peekaboo);
    }
    for (final c in custom) {
      if (c.computerUse) require('${c.key}-cu', checker.computerUse);
    }
  }

  Future<void> readPermissions() async {
    final p = await permissions.status();
    perms = p;
    permsRead = true;
    _changed();
  }

  /// Asks macOS for one of this app's permissions (this machine only).
  Future<void> grant(String which) async {
    if (which == 'screenRecording') {
      await permissions.requestScreenRecording();
      screenAsked = true;
    } else {
      await permissions.requestAccessibility();
    }
    await readPermissions();
  }

  Future<void> loadModels(CustomDraft c) async {
    c
      ..loading = true
      ..modelsError = null;
    _changed();
    final (list, error) = await checker.models(
      c.baseUrl.text,
      c.envKey.text.trim(),
    );
    c
      ..loading = false
      ..modelsError = error
      ..models = list;
    // Keep the model if the server has it; else the first one.
    if (list != null &&
        list.isNotEmpty &&
        !list.any((m) => m.id == c.model.text)) {
      c.pick(list.first);
    }
    _changed();
  }

  /// The agents as typed, or why they cannot be saved. A brain needs at
  /// least one ([needOne]): its orchestrator runs on it.
  (WorkerTypesConfig?, String?) read({required bool needOne}) {
    final out = <WorkerType>[];
    final seen = <String>{};
    for (final c in custom) {
      final (t, e) = c.build();
      if (e != null) return (null, e);
      if (!seen.add(t!.id)) {
        return (null, 'Two custom agents are named "${t.id}".');
      }
      out.add(t);
    }
    final config = WorkerTypesConfig(
      codex: BuiltinSetup(
        enabled: agents.codex.enabled,
        cwd: cwd(codexCwd),
        model: agents.codex.model,
        maxConcurrent: agents.codex.maxConcurrent,
        computerUse: agents.codex.computerUse,
      ),
      claude: BuiltinSetup(
        enabled: agents.claude.enabled,
        cwd: cwd(claudeCwd),
        model: agents.claude.model,
        maxConcurrent: agents.claude.maxConcurrent,
        chrome: agents.claude.chrome,
        mac: agents.claude.mac,
      ),
      custom: out,
      projectDir: cwd(projectDir),
      maxWorkers: maxWorkers,
    );
    if (needOne && config.types.isEmpty) {
      return (
        null,
        'A brain needs at least one agent to run its orchestrator on.',
      );
    }
    return (config, null);
  }

  @override
  void dispose() {
    _disposed = true;
    projectDir.dispose();
    codexCwd.dispose();
    claudeCwd.dispose();
    for (final c in custom) {
      c.dispose();
    }
    super.dispose();
  }
}

/// Edits an [AgentsDraft]: this machine's project folder and (for a body)
/// how many workers at once, Codex and Claude on or off with their folders,
/// models, limits and tools, custom agents, and this app's macOS
/// permissions. Each agent is checked as it is turned on.
class AgentsEditor extends StatefulWidget {
  const AgentsEditor({super.key, required this.draft, this.onRestart});

  final AgentsDraft draft;

  /// Saves and starts this app again (Screen Recording applies after a
  /// restart); this machine only.
  final VoidCallback? onRestart;

  @override
  State<AgentsEditor> createState() => _AgentsEditorState();
}

class _AgentsEditorState extends State<AgentsEditor> {
  AgentsDraft get dr => widget.draft;

  @override
  void initState() {
    super.initState();
    dr.addListener(_repaint);
  }

  @override
  void didUpdateWidget(AgentsEditor old) {
    super.didUpdateWidget(old);
    if (old.draft != dr) {
      old.draft.removeListener(_repaint);
      dr.addListener(_repaint);
    }
  }

  @override
  void dispose() {
    dr.removeListener(_repaint);
    super.dispose();
  }

  void _repaint() {
    if (mounted) setState(() {});
  }

  Widget _status(String key) {
    if (dr.checking.contains(key)) {
      return const Text(
        'Checking…',
        style: TextStyle(fontSize: 12, color: Palette.textDim),
      );
    }
    final r = dr.checks[key];
    if (r == null) return const SizedBox.shrink();
    return Text(
      '${r.ok ? '✓' : '✗'} ${r.text}',
      key: Key('status-$key'),
      style: TextStyle(
        fontSize: 12,
        color: r.ok ? Palette.added : Palette.warning,
      ),
    );
  }

  Widget _builtin({
    required String id,
    required String label,
    required String sub,
    required BuiltinSetup setup,
    required TextEditingController cwd,
    required VoidCallback check,
    Widget? extra,
    List<Widget> tools = const [],
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: Key('agent-$id'),
          contentPadding: EdgeInsets.zero,
          value: setup.enabled,
          onChanged: (v) {
            setState(() => setup.enabled = v);
            if (v) check();
          },
          title: Text(label),
          subtitle: Text(sub, style: const TextStyle(fontSize: 12)),
        ),
        if (setup.enabled)
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: Key('cwd-$id'),
                        controller: cwd,
                        decoration: const InputDecoration(
                          labelText: 'Working folder (optional)',
                          hintText: '~/src',
                          helperText: 'Where its workers start. Empty: the project folder.',
                          isDense: true,
                        ),
                      ),
                    ),
                    TextButton(
                      key: Key('check-$id'),
                      onPressed: check,
                      child: const Text('Check'),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                _status(id),
                ?extra,
                if (dr.checks[id]?.models case final models?
                    when models.isNotEmpty)
                  DropdownButtonFormField<String?>(
                    key: Key('model-$id'),
                    initialValue: models.any((m) => m.id == setup.model)
                        ? setup.model
                        : null,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Default model for its workers',
                      isDense: true,
                    ),
                    items: [
                      DropdownMenuItem(
                        value: null,
                        child: Text(
                          'Default (${models.where((m) => m.isDefault).firstOrNull?.label ?? models.first.label ?? models.first.id})',
                        ),
                      ),
                      for (final m in models)
                        DropdownMenuItem(
                          value: m.id,
                          child: Text(m.label ?? m.id),
                        ),
                    ],
                    onChanged: (v) => setState(() => setup.model = v),
                  ),
                _atOnce(
                  'at-once-$id',
                  setup.maxConcurrent ?? 0,
                  (v) => setup.maxConcurrent = v == 0 ? null : v,
                ),
                ...tools,
              ],
            ),
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final codexCheck = dr.checks['codex'];
    final ids = dr.ids;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ..._machine(),
        _builtin(
          id: 'codex',
          label: 'Codex',
          sub: 'OpenAI Codex on your subscription.',
          setup: dr.agents.codex,
          cwd: dr.codexCwd,
          check: dr.checkCodex,
          tools: [
            _tool(
              key: 'codex-cu',
              label: 'Computer Use (Mac apps and Chrome)',
              value: dr.agents.codex.computerUse,
              onChanged: (v) => dr.agents.codex.computerUse = v,
              check: dr.checker.computerUse,
            ),
          ],
          extra: codexCheck != null && codexCheck.needsLogin && dr.local
              ? Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const Key('codex-login'),
                    onPressed: () => dr.check('codex', () async {
                      final r = await dr.checker.codexLogin();
                      return r.ok ? dr.checker.codex(dr.cwd(dr.codexCwd)) : r;
                    }),
                    child: const Text('Log in to Codex (opens the browser)'),
                  ),
                )
              : null,
        ),
        _builtin(
          id: 'claude',
          label: 'Claude',
          sub: 'Anthropic Claude Code on your subscription. To log in, run `claude auth login`.',
          setup: dr.agents.claude,
          cwd: dr.claudeCwd,
          check: dr.checkClaude,
          tools: [
            _tool(
              key: 'claude-chrome',
              label: 'Chrome (Claude in Chrome)',
              value: dr.agents.claude.chrome,
              onChanged: (v) => dr.agents.claude.chrome = v,
              check: dr.checker.chrome,
            ),
            _tool(
              key: 'claude-mac',
              label: 'Mac apps (Peekaboo)',
              value: dr.agents.claude.mac,
              onChanged: (v) => dr.agents.claude.mac = v,
              check: dr.checker.peekaboo,
            ),
          ],
        ),
        for (final d in dr.custom) _customCard(d),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('add-custom'),
            onPressed: () => setState(() => dr.custom.add(CustomDraft())),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add a custom agent (a Responses API server)'),
          ),
        ),
        _permissionsSection(theme),
        if (ids.isEmpty)
          Text(
            'None turned on: this body offers no workers, only its tools (fetch_image).',
            style: theme.textTheme.bodySmall?.copyWith(color: Palette.textDim),
          ),
      ],
    );
  }

  /// How many workers of one type may run at once on this body (0: only the
  /// body's own limit).
  Widget _atOnce(String key, int value, void Function(int) onChanged) =>
      Padding(
        padding: const EdgeInsets.only(top: 4, right: 8),
        child: Row(
          children: [
            const Text('At once', style: TextStyle(fontSize: 13)),
            Expanded(
              child: Slider(
                key: Key(key),
                value: value.toDouble(),
                max: 8,
                divisions: 8,
                label: value == 0 ? 'No limit of its own' : '$value',
                onChanged: (v) => setState(() => onChanged(v.round())),
              ),
            ),
            SizedBox(
              width: 64,
              child: Text(
                value == 0 ? 'No limit' : '$value',
                key: Key('$key-text'),
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      );

  /// This machine: its project folder, and for a body how many workers at
  /// once (all types together).
  List<Widget> _machine() => [
    TextField(
      key: const Key('project-dir'),
      controller: dr.projectDir,
      decoration: InputDecoration(
        labelText: 'Project folder (optional)',
        hintText: '~/src',
        helperText:
            'Where workers start when nothing else is set (and a brain on this app works, if it sets no folder). '
            'Empty: ${dr.projectDirDefault}.',
        helperMaxLines: 2,
        isDense: true,
      ),
    ),
    Padding(
      padding: const EdgeInsets.only(top: 8, right: 8),
      child: Row(
        children: [
          const Text(
            'Workers at once on this body',
            style: TextStyle(fontSize: 13),
          ),
          Expanded(
            child: Slider(
              key: const Key('max-workers'),
              value: dr.maxWorkers.toDouble(),
              min: 1,
              max: 16,
              divisions: 15,
              label: '${dr.maxWorkers}',
              onChanged: (v) => setState(() => dr.maxWorkers = v.round()),
            ),
          ),
          SizedBox(
            width: 32,
            child: Text('${dr.maxWorkers}', key: const Key('max-workers-text')),
          ),
        ],
      ),
    ),
    const SizedBox(height: 12),
  ];

  /// A switch for a tool that drives the Mac or Chrome, with what it needs
  /// on this machine once it is on.
  Widget _tool({
    required String key,
    required String label,
    String? sub,
    required bool value,
    required void Function(bool) onChanged,
    required Future<List<Requirement>> Function() check,
  }) {
    final reqs = dr.reqs[key];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: Key('tool-$key'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          value: value,
          title: Text(label, style: const TextStyle(fontSize: 13)),
          subtitle: sub == null
              ? null
              : Text(sub, style: const TextStyle(fontSize: 11)),
          onChanged: (v) {
            setState(() => onChanged(v));
            if (v) dr.require(key, check);
          },
        ),
        if (value)
          Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 6),
            child: reqs == null
                ? const Text(
                    'Checking…',
                    style: TextStyle(fontSize: 12, color: Palette.textDim),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final r in reqs)
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${r.ok ? '✓' : '✗'} ${r.name}: ${r.detail}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: r.ok ? Palette.added : Palette.warning,
                                ),
                              ),
                            ),
                            if (!r.ok && r.grant != null && dr.local)
                              TextButton(
                                key: Key('grant-$key-${r.grant}'),
                                onPressed: () async {
                                  await dr.grant(r.grant!);
                                  await dr.require(key, check);
                                },
                                child: const Text(
                                  'Grant',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                            if (!r.ok && r.settingsPane != null && dr.local)
                              TextButton(
                                key: Key('open-$key-${r.settingsPane}'),
                                onPressed: () => dr.permissions.openSettings(
                                  r.settingsPane!,
                                ),
                                child: const Text(
                                  'Open Settings',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                          ],
                        ),
                      TextButton(
                        key: Key('recheck-$key'),
                        onPressed: () => dr.require(key, check),
                        child: const Text(
                          'Check again',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
          ),
      ],
    );
  }

  /// This app's own macOS permissions: workers run as its children, so what
  /// they do in the shell (`screencapture`, a clicking AppleScript) is asked
  /// on its behalf.
  Widget _permissionsSection(ThemeData theme) {
    final p = dr.perms;
    Widget row(
      String name,
      String what,
      bool? ok,
      VoidCallback grant,
      String pane,
    ) => Row(
      children: [
        Expanded(
          child: Text(
            '${ok == true ? '✓' : '✗'} $name: ${ok == true ? 'granted' : 'not granted'} ($what)',
            style: TextStyle(
              fontSize: 12,
              color: ok == true ? Palette.added : Palette.warning,
            ),
          ),
        ),
        if (ok != true && dr.local) ...[
          TextButton(
            key: Key('grant-$pane'),
            onPressed: grant,
            child: const Text('Grant', style: TextStyle(fontSize: 12)),
          ),
          TextButton(
            onPressed: () => dr.permissions.openSettings(pane),
            child: const Text('Open Settings', style: TextStyle(fontSize: 12)),
          ),
        ],
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Divider(),
          Text(
            dr.local
                ? "This app's macOS permissions"
                : "The app's macOS permissions on that machine",
            style: theme.textTheme.titleSmall,
          ),
          Text(
            'Workers run inside this app, so macOS asks this app for what they do in the shell. '
            '${dr.local ? 'Grant them now, while you are here.' : 'Grant them on that machine (its start screen).'}',
            style: theme.textTheme.bodySmall?.copyWith(color: Palette.textDim),
          ),
          const SizedBox(height: 6),
          if (!dr.permsRead)
            const Text(
              'Checking…',
              style: TextStyle(fontSize: 12, color: Palette.textDim),
            )
          else if (p == null)
            const Text(
              'Not available here (not macOS)',
              style: TextStyle(fontSize: 12, color: Palette.textDim),
            )
          else ...[
            row(
              'Screen Recording',
              'screenshots: screencapture, Peekaboo',
              p['screenRecording'],
              () => dr.grant('screenRecording'),
              'Privacy_ScreenCapture',
            ),
            row(
              'Accessibility',
              'clicks and keys: AppleScript, Peekaboo',
              p['accessibility'],
              () => dr.grant('accessibility'),
              'Privacy_Accessibility',
            ),
            Wrap(
              children: [
                TextButton(
                  key: const Key('perm-recheck'),
                  onPressed: dr.readPermissions,
                  child: const Text(
                    'Check again',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                if (dr.screenAsked &&
                    p['screenRecording'] != true &&
                    widget.onRestart != null)
                  TextButton(
                    key: const Key('restart'),
                    onPressed: widget.onRestart,
                    child: const Text(
                      'Restart this app (Screen Recording applies after a restart)',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _customCard(CustomDraft d) {
    Widget field(
      String key,
      TextEditingController t,
      String label, {
      String? hint,
      String? help,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: TextField(
        key: Key('custom-${d.key}-$key'),
        controller: t,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: help,
          helperMaxLines: 2,
          isDense: true,
        ),
        onChanged: (_) => setState(() {}),
      ),
    );
    final models = d.models;
    final listed = models != null && models.isNotEmpty;
    return Card(
      key: Key('custom-${d.key}'),
      color: Palette.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: field(
                    'id',
                    d.id,
                    'Id (required)',
                    hint: 'kiapi',
                    help: 'The name the orchestrator uses. a-z, 0-9, _ and -; not codex or claude.',
                  ),
                ),
                IconButton(
                  tooltip: 'Remove',
                  onPressed: () => setState(() {
                    dr.custom.remove(d);
                    d.dispose();
                  }),
                  icon: const Icon(Icons.close, size: 16),
                ),
              ],
            ),
            field(
              'url',
              d.baseUrl,
              'Base URL (required)',
              hint: 'http://127.0.0.1:8500/v1',
              help: 'An OpenAI Responses API server, with its version (…/v1).',
            ),
            field(
              'key',
              d.envKey,
              'API key variable (optional)',
              hint: 'OPENROUTER_API_KEY',
              help: 'The name of an environment variable holding the key, not the key. Empty: no key.',
            ),
            Row(
              children: [
                Expanded(
                  child: listed
                      ? DropdownButtonFormField<String>(
                          key: Key('custom-${d.key}-model-list'),
                          initialValue: models.any((m) => m.id == d.model.text)
                              ? d.model.text
                              : null,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Model (required)',
                            isDense: true,
                          ),
                          items: [
                            for (final m in models)
                              DropdownMenuItem(
                                value: m.id,
                                child: Text(
                                  m.contextWindow == null
                                      ? m.id
                                      : '${m.id}  ·  ${m.contextWindow! ~/ 1000}K context',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (v) => setState(
                            () => d.pick(models.firstWhere((m) => m.id == v)),
                          ),
                        )
                      : field(
                          'model',
                          d.model,
                          'Model (required)',
                          hint: 'qwen3.8-flash-next',
                          help: models == null
                              ? 'Load the list from the server, or type the id.'
                              : 'The server has no model list: type the id.',
                        ),
                ),
                TextButton(
                  key: Key('load-${d.key}'),
                  onPressed: d.loading ? null : () => dr.loadModels(d),
                  child: Text(
                    d.loading
                        ? 'Loading…'
                        : listed
                        ? 'Reload'
                        : 'Load models',
                  ),
                ),
              ],
            ),
            if (d.modelsError case final e?)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '✗ $e',
                  style: const TextStyle(fontSize: 12, color: Palette.warning),
                ),
              ),
            field(
              'cwd',
              d.cwd,
              'Working folder (optional)',
              hint: '~/src',
              help: 'Where its workers start. Empty: the project folder.',
            ),
            field(
              'desc',
              d.description,
              'What it is good for (optional, read by the orchestrator)',
              hint: 'Local model: free and private, but slower. Small, well-specified tasks.',
            ),
            _atOnce(
              'custom-${d.key}-max',
              d.maxConcurrent,
              (v) => d.maxConcurrent = v,
            ),
            Row(
              children: [
                Expanded(child: _status(d.key)),
                TextButton(
                  key: Key('check-${d.key}'),
                  onPressed: () => dr.checkCustom(d),
                  child: const Text('Check'),
                ),
              ],
            ),
            _tool(
              key: '${d.key}-cu',
              label: 'Computer Use (Mac apps and Chrome)',
              sub: 'Runs on this machine\'s Codex setup (~/.codex) while on; its other servers stay off.',
              value: d.computerUse,
              onChanged: (v) => d.computerUse = v,
              check: dr.checker.computerUse,
            ),
          ],
        ),
      ),
    );
  }
}

/// A custom agent being typed.
class CustomDraft {
  CustomDraft() : key = 'c${_seq++}';

  factory CustomDraft.from(WorkerType t) => CustomDraft()
    ..id.text = t.id
    ..baseUrl.text = t.baseUrl ?? ''
    ..model.text = t.model ?? ''
    ..envKey.text = t.envKey ?? ''
    ..cwd.text = t.cwd ?? ''
    ..description.text = t.description
    ..maxConcurrent = t.maxConcurrent ?? 0
    ..computerUse = t.computerUse
    .._label = t.label
    .._contextWindow = t.contextWindow;

  static int _seq = 0;
  final String key;
  final id = TextEditingController();
  final baseUrl = TextEditingController();
  final model = TextEditingController();
  final envKey = TextEditingController();
  final cwd = TextEditingController();
  final description = TextEditingController();

  /// 0: no limit of its own (only the body's).
  int maxConcurrent = 0;
  bool computerUse = false;
  String? _label;
  int? _contextWindow;

  /// The server's models once loaded (empty: it has no list).
  List<ModelInfo>? models;
  String? modelsError;
  bool loading = false;

  void pick(ModelInfo m) {
    model.text = m.id;
    // The window of the model picked (unknown: the catalog's default).
    _contextWindow = m.contextWindow;
  }

  (WorkerType?, String?) build() {
    try {
      return (
        WorkerType.customFromJson({
          'id': id.text.trim(),
          'label': ?_label,
          'base_url': baseUrl.text.trim(),
          'model': model.text.trim(),
          'env_key': envKey.text.trim(),
          'cwd': cwd.text.trim(),
          'description': description.text.trim(),
          if (maxConcurrent > 0) 'max_concurrent': maxConcurrent,
          'context_window': ?_contextWindow,
          'computer_use': computerUse,
        }),
        null,
      );
    } on FormatException catch (e) {
      return (null, e.message);
    }
  }

  void dispose() {
    for (final t in [id, baseUrl, model, envKey, cwd, description]) {
      t.dispose();
    }
  }
}
