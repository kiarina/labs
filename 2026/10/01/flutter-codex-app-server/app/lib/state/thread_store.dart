import 'dart:convert';
import 'dart:io';

/// Remembers which threads this app started, so the sidebar can read just
/// those (`thread/read` per id) instead of scanning every local thread.
///
/// Stored as JSON per CODEX_HOME, because thread ids only make sense against
/// the app-server's own home:
/// `{"<codexHome>": {"<threadId>": <last used, ms since epoch>}}`.
class ThreadStore {
  ThreadStore(this.file);

  /// `~/Library/Application Support/<bundle id>/threads.json`, or
  /// `$CODEX_FLUTTER_STATE_DIR/threads.json`.
  factory ThreadStore.defaultLocation() {
    final env = Platform.environment;
    final dir =
        env['CODEX_FLUTTER_STATE_DIR'] ??
        '${env['HOME']}/Library/Application Support/com.kiarina.labs.codexFlutter';
    return ThreadStore(File('$dir/threads.json'));
  }

  final File file;
  Map<String, Map<String, int>> _data = {};
  String _home = '';

  /// Entries for the opened CODEX_HOME. Before [open] there is nothing to
  /// read, and nothing is written under an empty key.
  Map<String, int> get _threads =>
      _home.isEmpty ? <String, int>{} : _data.putIfAbsent(_home, () => {});

  /// Loads the file and selects the entries for [codexHome]. Returns false
  /// when this CODEX_HOME has never been seen (nothing to show yet).
  Future<bool> open(String codexHome) async {
    _home = codexHome;
    if (await file.exists()) {
      final raw = jsonDecode(await file.readAsString()) as Map;
      _data = {
        for (final e in raw.entries)
          e.key as String: (e.value as Map).map(
            (k, v) => MapEntry(k as String, (v as num).toInt()),
          ),
      };
    }
    _data.remove('');
    return _data.containsKey(codexHome);
  }

  int get length => _threads.length;

  bool contains(String threadId) => _threads.containsKey(threadId);

  /// Thread ids, most recently used first.
  List<String> recent({int? limit}) {
    final ids = _threads.keys.toList()
      ..sort((a, b) => _threads[b]!.compareTo(_threads[a]!));
    return limit == null ? ids : ids.take(limit).toList();
  }

  Future<void> touch(String threadId, [int? atMs]) async {
    final at = atMs ?? DateTime.now().millisecondsSinceEpoch;
    final old = _threads[threadId];
    if (old != null && old >= at) return;
    _threads[threadId] = at;
    await _save();
  }

  Future<void> addAll(Map<String, int> threads) async {
    _threads.addAll(threads);
    await _save();
  }

  Future<void> remove(String threadId) async {
    if (_threads.remove(threadId) != null) await _save();
  }

  Future<void> _lastSave = Future.value();

  /// Writes are chained so two quick updates cannot interleave.
  Future<void> _save() => _lastSave = _lastSave.then((_) => _write());

  Future<void> _write() async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(_data));
    await tmp.rename(file.path);
  }
}
