import 'dart:convert';
import 'dart:io';

import '../state/thread_view.dart' show Json;

/// What runs a worker type.
enum WorkerKind {
  /// OpenAI Codex (`codex app-server`, the user's subscription).
  codex,

  /// Anthropic Claude (the Agent SDK, the user's subscription).
  claude,

  /// Codex driven by another model server with an OpenAI Responses API
  /// (a local model, another provider); one app-server process each.
  custom;

  static WorkerKind parse(String s) =>
      WorkerKind.values.firstWhere((k) => k.name == s, orElse: () => custom);
}

/// One kind of worker a body offers, by id: `codex`, `claude`, and the
/// custom ones in the body's `worker-types.json`. The orchestrator picks one
/// per worker (`start_thread`'s `worker_type`); the choices come from
/// `list_bodies`, not from the tool definition, because they change while a
/// conversation runs and differ from body to body.
class WorkerType {
  WorkerType({
    required this.id,
    required this.kind,
    String? label,
    this.description = '',
    this.maxConcurrent,
    this.baseUrl,
    this.model,
    this.envKey,
    this.contextWindow,
  }) : label = label ?? id;

  final String id;
  final WorkerKind kind;
  final String label;

  /// For the orchestrator: what this worker type is good for.
  final String description;

  /// Workers of this type allowed to run at once on the body (null: only
  /// the body's overall limit).
  final int? maxConcurrent;

  // Custom only.

  /// The Responses API base, with its version (`http://host:8500/v1`).
  final String? baseUrl;
  final String? model;

  /// Name of the environment variable holding the API key on the body's
  /// machine (the key itself never leaves that machine).
  final String? envKey;
  final int? contextWindow;

  /// What the body tells the brain (no secrets: [envKey] only by name).
  Json toInfo({String? error}) => {
    'id': id,
    'kind': kind.name,
    'label': label,
    'description': description,
    'maxConcurrent': maxConcurrent,
    'model': ?model,
    'error': ?error,
  };

  static final codex = WorkerType(
    id: 'codex',
    kind: WorkerKind.codex,
    label: 'Codex',
    description: 'OpenAI Codex on the user\'s subscription. Strong at code and at running commands.',
  );

  static final claude = WorkerType(
    id: 'claude',
    kind: WorkerKind.claude,
    label: 'Claude',
    description: 'Anthropic Claude Code on the user\'s subscription. Strong at code, careful with long tasks.',
  );

  /// The custom type used when the body has no `worker-types.json`: kiapi
  /// on this machine (KIAPI_BASE_URL, KIAPI_MODEL).
  static WorkerType kiapiDefault(Map<String, String> env) => WorkerType(
    id: 'kiapi',
    kind: WorkerKind.custom,
    label: 'kiapi',
    description:
        'Codex driven by a local model (kiapi) on this machine: free and private, but slower and '
        'weaker. Use it for small, well-specified tasks, or when the user asks for it.',
    maxConcurrent: 1,
    baseUrl:
        '${(env['KIAPI_BASE_URL'] ?? 'http://127.0.0.1:8500').replaceAll(RegExp(r'/+$'), '')}/v1',
    model: env['KIAPI_MODEL'] ?? 'qwen3.8-flash-next',
    contextWindow: 200000,
  );

  static final _id = RegExp(r'^[a-z0-9][a-z0-9_-]*$');

  static WorkerType _custom(Json j) {
    final id = j['id'] as String? ?? '';
    if (!_id.hasMatch(id) || id == 'codex' || id == 'claude') {
      throw FormatException('bad worker type id "$id" (a-z, 0-9, _ and -; not codex or claude)');
    }
    final base = j['base_url'] as String?;
    final model = j['model'] as String?;
    if (base == null || model == null) {
      throw FormatException('worker type "$id" needs base_url and model');
    }
    return WorkerType(
      id: id,
      kind: WorkerKind.custom,
      label: j['label'] as String?,
      description: j['description'] as String? ?? '',
      maxConcurrent: (j['max_concurrent'] as num?)?.toInt(),
      baseUrl: base.replaceAll(RegExp(r'/+$'), ''),
      model: model,
      envKey: j['env_key'] as String?,
      contextWindow: (j['context_window'] as num?)?.toInt(),
    );
  }

  /// Codex, Claude, and the custom types in [file] (`{"custom": [...]}`), or
  /// kiapi when there is no file.
  static List<WorkerType> load(File file, Map<String, String> env) {
    if (!file.existsSync()) return [codex, claude, kiapiDefault(env)];
    final j = jsonDecode(file.readAsStringSync()) as Map;
    final custom = [
      for (final c in (j['custom'] as List? ?? const []).cast<Map>())
        _custom(c.cast<String, dynamic>()),
    ];
    final ids = <String>{};
    for (final t in custom) {
      if (!ids.add(t.id)) throw FormatException('worker type "${t.id}" appears twice');
    }
    return [codex, claude, ...custom];
  }
}
