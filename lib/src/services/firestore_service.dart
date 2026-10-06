import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';

import '../config/app_config.dart';
import '../models/app_models.dart';
import 'perf_log.dart';
import 'ttl_memo.dart';

/// Result of trying to record a late log. The deterministic doc id
/// (`studentId_YYYY-MM-DD`, SECURITY.md §3) is what makes duplicates
/// impossible — enforced in a transaction here. `queued` is Phase 5: the scan
/// was captured offline and queued locally for sync-on-reconnect rather than
/// written now (no network to enforce the idempotency guarantee yet).
enum RecordOutcome { recorded, alreadyRecorded, queued }

class RecordResult {
  const RecordResult.recorded() : outcome = RecordOutcome.recorded;
  const RecordResult.alreadyRecorded() : outcome = RecordOutcome.alreadyRecorded;
  const RecordResult.queued() : outcome = RecordOutcome.queued;

  final RecordOutcome outcome;
}

abstract class FirestoreService {
  Future<Student?> findStudentByCode(String code);
  Future<ScanSettings> fetchSettings();
  Stream<int> lateCountInPeriod(String studentId);

  /// Live late logs for the current LOCAL calendar day, joined with the
  /// student's name/department/year. The window is recomputed per listen, so at
  /// the next local calendar day a fresh subscription naturally yields zero —
  /// the daily reset is a view/query reset (NEW_DECISIONS.md §4), never a
  /// delete. The dashboard is the primary consumer.
  Stream<List<LateLogEntry>> todayLateLogs();

  /// Full roster snapshot for list screens and the offline cache (Phase 5).
  /// The cache layer strips photoBase64 before persisting; the raw list here
  /// is only touched while the app is online.
  Future<List<Student>> allStudents();

  /// True once the deterministic doc id for today exists (SECURITY.md §3).
  Stream<bool> alreadyRecordedToday(String studentId);

  /// Server-authoritative escalation state for the current reset period
  /// (escalation_queue/{studentId}_{period}). Null until the server decides
  /// (SECURITY.md §1 — the app only displays this).
  Stream<EscalationVerdict?> escalationVerdict(String studentId);

  /// All department reference docs (id, name, HOD email). Read-only client
  /// surface (firestore.rules) — used by the HOD mail screen to know the
  /// recipient and the canonical departmentId for a mail request.
  Future<List<DepartmentInfo>> departments();

  /// Escalated students for `period` (status=escalated in escalation_queue),
  /// grouped by department and enriched with current photo/name from students.
  /// `departmentId` on each group is the canonical id for enqueuing a mail.
  Future<List<EscalationGroup>> escalatedGroups(String period);

  /// Enqueue an escalation-mail request for a department (mail_queue create —
  /// the only client-writable path in Phase 3; the send itself is server-only).
  /// Mirrors the mail_queue doc shape that scripts/process-mail.js consumes.
  Future<void> enqueueMailRequest({
    required String departmentId,
    required String department,
    required String period,
    required List<String> studentIds,
    required String requestedBy,
  });

  /// Late entries in an inclusive local day range, joined with the student's
  /// name/department/year, optionally filtered by department (resolved with the
  /// same fuzzy rule the server uses) and year. Mirrors the report generator's
  /// server-side row build for the preview card.
  Future<List<ReportRow>> reportRows({
    required DateTime start,
    required DateTime end,
    DepartmentInfo? department,
    String? year,
  });

  /// Distinct `year` values currently on file, to offer as report filters.
  Future<List<String>> reportYears();

  /// Enqueue an attendance-report request (`report_requests` create — the only
  /// client-writable path in Phase 4; generation itself is server-only).
  /// Mirrors the report_requests doc shape that scripts/generate-report.js
  /// consumes. `department` is sent as the canonical department id.
  Future<void> enqueueReportRequest({
    required ReportFilters filters,
    required String requestedBy,
  });

