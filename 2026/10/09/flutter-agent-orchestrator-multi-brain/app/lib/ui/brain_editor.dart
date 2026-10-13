import 'package:flutter/material.dart';

import '../agents/agent_check.dart';
import '../agents/worker_types.dart';
import '../orchestrator/brain_config.dart';
import 'theme.dart';

/// A brain's settings being edited ([BrainConfig]): the one agent its
/// orchestrator runs on, checked as it is picked, then its model, effort,
/// folder and whether finished workers wake it. The start screen edits this
/// app's ([local]); a console edits a brain's through it, its checks run on
/// that brain's machine and logging in stays there.
class BrainDraft extends ChangeNotifier {
  BrainDraft(
    BrainConfig config, {
    this.checker = const AgentChecker(),
    this.local = true,
    this.projectDirDefault = 'the project folder',
  }) : config = config.copy();

  final BrainConfig config;
  final AgentChecker checker;
  final bool local;

  /// Where the orchestrator works when its folder is empty.
  final String projectDirDefault;

  /// The talker's agent (dual mode): edited like this one, without a folder
  /// or waking.
  BrainDraft get talker => _talker ??= BrainDraft(
    config.talker ?? BrainConfig(kind: WorkerKind.claude),
    checker: checker,
    local: local,
  )..addListener(_changed);
  BrainDraft? _talker;

  void pickMode(BrainMode m) {
    if (config.mode == m) return;
    config.mode = m;
    _changed();
    if (m == BrainMode.dual && talker.check == null) talker.runCheck();
  }

  late final cwd = TextEditingController(text: config.cwd ?? '');
  late final baseUrl = TextEditingController(text: config.baseUrl ?? '');
  late final envKey = TextEditingController(text: config.envKey ?? '');
  late final customModel = TextEditingController(
    text: config.kind == WorkerKind.custom ? config.model ?? '' : '',
  );

  /// The last check of the agent picked (null: not checked, or checking).
  CheckResult? check;
  bool checking = false;

  /// A custom server's models, once loaded (empty: it has no list).
  List<ModelInfo>? customModels;
  String? customModelsError;
  bool loadingModels = false;
  bool _disposed = false;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  String? _text(TextEditingController t) =>
      t.text.trim().isEmpty ? null : t.text.trim();

  /// The models to pick from: the checked agent's, or the custom server's.
  List<ModelInfo> get models => config.kind == WorkerKind.custom
      ? customModels ?? const []
      : check?.models ?? const [];

  void pickKind(WorkerKind k) {
    if (k == config.kind) return;
    config
      ..kind = k
      ..model = null
      ..effort = null;
    check = null;
    _changed();
    runCheck();
  }

  /// Checks the agent picked (no model tokens): Codex and Claude logged in,
  /// a custom server answers with the model.
  Future<void> runCheck() async {
    final kind = config.kind;
    final (c, error) = read();
    if (c == null) {
      check = CheckResult(false, error!);
      _changed();
      return;
    }
    checking = true;
    check = null;
    _changed();
    final r = switch (kind) {
      WorkerKind.codex => await checker.codex(c.cwd),
      WorkerKind.claude => await checker.claude(c.cwd),
      WorkerKind.custom => await checker.custom(c.customType().$1!),
    };
    if (kind != config.kind) return; // picked another meanwhile
    checking = false;
    check = r;
    _changed();
  }

  Future<void> login() async {
    checking = true;
    check = null;
    _changed();
    final r = await checker.codexLogin();
    if (!r.ok) {
      checking = false;
      check = r;
      _changed();
      return;
    }
    await runCheck();
  }

  Future<void> loadModels() async {
    loadingModels = true;
    customModelsError = null;
    _changed();
    final (list, error) = await checker.models(baseUrl.text, _text(envKey));
    loadingModels = false;
    customModels = list;
    customModelsError = error;
    if (list != null &&
        list.isNotEmpty &&
        !list.any((m) => m.id == customModel.text)) {
      pickModel(list.first);
    }
    _changed();
  }

  void pickModel(ModelInfo? m) {
    if (config.kind == WorkerKind.custom) {
      customModel.text = m?.id ?? '';
      config.contextWindow = m?.contextWindow;
    } else {
      config.model = m?.id;
    }
    config.effort = null;
    _changed();
  }

  void changed() => _changed();

  /// The settings as typed, or why they cannot be saved.
  (BrainConfig?, String?) read() {
    final c = config.copy()..cwd = _text(cwd);
    if (c.kind == WorkerKind.custom) {
      c
        ..baseUrl = _text(baseUrl)
        ..envKey = _text(envKey)
        ..model = _text(customModel);
    } else {
      c
        ..baseUrl = null
        ..envKey = null
        ..contextWindow = null;
    }
    if (c.mode == BrainMode.dual) {
      final (t, e) = talker.read();
      if (e != null) return (null, 'the talker: $e');
      c.talker = t;
    } else {
      c.talker = null;
    }
    if (c.problem case final p?) return (null, p);
    return (c, null);
  }

