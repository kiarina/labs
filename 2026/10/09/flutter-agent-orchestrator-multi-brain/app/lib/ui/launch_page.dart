import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:orchestrator_signal/signal_server.dart';

import '../agents/agent_check.dart';
import '../agents/mac_permissions.dart';
import '../agents/worker_types.dart';
import '../mesh/launch.dart';
import 'theme.dart';

/// The first screen when no `ORCH_*` variables are set, in three steps:
///
/// 1. Signaling: start the server in this app (fails here when the port is
///    in use) or join one (fails here when it cannot be read).
/// 2. Roles: the name, and brain and/or body (neither: a console only).
/// 3. Owner, for a body: which brain it belongs to, from the roster read in
///    step 1.
/// 4. Agents, for a brain or a body: Codex and Claude on or off, custom ones
///    (a Responses API server) added freely, each checked as it is turned on
///    ([AgentChecker]). A body offers them as worker types; a brain runs its
///    orchestrator on one. Kept in `worker-types.json`.
class LaunchPage extends StatefulWidget {
  const LaunchPage({
    super.key,
    required this.initial,
    required this.ownersFile,
    required this.onStart,
    required this.typesFile,
    required this.stateDir,
    this.checker = const AgentChecker(),
    this.permissions = const MacPermissions(),
    this.error,
  });

  /// Where the start screen's choices are kept (`launch.json`).
  final String stateDir;
  final MacPermissions permissions;

  /// Where the agents chosen in step 4 are kept (`worker-types.json`).
  final File typesFile;
  final AgentChecker checker;

  final LaunchConfig initial;

  /// Where an in-app signaling server keeps body ownership.
  final File ownersFile;
  final void Function(LaunchConfig config, SignalServer? server) onStart;
  final String? error;

  @override
  State<LaunchPage> createState() => _LaunchPageState();
}

/// What the signaling server reports.
class _Roster {
  _Roster(this.brains, this.online, this.owners);

  final List<String> brains;
  final Set<String> online;
  final Map<String, String?> owners;
}

class _LaunchPageState extends State<LaunchPage> {
  late final LaunchConfig c = widget.initial;
  late final _name = TextEditingController(text: c.name);
  late final _port = TextEditingController(text: '${c.port}');
  late final _url = TextEditingController(text: c.url);
  late String? _error = widget.error;
  bool _busy = false;
  int _step = 0;

  /// The steps for the roles chosen so far.
  List<String> get _steps => [
    'Signaling',
    'Roles',
    if (c.body) 'Belongs to',
    if (c.brain || c.body) 'Agents',
  ];

  String get _stepName => _steps[_step.clamp(0, _steps.length - 1)];
  bool get _lastStep => _step >= _steps.length - 1;

  /// The next step, or start on the last one.
  void _advance() {
    if (_lastStep) {
      _start();
      return;
    }
    setState(() {
      _error = null;
      _step++;
    });
    if (_stepName == 'Agents') _checkAll();
  }

  /// The server started in step 1 (kept while going back and forth).
  SignalServer? _server;
  int? _serverPort;
  _Roster? _roster;
  bool _ownerTouched = false;

  @override
  void dispose() {
    _projectDir.dispose();
    _codexCwd.dispose();
    _claudeCwd.dispose();
    for (final d in _custom) {
      d.dispose();
    }
    _name.dispose();
    _port.dispose();
    _url.dispose();
    super.dispose();
  }

  // ---- step 1: signaling ----------------------------------------------------

  Future<void> _signalingNext() async {
    final port = int.tryParse(_port.text.trim());
    if (c.signaling && (port == null || port <= 0 || port > 65535)) {
      setState(() => _error = 'The port must be a number from 1 to 65535.');
      return;
    }
    c
      ..port = port ?? c.port
      ..url = _url.text.trim().isEmpty
          ? 'ws://localhost:8765'
          : _url.text.trim();
    setState(() {
      _busy = true;
      _error = null;
    });
    // Start, restart on another port, or stop the in-app server.
    if (_server != null && (!c.signaling || _serverPort != c.port)) {
      await _server!.close();
      _server = null;
    }
    if (c.signaling && _server == null) {
      final server = SignalServer(port: c.port, ownersFile: widget.ownersFile);
      try {
        await server.start();
        _server = server;
        _serverPort = c.port;
      } on SocketException catch (e) {
        setState(() {
          _busy = false;
          _error =
              'Could not start signaling on port ${c.port}: it is in use '
              '(${e.osError?.message ?? e.message}).';
        });
        return;
      }
    }
    final error = await _readRoster();
    setState(() {
      _busy = false;
      _error = error;
      if (error == null) _step = 1;
    });
  }

