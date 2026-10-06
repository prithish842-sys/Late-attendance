/// Client-side sign-in attempt limiter (NEW_TASKS.md C1): at most
/// [maxAttempts] failures inside a sliding [window] before sign-in is blocked
/// for the remainder of the window. Pure logic with an injectable clock — the
/// storage layer (login screen state / localStorage) lives at the call sites.
///
/// This is defence-in-depth, not a security boundary: a determined attacker
/// can clear app state. Firebase Auth's own `too-many-requests` backstop still
/// applies server-side.
class LoginThrottle {
  LoginThrottle({
    this.maxAttempts = 5,
    this.window = const Duration(minutes: 15),
  });

  static const int defaultMaxAttempts = 5;
  static const Duration defaultWindow = Duration(minutes: 15);

  final int maxAttempts;
  final Duration window;
  final List<DateTime> _failures = [];

  /// Failure timestamps still inside the window (oldest first).
  List<DateTime> get failures => List.unmodifiable(_failures);

  /// Remaining lock, or null when sign-in is allowed. Auto-releases once the
  /// oldest failure ages out — no separate unlock step.
  Duration? lockedRemaining(DateTime now) {
    _prune(now);
    if (_failures.length < maxAttempts) return null;
    final remaining = _failures.first.add(window).difference(now);
    return remaining.isNegative ? null : remaining;
  }

  /// Record a failed attempt; returns the remaining lock (null = still free).
  Duration? recordFailure(DateTime now) {
    _failures.add(now);
    return lockedRemaining(now);
  }

  /// A successful sign-in wipes the ledger.
  void recordSuccess() => _failures.clear();

  void _prune(DateTime now) =>
      _failures.removeWhere((t) => now.difference(t) >= window);

  /// Plain-language lock message (DESIGN.md §5): whole minutes rounded up,
  /// "a moment" below one minute.
  static String lockMessage(Duration remaining) {
    final minutes = (remaining.inSeconds + 59) ~/ 60;
    if (minutes <= 1) {
      return 'Too many failed sign-in attempts — try again in a moment.';
    }
    return 'Too many failed sign-in attempts — try again in $minutes minutes.';
  }
}
