import 'dart:async';

import '../models/app_models.dart';
import 'connectivity_service.dart';
import 'firestore_service.dart';
import 'offline_store.dart';
import 'scan_service.dart';

/// Phase 5 sync-on-reconnect (docs/TASKS.md). Watches the connectivity stream
/// and, the moment the device flips offline → online, drains the pending-scan
/// queue oldest-first into late_logs via the server-authoritative transaction
/// (ScanService.syncPending). Network failures mid-run simply leave the queue
/// intact for the next reconnect/poll — a duplicate write is impossible because
/// of the deterministic doc id (SECURITY.md §3), and an interrupted final remove
/// would only mean the next sync re-asserts alreadyRecorded and drops it.
class SyncService {
  SyncService({
    required this.scan,
    required this.offline,
    required this.connectivity,
  });

  final ScanService scan;
  final OfflineStore offline;
  final ConnectivityService connectivity;

  final _controller = StreamController<SyncResult>.broadcast();
  StreamSubscription<bool>? _subscription;
  bool _started = false;
  bool _online = true;

  /// Listeners get every run's result (e.g. the offline banner "x synced").
  Stream<SyncResult> get onSync => _controller.stream;

  int get pendingCount => offline.pendingScans().length;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _online = await connectivity.isOnline();
    if (_online) await syncNow();
    _subscription = connectivity.stream().listen((online) {
      final turnedOnline = online && !_online;
      _online = online;
      if (turnedOnline) syncNow();
    });
  }

  Future<void> stop() async {
    _started = false;
    await _subscription?.cancel();
    _subscription = null;
  }

  /// Drain the queue. Oldest-first, `synced` counts entries drained (recorded
  /// or alreadyRecorded — both mean "leave the queue"), `remaining` is what
  /// could not be pushed yet (still offline / transient failure).
  Future<SyncResult> syncNow() async {
    var synced = 0;
    for (final pending in offline.pendingScans()) {
      try {
        final result = await scan.syncPending(pending);
        if (result.outcome == RecordOutcome.recorded ||
            result.outcome == RecordOutcome.alreadyRecorded) {
          synced++;
        }
      } on Object {
        // Transient failure — stop and retry on the next signal. The queue is
        // untouched, so nothing is lost and nothing can double-write.
        break;
      }
    }
    final result = SyncResult(synced: synced, remaining: offline.pendingScans().length);
    if (!_controller.isClosed) _controller.add(result);
    return result;
  }
}