  /// Enqueue a HOD report-mail request (`mail_queue` create with `type:
  /// "report"` — Phase 2 of docs-new-updates/NEW_TASKS.md). The send itself is
  /// server-only: the runner resolves the recipient, rebuilds the filtered
  /// rows, attaches the PDF(s)/Excel and writes the mail_logs audit row.
  Future<void> enqueueReportMail({
    required String departmentId,
    required String department,
    required String periodType,
    required String startDate,
    required String endDate,
    required String attachmentMode,
    String? year,
    required String requestedBy,
  });

  /// Enqueue a weekly-audit HOD mail request (`mail_queue` create with
  /// `type:"weekly_audit"` — Phase 3 of docs-new-updates/NEW_TASKS.md). The send
  /// itself is server-only: the runner resolves the Monday→Sunday window,
  /// aggregates the week server-authoritatively, builds the PDF/Excel, sends
  /// and writes the mail_logs audit row. `startDate` is the Monday the week
  /// begins on (YYYY-MM-DD).
  Future<void> enqueueWeeklyAuditMail({
    required String departmentId,
    required String department,
    required String startDate,
    required String requestedBy,
  });

  /// Chronological HOD mail audit trail (mail_logs, newest first). Server-only
  /// writes; staff read them read-only (firestore.rules).
  Future<List<MailLogEntry>> recentMailLogs({int limit = 40});

  // ── Phase 4 Admin reads + lifecycle intents ───────────────────────────────

  /// Deletion evidence rows (deletion_records, newest first) for the Recently
  /// Deleted screen. Admin-only reads (firestore.rules); includes students
  /// already permanently deleted (their evidence row is retained).
  Future<List<DeletionRecord>> deletionRecords({int limit = 200});

  /// Batch-import history (import_batches, newest first) — batch metadata.
  Future<List<ImportBatchMeta>> importBatches({int limit = 50});

  /// Enqueue a Phase 4 admin lifecycle/import intent (`admin_requests` create —
  /// the only client-writable admin path on Spark; scripts/process-admin.js is
  /// the server-side consumer, and the Blaze callables do the same work). The
  /// server re-validates everything; this is just the raw request event.
  Future<void> enqueueAdminRequest({
    required String type,
    String? importId,
    String? filename,
    String? departmentId,
    String? department,
    List<ImportRow>? rows,
    List<String>? studentIds,
    String? reason,
    required String requestedBy,
  });

  Future<RecordResult> recordLate({
    required String studentId,
    required String scannedBy,
    required String scanMethod,
  });

  /// Push a scan that was captured while offline into late_logs. The doc id
  /// and deviceTimestamp come from the queue untouched (SECURITY.md §3), and
  /// `syncedOffline:true` marks the log — the server's escalateLateLog trigger
  /// (Blaze) or scripts/process-offline-sync.js (Spark) then compares the
  /// device clock against its own receipt time and writes offline_sync_flags
  /// when the mismatch matters (SECURITY.md §2). Idempotent: if the
  /// deterministic doc already exists the scan resolves to alreadyRecorded and
  /// SyncService drops it from the queue.
  Future<RecordResult> syncOfflineScan({required PendingScan scan});
}

class FirebaseFirestoreService implements FirestoreService {
  FirebaseFirestoreService({FirebaseFirestore? db})
      : _db = db ??
            FirebaseFirestore.instanceFor(
              app: Firebase.app(),
              databaseId: AppConfig.firestoreDatabaseId,
            );

  final FirebaseFirestore _db;

  /// QA instrumentation (NEW_TASKS Phase 8): times [run], records the round
  /// trip through [PerfLog.db] with the document count produced by [count].
  Future<T> _track<T>(String op, Future<T> Function() run, {int Function(T)? count}) async {
    final sw = Stopwatch()..start();
    try {
      final value = await run();
      sw.stop();
      PerfLog.db(op, count == null ? 0 : count(value), sw.elapsedMilliseconds);
      return value;
    } catch (_) {
      sw.stop();
      PerfLog.db(op, -1, sw.elapsedMilliseconds, error: true);
      rethrow;
    }
  }