  @override
  void dispose() {
    _disposed = true;
    for (final t in [cwd, baseUrl, envKey, customModel]) {
      t.dispose();
    }
    _talker?.dispose();
    super.dispose();
  }
}

class BrainEditor extends StatefulWidget {
  const BrainEditor({
    super.key,
    required this.draft,
    this.keyPrefix = 'brain',
    this.agentOnly = false,
  });

  final BrainDraft draft;

  /// Widget keys start with it (`brain-…`, `talker-…`).
  final String keyPrefix;

  /// Only the agent, model and effort (the talker's part of a dual brain).
  final bool agentOnly;

  @override
  State<BrainEditor> createState() => _BrainEditorState();
}

class _BrainEditorState extends State<BrainEditor> {
  BrainDraft get d => widget.draft;

  @override
  void initState() {
    super.initState();
    d.addListener(_repaint);
  }

  @override
  void didUpdateWidget(BrainEditor old) {
    super.didUpdateWidget(old);
    if (old.draft != d) {
      old.draft.removeListener(_repaint);
      d.addListener(_repaint);
    }
  }

  @override
  void dispose() {
    d.removeListener(_repaint);
    super.dispose();
  }

  void _repaint() {
    if (mounted) setState(() {});
  }

  Widget _field(
    String key,
    TextEditingController t,
    String label, {
    String? hint,
    String? help,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: TextField(
      key: Key('${widget.keyPrefix}-$key'),
      controller: t,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: help,
        helperMaxLines: 2,
        isDense: true,
      ),
      onChanged: (_) => d.changed(),
    ),
  );

