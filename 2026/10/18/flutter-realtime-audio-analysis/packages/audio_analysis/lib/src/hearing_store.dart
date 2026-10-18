import 'consumer/events.dart';

/// Time-bounded log of what was heard. Old events fall off by age and count,
/// so memory stays bounded however long the mic is on.
class HearingStore {
  HearingStore({this.retention = const Duration(hours: 1), this.maxEvents = 5000});

  final Duration retention;
  final int maxEvents;
  final List<HearingEvent> _events = [];

  int get length => _events.length;

  void add(HearingEvent event) {
    _events.add(event);
    _events.sort((a, b) => a.start.compareTo(b.start));
    _prune();
  }

  void clear() => _events.clear();

  void _prune() {
    final cutoff = DateTime.now().subtract(retention).millisecondsSinceEpoch / 1000;
    _events.removeWhere((e) => e.end < cutoff);
    while (_events.length > maxEvents) {
      _events.removeAt(0);
    }
  }

  /// What a brain tool would call: events overlapping [since, until] (Unix
  /// seconds), optionally only some kinds, newest last, at most [limit]
  /// (the newest ones are kept).
  List<HearingEvent> query({double? since, double? until, Set<String>? kinds, int limit = 100}) {
    _prune();
    final matched = _events.where((e) {
      if (since != null && e.end < since) return false;
      if (until != null && e.start > until) return false;
      if (kinds != null && !kinds.contains(e.kind)) return false;
      return true;
    }).toList();
    if (matched.length <= limit) return matched;
    return matched.sublist(matched.length - limit);
  }
}