  @override
  Future<Student?> findStudentByCode(String code) async {
    final trimmed = code.trim();
    if (trimmed.isEmpty) return null;

    // Lookup by student ID (doc id) first — the document ID is the studentId.
    final byId = await _track(
      'students.doc.get',
      () => _db.collection('students').doc(trimmed).get(),
      count: (s) => s.exists ? 1 : 0,
    );
    if (byId.exists) {
      return Student.fromFirestore(byId.id, byId.data() ?? {});
    }

    // Fall back to the barcode number printed on the ID card.
    final byBarcode = await _track(
      'students.barcodeQuery',
      () => _db
          .collection('students')
          .where('barcode', isEqualTo: trimmed)
          .limit(1)
          .get(),
      count: (s) => s.size,
    );
    if (byBarcode.docs.isNotEmpty) {
      final d = byBarcode.docs.first;
      return Student.fromFirestore(d.id, d.data());
    }

    // Scratched/unreadable barcodes: fall back to the register number printed
    // on the card (always readable). Stored values are uppercase, so the key
    // is normalized for this field query only.
    final regKey =
        trimmed == trimmed.toUpperCase() ? trimmed : trimmed.toUpperCase();
    final byRegister = await _track(
      'students.registerNumberQuery',
      () => _db
          .collection('students')
          .where('registerNumber', isEqualTo: regKey)
          .limit(1)
          .get(),
      count: (s) => s.size,
    );
    if (byRegister.docs.isNotEmpty) {
      final d = byRegister.docs.first;
      return Student.fromFirestore(d.id, d.data());
    }
    return null;
  }

  @override
  Future<ScanSettings> fetchSettings() async {
    try {
      final doc = await _track(
        'settings.get',
        () => _db.collection('settings').doc('default').get(),
        count: (s) => s.exists ? 1 : 0,
      );
      if (doc.exists) return ScanSettings.fromFirestore(doc.data() ?? {});
    } on FirebaseException {
      // Fall back to defaults if the settings read fails.
    }
    return const ScanSettings();
  }

  @override
  Future<List<Student>> allStudents() async {
    // B8 note: a field projection (photos excluded) would cut this read to a
    // fraction — evaluated and BLOCKED: cloud_firestore 6.10 exposes no
    // Query.select() (only the new Pipeline API). Follow-up: move photoBase64
    // to Storage/separate docs (docs/ARCHITECTURE.md already anticipates it).
    final snap = await _track(
      'students.get',
      () => _db.collection('students').get(),
      count: (s) => s.size,
    );
    final list = snap.docs
        .map((d) => Student.fromFirestore(d.id, d.data()))
        .toList()
      ..sort((a, b) => a.studentId.compareTo(b.studentId));
    return list;
  }

  /// Count of late_logs for `studentId` in the current reset period.
  /// Phase 1 supports the seeded `monthly` reset period (settings doc).
  /// Uses the composite index (studentId, scanTimestamp) in
  /// firestore.indexes.json.
  @override
  Stream<int> lateCountInPeriod(String studentId) {
    final now = DateTime.now();
    final start = DateTime.utc(now.year, now.month, 1);
    final end = DateTime.utc(now.year, now.month + 1, 1);
    return _db
        .collection('late_logs')
        .where('studentId', isEqualTo: studentId)
        .where('scanTimestamp', isGreaterThanOrEqualTo: start)
        .where('scanTimestamp', isLessThan: end)
        .snapshots()
        .map((snap) => snap.docs.length);
  }