  Widget _status() {
    if (d.checking) {
      return const Text(
        'Checking…',
        style: TextStyle(fontSize: 12, color: Palette.textDim),
      );
    }
    final r = d.check;
    if (r == null) return const SizedBox.shrink();
    return Text(
      '${r.ok ? '✓' : '✗'} ${r.text}',
      key: Key('${widget.keyPrefix}-status'),
      style: TextStyle(
        fontSize: 12,
        color: r.ok ? Palette.added : Palette.warning,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = d.config;
    final custom = c.kind == WorkerKind.custom;
    final models = d.models;
    final current = custom ? d.customModel.text : c.model;
    final model = models.where((m) => m.id == current).firstOrNull;
    final efforts =
        (model ??
                models.where((m) => m.isDefault).firstOrNull ??
                models.firstOrNull)
            ?.efforts ??
        const <String>[];
    final dual = !widget.agentOnly && c.mode == BrainMode.dual;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.agentOnly) ...[
          SegmentedButton<BrainMode>(
            key: Key('${widget.keyPrefix}-mode'),
            segments: const [
              ButtonSegment(value: BrainMode.single, label: Text('Single')),
              ButtonSegment(
                value: BrainMode.dual,
                label: Text('Talker + Thinker'),
              ),
            ],
            selected: {c.mode},
            onSelectionChanged: (s) => d.pickMode(s.first),
          ),
          const SizedBox(height: 6),
          Text(
            dual
                ? 'Two agents. The talker talks with you and hands what needs deciding or doing to the thinker; '
                      'the thinker decides and acts (workers, tools) and reports back. The talker keeps talking while '
                      'the thinker works.'
                : 'One agent talks with you, decides and acts.',
            style: const TextStyle(fontSize: 12, color: Palette.textDim),
          ),
          const SizedBox(height: 12),
          if (dual) ...[
            Text('Thinker', style: theme.textTheme.titleSmall),
            const Text(
              'Decides and acts: runs workers on bodies, uses the tools.',
              style: TextStyle(fontSize: 12, color: Palette.textDim),
            ),
            const SizedBox(height: 6),
          ],
        ],
        SegmentedButton<WorkerKind>(
          key: Key('${widget.keyPrefix}-kind'),
          segments: const [
            ButtonSegment(value: WorkerKind.codex, label: Text('Codex')),
            ButtonSegment(value: WorkerKind.claude, label: Text('Claude')),
            ButtonSegment(value: WorkerKind.custom, label: Text('Custom')),
          ],
          selected: {c.kind},
          onSelectionChanged: (s) => d.pickKind(s.first),
        ),
        const SizedBox(height: 6),
        Text(switch (c.kind) {
          WorkerKind.codex => 'OpenAI Codex on your subscription.',
          WorkerKind.claude => 'Anthropic Claude Code on your subscription. To log in, run `claude auth login`.',
          WorkerKind.custom =>
            'Codex driven by another model server (an OpenAI Responses API).',
        }, style: const TextStyle(fontSize: 12, color: Palette.textDim)),
        const SizedBox(height: 8),
        if (custom) ...[
          _field(
            'url',
            d.baseUrl,
            'Base URL (required)',
            hint: 'http://127.0.0.1:8500/v1',
            help: 'An OpenAI Responses API server, with its version (…/v1).',
          ),
          _field(
            'key',
            d.envKey,
            'API key variable (optional)',
            hint: 'OPENROUTER_API_KEY',
            help: 'The name of an environment variable holding the key, not the key. Empty: no key.',
          ),
        ],
        Row(
          children: [
            Expanded(child: _status()),
            if (custom)
              TextButton(
                key: Key('${widget.keyPrefix}-load-models'),
                onPressed: d.loadingModels ? null : d.loadModels,
                child: Text(d.loadingModels ? 'Loading…' : 'Load models'),
              ),
            TextButton(
              key: Key('${widget.keyPrefix}-check'),
              onPressed: d.checking ? null : d.runCheck,
              child: const Text('Check'),
            ),
          ],
        ),
        if (d.check case final r? when r.needsLogin && d.local)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: Key('${widget.keyPrefix}-login'),
              onPressed: d.login,
              child: const Text('Log in to Codex (opens the browser)'),
            ),
          ),
        if (d.customModelsError case final e? when custom)
          Text(
            '✗ $e',
            style: const TextStyle(fontSize: 12, color: Palette.warning),
          ),
        const SizedBox(height: 4),
        if (custom && models.isEmpty)
          _field(
            'model',
            d.customModel,
            'Model (required)',
            hint: 'qwen3.8-flash-next',
            help: d.customModels == null
                ? 'Load the list from the server, or type the id.'
                : 'The server has no model list: type the id.',
          )
        else if (models.isNotEmpty)
          DropdownButtonFormField<String?>(
            // A new list (another agent, reloaded) starts from its value.
            key: ValueKey(
              '${widget.keyPrefix}-model-${c.kind.name}-${models.length}',
            ),
            initialValue: model?.id,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: custom ? 'Model (required)' : 'Model',
              isDense: true,
            ),
            items: [
              if (!custom)
                DropdownMenuItem(
                  value: null,
                  child: Text(
                    'Default (${(models.where((m) => m.isDefault).firstOrNull ?? models.first).label ?? models.first.id})',
                  ),
                ),
              for (final m in models)
                DropdownMenuItem(value: m.id, child: Text(m.label ?? m.id)),
            ],
            onChanged: (v) =>
                d.pickModel(models.where((m) => m.id == v).firstOrNull),
          ),
        if (efforts.isNotEmpty)
          DropdownButtonFormField<String?>(
            key: ValueKey('${widget.keyPrefix}-effort-${model?.id}'),
            initialValue: efforts.contains(c.effort) ? c.effort : null,
            decoration: const InputDecoration(
              labelText: 'Effort',
              isDense: true,
            ),
            items: [
              const DropdownMenuItem(value: null, child: Text('Default')),
              for (final e in efforts)
                DropdownMenuItem(value: e, child: Text(e)),
            ],
            onChanged: (v) {
              c.effort = v;
              d.changed();
            },
          ),
        if (!widget.agentOnly) ...[
          const SizedBox(height: 8),
          _field(
            'cwd',
            d.cwd,
            'Folder (optional)',
            hint: '~/src',
            help:
                'Where the orchestrator works. Empty: ${d.projectDirDefault}.',
          ),
          SwitchListTile(
            key: Key('${widget.keyPrefix}-wake'),
            contentPadding: EdgeInsets.zero,
            value: c.wakeOnFinish,
            title: const Text(
              'Wake it when a worker finishes',
              style: TextStyle(fontSize: 14),
            ),
            subtitle: const Text(
              'Off: it hears about finished workers the next time you write.',
              style: TextStyle(fontSize: 12),
            ),
            onChanged: (v) {
              c.wakeOnFinish = v;
              d.changed();
            },
          ),
        ],
        if (dual) ...[
          const Divider(height: 24),
          Text('Talker', style: theme.textTheme.titleSmall),
          const Text(
            'Talks with you: listens, asks back, tells you what the thinker found and did. A quick model fits.',
            style: TextStyle(fontSize: 12, color: Palette.textDim),
          ),
          const SizedBox(height: 6),
          BrainEditor(draft: d.talker, keyPrefix: 'talker', agentOnly: true),
        ],
      ],
    );
  }
}
