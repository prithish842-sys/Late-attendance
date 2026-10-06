import 'package:flutter_test/flutter_test.dart';
import 'package:late_attendance/src/services/ttl_memo.dart';

void main() {
  group('TtlMemo (B6)', () {
    test('returns the value inside the TTL and drops it once expired', () {
      final memo = TtlMemo<String>(const Duration(minutes: 5));
      final t0 = DateTime(2026, 10, 1, 8);
      memo.put('key', 'value', now: t0);

      expect(memo.get('key', now: t0.add(const Duration(minutes: 4))), 'value');
      expect(memo.get('key', now: t0.add(const Duration(minutes: 5))), isNull);
      // The expired entry was removed, not just hidden.
      expect(memo.length, 0);
    });

    test('keys are isolated and a later put replaces the same key', () {
      final memo = TtlMemo<int>(const Duration(seconds: 60));
      final t0 = DateTime(2026, 10, 1, 8);
      memo.put('a', 1, now: t0);
      memo.put('b', 2, now: t0);
      expect(memo.get('a', now: t0), 1);
      expect(memo.get('b', now: t0), 2);

      memo.put('a', 11, now: t0);
      expect(memo.get('a', now: t0), 11);
      expect(memo.length, 2);
    });

    test('put prunes expired siblings and enforces the capacity bound', () {
      final memo = TtlMemo<int>(const Duration(seconds: 60), maxEntries: 3);
      final t0 = DateTime(2026, 10, 1, 8);
      memo.put('stale', 0, now: t0);
      memo.put('fresh1', 1, now: t0.add(const Duration(seconds: 50)));

      // A put at +70s prunes the stale entry before writing.
      memo.put('fresh2', 2, now: t0.add(const Duration(seconds: 70)));
      expect(memo.get('stale', now: t0.add(const Duration(seconds: 70))), isNull);
      expect(memo.length, 2);

      // Capacity 3: two more puts evict the oldest surviving entries.
      memo.put('x', 3, now: t0.add(const Duration(seconds: 71)));
      memo.put('y', 4, now: t0.add(const Duration(seconds: 72)));
      expect(memo.length, 3);
      expect(memo.get('y', now: t0.add(const Duration(seconds: 72))), 4);
    });

    test('overwriting an existing key at capacity never evicts siblings', () {
      final memo = TtlMemo<String>(const Duration(minutes: 1), maxEntries: 2);
      final t0 = DateTime(2026, 10, 1, 8);
      memo.put('a', 'A', now: t0);
      memo.put('b', 'B', now: t0);

      memo.put('a', 'A2', now: t0.add(const Duration(seconds: 1)));
      final at = t0.add(const Duration(seconds: 2));
      expect(memo.length, 2);
      expect(memo.get('a', now: at), 'A2');
      expect(memo.get('b', now: at), 'B');
    });

    test('clear empties every entry', () {
      final memo = TtlMemo<String>(const Duration(hours: 1));
      memo.put('a', '1');
      memo.put('b', '2');
      memo.clear();
      expect(memo.length, 0);
      expect(memo.get('a'), isNull);
    });

    test('misses are safe on unknown keys', () {
      final memo = TtlMemo<String>(const Duration(hours: 1));
      expect(memo.get('never-written'), isNull);
    });
  });
}