  /// Local-day window for the dashboard's today stream. [today] is the instant
  /// the subscription starts; the window is fixed for the life of that
  /// subscription (the dashboard re-subscribes at the next local midnight to
  /// get the new window — a view reset, no data deletion).
  @override
  Stream<List<LateLogEntry>> todayLateLogs() {
    final now = DateTime.now();
    final startLocal = DateTime(now.year, now.month, now.day);
    final endLocal = startLocal.add(const Duration(days: 1));
    final startUtc = startLocal.toUtc();
    final endUtc = endLocal.toUtc();

    // QA fix: the full roster used to be re-downloaded on EVERY emission of
    // this stream — one whole `students` collection read per new scan while
    // the dashboard was open. The roster is now loaded once per subscription
    // and only refreshed if a scan arrives for a student this cache does not
    // know yet (admin added someone mid-day), and at most once for that case.
    var roster = <String, Map<String, dynamic>>{};
    var rosterLoaded = false;
    var rosterRefreshedForUnknown = false;

    Future<Map<String, Map<String, dynamic>>> rosterFor(
      Set<String> neededIds,
    ) async {
      final missing = neededIds.any((id) => !roster.containsKey(id));
      final shouldLoad = !rosterLoaded ||
          (missing && !rosterRefreshedForUnknown);
      if (!shouldLoad) return roster;
      final label = rosterLoaded
          ? 'students.get (today roster refresh)'
          : 'students.get (today roster load)';
      final studentsSnap = await _track(
        label,
        () => _db.collection('students').get(),
        count: (s) => s.size,
      );
      final wasLoaded = rosterLoaded;
      roster = {for (final d in studentsSnap.docs) d.id: d.data()};
      rosterLoaded = true;
      // Only the mid-session refresh counts against the one-refresh budget —
      // the initial load must not consume it.
      if (wasLoaded) rosterRefreshedForUnknown = true;
      PerfLog.event('todayLateLogs: roster loaded (${roster.length} students)');
      return roster;
    }

    return _db
        .collection('late_logs')
        .where('scanTimestamp', isGreaterThanOrEqualTo: startUtc)
        .where('scanTimestamp', isLessThan: endUtc)
        .snapshots()
        .asyncMap((snap) async {
      if (snap.docs.isEmpty) return <LateLogEntry>[];
      final needed = <String>{};
      for (final doc in snap.docs) {
        final data = doc.data();
        needed.add((data['studentId'] as String?) ?? doc.id.split('_').first);
      }
      final studentMap = await rosterFor(needed);
      final entries = <LateLogEntry>[];
      for (final doc in snap.docs) {
        final data = doc.data();
        final studentId = (data['studentId'] as String?) ?? doc.id.split('_').first;
        final student = studentMap[studentId] ?? const <String, dynamic>{};
        final stamp = data['scanTimestamp'];
        final local = (stamp is Timestamp ? stamp.toDate().toLocal() : now);
        entries.add(LateLogEntry(
          studentId: studentId,
          name: (student['name'] as String?) ?? studentId,
          department: (student['department'] as String?) ?? '',
          year: (student['year'] as String?) ?? '',
          localTime: hhmm(local),
          scanMethod: data['scanMethod'] as String? ?? 'barcode',
          syncedOffline: data['syncedOffline'] as bool? ?? false,
        ));
      }
      // Newest scan first — the gate flow ends with the last capture on top.
      entries.sort((a, b) => b.localTime.compareTo(a.localTime));
      return entries;
    });
  }

  /// Deterministic doc id based on the device's local date — matches
  /// ARCHITECTURE.md §2 late_logs doc id convention.
  String _lateLogId(String studentId, DateTime when) {
    final mm = when.month.toString().padLeft(2, '0');
    final dd = when.day.toString().padLeft(2, '0');
    return '${studentId}_${when.year}-$mm-$dd';
  }

  @override
  Stream<bool> alreadyRecordedToday(String studentId) {
    final ref = _db.collection('late_logs').doc(_lateLogId(studentId, DateTime.now()));
    return ref.snapshots().map((s) => s.exists);
  }

  /// Escalation verdict for the current reset period. Reads the deterministic
  /// escalation_queue doc (`studentId_YYYY-MM` for the monthly reset period),
  /// yielding null while the server hasn't produced a verdict yet.
  @override
  Stream<EscalationVerdict?> escalationVerdict(String studentId) {
    final now = DateTime.now();
    final mm = now.month.toString().padLeft(2, '0');
    final ref = _db.collection('escalation_queue').doc('${studentId}_${now.year}-$mm');
    return ref.snapshots().map((s) {
      if (!s.exists) return null;
      return EscalationVerdict.fromFirestore(s.data() ?? {});
    });
  }

