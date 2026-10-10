import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:orchestrator_signal/signal_server.dart';

import '../agents/agent_check.dart';
import '../agents/mac_permissions.dart';
import '../agents/worker_types.dart';
import '../orchestrator/brain_config.dart';
import 'agents_editor.dart';
import 'brain_editor.dart';
import '../mesh/launch.dart';
import 'theme.dart';

/// The first screen when no `ORCH_*` variables are set, in steps:
///
/// 1. Signaling: start the server in this app (fails here when the port is
///    in use) or join one (fails here when it cannot be read).
/// 2. Roles: the name, and brain and/or body (neither: a console only).
/// 3. Brain, for a brain: the one agent its orchestrator runs on (checked
///    as it is picked), its model, effort and folder ([BrainEditor]). Kept
///    in `brain.json`.
/// 4. Belongs to, for a body: which brain it belongs to, from the roster
///    read in step 1.
/// 5. Body, for a body: the agents it offers as workers (Codex and Claude on
///    or off, custom ones added freely, each checked as it is turned on),
///    their tools, and this app's macOS permissions ([AgentsEditor]). Kept
///    in `worker-types.json`.
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
  final Map<String, List<String>> owners;
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
    if (c.brain) 'Brain',
    if (c.body) 'Belongs to',
    if (c.body) 'Body',
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
    if (_stepName == 'Body') _draft.checkAll();
    if (_stepName == 'Brain' && _brain.check == null) _brain.runCheck();
  }

  /// The server started in step 1 (kept while going back and forth).
  SignalServer? _server;
  int? _serverPort;
  _Roster? _roster;
  bool _ownerTouched = false;

  @override
  void dispose() {
    _draft.dispose();
    _brain.dispose();
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
        {
          for (final e in (j['owners'] as Map).entries)
            e.key as String: brainList(e.value),
        },
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
        c.owners = [
          for (final o in known[c.name]!)
            c.brain && o == c.name ? LaunchConfig.self : o,
        ];
      } else if (c.brain) {
        c.owners = [LaunchConfig.self];
      }
    }
    if (!c.brain) c.owners.remove(LaunchConfig.self);
    _advance();
  }

  // ---- step 3: owner --------------------------------------------------------

  /// (value, label): this app if it is a brain, the brains online, and the
  /// saved choices (they may join later).
  List<(String, String)> get _brainChoices {
    final out = <String, String>{
      if (c.brain)
        LaunchConfig.self: '${c.name.isEmpty ? 'this app' : c.name} (this app)',
      for (final b in _roster?.brains ?? const <String>[])
        if (!(c.brain && b == c.name)) b: b,
    };
    for (final o in c.owners) {
      if (o != LaunchConfig.self && !out.containsKey(o)) out[o] = '$o (offline)';
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
    final (brain, brainError) = c.brain ? _brain.read() : (null, null);
    final (body, bodyError) = c.body
        ? _draft.read(needOne: false)
        : (null, null);
    if (brainError ?? bodyError case final e?) {
      setState(() => _error = e);
      return;
    }
    brain?.save(widget.stateDir);
    body?.save(widget.typesFile);
    c.assignOwner = c.body;
    widget.onStart(c, _server);
  }

  // ---- step 3: brain --------------------------------------------------------

  late final _brain = BrainDraft(
    () {
      try {
        return BrainConfig.load(widget.stateDir, const {});
      } catch (_) {
        return BrainConfig();
      }
    }(),
    checker: widget.checker,
    projectDirDefault:
        'this machine\'s project folder (${c.body ? 'the Body step' : Platform.environment['ORCH_CWD'] ?? 'the home folder'})',
  );

  List<Widget> _brainStep(ThemeData theme) => [
    _title(
      theme,
      'Brain',
      'The agent its orchestrator runs on. It talks with you and hands work to the workers of its bodies; '
          'it gets no tools that drive the Mac or Chrome. Checked as you pick it (no model tokens).',
    ),
    BrainEditor(draft: _brain),
  ];

  // ---- step 5: body ---------------------------------------------------------

  late final _draft = AgentsDraft(
    () {
      try {
        return WorkerTypesConfig.load(widget.typesFile, Platform.environment);
      } catch (_) {
        return WorkerTypesConfig();
      }
    }(),
    checker: widget.checker,
    permissions: widget.permissions,
  );

  /// Saves what is on the screen and starts the app again (Screen Recording
  /// applies to a running app only after a restart).
  Future<void> _restart() async {
    c
      ..name = _name.text.trim()
      ..port = int.tryParse(_port.text.trim()) ?? c.port
      ..url = _url.text.trim().isEmpty ? c.url : _url.text.trim();
    c.save(widget.stateDir);
    final (config, _) = _draft.read(needOne: false);
    config?.save(widget.typesFile);
    await _server?.close();
    await widget.permissions.relaunch();
  }

  List<Widget> _bodyStep(ThemeData theme) => [
    _title(
      theme,
      'Body',
      'The agents the brain this body belongs to can start here as workers, and their tools. '
          'Each is checked when turned on (no model tokens).',
    ),
    AgentsEditor(draft: _draft, onRestart: _restart),
  ];

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
                  'Brain' => _brainStep(theme),
                  _ => _bodyStep(theme),
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
        'Only these brains run workers on this body. With several, it is shared: one brain uses it at a time, '
            'the others can only read there until its workers finish. Consoles can change this later.',
      ),
      if (choices.isEmpty)
        Text(
          'No brain online yet: it can be added from a console later.',
          style: theme.textTheme.bodySmall?.copyWith(color: Palette.textDim),
        ),
      for (final (value, label) in choices)
        CheckboxListTile(
          key: Key('owner-$value'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: c.owners.contains(value),
          title: Text(label),
          onChanged: (v) => setState(() {
            v == true ? c.owners.add(value) : c.owners.remove(value);
            _ownerTouched = true;
          }),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const Key('refresh'),
          onPressed: _busy ? null : _refresh,
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text('Read the brains again'),
        ),
      ),
    ];
  }

}
