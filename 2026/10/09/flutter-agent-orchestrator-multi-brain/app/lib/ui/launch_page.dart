import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:orchestrator_signal/signal_server.dart';

import '../mesh/launch.dart';
import 'theme.dart';

/// The first screen when no `ORCH_*` variables are set: what this app does
/// (brain, body, signaling) and where it joins. Starting the signaling
/// server fails here when its port is in use.
class LaunchPage extends StatefulWidget {
  const LaunchPage({
    super.key,
    required this.initial,
    required this.ownersFile,
    required this.onStart,
    this.error,
  });

  final LaunchConfig initial;

  /// Where an in-app signaling server keeps body ownership.
  final File ownersFile;
  final void Function(LaunchConfig config, SignalServer? server) onStart;
  final String? error;

  @override
  State<LaunchPage> createState() => _LaunchPageState();
}

/// What the signaling server at a URL reports (for the brain list).
class _Roster {
  _Roster(this.brains, this.owners);

  final List<String> brains;
  final Map<String, String?> owners;
}

class _LaunchPageState extends State<LaunchPage> {
  late final LaunchConfig c = widget.initial;
  late final _name = TextEditingController(text: c.name);
  late final _port = TextEditingController(text: '${c.port}');
  late final _url = TextEditingController(text: c.url);
  late String? _error = widget.error;
  bool _starting = false;

  _Roster? _roster;
  String? _rosterError;
  bool _ownerTouched = false;

  @override
  void initState() {
    super.initState();
    // A brain that is a body runs workers on itself unless told otherwise.
    if (c.brain && c.owner == null) c.owner = LaunchConfig.self;
    if (!c.signaling) unawaited(_fetchRoster());
  }

  @override
  void dispose() {
    _name.dispose();
    _port.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _fetchRoster() async {
    final url = _url.text.trim();
    setState(() => _rosterError = null);
    try {
      final http = Uri.parse(url.replaceFirst(RegExp('^ws'), 'http'));
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
      final req = await client.getUrl(http);
      final res = await req.close().timeout(const Duration(seconds: 3));
      final j = jsonDecode(await res.transform(utf8.decoder).join()) as Map;
      client.close();
      final brains = [
        for (final n in (j['nodes'] as List).cast<Map>())
          if (n['brain'] == true) n['name'] as String,
      ]..sort();
      final owners = (j['owners'] as Map).cast<String, String?>();
      if (!mounted || _url.text.trim() != url) return;
      setState(() {
        _roster = _Roster(brains, owners);
        // Show where this body already belongs, unless the user chose.
        final name = _name.text.trim();
        if (!_ownerTouched && owners.containsKey(name)) {
          final o = owners[name];
          c.owner = c.brain && o == name ? LaunchConfig.self : o;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _roster = null;
        _rosterError = 'could not read $url';
      });
    }
  }

  /// Brains to belong to (value, label): this app if it is a brain, the
  /// ones the server knows, and the saved choice (it may join later).
  List<(String, String)> get _brainChoices {
    final name = _name.text.trim();
    final out = <String, String>{
      if (c.brain) LaunchConfig.self: '${name.isEmpty ? 'this app' : name} (this app)',
      for (final b in _roster?.brains ?? const <String>[])
        if (!(c.brain && b == name)) b: b,
    };
    if (c.owner case final o? when !out.containsKey(o)) {
      if (o != LaunchConfig.self) out[o] = o;
    }
    return [for (final e in out.entries) (e.key, e.value)];
  }

  Future<void> _start() async {
    final port = int.tryParse(_port.text.trim());
    if (c.signaling && (port == null || port <= 0 || port > 65535)) {
      setState(() => _error = 'The port must be a number from 1 to 65535.');
      return;
    }
    c
      ..name = _name.text.trim()
      ..port = port ?? c.port
      ..url = _url.text.trim().isEmpty ? 'ws://localhost:8765' : _url.text.trim()
      ..assignOwner = c.body;
    setState(() {
      _starting = true;
      _error = null;
    });
    SignalServer? server;
    if (c.signaling) {
      server = SignalServer(port: c.port, ownersFile: widget.ownersFile);
      try {
        await server.start();
      } on SocketException catch (e) {
        setState(() {
          _starting = false;
          _error =
              'Could not start signaling on port ${c.port}: it is in use '
              '(${e.osError?.message ?? e.message}).';
        });
        return;
      }
    }
    widget.onStart(c, server);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final choices = _brainChoices;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Start this app as', style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  'Every app has a console. Pick any of these.',
                  style: theme.textTheme.bodySmall?.copyWith(color: Palette.textDim),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: 'Name (body id)',
                    hintText: 'empty: host name and 4 random digits',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  key: const Key('role-brain'),
                  value: c.brain,
                  onChanged: (v) => setState(() {
                    c.brain = v!;
                    if (c.brain && c.owner == null && !_ownerTouched) c.owner = LaunchConfig.self;
                    if (!c.brain && c.owner == LaunchConfig.self) c.owner = null;
                  }),
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
                if (c.body)
                  Padding(
                    padding: const EdgeInsets.only(left: 56, right: 8, bottom: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String?>(
                            key: const Key('owner'),
                            initialValue: choices.any((e) => e.$1 == c.owner) ? c.owner : null,
                            decoration: const InputDecoration(labelText: 'Belongs to'),
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
                        if (!c.signaling)
                          IconButton(
                            tooltip: 'Read the brains from the signaling server',
                            onPressed: _fetchRoster,
                            icon: const Icon(Icons.refresh, size: 18),
                          ),
                      ],
                    ),
                  ),
                CheckboxListTile(
                  key: const Key('role-signal'),
                  value: c.signaling,
                  onChanged: (v) => setState(() {
                    c.signaling = v!;
                    if (!c.signaling) unawaited(_fetchRoster());
                  }),
                  title: const Text('Signaling'),
                  subtitle: const Text('Runs the signaling server (roster, ownership, WebRTC relay) in this app.'),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 56, right: 8),
                  child: c.signaling
                      ? TextField(
                          key: const Key('port'),
                          controller: _port,
                          decoration: const InputDecoration(labelText: 'Port'),
                          keyboardType: TextInputType.number,
                        )
                      : TextField(
                          key: const Key('url'),
                          controller: _url,
                          decoration: InputDecoration(
                            labelText: 'Signaling URL',
                            hintText: 'ws://localhost:8765',
                            helperText: _rosterError ??
                                (_roster == null
                                    ? null
                                    : '${_roster!.brains.length} brain(s) there'),
                          ),
                          onSubmitted: (_) => _fetchRoster(),
                        ),
                ),
                const SizedBox(height: 20),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                  ),
                FilledButton(
                  key: const Key('start'),
                  onPressed: _starting ? null : _start,
                  child: Text(_starting ? 'Starting…' : 'Start'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
