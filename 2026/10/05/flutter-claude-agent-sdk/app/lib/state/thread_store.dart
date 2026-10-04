import 'dart:convert';
import 'dart:io';

/// Remembers which Agent SDK sessions this app started, so the sidebar reads
/// just those (`getSessionInfo` per id) instead of every session under
/// `~/.claude/projects`, and the section names (sections are session tags;
/// an empty section exists only here).
///
/// `{"sessions": {"<sessionId>": <last used, ms since epoch>}, "sections": [..]}`
class ThreadStore {
  ThreadStore(this.file);

  /// `~/Library/Application Support/<bundle id>/sessions.json`, or
  /// `$CLAUDE_FLUTTER_STATE_DIR/sessions.json`.
  factory ThreadStore.defaultLocation() {
    final env = Platform.environment;
    final dir =
        env['CLAUDE_FLUTTER_STATE_DIR'] ??
        '${env['HOME']}/Library/Application Support/com.kiarina.labs.claudeFlutter';
    return ThreadStore(File('$dir/sessions.json'));
  }

  final File file;
  Map<String, int> _sessions = {};
  List<String> sections = [];

  Future<void> open() async {
    if (!await file.exists()) return;
    final raw = jsonDecode(await file.readAsString()) as Map;
    _sessions = (raw['sessions'] as Map? ?? const {}).map(
      (k, v) => MapEntry(k as String, (v as num).toInt()),
    );
    sections = (raw['sections'] as List? ?? const []).cast<String>().toList();
  }

  int get length => _sessions.length;

  bool contains(String sessionId) => _sessions.containsKey(sessionId);

  /// Session ids, most recently used first.
  List<String> recent({int? limit}) {
    final ids = _sessions.keys.toList()
      ..sort((a, b) => _sessions[b]!.compareTo(_sessions[a]!));
    return limit == null ? ids : ids.take(limit).toList();
  }

  Future<void> touch(String sessionId) async {
    _sessions[sessionId] = DateTime.now().millisecondsSinceEpoch;
    await _save();
  }

  Future<void> remove(String sessionId) async {
    if (_sessions.remove(sessionId) != null) await _save();
  }

  Future<void> setSections(List<String> names) async {
    sections = names;
    await _save();
  }

  Future<void> _lastSave = Future.value();

  /// Writes are chained so two quick updates cannot interleave.
  Future<void> _save() => _lastSave = _lastSave.then((_) => _write());

  Future<void> _write() async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ')
          .convert({'sessions': _sessions, 'sections': sections}),
    );
    await tmp.rename(file.path);
  }
}
