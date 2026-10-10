import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:orchestrator_signal/signal_server.dart';

import '../agents/agent_check.dart';
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
    this.checker = const AgentChecker(),
    this.error,
  });

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
      ..url = _url.text.trim().isEmpty ? 'ws://localhost:8765' : _url.text.trim();
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
      final req = await client.getUrl(Uri.parse(url.replaceFirst(RegExp('^ws'), 'http')));
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
      if (c.brain) LaunchConfig.self: '${c.name.isEmpty ? 'this app' : c.name} (this app)',
      for (final b in _roster?.brains ?? const <String>[])
        if (!(c.brain && b == c.name)) b: b,
    };
    if (c.owner case final o? when o != LaunchConfig.self && !out.containsKey(o)) {
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

  String? _cwd(TextEditingController t) => t.text.trim().isEmpty ? null : t.text.trim();

  void _checkCodex() => _check('codex', () => widget.checker.codex(_cwd(_codexCwd)));
  void _checkClaude() => _check('claude', () => widget.checker.claude(_cwd(_claudeCwd)));
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
  }

  /// The agents as typed, or why they cannot be saved.
  (WorkerTypesConfig?, String?) _readAgents() {
    final custom = <WorkerType>[];
    final ids = <String>{};
    for (final d in _custom) {
      final (t, e) = d.build();
      if (e != null) return (null, e);
      if (!ids.add(t!.id)) return (null, 'Two custom agents are named "${t.id}".');
      custom.add(t);
    }
    final config = WorkerTypesConfig(
      codex: BuiltinSetup(enabled: _agents.codex.enabled, cwd: _cwd(_codexCwd), model: _agents.codex.model),
      claude: BuiltinSetup(enabled: _agents.claude.enabled, cwd: _cwd(_claudeCwd), model: _agents.claude.model),
      custom: custom,
    );
    if (c.brain && config.types.isEmpty) {
      return (null, 'A brain needs at least one agent to run its orchestrator on.');
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
                              ? const TextStyle(color: Palette.text, fontWeight: FontWeight.w600)
                              : null,
                        ),
                    ],
                  ),
                  key: const Key('steps'),
                  style: theme.textTheme.bodySmall?.copyWith(color: Palette.textFaint),
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
                    child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
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
        Text(sub, style: theme.textTheme.bodySmall?.copyWith(color: Palette.textDim)),
      ],
    ),
  );

  List<Widget> _signalingStep(ThemeData theme) => [
    _title(theme, 'Signaling server', 'Every app joins one. It keeps the roster and who owns which body.'),
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
          helperText: taken ? 'An app named $name is online; this one will get a suffix (-2).' : null,
        ),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 12),
      CheckboxListTile(
        key: const Key('role-brain'),
        value: c.brain,
        onChanged: (v) => setState(() => c.brain = v!),
        title: const Text('Brain'),
        subtitle: const Text('Runs an orchestrator. Consoles pick a brain to talk to.'),
        controlAffinity: ListTileControlAffinity.leading,
      ),
      CheckboxListTile(
        key: const Key('role-body'),
        value: c.body,
        onChanged: (v) => setState(() => c.body = v!),
        title: const Text('Body'),
        subtitle: const Text('Lets the brain it belongs to run workers on this machine.'),
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
              initialValue: choices.any((e) => e.$1 == c.owner) ? c.owner : null,
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
      return const Text('Checking…', style: TextStyle(fontSize: 12, color: Palette.textDim));
    }
    final r = _checks[key];
    if (r == null) return const SizedBox.shrink();
    return Text(
      '${r.ok ? '✓' : '✗'} ${r.text}',
      key: Key('status-$key'),
      style: TextStyle(fontSize: 12, color: r.ok ? Palette.added : Palette.warning),
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
                          labelText: 'Working folder',
                          hintText: 'empty: the project folder',
                          isDense: true,
                        ),
                      ),
                    ),
                    TextButton(key: Key('check-$id'), onPressed: check, child: const Text('Check')),
                  ],
                ),
                const SizedBox(height: 4),
                _status(id),
                ?extra,
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
          if (c.body) 'The brain this body belongs to can start these as workers here.',
          if (c.brain) 'The orchestrator runs on one of them.',
          'Each is checked when turned on (no model tokens).',
        ].join(' '),
      ),
      _builtin(
        id: 'codex',
        label: 'Codex',
        sub: 'OpenAI Codex on your subscription.',
        setup: _agents.codex,
        cwd: _codexCwd,
        check: _checkCodex,
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
      if (ids.isEmpty)
        Text(
          c.brain
              ? 'Turn on at least one: the orchestrator runs on it.'
              : 'None turned on: this body offers no workers, only its tools (fetch_image).',
          style: theme.textTheme.bodySmall?.copyWith(color: Palette.textDim),
        ),
      if (c.brain && ids.isNotEmpty) ...[
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          key: const Key('orchestrator'),
          initialValue: ids.contains(c.orchestrator) ? c.orchestrator : ids.first,
          decoration: const InputDecoration(labelText: 'The orchestrator runs on'),
          items: [for (final id in ids) DropdownMenuItem(value: id, child: Text(id))],
          onChanged: (v) => setState(() => c.orchestrator = v),
        ),
      ],
    ];
  }

  Widget _customCard(_CustomDraft d) {
    Widget field(String key, TextEditingController t, String label, {String? hint}) => Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: TextField(
        key: Key('custom-${d.key}-$key'),
        controller: t,
        decoration: InputDecoration(labelText: label, hintText: hint, isDense: true),
        onChanged: (_) => setState(() {}),
      ),
    );
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
                Expanded(child: field('id', d.id, 'Id', hint: 'kiapi, local-qwen, …')),
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
            field('url', d.baseUrl, 'Base URL', hint: 'http://127.0.0.1:8500/v1'),
            field('model', d.model, 'Model'),
            field('key', d.envKey, 'API key variable (optional)', hint: 'OPENROUTER_API_KEY'),
            field('cwd', d.cwd, 'Working folder (optional)', hint: 'empty: the project folder'),
            field('desc', d.description, 'What it is good for (the orchestrator reads this)'),
            field('max', d.maxConcurrent, 'At once per body (optional)', hint: 'empty: no limit of its own'),
            Row(
              children: [
                Expanded(child: _status(d.key)),
                TextButton(key: Key('check-${d.key}'), onPressed: () => _checkCustom(d), child: const Text('Check')),
              ],
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
    ..maxConcurrent.text = t.maxConcurrent?.toString() ?? ''
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
  final maxConcurrent = TextEditingController();
  String? _label;
  int? _contextWindow;

  (WorkerType?, String?) build() {
    final max = maxConcurrent.text.trim();
    if (max.isNotEmpty && (int.tryParse(max) ?? 0) < 1) {
      return (null, 'Custom agent "${id.text.trim()}": "at once" must be a positive number.');
    }
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
          if (max.isNotEmpty) 'max_concurrent': int.parse(max),
          'context_window': ?_contextWindow,
        }),
        null,
      );
    } on FormatException catch (e) {
      return (null, e.message);
    }
  }

  void dispose() {
    for (final t in [id, baseUrl, model, envKey, cwd, description, maxConcurrent]) {
      t.dispose();
    }
  }
}
