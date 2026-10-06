import 'package:flutter/foundation.dart';

/// Debug-only instrumentation for the QA pass (NEW_TASKS "Phase 8").
///
/// Every line is prefixed `[perf]` so the numbers can be grepped straight out
/// of `flutter run` / DevTools console output, and every call is guarded by
/// `kDebugMode` so the whole helper tree-shakes out of release builds.
///
/// Three things are recorded:
///  * phase timings — `start('scan->verify')` … `stop('scan->verify')`
///  * one-shot markers — `mark(...)`/`stopPending(...)` for cross-widget spans
///    (e.g. Submit tapped on the verify screen, resolved by the dashboard)
///  * Firestore round trips — `db('students.get', docs, ms)` which both logs
///    and accumulates a per-operation count for the end-of-session audit
class PerfLog {
  PerfLog._();

  static final Map<String, Stopwatch> _watches = <String, Stopwatch>{};
  static String? _pending;

  /// Aggregated Firestore stats: op -> {calls, docs, ms}.
  static final Map<String, List<int>> dbStats = <String, List<int>>{};

  static bool enabled = kDebugMode;

  static void start(String label) {
    if (!enabled) return;
    _watches[label] = Stopwatch()..start();
  }

  static void stop(String label) {
    if (!enabled) return;
    final w = _watches.remove(label);
    if (w == null) return;
    w.stop();
    debugPrint('[perf] $label ${w.elapsedMilliseconds}ms');
  }

  /// Start a span that will be closed by a *different* widget (submit →
  /// dashboard). Replaces any span still open with the same label.
  static void startPending(String label) {
    if (!enabled) return;
    _pending = label;
    _watches[label] = Stopwatch()..start();
  }

  /// Close the pending span if (and only if) it is still open.
  static void stopPending() {
    if (!enabled) return;
    final label = _pending;
    if (label == null) return;
    _pending = null;
    stop(label);
  }

  /// One-shot event, no duration — useful as a slice point in a trace.
  static void event(String message) {
    if (!enabled) return;
    debugPrint('[perf] $message');
  }

  /// Record one Firestore round trip. [docs] is the number of documents read
  /// (0 for writes, -1 for a failed call).
  static void db(String op, int docs, int ms, {bool error = false}) {
    if (!enabled) return;
    final s = dbStats.putIfAbsent(op, () => <int>[0, 0, 0, 0]);
    s[0] += 1;
    if (docs > 0) s[1] += docs;
    s[2] += ms;
    if (error) s[3] += 1;
    debugPrint('[perf] db $op ${error ? 'ERROR ' : ''}${docs >= 0 ? 'docs=$docs ' : ''}ms=$ms');
  }

  /// Flush the accumulated Firestore table (called when leaving a screen that
  /// does a lot of work, e.g. before reporting a report-preview measurement).
  static void dumpDb(String scope) {
    if (!enabled || dbStats.isEmpty) return;
    final buf = StringBuffer('[perf] db-summary ($scope) ');
    dbStats.forEach((op, s) {
      buf.write('$op: ${s[0]} calls/${s[1]} docs/${s[2]}ms/${s[3]} errs; ');
    });
    debugPrint(buf.toString());
  }
}
