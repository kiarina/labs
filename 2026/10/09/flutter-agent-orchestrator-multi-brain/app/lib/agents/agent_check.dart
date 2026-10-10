import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../body/body.dart' show claudeLoggedIn;
import '../rpc/rpc_client.dart';
import 'worker_types.dart';

/// A model a custom server lists.
class ModelInfo {
  const ModelInfo(this.id, this.contextWindow);

  final String id;
  final int? contextWindow;
}

/// One thing a tool needs on this machine, and whether it is there.
class Requirement {
  const Requirement(this.name, this.ok, this.detail, {this.settingsPane, this.grant});

  final String name;
  final bool ok;
  final String detail;

  /// System Settings › Privacy & Security pane to open to fix it.
  final String? settingsPane;

  /// This app's permission that fixes it (`screenRecording`,
  /// `accessibility`): the start screen asks macOS for it.
  final String? grant;
}

/// The outcome of checking one agent on the start screen.
class CheckResult {
  const CheckResult(this.ok, this.text, {this.needsLogin = false});

  final bool ok;
  final String text;

  /// Codex is reachable but not logged in: the screen offers to log in.
  final bool needsLogin;
}

/// Checks, on the start screen, that what is turned on can run here: the
/// backend starts and is logged in, the working directory can be read (which
/// also brings up macOS's folder permission prompt now, while someone is
/// there), and a custom server answers. Nothing here spends model tokens.
class AgentChecker {
  const AgentChecker();

  Future<CheckResult> codex(String? cwd) async {
    if (_dir(cwd) case final e?) return CheckResult(false, e);
    final c = await codexAppServer(name: 'codex-check');
    try {
      await _initCodex(c);
      final a = await c.request('account/read', {}) as Map;
      final account = a['account'] as Map?;
      if (account == null) {
        return const CheckResult(false, 'Not logged in', needsLogin: true);
      }
      return CheckResult(true, 'Logged in (${account['planType'] ?? account['type'] ?? 'ok'})');
    } catch (e) {
      return CheckResult(false, '$e');
    } finally {
      c.dispose();
    }
  }

  /// Starts Codex's ChatGPT login: opens the browser and waits for it to
  /// finish (up to 5 minutes).
  Future<CheckResult> codexLogin() async {
    final c = await codexAppServer(name: 'codex-login');
    try {
      await _initCodex(c);
      final done = c.notifications
          .firstWhere((n) => n.method == 'account/login/completed')
          .timeout(const Duration(minutes: 5));
      final r = await c.request('account/login/start', {'type': 'chatgpt'}) as Map;
      await Process.run('open', [r['authUrl'] as String]);
      final n = await done;
      if (n.params['success'] == false) {
        return CheckResult(false, 'Login failed: ${n.params['error'] ?? 'unknown'}');
      }
      return const CheckResult(true, 'Logged in');
    } on TimeoutException {
      return const CheckResult(false, 'Login did not finish in 5 minutes');
    } catch (e) {
      return CheckResult(false, '$e');
    } finally {
      c.dispose();
    }
  }

  Future<CheckResult> claude(String? cwd) async {
    if (_dir(cwd) case final e?) return CheckResult(false, e);
    final RpcClient c;
    try {
      c = claudeBridge();
    } catch (e) {
      return CheckResult(false, '$e');
    }
    try {
      await c.start();
      final r = await c
          .request('initialize', {'cwd': expandHome(cwd) ?? Platform.environment['HOME'] ?? '/'})
          .timeout(const Duration(seconds: 30)) as Map;
      final account = (r['account'] as Map?)?.cast<String, dynamic>();
      if (!claudeLoggedIn(account)) {
        return const CheckResult(false, 'Not logged in: run `claude auth login` in a terminal, then check again');
      }
      return CheckResult(true, 'Logged in (${account!['subscriptionType'] ?? account['email'] ?? 'ok'})');
    } catch (e) {
      return CheckResult(false, '$e');
    } finally {
      c.dispose();
    }
  }