  // ── B6 caching ────────────────────────────────────────────────────────────
  // Departments are tiny, nearly static, and every screen fetches them on
  // entry (5-min TTL). Report rows are heavy (full students + a late_logs
  // range scan) and are re-requested with identical params when a preview is
  // revisited (60-s TTL, params-keyed). Department edits happen only in
  // admin-web, so staleness on the app side is bounded purely by the TTL —
  // no invalidation hook exists or is needed here. Report rows ARE
  // invalidated on every late-log write (recordLate / syncOfflineScan) so a
  // scan done seconds before opening a report is never masked by the cache
  // (review finding MEDIUM).
  final _departmentsMemo = TtlMemo<List<DepartmentInfo>>(const Duration(minutes: 5));
  final _reportRowsMemo = TtlMemo<List<ReportRow>>(const Duration(seconds: 60));

  static String _reportRowsKey(
    DateTime start,
    DateTime end,
    DepartmentInfo? department,
    String? year,
  ) =>
      '${start.year}-${start.month}-${start.day}|'
      '${end.year}-${end.month}-${end.day}|'
      '${department?.id ?? ''}|${department?.name ?? ''}|$year';

  @override
  Future<List<DepartmentInfo>> departments() async {
    final cached = _departmentsMemo.get('all');
    if (cached != null) return List.of(cached);
    final snap = await _track(
      'departments.get',
      () => _db.collection('departments').get(),
      count: (s) => s.size,
    );
    final list = snap.docs
        .map((d) => DepartmentInfo.fromFirestore(d.id, d.data()))
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    _departmentsMemo.put('all', list);
    return List.of(list);
  }

  @override
  Future<List<EscalationGroup>> escalatedGroups(String period) async {
    final depts = await departments();
    final snap = await _track(
      'escalation_queue.escalatedQuery',
      () => _db
          .collection('escalation_queue')
          .where('status', isEqualTo: 'escalated')
          .get(),
      count: (s) => s.size,
    );

    final groups = <String, EscalationGroup>{};
    final matches = <(EscalationVerdict, Map<String, dynamic>)>[];
    for (final doc in snap.docs) {
      final data = doc.data();
      final verdict = EscalationVerdict.fromFirestore(data);
      if (verdict.status != 'escalated' || verdict.period != period) continue;
      matches.add((verdict, data));
    }
    // QA: N+1 in the original code was serial (`await` inside the loop) —
    // the reads are still one-per-student, but now they run concurrently.
    final students = await Future.wait(
      matches.map(
        (m) => _track(
          'students.doc.get (escalation fan-out)',
          () => _db.collection('students').doc(m.$1.studentId).get(),
          count: (s) => s.exists ? 1 : 0,
        ),
      ),
    );
    for (var i = 0; i < matches.length; i++) {
      final verdict = matches[i].$1;
      final queueData = matches[i].$2;
      final studentSnap = students[i];
      final studentData = studentSnap.exists ? studentSnap.data() ?? {} : const <String, dynamic>{};
      final entry = EscalationEntry(
        verdict: verdict,
        name: (studentData['name'] as String? ?? queueData['name'] as String?) ?? verdict.studentId,
        photoBase64: studentData['photoBase64'] as String?,
      );

      final display = verdict.department.isNotEmpty ? verdict.department : 'Unassigned';
      final existing = groups[display];
      if (existing == null) {
        final deptInfo = findDepartment(depts, display);
        groups[display] = EscalationGroup(
          department: display,
          deptInfo: deptInfo,
          students: [entry],
        );
      } else {
        groups[display] = EscalationGroup(
          department: existing.department,
          deptInfo: existing.deptInfo,
          students: [...existing.students, entry],
        );
      }
    }

    final list = groups.values.toList()
      ..sort((a, b) => a.department.toLowerCase().compareTo(b.department.toLowerCase()));
    for (final g in list) {
      g.students.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }
    return list;
  }

