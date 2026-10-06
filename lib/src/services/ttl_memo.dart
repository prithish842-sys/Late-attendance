/// Tiny in-memory TTL cache used by [FirebaseFirestoreService] (NEW_TASKS.md
/// B6). FIFO eviction, bounded capacity, injected clock for tests — pure logic,
/// no Firestore involvement.
class TtlMemo<T> {
  TtlMemo(this.ttl, {this.maxEntries = 32})
      : assert(maxEntries > 0, 'maxEntries must be positive');

  final Duration ttl;
  final int maxEntries;
  final Map<String, (T, DateTime)> _entries = {};

  /// Returns the cached value for [key] when it is younger than [ttl],
  /// otherwise null (and the stale entry is dropped).
  T? get(String key, {DateTime? now}) {
    final entry = _entries[key];
    if (entry == null) return null;
    if ((now ?? DateTime.now()).difference(entry.$2) >= ttl) {
      _entries.remove(key);
      return null;
    }
    return entry.$1;
  }

  /// Stores [value] under [key], pruning expired entries first and evicting
  /// the oldest entries when the capacity limit would be exceeded. Overwriting
  /// an existing key refreshes it in place and never evicts (review finding
  /// LOW: the old loop shrank the cache on every overwrite).
  void put(String key, T value, {DateTime? now}) {
    final at = now ?? DateTime.now();
    _entries.removeWhere((_, v) => at.difference(v.$2) >= ttl);
    if (!_entries.containsKey(key)) {
      while (_entries.length >= maxEntries) {
        _entries.remove(_entries.keys.first);
      }
    }
    _entries[key] = (value, at);
  }

  void clear() => _entries.clear();

  int get length => _entries.length;
}
