import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

import '../models/app_models.dart';

/// Local-first cache and pending-scan queue for Phase 5 offline mode
/// (docs/TASKS.md, docs/ARCHITECTURE.md §2). Two implementations exist:
/// [HiveOfflineStore] for the device (Hive boxes under the app support
/// directory) and [MemoryOfflineStore] for widget tests. Everything stored is
/// a primitive or a Map so Hive needs no code generation — the roster cache
/// deliberately strips photoBase64 to keep the cache lean.
abstract class OfflineStore {
  /// Replace the cached roster snapshot. Photos are stripped by the
  /// implementation before persisting; in-memory copies keep them so an
  /// offline scan still verifies the identity card visual and name.
  Future<void> cacheStudents(List<Student> students);

  /// Students currently in the cache, in roster order. Empty when the roster
  /// has never been refreshed while online.
  List<Student> cachedStudents();

  Future<void> cacheSettings(ScanSettings settings);
  ScanSettings? cachedSettings();

  /// Last-known period count for a student (for the offline badge). Stored per
  /// studentId, refreshed on successful online records and cache warmups.
  Future<void> cachePeriodCount(String studentId, int count);
  int? cachedPeriodCount(String studentId);

  /// Queue a scan captured while offline. Keyed by the deterministic doc id
  /// (`studentId_YYYY-MM-DD`, SECURITY.md §3) so re-queues overwrite.
  Future<void> enqueueScan(PendingScan scan);

  /// Pending scans, oldest first (capture order for the sync loop).
  List<PendingScan> pendingScans();

  Future<void> removeScan(String docId);

  /// Drop every cached value + pending scan (logout, storage full, tests).
  Future<void> clear();
}

/// Hive-backed store. Call [open] once after `Hive.init` (init is done by the
/// app with `getApplicationSupportDirectory` so the device storage survives
/// restarts). All reads are synchronous after open — Hive writes to an already
/// opened box are synchronous too, which keeps the scan path lock-free.
class HiveOfflineStore implements OfflineStore {
  HiveOfflineStore._(this._studentsBox, this._settingsBox, this._countsBox, this._pendingBox);

  static const _studentsKey = 'roster';
  static const _settingsKey = 'settings';

  final Box _studentsBox;
  final Box _settingsBox;
  final Box _countsBox;
  final Box _pendingBox;

  /// Open all four boxes. Throws if Hive wasn't initialized first.
  static Future<HiveOfflineStore> open() async {
    final students = await Hive.openBox<dynamic>('offline_students');
    final settings = await Hive.openBox<dynamic>('offline_settings');
    final counts = await Hive.openBox<dynamic>('offline_counts');
    final pending = await Hive.openBox<dynamic>('offline_pending_scans');
    return HiveOfflineStore._(students, settings, counts, pending);
  }

  List<Student> get _roster {
    final raw = _studentsBox.get(_studentsKey);
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((m) => Student.fromCacheMap(Map<String, dynamic>.from(m)))
        .toList();
  }

  @override
  Future<void> cacheStudents(List<Student> students) async {
    final lean = students
        .map((s) => s.toCacheMap())
        .toList();
    await _studentsBox.put(_studentsKey, lean);
  }

  @override
  List<Student> cachedStudents() => _roster;

  @override
  Future<void> cacheSettings(ScanSettings settings) async {
    await _settingsBox.put(_settingsKey, {
      'escalationThreshold': settings.escalationThreshold,
      'resetPeriod': settings.resetPeriod,
    });
  }

  @override
  ScanSettings? cachedSettings() {
    final raw = _settingsBox.get(_settingsKey);
    if (raw is! Map) return null;
    return ScanSettings.fromFirestore(Map<String, dynamic>.from(raw));
  }

  @override
  Future<void> cachePeriodCount(String studentId, int count) async {
    await _countsBox.put(studentId, count);
  }

  @override
  int? cachedPeriodCount(String studentId) => _countsBox.get(studentId) as int?;

  @override
  Future<void> enqueueScan(PendingScan scan) async {
    await _pendingBox.put(scan.docId, scan.toJson());
  }

  @override
  List<PendingScan> pendingScans() {
    final list = _pendingBox.values
        .whereType<Map>()
        .map((m) => PendingScan.fromJson(Map<String, dynamic>.from(m)))
        .toList()
      ..sort((a, b) {
        final ta = a.queuedAt ?? a.deviceTimestamp;
        final tb = b.queuedAt ?? b.deviceTimestamp;
        return ta.compareTo(tb);
      });
    return list;
  }

  @override
  Future<void> removeScan(String docId) async {
    await _pendingBox.delete(docId);
  }

  @override
  Future<void> clear() async {
    for (final box in [_studentsBox, _settingsBox, _countsBox, _pendingBox]) {
      await box.clear();
    }
  }
}

/// In-memory store for widget tests and previews. Mirrors Hive semantics
/// (sorted pending list, map keyed by docId) without touching disk.
class MemoryOfflineStore implements OfflineStore {
  List<Student> _students = const [];
  ScanSettings? _settings;
  final _counts = <String, int>{};
  final _pending = <String, PendingScan>{};

  @override
  Future<void> cacheStudents(List<Student> students) async {
    _students = List.of(students);
  }

  @override
  List<Student> cachedStudents() => _students;

  @override
  Future<void> cacheSettings(ScanSettings settings) async {
    _settings = settings;
  }

  @override
  ScanSettings? cachedSettings() => _settings;

  @override
  Future<void> cachePeriodCount(String studentId, int count) async {
    _counts[studentId] = count;
  }

  @override
  int? cachedPeriodCount(String studentId) => _counts[studentId];

  @override
  Future<void> enqueueScan(PendingScan scan) async {
    _pending[scan.docId] = scan;
  }

  @override
  List<PendingScan> pendingScans() {
    final list = _pending.values.toList()
      ..sort((a, b) {
        final ta = a.queuedAt ?? a.deviceTimestamp;
        final tb = b.queuedAt ?? b.deviceTimestamp;
        return ta.compareTo(tb);
      });
    return list;
  }

  @override
  Future<void> removeScan(String docId) async {
    _pending.remove(docId);
  }

  @override
  Future<void> clear() async {
    _students = const [];
    _settings = null;
    _counts.clear();
    _pending.clear();
  }
}

/// Resolve the app-support directory the device uses for Hive boxes. Split out
/// so tests can point Hive.init at a temp dir without importing path_provider
/// mocking plumbing. On web there is no filesystem: path_provider has no web
/// implementation (it would throw "No implementation found ... on channel
/// path_provider") and Hive's web backend stores boxes in IndexedDB, which
/// ignores the path — so return a harmless placeholder.
Future<String> defaultHiveDirectory() async {
  if (kIsWeb) return '';
  final dir = await getApplicationSupportDirectory();
  return dir.path;
}