  /// The server's models (`GET {baseUrl}/models`, with the API key from the
  /// environment variable [envKey] if set): their ids and context windows
  /// when the server tells. Returns the models or why there are none.
  Future<(List<ModelInfo>?, String?)> models(String baseUrl, String? envKey) async {
    String? key;
    if (envKey != null && envKey.isNotEmpty) {
      key = Platform.environment[envKey];
      if (key == null || key.isEmpty) {
        return (null, '\$$envKey is not set in this app\'s environment (ORCH_FORWARD_ENV)');
      }
    }
    final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse('$base/models');
    if (base.isEmpty || uri == null || !uri.hasScheme) {
      return (null, 'Enter a URL like http://127.0.0.1:8500/v1');
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await client.getUrl(uri);
      if (key != null) req.headers.set('authorization', 'Bearer $key');
      final res = await req.close().timeout(const Duration(seconds: 5));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode == 401 || res.statusCode == 403) {
        return (null, 'The server refused the key (${res.statusCode})');
      }
      if (res.statusCode == 404) return (const <ModelInfo>[], null);
      if (res.statusCode != 200) return (null, 'HTTP ${res.statusCode} from $uri');
      return (
        [
          for (final m in ((jsonDecode(body) as Map)['data'] as List? ?? const []).cast<Map>())
            if (m['id'] is String)
              ModelInfo(m['id'] as String, (m['context_window'] as num?)?.toInt()),
        ],
        null,
      );
    } catch (e) {
      return (null, 'Cannot reach $base: $e');
    } finally {
      client.close();
    }
  }

  /// The server answers and has [WorkerType.model].
  Future<CheckResult> custom(WorkerType t) async {
    if (_dir(t.cwd) case final e?) return CheckResult(false, e);
    final (list, error) = await models(t.baseUrl!, t.envKey);
    if (error != null) return CheckResult(false, error);
    if (list!.isEmpty) {
      return const CheckResult(true, 'Reachable (it has no model list to check the model against)');
    }
    final ids = [for (final m in list) m.id];
    return ids.contains(t.model)
        ? CheckResult(true, 'Reachable, has ${t.model}')
        : CheckResult(false, 'Reachable, but no model ${t.model} (has: ${ids.take(5).join(', ')})');
  }

  /// What Codex's Computer Use needs here (Codex and custom agents): the
  /// Codex Computer Use app, and its plugin turned on in `~/.codex`. The
  /// app holds its own macOS permissions (set up from the Codex app).
  Future<List<Requirement>> computerUse() async {
    final home = Platform.environment['HOME'] ?? '';
    final app = Directory('$home/.codex/computer-use/Codex Computer Use.app').existsSync();
    final config = File('$home/.codex/config.toml');
    final text = config.existsSync() ? config.readAsStringSync() : '';
    final plugin = RegExp(
      r'\[plugins\."computer-use@openai-bundled"\]\s*\n\s*enabled\s*=\s*true',
    ).hasMatch(text);
    return [
      Requirement(
        'Codex Computer Use',
        app,
        app ? 'Installed (it holds its own macOS permissions)' : 'Not installed: set up Computer Use in the Codex app',
      ),
      Requirement(
        'Computer Use plugin',
        plugin,
        plugin ? 'On in ~/.codex' : 'Off in ~/.codex: turn on Computer Use in the Codex app',
      ),
    ];
  }

  /// What Claude in Chrome needs: Chrome, and the extension's connector
  /// (its native messaging host). Whether the extension is signed in shows
  /// only when a worker uses it.
  Future<List<Requirement>> chrome() async {
    final home = Platform.environment['HOME'] ?? '';
    final chrome = ['/Applications/Google Chrome.app', '$home/Applications/Google Chrome.app']
        .any((p) => Directory(p).existsSync());
    final host = File(
      '$home/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.anthropic.claude_code_browser_extension.json',
    ).existsSync();
    return [
      Requirement('Google Chrome', chrome, chrome ? 'Installed' : 'Not installed'),
      Requirement(
        'Claude in Chrome',
        host,
        host ? 'Connector installed' : 'Install the Claude extension in Chrome, then run `claude --chrome` once',
      ),
    ];
  }

  /// What Mac control through Peekaboo needs: the `peekaboo` command, and
  /// Screen Recording and Accessibility. Workers run it with `--no-remote`
  /// (inside this app), so they are this app's permissions; checked the same
  /// way, from this app.
  Future<List<Requirement>> peekaboo() async {
    final bin = Platform.environment['PEEKABOO_BIN'] ?? '/opt/homebrew/bin/peekaboo';
    if (!File(bin).existsSync()) {
      return const [Requirement('Peekaboo', false, 'Not installed: brew install openclaw/tap/peekaboo')];
    }
    try {
      final r = await Process.run(bin, ['permissions', '--json', '--no-remote'])
          .timeout(const Duration(seconds: 20));
      final data = ((jsonDecode(r.stdout as String) as Map)['data'] as Map?) ?? const {};
      return [
        const Requirement('Peekaboo', true, 'Installed'),
        for (final p in (data['permissions'] as List? ?? const []).cast<Map>())
          if (p['isRequired'] == true)
            Requirement(
              'Peekaboo: ${p['name']}',
              p['isGranted'] == true,
              p['isGranted'] == true ? 'Granted (to this app)' : 'Not granted to this app',
              settingsPane: switch (p['name']) {
                'Screen Recording' => 'Privacy_ScreenCapture',
                'Accessibility' => 'Privacy_Accessibility',
                _ => null,
              },
              grant: switch (p['name']) {
                'Screen Recording' => 'screenRecording',
                'Accessibility' => 'accessibility',
                _ => null,
              },
            ),
      ];
    } catch (e) {
      return [Requirement('Peekaboo', false, 'peekaboo permissions failed: $e')];
    }
  }

  Future<void> _initCodex(RpcClient c) async {
    await c.start();
    await c.request('initialize', {
      'clientInfo': {
        'name': 'agent_orchestrator',
        'title': 'Agent Orchestrator (lab)',
        'version': '0.1.0',
      },
      'capabilities': {'experimentalApi': true, 'requestAttestation': false},
    }).timeout(const Duration(seconds: 20));
    c.notify('initialized');
  }

  /// Lists [cwd]: it must exist, and reading it now raises macOS's folder
  /// prompt (Documents, Desktop, …) while someone is at the screen.
  String? _dir(String? cwd) {
    final path = expandHome(cwd);
    if (path == null) return null;
    final d = Directory(path);
    if (!d.existsSync()) return 'No folder $path';
    try {
      d.listSync().take(1).toList();
    } on FileSystemException catch (e) {
      return 'Cannot read $path: ${e.osError?.message ?? e.message}';
    }
    return null;
  }
}
