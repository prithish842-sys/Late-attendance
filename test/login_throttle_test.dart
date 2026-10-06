import 'package:flutter_test/flutter_test.dart';
import 'package:late_attendance/src/services/login_throttle.dart';

void main() {
  group('LoginThrottle (C1)', () {
    final t0 = DateTime(2026, 10, 1, 9);

    test('allows sign-in below the cap and locks at the 5th failure', () {
      final throttle = LoginThrottle();
      for (var i = 0; i < 4; i++) {
        expect(throttle.recordFailure(t0), isNull, reason: 'attempt ${i + 1}');
      }
      final remaining = throttle.recordFailure(t0);
      expect(remaining, isNotNull);
      expect(remaining, LoginThrottle.defaultWindow);
      expect(throttle.lockedRemaining(t0), isNotNull);
    });

    test('the lock auto-releases once the oldest failure ages out', () {
      final throttle = LoginThrottle();
      // Staggered attempts — one per minute — so only the oldest expires first.
      for (var i = 0; i < 5; i++) {
        throttle.recordFailure(t0.add(Duration(minutes: i)));
      }
      final inside = t0.add(const Duration(minutes: 14));
      expect(throttle.lockedRemaining(inside), isNotNull);

      final after = t0.add(const Duration(minutes: 15, seconds: 1));
      expect(throttle.lockedRemaining(after), isNull);
      // Only the stale entry expired — the ledger is now at 4 failures again.
      expect(throttle.failures.length, 4);
    });

    test('a successful sign-in clears the ledger', () {
      final throttle = LoginThrottle();
      for (var i = 0; i < 5; i++) {
        throttle.recordFailure(t0);
      }
      throttle.recordSuccess();
      expect(throttle.failures, isEmpty);
      expect(throttle.lockedRemaining(t0), isNull);
    });

    test('lock messages stay plain-language and rounded up', () {
      expect(
        LoginThrottle.lockMessage(const Duration(minutes: 15)),
        'Too many failed sign-in attempts — try again in 15 minutes.',
      );
      expect(
        LoginThrottle.lockMessage(const Duration(seconds: 30)),
        'Too many failed sign-in attempts — try again in a moment.',
      );
      expect(
        LoginThrottle.lockMessage(const Duration(minutes: 1, seconds: 40)),
        'Too many failed sign-in attempts — try again in 2 minutes.',
      );
    });
  });
}