  @override
  Future<void> enqueueMailRequest({
    required String departmentId,
    required String department,
    required String period,
    required List<String> studentIds,
    required String requestedBy,
  }) async {
    final tail = departmentId.replaceAll(RegExp('[^a-z0-9]'), '_');
    final idTail = tail.length <= 24 ? tail : tail.substring(0, 24);
    final id = '${idTail}_${period}_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    await _track(
      'mail_queue.set (escalation)',
      () => _db.collection('mail_queue').doc(id).set({
        'departmentId': departmentId,
        'department': department,
        'period': period,
        'studentIds': studentIds,
        'requestedBy': requestedBy,
        'status': 'pending',
        'attemptCount': 0,
        'requestedAt': FieldValue.serverTimestamp(),
      }),
    );
  }

  @override
  Future<List<ReportRow>> reportRows({
    required DateTime start,
    required DateTime end,
    DepartmentInfo? department,
    String? year,
  }) async {
    final cacheKey = _reportRowsKey(start, end, department, year);
    final cached = _reportRowsMemo.get(cacheKey);
    if (cached != null) return List.of(cached);
    final yearToken = (year == null || year.isEmpty) ? null : displayToken(year);
    // Tier indicators ("1", "1st", "I") filter by grade classification so
    // unclassified batch-string years never sneak into a 1st/2nd/3rd filter;
    // any other value keeps the exact-token match (Phase 4 back-compat).
    final tierFilter = (year == null || year.isEmpty) ? null : yearTier(year);
    final allDepartments = await departments();
    final startUtc = DateTime.utc(start.year, start.month, start.day);
    final endExclusiveUtc = DateTime.utc(end.year, end.month, end.day).add(const Duration(days: 1));

    final studentsSnap = await _track(
      'students.get (reportRows)',
      () => _db.collection('students').get(),
      count: (s) => s.size,
    );
    final studentMap = <String, Map<String, dynamic>>{
      for (final d in studentsSnap.docs) d.id: d.data(),
    };
    final snap = await _track(
      'late_logs.range (reportRows)',
      () => _db
          .collection('late_logs')
          .where('scanTimestamp', isGreaterThanOrEqualTo: startUtc)
          .where('scanTimestamp', isLessThan: endExclusiveUtc)
          .get(),
      count: (s) => s.size,
    );

    final rows = <ReportRow>[];
    for (final doc in snap.docs) {
      final data = doc.data();
      final studentId = (data['studentId'] as String?) ?? doc.id.split('_').first;
      final student = studentMap[studentId] ?? const <String, dynamic>{};
      final studentDept = (student['department'] as String?) ?? '';
      if (!_matchesDepartment(department, studentDept, allDepartments)) continue;
      final studentYear = (student['year'] as String?) ?? '';
      if (tierFilter != null) {
        if (yearTier(studentYear) != tierFilter) continue;
      } else if (yearToken != null && displayToken(studentYear) != yearToken) {
        continue;
      }

      final stamp = data['scanTimestamp'];
      final utc = (stamp is Timestamp ? stamp.toDate() : DateTime.now()).toUtc();
      final mm2 = utc.month.toString().padLeft(2, '0');
      final dd2 = utc.day.toString().padLeft(2, '0');
      final hh = utc.hour.toString().padLeft(2, '0');
      final mi = utc.minute.toString().padLeft(2, '0');
      rows.add(ReportRow(
        date: '${utc.year}-$mm2-$dd2',
        time: '$hh:$mi',
        studentId: studentId,
        name: (student['name'] as String?) ?? studentId,
        department: studentDept,
        year: studentYear.isEmpty ? null : studentYear,
      ));
    }
    rows.sort((a, b) {
      final c = '${a.date}${a.time}'.compareTo('${b.date}${b.time}');
      return c != 0 ? c : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    _reportRowsMemo.put(cacheKey, rows);
    return List.of(rows);
  }

  @override
  Future<List<String>> reportYears() async {
    final snap = await _track(
      'students.get (reportYears)',
      () => _db.collection('students').get(),
      count: (s) => s.size,
    );
    final years = <String>{};
    for (final d in snap.docs) {
      final y = (d.data()['year'] as String?) ?? '';
      if (y.isNotEmpty) years.add(y);
    }
    final list = years.toList()..sort();
    return list;
  }

  @override
  Future<void> enqueueReportRequest({
    required ReportFilters filters,
    required String requestedBy,
  }) async {
    final id = 'report_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    await _track(
      'report_requests.set',
      () => _db.collection('report_requests').doc(id).set({
        'periodType': filters.periodType.name,
        'startDate': dayKey(filters.startDate),
        'endDate': dayKey(filters.endDate),
        'department': filters.department?.id,
        'year': filters.year,
        'requestedBy': requestedBy,
        'status': 'pending',
        'attemptCount': 0,
        'requestedAt': FieldValue.serverTimestamp(),
      }),
    );
  }

  @override
  Future<void> enqueueReportMail({
    required String departmentId,
    required String department,
    required String periodType,
    required String startDate,
    required String endDate,
    required String attachmentMode,
    String? year,
    required String requestedBy,
  }) async {
    final tail = departmentId.replaceAll(RegExp('[^a-z0-9]'), '_');
    final idTail = tail.length <= 24 ? tail : tail.substring(0, 24);
    final id = '_report_${idTail}_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    await _track(
      'mail_queue.set (report)',
      () => _db.collection('mail_queue').doc(id).set({
        'type': 'report',
        'departmentId': departmentId,
        'department': department,
        'periodType': periodType,
        'startDate': startDate,
        'endDate': endDate,
        'attachmentMode': attachmentMode,
        'year': year,
        'requestedBy': requestedBy,
        'status': 'pending',
        'attemptCount': 0,
        'requestedAt': FieldValue.serverTimestamp(),
      }),
    );
  }

  @override
  Future<void> enqueueWeeklyAuditMail({
    required String departmentId,
    required String department,
    required String startDate,
    required String requestedBy,
  }) async {
    final tail = departmentId.replaceAll(RegExp('[^a-z0-9]'), '_');
    final idTail = tail.length <= 24 ? tail : tail.substring(0, 24);
    final id = '_weekly_${idTail}_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    await _track(
      'mail_queue.set (weekly)',
      () => _db.collection('mail_queue').doc(id).set({
        'type': 'weekly_audit',
        'departmentId': departmentId,
        'department': department,
        'startDate': startDate,
        'requestedBy': requestedBy,
        'status': 'pending',
        'attemptCount': 0,
        'requestedAt': FieldValue.serverTimestamp(),
      }),
    );
  }

  @override
  Future<List<MailLogEntry>> recentMailLogs({int limit = 40}) async {
    final snap = await _track(
      'mail_logs.recent',
      () => _db
          .collection('mail_logs')
          .orderBy('sentTimestamp', descending: true)
          .limit(limit.clamp(1, 100))
          .get(),
      count: (s) => s.size,
    );
    return snap.docs.map((d) => MailLogEntry.fromFirestore(d.id, d.data())).toList();
  }

  @override
  Future<List<DeletionRecord>> deletionRecords({int limit = 200}) async {
    final snap = await _track(
      'deletion_records.recent',
      () => _db
          .collection('deletion_records')
          .orderBy('deletedAt', descending: true)
          .limit(limit.clamp(1, 500))
          .get(),
      count: (s) => s.size,
    );
    return snap.docs.map((d) => DeletionRecord.fromFirestore(d.id, d.data())).toList();
  }

  @override
  Future<List<ImportBatchMeta>> importBatches({int limit = 50}) async {
    final snap = await _track(
      'import_batches.recent',
      () => _db
          .collection('import_batches')
          .orderBy('createdAt', descending: true)
          .limit(limit.clamp(1, 100))
          .get(),
      count: (s) => s.size,
    );
    return snap.docs.map((d) => ImportBatchMeta.fromFirestore(d.id, d.data())).toList();
  }

  @override
  Future<void> enqueueAdminRequest({
    required String type,
    String? importId,
    String? filename,
    String? departmentId,
    String? department,
    List<ImportRow>? rows,
    List<String>? studentIds,
    String? reason,
    required String requestedBy,
  }) async {
    final suffix = importId ?? type;
    final tail = suffix.replaceAll(RegExp('[^a-z0-9]'), '_');
    final idTail = tail.length <= 40 ? tail : tail.substring(0, 40);
    final id = '${idTail}_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    await _track(
      'admin_requests.set ($type)',
      () => _db.collection('admin_requests').doc(id).set({
        'type': type,
        'importId': ?importId,
        'filename': ?filename,
        'departmentId': ?departmentId,
        'department': ?department,
        'rows': ?rows
            ?.map((r) => {
                  'registerNumber': r.registerNumber.trim().toUpperCase(),
                  'name': r.name.trim(),
                  'department': r.department.trim(),
                  'currentYear': r.currentYear,
                  'batchStartYear': r.batchStartYear,
                  'batchEndYear': r.batchEndYear,
                  'photoUrl': r.photoUrl,
                })
            .toList(),
        'studentIds': ?studentIds,
        'reason': ?reason,
        'requestedBy': requestedBy,
        'status': 'pending',
        'requestedAt': FieldValue.serverTimestamp(),
      }),
    );
  }

  /// Does `studentDept` belong to the selected department? Same rule as the
  /// server (functions/report-generator.js matchesDepartment): exact token
  /// match on id/name, OR the student's display string resolves to the
  /// selected reference doc ("B.SC CS" → BSC-CS).
  bool _matchesDepartment(
    DepartmentInfo? dept,
    String studentDept,
    List<DepartmentInfo> allDepartments,
  ) {
    if (dept == null) return true;
    final stok = displayToken(studentDept);
    if (stok.isEmpty) return false;
    if (stok == displayToken(dept.id) || stok == displayToken(dept.name)) return true;
    final resolved = findDepartment(allDepartments, studentDept);
    return resolved != null && resolved.id == dept.id;
  }

  @override
  Future<RecordResult> recordLate({
    required String studentId,
    required String scannedBy,
    required String scanMethod,
  }) async {
    final ref = _db.collection('late_logs').doc(_lateLogId(studentId, DateTime.now()));
    return _track(
      'late_logs.txn.record',
      () async {
        try {
          await _db.runTransaction((txn) async {
            final existing = await txn.get(ref);
            if (existing.exists) {
              throw _AlreadyRecordedException();
            }
            txn.set(ref, {
              'studentId': studentId,
              'scannedBy': scannedBy,
              'scanTimestamp': FieldValue.serverTimestamp(),
              'scanMethod': scanMethod,
              'syncedOffline': false,
              'deviceTimestamp': DateTime.now(),
            });
          });
          _reportRowsMemo.clear();
          return const RecordResult.recorded();
        } on _AlreadyRecordedException {
          return const RecordResult.alreadyRecorded();
        }
      },
    );
  }

  @override
  Future<RecordResult> syncOfflineScan({required PendingScan scan}) async {
    final ref = _db.collection('late_logs').doc(scan.docId);
    return _track(
      'late_logs.txn.sync',
      () async {
        try {
          await _db.runTransaction((txn) async {
            final existing = await txn.get(ref);
            if (existing.exists) {
              throw _AlreadyRecordedException();
            }
            txn.set(ref, {
              'studentId': scan.studentId,
              'scannedBy': scan.scannedBy,
              'scanTimestamp': FieldValue.serverTimestamp(),
              'scanMethod': scan.scanMethod,
              'syncedOffline': true,
              // The phone's clock at capture time rides along untouched so the
              // server can validate device-vs-server time later (SECURITY.md §2).
              'deviceTimestamp': scan.deviceTimestamp,
            });
          });
          _reportRowsMemo.clear();
          return const RecordResult.recorded();
        } on _AlreadyRecordedException {
          return const RecordResult.alreadyRecorded();
        }
      },
    );
  }
}

class _AlreadyRecordedException implements Exception {
  const _AlreadyRecordedException();
}