  /// Reads the roster over plain HTTP; returns an error, or null.
  Future<String?> _readRoster() async {
    final url = c.signalUrl;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final req = await client.getUrl(
        Uri.parse(url.replaceFirst(RegExp('^ws'), 'http')),
      );
      final res = await req.close().timeout(const Duration(seconds: 3));
      final j = jsonDecode(await res.transform(utf8.decoder).join()) as Map;
      final nodes = (j['nodes'] as List).cast<Map>();
      _roster = _Roster(
        [
          for (final n in nodes)
            if (n['brain'] == true && n['online'] == true) n['name'] as String,
        ]..sort(),
        {
          for (final n in nodes)
            if (n['online'] == true) n['name'] as String,
        },
        (j['owners'] as Map).cast<String, String?>(),
      );
      return null;
    } catch (e) {
      return 'Could not read the signaling server at $url.';
    } finally {
      client.close();
    }
  }

  // ---- step 2: roles --------------------------------------------------------

  void _rolesNext() {
    c.name = _name.text.trim();
    if (!c.body) {
      _advance();
      return;
    }
    // Where this body belongs: as before unless chosen on this screen.
    if (!_ownerTouched) {
      final known = _roster?.owners;
      if (known != null && c.name.isNotEmpty && known.containsKey(c.name)) {
        final o = known[c.name];
        c.owner = c.brain && o == c.name ? LaunchConfig.self : o;
      } else if (c.brain) {
        c.owner = LaunchConfig.self;
      }
    }
    if (!c.brain && c.owner == LaunchConfig.self) c.owner = null;
    _advance();
  }

  // ---- step 3: owner --------------------------------------------------------

  /// (value, label): this app if it is a brain, the brains online, and the
  /// saved choice (it may join later).
  List<(String, String)> get _brainChoices {
    final out = <String, String>{
      if (c.brain)
        LaunchConfig.self: '${c.name.isEmpty ? 'this app' : c.name} (this app)',
      for (final b in _roster?.brains ?? const <String>[])
        if (!(c.brain && b == c.name)) b: b,
    };
    if (c.owner case final o?
        when o != LaunchConfig.self && !out.containsKey(o)) {
      out[o] = '$o (offline)';
    }
    return [for (final e in out.entries) (e.key, e.value)];
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    final error = await _readRoster();
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  void _start() {
    if (c.brain || c.body) {
      final error = _saveAgents();
      if (error != null) {
        setState(() => _error = error);
        return;
      }
    }
    c.assignOwner = c.body;
    widget.onStart(c, _server);
  }

  // ---- step 4: agents -------------------------------------------------------

  late final WorkerTypesConfig _agents = () {
    try {
      return WorkerTypesConfig.load(widget.typesFile, Platform.environment);
    } catch (_) {
      return WorkerTypesConfig();
    }
  }();
  late final _projectDir = TextEditingController(
    text: _agents.projectDir ?? '',
  );
  late int _maxWorkers = _agents.maxWorkers;
  late final _codexCwd = TextEditingController(text: _agents.codex.cwd ?? '');
  late final _claudeCwd = TextEditingController(text: _agents.claude.cwd ?? '');
  late final List<_CustomDraft> _custom = [
    for (final t in _agents.custom) _CustomDraft.from(t),
  ];

  /// Check results by id (`codex`, `claude`, a custom draft's key).
  final _checks = <String, CheckResult?>{};
  final _checking = <String>{};

  Future<void> _check(String key, Future<CheckResult> Function() run) async {
    setState(() {
      _checking.add(key);
      _checks[key] = null;
    });
    final r = await run();
    if (!mounted) return;
    setState(() {
      _checking.remove(key);
      _checks[key] = r;
    });
  }

  String? _cwd(TextEditingController t) =>
      t.text.trim().isEmpty ? null : t.text.trim();

  void _checkCodex() =>
      _check('codex', () => widget.checker.codex(_cwd(_codexCwd)));
  void _checkClaude() =>
      _check('claude', () => widget.checker.claude(_cwd(_claudeCwd)));
  void _checkCustom(_CustomDraft d) {
    final t = d.build();
    if (t.$2 != null) {
      setState(() => _checks[d.key] = CheckResult(false, t.$2!));
      return;
    }
    _check(d.key, () => widget.checker.custom(t.$1!));
  }

  void _checkAll() {
    if (_agents.codex.enabled) _checkCodex();
    if (_agents.claude.enabled) _checkClaude();
    for (final d in _custom) {
      _checkCustom(d);
    }
    _checkTools();
    _readPermissions();
  }

  // ---- tools that drive the Mac or Chrome ----------------------------------

  /// Requirements by key (`codex-cu`, `claude-chrome`, `claude-mac`,
  /// `<draft>-cu`); null while checking.
  final _reqs = <String, List<Requirement>?>{};

  Future<void> _require(
    String key,
    Future<List<Requirement>> Function() run,
  ) async {
    setState(() => _reqs[key] = null);
    final r = await run();
    if (mounted) setState(() => _reqs[key] = r);
  }

  void _checkTools() {
    if (_agents.codex.enabled && _agents.codex.computerUse) {
      _require('codex-cu', widget.checker.computerUse);
    }
    if (_agents.claude.enabled && _agents.claude.chrome) {
      _require('claude-chrome', widget.checker.chrome);
    }
    if (_agents.claude.enabled && _agents.claude.mac) {
      _require('claude-mac', widget.checker.peekaboo);
    }
    for (final d in _custom) {
      if (d.computerUse) _require('${d.key}-cu', widget.checker.computerUse);
    }
  }

  Map<String, bool>? _perms;
  bool _permsRead = false;

  /// Asked for Screen Recording on this run: it applies after a restart.
  bool _screenAsked = false;

  Future<void> _readPermissions() async {
    final p = await widget.permissions.status();
    if (mounted) {
      setState(() {
        _perms = p;
        _permsRead = true;
      });
    }
  }

  /// Saves what is on the screen and starts the app again (Screen Recording
  /// applies to a running app only after a restart).
  Future<void> _restart() async {
    c
      ..name = _name.text.trim()
      ..port = int.tryParse(_port.text.trim()) ?? c.port
      ..url = _url.text.trim().isEmpty ? c.url : _url.text.trim();
    c.save(widget.stateDir);
    final (config, _) = _readAgents();
    config?.save(widget.typesFile);
    await _server?.close();
    await widget.permissions.relaunch();
  }

  /// The agents as typed, or why they cannot be saved.
  (WorkerTypesConfig?, String?) _readAgents() {
    final custom = <WorkerType>[];
    final ids = <String>{};
    for (final d in _custom) {
      final (t, e) = d.build();
      if (e != null) return (null, e);
      if (!ids.add(t!.id)) {
        return (null, 'Two custom agents are named "${t.id}".');
      }
      custom.add(t);
    }
    final config = WorkerTypesConfig(
      codex: BuiltinSetup(
        enabled: _agents.codex.enabled,
        cwd: _cwd(_codexCwd),
        model: _agents.codex.model,
        maxConcurrent: _agents.codex.maxConcurrent,
        computerUse: _agents.codex.computerUse,
      ),
      claude: BuiltinSetup(
        enabled: _agents.claude.enabled,
        cwd: _cwd(_claudeCwd),
        model: _agents.claude.model,
        maxConcurrent: _agents.claude.maxConcurrent,
        chrome: _agents.claude.chrome,
        mac: _agents.claude.mac,
      ),
      custom: custom,
      projectDir: _cwd(_projectDir),
      maxWorkers: _maxWorkers,
    );
    if (c.brain && config.types.isEmpty) {
      return (
        null,
        'A brain needs at least one agent to run its orchestrator on.',
      );
    }
    return (config, null);
  }

  String? _saveAgents() {
    final (config, error) = _readAgents();
    if (error != null) return error;
    config!.save(widget.typesFile);
    final ids = [for (final t in config.types) t.id];
    if (c.brain && !ids.contains(c.orchestrator)) c.orchestrator = ids.first;
    return null;
  }

  // ---- view -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final steps = _steps;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      for (var i = 0; i < steps.length; i++)
                        TextSpan(
                          text: '${i > 0 ? '   ' : ''}${i + 1}. ${steps[i]}',
                          style: i == _step
                              ? const TextStyle(
                                  color: Palette.text,
                                  fontWeight: FontWeight.w600,
                                )
                              : null,
                        ),
                    ],
                  ),
                  key: const Key('steps'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Palette.textFaint,
                  ),
                ),
                const SizedBox(height: 8),
                ...switch (_stepName) {
                  'Signaling' => _signalingStep(theme),
                  'Roles' => _rolesStep(theme),
                  'Belongs to' => _ownerStep(theme),
                  _ => _agentsStep(theme),
                },
                const SizedBox(height: 20),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _error!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                Row(
                  children: [
                    if (_step > 0)
                      TextButton(
                        key: const Key('back'),
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                _error = null;
                                _step--;
                              }),
                        child: const Text('Back'),
                      ),
                    const Spacer(),
                    FilledButton(
                      key: const Key('next'),
                      onPressed: _busy
                          ? null
                          : switch (_stepName) {
                              'Signaling' => _signalingNext,
                              'Roles' => _rolesNext,
                              _ => _advance,
                            },
                      child: Text(
                        _busy
                            ? 'Working…'
                            : _lastStep
                            ? 'Start'
                            : 'Next',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _title(ThemeData theme, String title, String sub) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          sub,
          style: theme.textTheme.bodySmall?.copyWith(color: Palette.textDim),
        ),
      ],
    ),
  );

  List<Widget> _signalingStep(ThemeData theme) => [
    _title(
      theme,
      'Signaling server',
      'Every app joins one. It keeps the roster and who owns which body.',
    ),
    RadioGroup<bool>(
      groupValue: c.signaling,
      onChanged: (v) => setState(() => c.signaling = v!),
      child: const Column(
        children: [
          RadioListTile(
            key: Key('signal-start'),
            value: true,
            title: Text('Start one in this app'),
          ),
          RadioListTile(
            key: Key('signal-join'),
            value: false,
            title: Text('Join one'),
          ),
        ],
      ),
    ),
    Padding(
      padding: const EdgeInsets.only(left: 56, right: 8),
      child: c.signaling
          ? TextField(
              key: const Key('port'),
              controller: _port,
              decoration: const InputDecoration(labelText: 'Port'),
              keyboardType: TextInputType.number,
              onSubmitted: (_) => _signalingNext(),
            )
          : TextField(
              key: const Key('url'),
              controller: _url,
              decoration: const InputDecoration(
                labelText: 'Signaling URL',
                hintText: 'ws://localhost:8765',
              ),
              onSubmitted: (_) => _signalingNext(),
            ),
    ),
  ];

  List<Widget> _rolesStep(ThemeData theme) {
    final name = _name.text.trim();
    final taken = name.isNotEmpty && (_roster?.online.contains(name) ?? false);
    final brains = _roster?.brains.length ?? 0;
    return [
      _title(
        theme,
        'This app',
        'Joined ${c.signalUrl} ($brains brain(s) there). Every app has a console; pick any of these.',
      ),
      TextField(
        key: const Key('name'),
        controller: _name,
        decoration: InputDecoration(
          labelText: 'Name (body id)',
          hintText: 'empty: host name and 4 random digits',
          helperText: taken
              ? 'An app named $name is online; this one will get a suffix (-2).'
              : null,
        ),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 12),
      CheckboxListTile(
        key: const Key('role-brain'),
        value: c.brain,
        onChanged: (v) => setState(() => c.brain = v!),
        title: const Text('Brain'),
        subtitle: const Text(
          'Runs an orchestrator. Consoles pick a brain to talk to.',
        ),
        controlAffinity: ListTileControlAffinity.leading,
      ),
      CheckboxListTile(
        key: const Key('role-body'),
        value: c.body,
        onChanged: (v) => setState(() => c.body = v!),
        title: const Text('Body'),
        subtitle: const Text(
          'Lets the brain it belongs to run workers on this machine.',
        ),
        controlAffinity: ListTileControlAffinity.leading,
      ),
      if (!c.brain && !c.body)
        Padding(
          padding: const EdgeInsets.only(left: 16, top: 4),
          child: Text(
            'Neither: this app is a console only.',
            style: theme.textTheme.bodySmall?.copyWith(color: Palette.textDim),
          ),
        ),
    ];
  }

  List<Widget> _ownerStep(ThemeData theme) {
    final choices = _brainChoices;
    return [
      _title(
        theme,
        'Belongs to',
        'Only this brain runs workers on this body. Consoles can move it later, while no workers run here.',
      ),
      Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<String?>(
              key: const Key('owner'),
              initialValue: choices.any((e) => e.$1 == c.owner)
                  ? c.owner
                  : null,
              decoration: const InputDecoration(labelText: 'Brain'),
              items: [
                const DropdownMenuItem(value: null, child: Text('No brain')),
                for (final (value, label) in choices)
                  DropdownMenuItem(value: value, child: Text(label)),
              ],
              onChanged: (v) => setState(() {
                c.owner = v;
                _ownerTouched = true;
              }),
            ),
          ),
          IconButton(
            key: const Key('refresh'),
            tooltip: 'Read the brains again',
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh, size: 18),
          ),
        ],
      ),
    ];
  }

  Widget _status(String key) {
    if (_checking.contains(key)) {
      return const Text(
        'Checking…',
        style: TextStyle(fontSize: 12, color: Palette.textDim),
      );
    }
    final r = _checks[key];
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
                if (_checks[id]?.models case final models?
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
                if (c.body)
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

  List<Widget> _agentsStep(ThemeData theme) {
    final codexCheck = _checks['codex'];
    final ids = [
      if (_agents.codex.enabled) 'codex',
      if (_agents.claude.enabled) 'claude',
      for (final d in _custom)
        if (d.id.text.trim().isNotEmpty) d.id.text.trim(),
    ];
    return [
      _title(
        theme,
        'Agents',
        [
          if (c.body)
            'The brain this body belongs to can start these as workers here.',
          if (c.brain) 'The orchestrator runs on one of them.',
          'Each is checked when turned on (no model tokens).',
        ].join(' '),
      ),
      ..._machine(),
      _builtin(
        id: 'codex',
        label: 'Codex',
        sub: 'OpenAI Codex on your subscription.',
        setup: _agents.codex,
        cwd: _codexCwd,
        check: _checkCodex,
        tools: [
          _tool(
            key: 'codex-cu',
            label: 'Computer Use (Mac apps and Chrome)',
            value: _agents.codex.computerUse,
            onChanged: (v) => _agents.codex.computerUse = v,
            check: widget.checker.computerUse,
          ),
        ],
        extra: codexCheck != null && codexCheck.needsLogin
            ? Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const Key('codex-login'),
                  onPressed: () => _check('codex', () async {
                    final r = await widget.checker.codexLogin();
                    return r.ok ? widget.checker.codex(_cwd(_codexCwd)) : r;
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
        setup: _agents.claude,
        cwd: _claudeCwd,
        check: _checkClaude,
        tools: [
          _tool(
            key: 'claude-chrome',
            label: 'Chrome (Claude in Chrome)',
            value: _agents.claude.chrome,
            onChanged: (v) => _agents.claude.chrome = v,
            check: widget.checker.chrome,
          ),
          _tool(
            key: 'claude-mac',
            label: 'Mac apps (Peekaboo)',
            value: _agents.claude.mac,
            onChanged: (v) => _agents.claude.mac = v,
            check: widget.checker.peekaboo,
          ),
        ],
      ),
      for (final d in _custom) _customCard(d),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const Key('add-custom'),
          onPressed: () => setState(() => _custom.add(_CustomDraft())),
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Add a custom agent (a Responses API server)'),
        ),
      ),
      _permissionsSection(theme),
      if (ids.isEmpty)
        Text(
          c.brain ? 'Turn on at least one: the orchestrator runs on it.' : 'None turned on: this body offers no workers, only its tools (fetch_image).',
          style: theme.textTheme.bodySmall?.copyWith(color: Palette.textDim),
        ),
      if (c.brain && ids.isNotEmpty) ...[
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          key: const Key('orchestrator'),
          initialValue: ids.contains(c.orchestrator)
              ? c.orchestrator
              : ids.first,
          decoration: const InputDecoration(
            labelText: 'The orchestrator runs on',
          ),
          items: [
            for (final id in ids) DropdownMenuItem(value: id, child: Text(id)),
          ],
          onChanged: (v) => setState(() => c.orchestrator = v),
        ),
      ],
    ];
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
      controller: _projectDir,
      decoration: InputDecoration(
        labelText: 'Project folder (optional)',
        hintText: '~/src',
        helperText:
            'Where workers start when nothing else is set${c.brain ? ', and where the orchestrator works' : ''}. '
            'Empty: ${Platform.environment['ORCH_CWD'] ?? 'the home folder'}.',
        helperMaxLines: 2,
        isDense: true,
      ),
    ),
    if (c.body)
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
                value: _maxWorkers.toDouble(),
                min: 1,
                max: 16,
                divisions: 15,
                label: '$_maxWorkers',
                onChanged: (v) => setState(() => _maxWorkers = v.round()),
              ),
            ),
            SizedBox(
              width: 32,
              child: Text('$_maxWorkers', key: const Key('max-workers-text')),
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
    final reqs = _reqs[key];
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
            if (v) _require(key, check);
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
                            if (!r.ok && r.grant != null)
                              TextButton(
                                key: Key('grant-$key-${r.grant}'),
                                onPressed: () async {
                                  await _grant(r.grant!);
                                  await _require(key, check);
                                },
                                child: const Text(
                                  'Grant',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                            if (!r.ok && r.settingsPane != null)
                              TextButton(
                                key: Key('open-$key-${r.settingsPane}'),
                                onPressed: () => widget.permissions
                                    .openSettings(r.settingsPane!),
                                child: const Text(
                                  'Open Settings',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                          ],
                        ),
                      TextButton(
                        key: Key('recheck-$key'),
                        onPressed: () => _require(key, check),
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

  /// Asks macOS for one of this app's permissions.
  Future<void> _grant(String which) async {
    if (which == 'screenRecording') {
      await widget.permissions.requestScreenRecording();
      setState(() => _screenAsked = true);
    } else {
      await widget.permissions.requestAccessibility();
    }
    await _readPermissions();
  }

  /// This app's own macOS permissions: workers run as its children, so what
  /// they do in the shell (`screencapture`, a clicking AppleScript) is asked
  /// on its behalf.
  Widget _permissionsSection(ThemeData theme) {
    final p = _perms;
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
        if (ok != true) ...[
          TextButton(
            key: Key('grant-$pane'),
            onPressed: grant,
            child: const Text('Grant', style: TextStyle(fontSize: 12)),
          ),
          TextButton(
            onPressed: () => widget.permissions.openSettings(pane),
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
            "This app's macOS permissions",
            style: theme.textTheme.titleSmall,
          ),
          Text(
            'Workers run inside this app, so macOS asks this app for what they do in the shell. '
            'Grant them now, while you are here.',
            style: theme.textTheme.bodySmall?.copyWith(color: Palette.textDim),
          ),
          const SizedBox(height: 6),
          if (!_permsRead)
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
              () => _grant('screenRecording'),
              'Privacy_ScreenCapture',
            ),
            row(
              'Accessibility',
              'clicks and keys: AppleScript, Peekaboo',
              p['accessibility'],
              () => _grant('accessibility'),
              'Privacy_Accessibility',
            ),
            Wrap(
              children: [
                TextButton(
                  key: const Key('perm-recheck'),
                  onPressed: _readPermissions,
                  child: const Text(
                    'Check again',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                if (_screenAsked && p['screenRecording'] != true)
                  TextButton(
                    key: const Key('restart'),
                    onPressed: _restart,
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

  Future<void> _loadModels(_CustomDraft d) async {
    setState(() {
      d.loading = true;
      d.modelsError = null;
    });
    final (list, error) = await widget.checker.models(
      d.baseUrl.text,
      d.envKey.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      d.loading = false;
      d.modelsError = error;
      d.models = list;
      // Keep the model if the server has it; else the first one.
      if (list != null &&
          list.isNotEmpty &&
          !list.any((m) => m.id == d.model.text)) {
        d.pick(list.first);
      }
    });
  }

  Widget _customCard(_CustomDraft d) {
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
                    _custom.remove(d);
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
                  onPressed: d.loading ? null : () => _loadModels(d),
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
                  onPressed: () => _checkCustom(d),
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
              check: widget.checker.computerUse,
            ),
          ],
        ),
      ),
    );
  }
}

/// A custom agent being typed on the start screen.
class _CustomDraft {
  _CustomDraft() : key = 'c${_seq++}';

  factory _CustomDraft.from(WorkerType t) => _CustomDraft()
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
