import '../models/app_models.dart';
import 'connectivity_service.dart';
import 'firestore_service.dart';
import 'offline_store.dart';

/// Orchestrates a scan regardless of connectivity (Phase 5, docs/TASKS.md).
///
/// Online: behaves exactly like the Phase 1 direct-Firestore path and warms the
/// offline cache as a side effect (roster, settings, period counts). Offline:
/// the roster and settings are served from the cache and the scan is QUEUED
/// for sync-on-reconnect (SyncService) instead of failing — late_logs only ever
/// receives the log via the server-authoritative sync transaction, so
/// SECURITY.md §3 idempotency holds even when the network dropped mid-scan.
///
/// The escalation verdict is never computed here (SECURITY.md §1): offline we
/// surface "currently offline" instead of guessing a verdict.
/// Thrown by [ScanService.recordLate] when the client-side submit cap trips
/// (30 live scans per rolling minute — NEW_TASKS.md B5 rate limiting). The
/// sync path ([ScanService.syncPending]) is deliberately NOT capped: a drained
/// offline queue must always get through. Only the verify screen surfaces this
/// to the operator; every other caller treats it like any other failure.
class ScanRateLimitException implements Exception {
  const ScanRateLimitException({
    this.maxScans = 30,
    this.window = const Duration(seconds: 60),
  });

  final int maxScans;
  final Duration window;

  @override
  String toString() =>
      'ScanRateLimitException: at most $maxScans scans per ${window.inSeconds}s';
}

class ScanService {
  ScanService({
    required this.firestore,
    required this.offline,
    required this.connectivity,
  });

  final FirestoreService firestore;
  final OfflineStore offline;
  final ConnectivityService connectivity;

  Future<bool> get isOnline => connectivity.isOnline();

  /// Live online/offline changes for UI (scan-screen banner).
  Stream<bool> get onlineStream => connectivity.stream();

  /// Settings from the server, cached for offline use. Falls back to the cache
  /// (or server defaults) when the network is down or the read fails.
  Future<ScanSettings> fetchSettings() async {
    try {
      final settings = await firestore.fetchSettings();
      await offline.cacheSettings(settings);
      return settings;
    } on Object catch (e) {
      if (!ConnectivityService.looksLikeOffline(e)) rethrow;
      return offline.cachedSettings() ?? const ScanSettings();
    }
  }

  /// Find a student by code. Online: real lookup, then warm the roster cache.
  /// Offline: cache only (null when this roster has never been refreshed).
  Future<Student?> findStudentByCode(String code) async {
    final trimmed = code.trim();
    if (trimmed.isEmpty) return null;
    if (await connectivity.isOnline()) {
      try {
        final student = await firestore.findStudentByCode(trimmed);
        if (student != null && offline.cachedStudents().isEmpty) {
          await refreshRosterCache();
        }
        return student;
      } on Object catch (e) {
        if (!ConnectivityService.looksLikeOffline(e)) rethrow;
      }
    }
    return _findInCache(trimmed);
  }

  /// Best-effort roster warm-up — never breaks a scan.
  Future<void> refreshRosterCache() async {
    try {
      final students = await firestore.allStudents();
      if (students.isNotEmpty) await offline.cacheStudents(students);
    } on Object {
      // Cache refresh is opportunistic; failures are irrelevant to the scan.
    }
  }

  Student? _findInCache(String code) {
    // Stored IDs/register numbers are uppercase; normalize the typed key so a
    // lowercase manual entry matches too.
    final key = code.trim().toUpperCase();
    for (final s in offline.cachedStudents()) {
      if (s.studentId.toUpperCase() == key) return s;
      final barcode = s.barcode;
      if (barcode != null && barcode.trim() == key) return s;
      final registerNumber = s.registerNumber;
      if (registerNumber != null && registerNumber.trim().toUpperCase() == key) {
        return s;
      }
    }
    return null;
  }

  /// Count of scans waiting to sync (offline banner).
  int pendingCount() => offline.pendingScans().length;

  /// Queued scans captured while offline, oldest first. The dashboard merges
  /// the ones dated today into its today list so the count stays truthful
  /// until SyncService uploads them.
  List<PendingScan> pendingScans() => offline.pendingScans();

  /// Last-known period count for a student, or null if never cached.
  int? cachedPeriodCount(String studentId) => offline.cachedPeriodCount(studentId);

  // Client submit cap (B5): timestamps of the last live recordLate attempts
  // within the rolling window. Pruned on every check, so the list can never
  // outgrow [ScanRateLimitException.maxScans].
  static const int _scanCap = 30;
  static const Duration _scanWindow = Duration(seconds: 60);
  final List<DateTime> _recentSubmits = [];

  bool _admitScanSubmission(DateTime now) {
    _recentSubmits.removeWhere((t) => now.difference(t) >= _scanWindow);
    if (_recentSubmits.length >= _scanCap) return false;
    _recentSubmits.add(now);
    return true;
  }

  /// Record a scan. Online: server transaction, same semantics as Phase 1
  /// (SECURITY.md §3). Offline (or a network failure mid-write): REQUIRED the
  /// student and scan to be queued — the caller treats [RecordOutcome.queued]
  /// as "scan accepted, will sync". Permission / validation errors rethrow.
  /// Throws [ScanRateLimitException] past the client submit cap (B5).
  Future<RecordResult> recordLate({
    required String studentId,
    required String studentName,
    required String scannedBy,
    required String scanMethod,
  }) async {
    if (!_admitScanSubmission(DateTime.now())) {
      throw const ScanRateLimitException();
    }
    if (await connectivity.isOnline()) {
      try {
        final result = await firestore.recordLate(
          studentId: studentId,
          scannedBy: scannedBy,
          scanMethod: scanMethod,
        );
        if (result.outcome == RecordOutcome.recorded) {
          final current = offline.cachedPeriodCount(studentId) ?? 0;
          await offline.cachePeriodCount(studentId, current + 1);
        }
        return result;
      } on Object catch (e) {
        if (!ConnectivityService.looksLikeOffline(e)) rethrow;
      }
    }
    await _queueScan(studentId: studentId, studentName: studentName, scannedBy: scannedBy, scanMethod: scanMethod);
    return const RecordResult.queued();
  }

  /// Sync one queued scan into late_logs. Idempotent: if the deterministic doc
  /// already exists the result is alreadyRecorded and the queue entry is
  /// dropped either way (nothing left behind, nothing duplicated).
  Future<RecordResult> syncPending(PendingScan scan) async {
    final result = await firestore.syncOfflineScan(scan: scan);
    if (result.outcome == RecordOutcome.recorded ||
        result.outcome == RecordOutcome.alreadyRecorded) {
      await offline.removeScan(scan.docId);
    }
    return result;
  }

  Future<void> _queueScan({
    required String studentId,
    required String studentName,
    required String scannedBy,
    required String scanMethod,
  }) async {
    final now = DateTime.now();
    final mm = now.month.toString().padLeft(2, '0');
    final dd = now.day.toString().padLeft(2, '0');
    final docId = '${studentId}_${now.year}-$mm-$dd';
    await offline.enqueueScan(PendingScan(
      studentId: studentId,
      studentName: studentName,
      scannedBy: scannedBy,
      scanMethod: scanMethod,
      deviceTimestamp: now,
      docId: docId,
      queuedAt: now,
    ));
  }
}