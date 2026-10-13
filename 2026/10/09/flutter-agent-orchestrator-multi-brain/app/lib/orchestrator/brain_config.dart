import 'dart:convert';
import 'dart:io';

import '../agents/worker_types.dart';
import '../state/thread_view.dart' show Json;

/// How a brain runs its orchestrator.
enum BrainMode {
  /// One agent talks with the user and decides and acts.
  single,

  /// Two agents: the talker talks with the user and hands what needs
  /// deciding or doing to the thinker, which decides, acts (the
  /// orchestrator's tools) and reports back to the talker.
  dual;

  static BrainMode parse(String? s) =>
      values.firstWhere((m) => m.name == s, orElse: () => single);
}

/// What a brain's orchestrator runs on and how (`brain.json` in the state
/// folder): one agent (Codex, Claude, or Codex on another Responses API
/// server), its model and effort, the folder it works in, and whether a
/// finished worker wakes it. In [BrainMode.dual] that agent is the thinker,
/// and [talker] is the agent the user talks with. Set on the start screen's
/// Brains step and from any console. Neither has tools that drive the Mac or
/// Chrome: those are for workers (a body's settings).
class BrainConfig {
  BrainConfig({
    this.mode = BrainMode.single,
    this.talker,
    this.kind = WorkerKind.codex,
    this.model,
    this.effort,
    this.cwd,
    this.wakeOnFinish = true,
    this.baseUrl,
    this.envKey,
    this.contextWindow,
  });

  BrainMode mode;

  /// The talker's agent, model and effort (dual mode; its folder and waking
  /// are unused).
  BrainConfig? talker;

  WorkerKind kind;

  /// Codex and Claude: the model picked (null: the agent's default).
  /// Custom: the server's model (required).
  String? model;
  String? effort;

  /// Where the orchestrator works (null: this machine's project folder).
  String? cwd;

  /// Start an orchestrator turn when a worker finishes while it is idle.
  bool wakeOnFinish;

  /// Custom: the Responses API server, the environment variable holding its
  /// key (the name, not the key), and the model's context window.
  String? baseUrl;
  String? envKey;
  int? contextWindow;

  String get label => switch (kind) {
    WorkerKind.codex => 'Codex',
    WorkerKind.claude => 'Claude',
    WorkerKind.custom => 'Custom',
  };

  /// The custom agent as a worker type (its app-server is started the same
  /// way, with a CODEX_HOME of its own and no Computer Use), or why it is
  /// incomplete.
  (WorkerType?, String?) customType() {
    try {
      return (
        WorkerType.customFromJson({
          'id': 'brain',
          'label': 'Custom',
          'base_url': baseUrl ?? '',
          'model': model ?? '',
          'env_key': envKey,
          'context_window': contextWindow,
        }),
        null,
      );
    } on FormatException catch (e) {
      return (
        null,
        e.message.replaceFirst('worker type "brain" ', 'the custom agent '),
      );
    }
  }

  /// Why it cannot be used, or null.
  String? get problem =>
      (kind == WorkerKind.custom ? customType().$2 : null) ??
      (mode == BrainMode.dual
          ? talker == null
                ? 'the talker has no agent'
                : talker!.problem
          : null);

  Json toJson() => {
    if (mode != BrainMode.single) 'mode': mode.name,
    if (mode == BrainMode.dual && talker != null)
      'talker': {
        for (final e in talker!.toJson().entries)
          if (e.key != 'cwd' && e.key != 'wake_on_finish') e.key: e.value,
      },
    'kind': kind.name,
    'model': ?model,
    'effort': ?effort,
    'cwd': ?cwd,
    'wake_on_finish': wakeOnFinish,
    if (kind == WorkerKind.custom) ...{
      'base_url': ?baseUrl,
      'env_key': ?envKey,
      'context_window': ?contextWindow,
    },
  };

  static BrainConfig fromJson(Json j) {
    String? s(String k) {
      final v = j[k] as String?;
      return v == null || v.trim().isEmpty ? null : v.trim();
    }

    return BrainConfig(
      mode: BrainMode.parse(j['mode'] as String?),
      talker: j['talker'] is Map
          ? fromJson((j['talker'] as Map).cast<String, dynamic>())
          : null,
      kind: WorkerKind.parse(j['kind'] as String? ?? 'codex'),
      model: s('model'),
      effort: s('effort'),
      cwd: s('cwd'),
      wakeOnFinish: j['wake_on_finish'] as bool? ?? true,
      baseUrl: s('base_url'),
      envKey: s('env_key'),
      contextWindow: (j['context_window'] as num?)?.toInt(),
    );
  }

  BrainConfig copy() => fromJson(toJson());

  static File fileIn(String stateDir) => File('$stateDir/brain.json');

  /// The saved config, or the default (Codex). `ORCH_ORCHESTRATOR=claude`
  /// (or `codex`) picks the agent for unattended starts.
  static BrainConfig load(String stateDir, Map<String, String> env) {
    final f = fileIn(stateDir);
    final c = f.existsSync()
        ? fromJson((jsonDecode(f.readAsStringSync()) as Map).cast())
        : BrainConfig();
    if (env['ORCH_ORCHESTRATOR'] case final k?
        when k == 'codex' || k == 'claude') {
      if (c.kind.name != k) {
        c
          ..kind = WorkerKind.parse(k)
          ..model = null
          ..effort = null;
      }
    }
    return c;
  }

  void save(String stateDir) {
    final f = fileIn(stateDir);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(toJson()));
  }
}
