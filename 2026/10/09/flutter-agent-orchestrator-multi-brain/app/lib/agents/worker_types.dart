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

/// One kind of worker a body offers, by id: `codex`, `claude` (one each, on
/// or off), and the custom ones. The orchestrator picks one per worker
/// (`start_thread`'s `worker_type`); the choices come from `list_bodies`,
/// not from the tool definition, because they change while a conversation
/// runs and differ from body to body. Set on the start screen and kept in
/// the state directory's `worker-types.json` ([WorkerTypesConfig]).
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
    this.cwd,
  }) : label = label ?? id;

  final String id;
  final WorkerKind kind;
  final String label;

  /// For the orchestrator: what this worker type is good for.
  final String description;

  /// Workers of this type allowed to run at once on the body (null: only
  /// the body's overall limit).
  final int? maxConcurrent;

  /// The default model (custom: the server's model, required).
  final String? model;

  /// Where its workers start when the orchestrator names no directory
  /// (`~/` allowed; null: the body's project directory).
  final String? cwd;

  // Custom only.

  /// The Responses API base, with its version (`http://host:8500/v1`).
  final String? baseUrl;

  /// Name of the environment variable holding the API key on the body's
  /// machine (the key itself never leaves that machine).
  final String? envKey;
  final int? contextWindow;

  /// [cwd] with `~/` expanded, or null.
  String? get resolvedCwd => expandHome(cwd);

  /// What the body tells the brain (no secrets: [envKey] only by name).
  Json toInfo({String? error}) => {
    'id': id,
    'kind': kind.name,
    'label': label,
    'description': description,
    'maxConcurrent': maxConcurrent,
    'model': ?model,
    'cwd': ?resolvedCwd,
    'error': ?error,
  };

  static final _id = RegExp(r'^[a-z0-9][a-z0-9_-]*$');

  /// Why [id] cannot name a custom type, or null.
  static String? badId(String id) => !_id.hasMatch(id)
      ? 'use a-z, 0-9, _ and - (starting with a letter or digit)'
      : id == 'codex' || id == 'claude'
      ? '"$id" is taken by the built-in one'
      : null;

  static WorkerType customFromJson(Json j) {
    final id = j['id'] as String? ?? '';
    if (badId(id) case final e?) throw FormatException('worker type "$id": $e');
    final base = j['base_url'] as String?;
    final model = j['model'] as String?;
    if (base == null || base.isEmpty || model == null || model.isEmpty) {
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
      envKey: _blankToNull(j['env_key'] as String?),
      contextWindow: (j['context_window'] as num?)?.toInt(),
      cwd: _blankToNull(j['cwd'] as String?),
    );
  }

  Json customToJson() => {
    'id': id,
    if (label != id) 'label': label,
    'base_url': baseUrl,
    'model': model,
    'env_key': ?envKey,
    'cwd': ?cwd,
    'description': description,
    'max_concurrent': ?maxConcurrent,
    'context_window': ?contextWindow,
  };
}

String? _blankToNull(String? s) => s == null || s.trim().isEmpty ? null : s.trim();

/// `~/x` to `$HOME/x`.
String? expandHome(String? path) {
  if (path == null) return null;
  final home = Platform.environment['HOME'] ?? '';
  if (path == '~') return home;
  return path.startsWith('~/') ? '$home${path.substring(1)}' : path;
}

/// Codex or Claude on this machine: on or off, where its workers start, and
/// its default model.
class BuiltinSetup {
  BuiltinSetup({this.enabled = true, this.cwd, this.model});

  bool enabled;
  String? cwd;
  String? model;

  Json toJson() => {'enabled': enabled, 'cwd': ?cwd, 'model': ?model};

  static BuiltinSetup fromJson(Object? j) {
    if (j is! Map) return BuiltinSetup();
    return BuiltinSetup(
      enabled: j['enabled'] as bool? ?? true,
      cwd: _blankToNull(j['cwd'] as String?),
      model: _blankToNull(j['model'] as String?),
    );
  }
}

/// What this app can run, from `worker-types.json`:
///
///     {"codex": {"enabled": true, "cwd": "~/src"},
///      "claude": {"enabled": false},
///      "custom": [{"id": "kiapi", "base_url": "http://127.0.0.1:8500/v1", "model": "..."}]}
///
/// A body offers these as worker types; a brain runs its orchestrator on one
/// of them. None at all is allowed: the body still serves its tools.
class WorkerTypesConfig {
  WorkerTypesConfig({BuiltinSetup? codex, BuiltinSetup? claude, List<WorkerType>? custom})
    : codex = codex ?? BuiltinSetup(),
      claude = claude ?? BuiltinSetup(),
      custom = custom ?? [];

  final BuiltinSetup codex;
  final BuiltinSetup claude;
  final List<WorkerType> custom;

  /// The worker types that are turned on.
  List<WorkerType> get types => [
    if (codex.enabled)
      WorkerType(
        id: 'codex',
        kind: WorkerKind.codex,
        label: 'Codex',
        description: 'OpenAI Codex on the user\'s subscription. Strong at code and at running commands.',
        model: codex.model,
        cwd: codex.cwd,
      ),
    if (claude.enabled)
      WorkerType(
        id: 'claude',
        kind: WorkerKind.claude,
        label: 'Claude',
        description: 'Anthropic Claude Code on the user\'s subscription. Strong at code, careful with long tasks.',
        model: claude.model,
        cwd: claude.cwd,
      ),
    ...custom,
  ];

  Json toJson() => {
    'codex': codex.toJson(),
    'claude': claude.toJson(),
    'custom': [for (final t in custom) t.customToJson()],
  };

  static WorkerTypesConfig fromJson(Json j) {
    final custom = [
      for (final c in (j['custom'] as List? ?? const []).cast<Map>())
        WorkerType.customFromJson(c.cast<String, dynamic>()),
    ];
    final ids = <String>{};
    for (final t in custom) {
      if (!ids.add(t.id)) throw FormatException('worker type "${t.id}" appears twice');
    }
    return WorkerTypesConfig(
      codex: BuiltinSetup.fromJson(j['codex']),
      claude: BuiltinSetup.fromJson(j['claude']),
      custom: custom,
    );
  }

  /// The setup in [file], or Codex and Claude (plus kiapi when KIAPI_BASE_URL
  /// is set) when there is none.
  static WorkerTypesConfig load(File file, Map<String, String> env) {
    if (!file.existsSync()) {
      return WorkerTypesConfig(custom: [if (env['KIAPI_BASE_URL'] != null) kiapiDefault(env)]);
    }
    return fromJson((jsonDecode(file.readAsStringSync()) as Map).cast());
  }

  void save(File file) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(toJson()));
  }

  /// kiapi on this machine (KIAPI_BASE_URL, KIAPI_MODEL).
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
}
