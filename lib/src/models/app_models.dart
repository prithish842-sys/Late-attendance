/// Student document from the `students` collection (ARCHITECTURE.md §2).
///
/// Phase 4 (Admin) adds the batch/lifecycle fields from NEW_ARCHITECTURE.md:
/// registerNumber, departmentId, batchStartYear/batchEndYear, currentYear,
/// photoUrl and the `active`/`archivedAt`/`deletedAt` soft-delete marks. All
/// stay optional so pre-Phase-4 documents (and the offline roster cache) keep
/// parsing; a missing `active` is treated as TRUE (legacy students are active).
class Student {
  const Student({
    required this.studentId,
    required this.name,
    required this.department,
    this.year,
    this.phone,
    this.photoBase64,
    this.photoMimeType,
    this.barcode,
    this.departmentId,
    this.registerNumber,
    this.currentYear,
    this.batchStartYear,
    this.batchEndYear,
    this.photoUrl,
    this.active = true,
    this.archivedAt,
    this.deletedAt,
  });

  final String studentId;
  final String name;
  final String department;
  final String? year;
  final String? phone;
  final String? photoBase64;
  final String? photoMimeType;
  final String? barcode;
  final String? departmentId;
  final String? registerNumber;
  final int? currentYear;
  final int? batchStartYear;
  final int? batchEndYear;
  final String? photoUrl;

  /// False once the student has been soft-deleted/archived (Phase 4). Missing
  /// on legacy docs — treated as active.
  final bool active;
  final DateTime? archivedAt;
  final DateTime? deletedAt;

  /// Batch has finished (batchEndYear ≤ current year) and the student is still
  /// active — the pass-out review surfaces exactly these (NEW_ADMIN_WORKFLOW.md).
  bool get passOutDue {
    if (!active) return false;
    final end = batchEndYear;
    if (end == null) return false;
    final now = DateTime.now();
    return end <= now.year;
  }

  factory Student.fromFirestore(String id, Map<String, dynamic> data) {
    return Student(
      studentId: id,
      name: data['name'] as String? ?? '',
      department: data['department'] as String? ?? '',
      year: data['year'] as String?,
      phone: data['phone'] as String?,
      photoBase64: data['photoBase64'] as String?,
      photoMimeType: data['photoMimeType'] as String?,
      barcode: data['barcode'] as String?,
      departmentId: data['departmentId'] as String?,
      registerNumber: data['registerNumber'] as String?,
      currentYear: (data['currentYear'] as num?)?.toInt(),
      batchStartYear: (data['batchStartYear'] as num?)?.toInt(),
      batchEndYear: (data['batchEndYear'] as num?)?.toInt(),
      photoUrl: data['photoUrl'] as String?,
      active: data['active'] as bool? ?? true,
      archivedAt: _timestampOrNull(data['archivedAt']),
      deletedAt: _timestampOrNull(data['deletedAt']),
    );
  }

  /// Lean map for the offline roster cache (Phase 5) — photos and contact
  /// fields are dropped; the full doc is re-read from Firestore when online.
  /// `active` IS cached so a soft-deleted student is never scannable offline.
  Map<String, dynamic> toCacheMap() => {
        'studentId': studentId,
        'name': name,
        'department': department,
        'year': year,
        'active': active,
      };

  factory Student.fromCacheMap(Map<String, dynamic> m) => Student(
        studentId: m['studentId'] as String? ?? '',
        name: m['name'] as String? ?? '',
        department: m['department'] as String? ?? '',
        year: m['year'] as String?,
        active: m['active'] as bool? ?? true,
      );
}

/// Firestore timestamps arrive as `Timestamp` (dot-typed), older rows as ISO
/// strings and offline maps as `{_seconds: n}`. Resolve defensively and stay
/// pure — no cloud_firestore import in this file (mirrors `_logTimestamp`).
DateTime? _timestampOrNull(Object? value) {
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  if (value is Map && value['_seconds'] is num) {
    final seconds = value['_seconds'] as num;
    return DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round(), isUtc: true);
  }
  final dyn = value as dynamic;
  final toDate = dyn?.toDate;
  if (toDate is Function) {
    final dt = toDate();
    if (dt is DateTime) return dt;
  }
  return null;
}

/// Late-count settings from the `settings` collection. Defaults mirror
/// docs/PRD.md (threshold 3, monthly reset) when the doc hasn't been
/// customized yet.
class ScanSettings {
  const ScanSettings({
    this.escalationThreshold = 3,
    this.resetPeriod = 'monthly',
  });

  final int escalationThreshold;
  final String resetPeriod;

  factory ScanSettings.fromFirestore(Map<String, dynamic> data) {
    return ScanSettings(
      escalationThreshold: (data['escalationThreshold'] as num?)?.toInt() ?? 3,
      resetPeriod: data['resetPeriod'] as String? ?? 'monthly',
    );
  }
}

/// Server-authoritative escalation verdict, read from `escalation_queue`
/// (docs/SECURITY.md §1). Written by the Cloud Function onCreate trigger
/// (functions/index.js) on Blaze, or by scripts/process-escalation.js on Spark.
/// The app only reads and displays this — it never computes it.
class EscalationVerdict {
  const EscalationVerdict({
    required this.studentId,
    required this.period,
    required this.count,
    required this.threshold,
    this.status = 'tracking',
    this.department = '',
  });

  final String studentId;
  final String period;
  final int count;
  final int threshold;
  final String status;
  final String department;

  bool get isEscalated => status == 'escalated';
  bool get isWarning => status == 'warning';

  factory EscalationVerdict.fromFirestore(Map<String, dynamic> data) {
    return EscalationVerdict(
      studentId: data['studentId'] as String? ?? '',
      period: data['period'] as String? ?? '',
      count: (data['count'] as num?)?.toInt() ?? 0,
      threshold: (data['threshold'] as num?)?.toInt() ?? 3,
      status: data['status'] as String? ?? 'tracking',
      department: data['department'] as String? ?? '',
    );
  }
}

/// Department record from the `departments` collection (docs/ARCHITECTURE.md §2).
/// `hodEmail` is the escalation-mail recipient for the department.
class DepartmentInfo {
  const DepartmentInfo({
    required this.id,
    required this.name,
    this.hodEmail,
  });

  final String id;
  final String name;
  final String? hodEmail;

  factory DepartmentInfo.fromFirestore(String id, Map<String, dynamic> data) {
    return DepartmentInfo(
      id: id,
      name: data['name'] as String? ?? id,
      hodEmail: data['hodEmail'] as String?,
    );
  }
}

/// Match a student's `department` display string ("B.SC CS") to the canonical
/// departments reference doc ("BSC-CS"). Same fuzzy rule the server uses in
/// functions/mail-core.js resolveDepartment — doc id OR name, alphanumerics
/// only. Returns null when nothing matches or the display is ambiguous.
DepartmentInfo? findDepartment(List<DepartmentInfo> departments, String display) {
  final needle = _token(display);
  DepartmentInfo? match;
  for (final d in departments) {
    if (_token(d.id) == needle || _token(d.name) == needle) {
      if (match != null) return null; // ambiguous
      match = d;
    }
  }
  return match;
}

String displayToken(String s) => s.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

String _token(String s) => displayToken(s);

/// One escalated student shown in the HOD mail screen — the server verdict
/// joined with the student's name/photo for display.
class EscalationEntry {
  const EscalationEntry({
    required this.verdict,
    required this.name,
    this.photoBase64,
  });

  final EscalationVerdict verdict;
  final String name;
  final String? photoBase64;

  String get studentId => verdict.studentId;
}

/// Escalated students grouped by department, so the screen can offer a single
/// mail action per HOD. `deptInfo` is null when the department reference doc
/// couldn't be resolved (the display string is still usable).
class EscalationGroup {
  const EscalationGroup({
    required this.department,
    required this.students,
    this.deptInfo,
  });

  final String department;
  final DepartmentInfo? deptInfo;
  final List<EscalationEntry> students;
}

/// Result of asking the mail service to send/queue an escalation mail.
enum MailRequestOutcome { queued, sent }

class MailSendResult {
  const MailSendResult.queued() : outcome = MailRequestOutcome.queued;
  const MailSendResult.sent() : outcome = MailRequestOutcome.sent;

  final MailRequestOutcome outcome;
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 4 — attendance reports (docs/TASKS.md). The app previews the window
// locally and expresses *intent*; the window used for the real Excel/PDF is
// recomputed server-authoritatively in functions/report-core.js reportWindow.
// ─────────────────────────────────────────────────────────────────────────────

enum ReportPeriodType { daily, weekly, monthly, custom }

/// Inclusive day range a report covers (local dates). The server trusts its own
/// UTC window math, but honours exactly these dates — functions/report-core.js
/// parseDay/startDate/endDate.
class ReportWindow {
  const ReportWindow({required this.start, required this.end});

  final DateTime start;
  final DateTime end;
}

/// Client-side mirror of report-core's window rules, for preview + intent only.
/// The server recomputes the authoritative window from the periodType, start and
/// end dates the app sends. Weekly weeks start on Monday; monthly is the
/// calendar month; custom clamps an inverted range.
ReportWindow reportWindowFor(
  ReportPeriodType periodType,
  DateTime anchor, {
  DateTime? customStart,
  DateTime? customEnd,
}) {
  final a = anchor;
  switch (periodType) {
    case ReportPeriodType.daily:
      return ReportWindow(start: a, end: a);
    case ReportPeriodType.weekly:
      final monday = DateTime(a.year, a.month, a.day - (a.weekday - 1));
      return ReportWindow(start: monday, end: DateTime(monday.year, monday.month, monday.day + 6));
    case ReportPeriodType.monthly:
      return ReportWindow(
        start: DateTime(a.year, a.month, 1),
        end: DateTime(a.year, a.month + 1, 0),
      );
    case ReportPeriodType.custom:
      final start = customStart ?? a;
      final end = customEnd ?? start;
      if (!start.isAfter(end)) return ReportWindow(start: start, end: end);
      return ReportWindow(start: end, end: start);
  }
}

/// "YYYY-MM-DD" key for a local date (payload / doc convention).
String dayKey(DateTime d) {
  final mm = d.month.toString().padLeft(2, '0');
  final dd = d.day.toString().padLeft(2, '0');
  return '${d.year}-$mm-$dd';
}

/// The app's report intent. `startDate`/`endDate` are inclusive local days.
class ReportFilters {
  const ReportFilters({
    required this.periodType,
    required this.startDate,
    required this.endDate,
    this.department,
    this.year,
  });

  final ReportPeriodType periodType;
  final DateTime startDate;
  final DateTime endDate;
  final DepartmentInfo? department;
  final String? year;
}

/// One late entry in a report — the server-authoritative join of late_logs with
/// the student's name/department/year (functions/report-generator.js).
class ReportRow {
  const ReportRow({
    required this.date,
    required this.time,
    required this.studentId,
    required this.name,
    required this.department,
    this.year,
  });

  final String date;
  final String time;
  final String studentId;
  final String name;
  final String department;
  final String? year;
}

class DepartmentLateTotal {
  const DepartmentLateTotal({required this.department, required this.count});

  final String department;
  final int count;

  factory DepartmentLateTotal.fromMap(Map<String, dynamic> data) {
    return DepartmentLateTotal(
      department: data['department'] as String? ?? '',
      count: (data['count'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Totals shown in the preview card and echoed by the server's report files.
class ReportSummary {
  const ReportSummary({
    required this.totalLateEntries,
    required this.distinctStudents,
    required this.byDepartment,
  });

  final int totalLateEntries;
  final int distinctStudents;
  final List<DepartmentLateTotal> byDepartment;

  factory ReportSummary.fromCallable(Map<String, dynamic> data) {
    return ReportSummary(
      totalLateEntries: (data['totalLateEntries'] as num?)?.toInt() ?? 0,
      distinctStudents: (data['distinctStudents'] as num?)?.toInt() ?? 0,
      byDepartment: ((data['byDepartment'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => DepartmentLateTotal.fromMap(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }
}

/// Same aggregation rule as functions/report-core.js runReportStats.
ReportSummary summarizeReport(List<ReportRow> rows) {
  final byDepartment = <String, int>{};
  final students = <String>{};
  for (final r in rows) {
    students.add(r.studentId);
    final dep = r.department.isEmpty ? 'Unassigned' : r.department;
    byDepartment[dep] = (byDepartment[dep] ?? 0) + 1;
  }
  final totals = byDepartment.entries.map((e) => DepartmentLateTotal(department: e.key, count: e.value)).toList()
    ..sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      return byCount != 0
          ? byCount
          : a.department.toLowerCase().compareTo(b.department.toLowerCase());
    });
  return ReportSummary(
    totalLateEntries: rows.length,
    distinctStudents: students.length,
    byDepartment: totals,
  );
}

enum ReportRequestOutcome { queued, generated }

class ReportRequestResult {
  const ReportRequestResult({
    required this.outcome,
    this.xlsxUrl,
    this.pdfUrl,
    this.stats,
  });

  const ReportRequestResult.queued()
      : this(
          outcome: ReportRequestOutcome.queued,
          xlsxUrl: null,
          pdfUrl: null,
          stats: null,
        );

  const ReportRequestResult.generated({this.xlsxUrl, this.pdfUrl, this.stats})
      : outcome = ReportRequestOutcome.generated;

  final ReportRequestOutcome outcome;
  final String? xlsxUrl;
  final String? pdfUrl;
  final ReportSummary? stats;
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 5 — offline mode (docs/TASKS.md). A scan captured while offline is
// queued (OfflineStore) and synced on reconnect via the server-authoritative
// pathway (SECURITY.md §3 deterministic doc id; §2 device-vs-server time). It
// is stored as plain Maps/primitives so Hive needs no code generation.
// ─────────────────────────────────────────────────────────────────────────────

/// A late-log capture that was not yet written to Firestore. `deviceTimestamp`
/// is the phone's clock at scan time and never touched again — the server keeps
/// its own `scanTimestamp` as authoritative receipt time and compares the two
/// (functions/offline-sync-core.js → offline_sync_flags).
class PendingScan {
  const PendingScan({
    required this.studentId,
    required this.scannedBy,
    required this.scanMethod,
    required this.deviceTimestamp,
    required this.docId,
    this.studentName = '',
    this.queuedAt,
  });

  final String studentId;
  final String studentName;
  final String scannedBy;
  final String scanMethod;
  final DateTime deviceTimestamp;
  final String docId;
  final DateTime? queuedAt;

  factory PendingScan.fromJson(Map<String, dynamic> json) {
    return PendingScan(
      studentId: json['studentId'] as String? ?? '',
      studentName: json['studentName'] as String? ?? '',
      scannedBy: json['scannedBy'] as String? ?? '',
      scanMethod: json['scanMethod'] as String? ?? 'qr',
      deviceTimestamp: DateTime.tryParse(json['deviceTimestamp'] as String? ?? '') ?? DateTime.now(),
      docId: json['docId'] as String? ?? '',
      queuedAt: DateTime.tryParse(json['queuedAt'] as String? ?? ''),
    );
  }

  Map<String, dynamic> toJson() => {
        'studentId': studentId,
        'studentName': studentName,
        'scannedBy': scannedBy,
        'scanMethod': scanMethod,
        'deviceTimestamp': deviceTimestamp.toIso8601String(),
        'docId': docId,
        'queuedAt': queuedAt?.toIso8601String(),
      };
}

/// Outcome of a sync run, echoed in the offline banner.
class SyncResult {
  const SyncResult({required this.synced, required this.remaining});

  final int synced;
  final int remaining;
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 1 (new updates) — PT Sir dashboard. Today's list is a live local-day
// view, never a delete: the next local calendar day naturally returns zero
// (NEW_DECISIONS.md §4). Queued offline scans are merged in locally so the
// count stays truthful ("accepted, will sync") until SyncService uploads them.
// ─────────────────────────────────────────────────────────────────────────────

/// "HH:MM" for a local wall-clock (dashboard today-list rows, report times).
String hhmm(DateTime d) {
  final hh = d.hour.toString().padLeft(2, '0');
  final mi = d.minute.toString().padLeft(2, '0');
  return '$hh:$mi';
}

/// The deterministic late-log doc id is `studentId_YYYY-MM-DD` (SECURITY.md §3).
/// Extract the local-date suffix so a queued offline scan can be matched
/// against today's dashboard window before it has synced.
String dayInLateDocId(String docId) {
  final match = RegExp(r'(\d{4}-\d{2}-\d{2})$').firstMatch(docId);
  return match?.group(1) ?? '';
}

/// One row in the PT Sir dashboard's "today" list — a live late_log or a scan
/// still waiting to sync (queued offline). `pending` marks the local-only,
/// not-yet-uploaded rows so the UI can tag them "saved offline" rather than
/// pretending they are on the server record yet.
class LateLogEntry {
  const LateLogEntry({
    required this.studentId,
    required this.name,
    required this.department,
    required this.localTime,
    this.year,
    this.scanMethod = 'barcode',
    this.syncedOffline = false,
    this.pending = false,
  });

  final String studentId;
  final String name;
  final String department;
  final String localTime;
  final String? year;
  final String scanMethod;
  final bool syncedOffline;
  final bool pending;

  factory LateLogEntry.fromPending(PendingScan scan) => LateLogEntry(
        studentId: scan.studentId,
        name: scan.studentName,
        department: '',
        localTime: hhmm(scan.deviceTimestamp),
        scanMethod: scan.scanMethod,
        syncedOffline: true,
        pending: true,
      );
}

/// Visually chunk a register number for confirmation screens (Miller's Law):
/// a leading id token and the trailing numeric run are separated with a space,
/// e.g. `26BSC008` → `26BSC 008`. Pure ids (or ids without a trailing run) are
/// returned verbatim.
String chunkRegNumber(String id) {
  final match = RegExp(r'^(.*?)(\d+)$').firstMatch(id);
  if (match == null) return id;
  final head = match.group(1) ?? '';
  final run = match.group(2) ?? '';
  if (head.isEmpty || run.isEmpty) return id;
  return '$head $run';
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 2 (new updates) — HOD report mail (docs-new-updates/NEW_TASKS.md).
// The app previews the mail locally and expresses *intent*; the authoritative
// mail — recipient, filter resolution, PDF(s)/Excel and the mail_logs audit
// row — is built server-side (functions/report-mail-sender.js), exactly like
// the escalation mail pipeline (SECURITY.md §1, §8).
// ─────────────────────────────────────────────────────────────────────────────

/// Grade tier of a student's stored `year` display string. Mirrors the server
/// classifier (functions/report-core.js yearTier) so preview, mail body and
/// split-PDF logic agree on which bucket a row belongs to.
///
/// 3rd Year (or "III") → 3; 2nd Year (or "II") → 2; 1st Year (or "I") → 1.
/// Four-digit batch-year strings (e.g. "2024-2027") are not grade tiers and
/// map to 0 ("Other") so they are never silently bucketed as a grade.
int yearTier(String? year) {
  if (year == null) return 0;
  final t = displayToken(year);
  if (t.isEmpty || RegExp(r'\d{4}').hasMatch(t)) return 0;
  const markers = {
    3: ['third', 'iiird', '3rd', 'iii', '3'],
    2: ['second', 'iind', '2nd', 'ii', '2'],
    1: ['first', '1st', 'i', '1'],
  };
  for (final tier in const [3, 2, 1]) {
    for (final marker in markers[tier]!) {
      if (t.contains(marker)) return tier;
    }
  }
  return 0;
}

String yearTierLabel(int tier) {
  switch (tier) {
    case 3:
      return '3rd Year';
    case 2:
      return '2nd Year';
    case 1:
      return '1st Year';
    default:
      return 'Other';
  }
}

/// "3rd" / "2nd" / "1st" / "Other" — the file-name token for split PDFs.
String reportTierToken(int tier) {
  switch (tier) {
    case 3:
      return '3rd';
    case 2:
      return '2nd';
    case 1:
      return '1st';
    default:
      return 'Other';
  }
}

/// Attachment date-range token. A single-day window stays a single date
/// (`2026-09-24`); wider windows are `<start>_to_<end>` (inclusive days).
String reportMailRange(DateTime start, DateTime end) =>
    start == end ? dayKey(start) : '${dayKey(start)}_to_${dayKey(end)}';

/// Backbone of the report mail file names: `<dept>_Late_Attendance_<range>`
/// (dept slug from the canonical department id, e.g. `BSC-CS` → `bsccs`).
String reportMailFileStem({
  required String department,
  required DateTime start,
  required DateTime end,
}) {
  final dept = displayToken(department);
  return '${dept.isEmpty ? 'report' : dept}_Late_Attendance_${reportMailRange(start, end)}';
}

/// Attachment file names the preview shows and the server sends. Combined
/// (default) = one PDF + one Excel; split = one PDF per year tier present
/// (`<dept>_3rd_Year_<range>.pdf`, …) + one Excel.
List<String> reportMailAttachmentNames({
  required String department,
  required DateTime start,
  required DateTime end,
  required ReportMailMode mode,
  required Set<int> tiers,
}) {
  final stem = reportMailFileStem(department: department, start: start, end: end);
  final names = <String>['$stem.xlsx'];
  if (mode == ReportMailMode.combined) {
    if (tiers.isNotEmpty) names.add('$stem.pdf');
  } else {
    final dept = displayToken(department);
    final base = dept.isEmpty ? 'report' : dept;
    for (final tier in const [3, 2, 1, 0]) {
      if (tiers.contains(tier)) {
        names.add('${base}_${reportTierToken(tier)}_Year_${reportMailRange(start, end)}.pdf');
      }
    }
  }
  return names;
}

String reportMailSubject({
  required String department,
  required DateTime start,
  required DateTime end,
}) =>
    'Late Attendance Report - $department - ${reportMailRange(start, end)}';

/// Plain-text mirror of the server's formal HOD mail body (the preview the
/// staff member confirms before the server sends the authoritative HTML).
/// Year buckets run 3rd → 2nd → 1st (then unclassified "Other"), per
/// docs-new-updates/NEW_DESIGN.md.
String buildReportMailBodyPreview({
  required String department,
  required DateTime start,
  required DateTime end,
  required List<ReportRow> rows,
  required int totalLateEntries,
  required int distinctStudents,
}) {
  final sb = StringBuffer()
    ..writeln('Dear HOD,')
    ..writeln()
    ..writeln('Please find the late attendance report for $department (${reportMailRange(start, end)}).')
    ..writeln();
  for (final tier in const [3, 2, 1, 0]) {
    final group = rows.where((r) => yearTier(r.year) == tier).toList();
    if (group.isEmpty) continue;
    sb
      ..writeln('${yearTierLabel(tier)} (${group.length})')
      ..writeln();
    for (final r in group) {
      sb.writeln('${r.studentId} - ${r.name}');
    }
    sb.writeln();
  }
  sb
    ..writeln('In total, $totalLateEntries late entries were recorded for $distinctStudents students in this period.')
    ..writeln()
    ..writeln('The full report is attached (Excel, along with the PDF).')
    ..writeln()
    ..writeln('Regards,');
  return sb.toString();
}

/// How the HOD report is attached: one combined PDF (default, per
/// docs-new-updates/NEW_REPORT_MAIL_WORKFLOW.md) or separate PDFs per year.
enum ReportMailMode { combined, split }

/// The app's HOD report-mail intent. The server re-resolves the window and
/// filters server-authoritatively before building/sending anything.
class ReportMailRequest {
  const ReportMailRequest({
    required this.periodType,
    required this.startDate,
    required this.endDate,
    required this.department,
    required this.mode,
    this.year,
  });

  final ReportPeriodType periodType;
  final DateTime startDate;
  final DateTime endDate;
  final DepartmentInfo department;
  final String? year;
  final ReportMailMode mode;
}

/// One read-only row of the `mail_logs` audit trail (docs/ARCHITECTURE.md §2).
/// Escalation mails and report mails share the collection; `type` picks the
/// label. Firestore reads come from the service, which hands over raw maps.
class MailLogEntry {
  const MailLogEntry({
    required this.id,
    required this.type,
    required this.department,
    required this.to,
    required this.subject,
    required this.period,
    this.label,
    this.studentsIncluded = 0,
    this.files = const [],
    this.sentTimestamp,
  });

  final String id;
  final String type;
  final String department;
  final String to;
  final String subject;
  final String period;
  final String? label;
  final int studentsIncluded;
  final List<String> files;
  final DateTime? sentTimestamp;

  bool get isReport => type == 'report';

  bool get isWeeklyAudit => type == 'weekly_audit';

  factory MailLogEntry.fromFirestore(String id, Map<String, dynamic> data) {
    return MailLogEntry(
      id: id,
      type: data['type'] as String? ?? 'escalation',
      department: data['department'] as String? ?? '',
      to: data['to'] as String? ?? '',
      subject: data['subject'] as String? ?? '',
      period: data['period'] as String? ?? '',
      label: data['label'] as String?,
      studentsIncluded: _logCount(data['studentsIncluded']),
      files: ((data['files'] as List?) ?? const []).whereType<String>().toList(),
      sentTimestamp: _logTimestamp(data['sentTimestamp']),
    );
  }
}

/// Firestore `sentTimestamp` arrives as a Timestamp; older rows may carry an
/// ISO string. Resolve defensively (pure — no cloud_firestore import needed).
DateTime? _logTimestamp(Object? v) {
  if (v is DateTime) return v;
  if (v is String) return DateTime.tryParse(v);
  if (v is Map && v['_seconds'] is num) {
    final seconds = v['_seconds'] as num;
    return DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round(), isUtc: true);
  }
  // cloud_firestore delivers a Timestamp instance (not a Map) — duck-type its
  // toDate() the same way `_timestampOrNull` does, or every live row renders
  // "time unknown".
  final dyn = v as dynamic;
  final toDate = dyn?.toDate;
  if (toDate is Function) {
    final dt = toDate();
    if (dt is DateTime) return dt;
  }
  return null;
}

/// mail_logs `studentsIncluded` is an array of student ids for escalation rows
/// and a count for report rows (or an array there too). Resolve defensively.
int _logCount(Object? v) {
  if (v is num) return v.toInt();
  if (v is List) return v.length;
  return 0;
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 3 — weekly audit (docs-new-updates/NEW_TASKS.md). The app previews the
// week and mirrors the server's aggregation locally
// (functions/weekly-audit-core.js aggregateWeeklyAudit) so the Weekly Audit
// screen and the HOD mail preview show EXACTLY what the server computes and
// sends — same Monday→Sunday window, same repeat threshold, same month-window
// columns (count + last-late-date inside the calendar month of the week start).
// Keep this file's weeklyAuditOverview in parity with the JS aggregate.
// ─────────────────────────────────────────────────────────────────────────────

/// "YYYY-MM" calendar-month key of a local day — matches the escalation period
/// key and monthly_student_status monthKey (NEW_ARCHITECTURE.md §2.6).
String monthKey(DateTime d) {
  final mm = d.month.toString().padLeft(2, '0');
  return '${d.year}-$mm';
}

/// One repeated-student row of the weekly audit — the MS Word column set from
/// NEW_AUDIT_WORKFLOW.md: name, register number, department, year, lates this
/// week, lates this month, last late date. `repeated` is decided by the
/// aggregator (weeklyCount >= repeatThreshold), exactly like the server.
class WeeklyStudentView {
  const WeeklyStudentView({
    required this.studentId,
    required this.name,
    required this.department,
    required this.year,
    required this.monthKey,
    required this.weekCount,
    required this.monthCount,
    required this.repeated,
    this.lastLateDate,
  });

  final String studentId;
  final String name;
  final String department;
  final String year;
  final String monthKey;
  final int weekCount;
  final int monthCount;
  final bool repeated;
  final String? lastLateDate;

  /// Severity tier for the month-column tint — same bucketing as the
  /// escalation counter (1st logged / 2nd warning / 3rd+ escalated).
  String monthStatus(int threshold) {
    final t = threshold > 0 ? threshold : 3;
    if (monthCount >= t) return 'escalated';
    if (monthCount >= 2) return 'warning';
    return 'logged';
  }
}

/// One department's weekly audit — counts plus its (name-sorted) master list.
class WeeklyAuditGroup {
  const WeeklyAuditGroup({
    required this.department,
    required this.uniqueStudents,
    required this.totalEvents,
    required this.repeatedStudents,
    required this.students,
  });

  final String department;
  final int uniqueStudents;
  final int totalEvents;
  final int repeatedStudents;
  final List<WeeklyStudentView> students;

  /// Repeated views only (weekCount >= threshold) — the filterable table body.
  List<WeeklyStudentView> get repeated => students.where((s) => s.repeated).toList();
}

/// Whole-week rollup — total events, distinct students, repeated count and the
/// departments (sorted uniqueStudents desc, then totalEvents desc, then name).
class WeeklyAuditOverview {
  const WeeklyAuditOverview({
    required this.monthKey,
    required this.totalEvents,
    required this.uniqueStudents,
    required this.repeatedStudents,
    required this.departments,
  });

  final String monthKey;
  final int totalEvents;
  final int uniqueStudents;
  final int repeatedStudents;

  /// Sorted as above; empty when no rows fall in the week.
  final List<WeeklyAuditGroup> departments;
}

/// Client-side mirror of functions/weekly-audit-core.js aggregateWeeklyAudit.
/// `weekStart` is the Monday the week begins on (local), the same anchor the
/// app sends as the mail intent's startDate. The rows come from the report-row
/// join (reportRows over the Monday→Sunday window) so names/departments/years
/// match the preview everywhere else.
WeeklyAuditOverview weeklyAuditOverview(
  List<ReportRow> rows,
  DateTime weekStart, {
  int repeatThreshold = 2,
}) {
  final threshold = repeatThreshold > 0 ? repeatThreshold : 2;
  final key = monthKey(weekStart);

  final byDept = <String, List<ReportRow>>{};
  for (final r in rows) {
    final dep = r.department.isEmpty ? 'Unassigned' : r.department;
    byDept.putIfAbsent(dep, () => []).add(r);
  }

  final depts = byDept.entries.map((e) {
    final deptRows = e.value;
    final byStudent = <String, WeeklyStudentView>{};
    for (final r in deptRows) {
      final existing = byStudent[r.studentId];
      final weekCount = (existing?.weekCount ?? 0) + 1;
      final inMonth = r.date.startsWith(key);
      final monthCount = (existing?.monthCount ?? 0) + (inMonth ? 1 : 0);
      final lastLate = existing?.lastLateDate;
      final last = inMonth && (lastLate == null || r.date.compareTo(lastLate) > 0) ? r.date : lastLate;
      byStudent[r.studentId] = WeeklyStudentView(
        studentId: r.studentId,
        name: r.name,
        department: r.department,
        year: r.year ?? '',
        monthKey: key,
        weekCount: weekCount,
        monthCount: monthCount,
        repeated: weekCount >= threshold,
        lastLateDate: last,
      );
    }
    final students = byStudent.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final repeated = students.where((s) => s.repeated).length;
    return WeeklyAuditGroup(
      department: e.key,
      uniqueStudents: students.length,
      totalEvents: deptRows.length,
      repeatedStudents: repeated,
      students: students,
    );
  }).toList()
    ..sort((a, b) {
      final byUnique = b.uniqueStudents.compareTo(a.uniqueStudents);
      if (byUnique != 0) return byUnique;
      final byEvents = b.totalEvents.compareTo(a.totalEvents);
      if (byEvents != 0) return byEvents;
      return a.department.toLowerCase().compareTo(b.department.toLowerCase());
    });

  return WeeklyAuditOverview(
    monthKey: key,
    totalEvents: rows.length,
    uniqueStudents: depts.fold(0, (n, d) => n + d.uniqueStudents),
    repeatedStudents: depts.fold(0, (n, d) => n + d.repeatedStudents),
    departments: depts,
  );
}

/// Attachment range token for a weekly audit (Monday→Sunday inclusive) —
/// `<start>_to_<endInclusive>`, matching the server's weeklyAuditRange.
String weeklyAuditRange(DateTime weekStart) {
  final endInclusive = DateTime(weekStart.year, weekStart.month, weekStart.day + 6);
  return reportMailRange(weekStart, endInclusive);
}

/// Filename stem: `{dept_slug}_Weekly_Audit_{range}` (server parity).
String weeklyAuditFileStem({
  required String department,
  required DateTime weekStart,
}) {
  final dept = displayToken(department);
  return '${dept.isEmpty ? 'report' : dept}_Weekly_Audit_${weeklyAuditRange(weekStart)}';
}

/// Attachment file names the preview shows and the server sends: the workbook
/// first, then the PDF (send order in functions/weekly-audit-sender.js).
List<String> weeklyAuditAttachmentNames({
  required String department,
  required DateTime weekStart,
}) {
  final stem = weeklyAuditFileStem(department: department, weekStart: weekStart);
  return ['$stem.xlsx', '$stem.pdf'];
}

/// Subject line the preview shows and the server sends.
String weeklyAuditSubject({
  required String department,
  required DateTime weekStart,
}) =>
    'Weekly Late Attendance Audit - $department - ${weeklyAuditRange(weekStart)}';

/// Plain-text mirror of the server's HOD weekly-audit HTML body (the preview
/// the staff member confirms before the server sends the authoritative mail).
/// Repeated students (late more than once this week) drive the table; the
/// totals line carries the department's full-week counts.
String buildWeeklyAuditBodyPreview({
  required String department,
  required DateTime weekStart,
  required WeeklyAuditGroup group,
}) {
  final sb = StringBuffer()
    ..writeln('Dear HOD,')
    ..writeln()
    ..writeln('Please find the weekly late attendance audit for $department (${weeklyAuditRange(weekStart)}).')
    ..writeln()
    ..writeln('The students listed below were each late more than once during this week:')
    ..writeln();
  final repeated = group.repeated;
  if (repeated.isEmpty) {
    sb.writeln('  No student was marked late more than once this week.');
  } else {
    for (final s in repeated) {
      final last = s.lastLateDate ?? '-';
      sb.writeln('  ${s.name} (${s.studentId}) - year ${s.year.isEmpty ? '-' : s.year} - '
          '${s.weekCount} this week, ${s.monthCount} this month, last late $last');
    }
  }
  sb
    ..writeln()
    ..writeln('In total, ${group.uniqueStudents} '
        '${group.uniqueStudents == 1 ? 'student was' : 'students were'} marked late on '
        '${group.totalEvents} ${group.totalEvents == 1 ? 'occasion' : 'occasions'} this week, '
        'of whom ${group.repeatedStudents} were late more than once.')
    ..writeln()
    ..writeln('The complete week data is attached as a PDF along with the Excel workbook.')
    ..writeln()
    ..writeln('Regards,');
  return sb.toString();
}

/// The app's HOD weekly-audit mail intent. `weekStart` is the Monday the week
/// begins on; the server re-resolves the Monday→Sunday window and rebuilds the
/// rows server-authoritatively before building/sending anything.
class WeeklyAuditMailRequest {
  const WeeklyAuditMailRequest({
    required this.department,
    required this.weekStart,
  });

  final DepartmentInfo department;
  final DateTime weekStart;
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 4 — Admin (docs-new-updates/NEW_TASKS.md §Phase 4). The import sheet
// validation mirrors functions/admin-core.js validateImportRows EXACTLY, and
// the lifecycle intents mirror functions/admin-scheduler.js. The client only
// previews/expresses intent; the server re-validates and writes.
// ─────────────────────────────────────────────────────────────────────────────

/// One raw row from an uploaded Excel sheet (order of columns per
/// NEW_ADMIN_WORKFLOW.md): Register Number, Student Name, Department,
/// Current Year, Batch Start Year, Batch End Year, Photo URL (optional).
class ImportRow {
  const ImportRow({
    required this.registerNumber,
    required this.name,
    required this.department,
    required this.currentYear,
    required this.batchStartYear,
    required this.batchEndYear,
    this.photoUrl,
  });

  final String registerNumber;
  final String name;
  final String department;
  final int? currentYear;
  final int? batchStartYear;
  final int? batchEndYear;
  final String? photoUrl;
}

/// A sheet row after validation — the preview shows `errors`/`warnings` per
/// row and only `valid` rows are eligible for commit (server re-checks).
class ImportRowResult {
  const ImportRowResult({
    required this.row,
    this.departmentId,
    this.departmentName,
    this.errors = const [],
    this.warnings = const [],
    this.valid = false,
  });

  final ImportRow row;
  final String? departmentId;
  final String? departmentName;
  final List<String> errors;
  final List<String> warnings;
  final bool valid;
}

class ImportCounts {
  const ImportCounts({
    required this.rows,
    required this.valid,
    required this.invalid,
    required this.warnings,
    this.committed = 0,
  });

  final int rows;
  final int valid;
  final int invalid;
  final int warnings;

  /// Students actually written to `students` (server-counted; for a committed
  /// batch this equals `valid` minus rows that re-validation skipped).
  final int committed;

  factory ImportCounts.fromFirestore(Map<String, dynamic> data) => ImportCounts(
        rows: (data['rows'] as num?)?.toInt() ?? 0,
        valid: (data['valid'] as num?)?.toInt() ?? 0,
        invalid: (data['invalid'] as num?)?.toInt() ?? 0,
        warnings: (data['warnings'] as num?)?.toInt() ?? 0,
        committed: (data['committed'] as num?)?.toInt() ?? 0,
      );
}

/// The validated sheet — the Batch Import screen's preview model.
class ImportSheetResult {
  const ImportSheetResult({
    required this.rows,
    required this.counts,
  });

  final List<ImportRowResult> rows;
  final ImportCounts counts;

  bool get ok => rows.isNotEmpty && counts.invalid == 0;
}

/// Soft-delete lifecycle reasons presented to the admin (mirrors the server
/// SOFT_DELETE_REASONS whitelist).
enum DeletionReason { passOut, manual }

/// One `deletion_records/{studentId}` evidence row (NEW_DECISIONS.md #12,#13).
/// Permanent deletion keeps this row (retention); restore removes it.
class DeletionRecord {
  const DeletionRecord({
    required this.studentId,
    this.registerNumber,
    this.name,
    this.department,
    this.departmentId,
    this.year,
    this.batchStartYear,
    this.batchEndYear,
    this.deletedAt,
    this.deletedBy,
    this.reason,
    this.retentionUntil,
    this.restored = false,
    this.permanentlyDeletedAt,
  });

  final String studentId;
  final String? registerNumber;
  final String? name;
  final String? department;
  final String? departmentId;
  final String? year;
  final int? batchStartYear;
  final int? batchEndYear;
  final DateTime? deletedAt;
  final String? deletedBy;
  final String? reason;
  final DateTime? retentionUntil;
  final bool restored;
  final DateTime? permanentlyDeletedAt;

  bool get alreadyPermanent => permanentlyDeletedAt != null;

  String get displayName => (registerNumber == null || registerNumber == studentId)
      ? (name ?? studentId)
      : '${name ?? studentId} ($registerNumber)';

  factory DeletionRecord.fromFirestore(String id, Map<String, dynamic> data) {
    return DeletionRecord(
      studentId: id,
      registerNumber: data['registerNumber'] as String?,
      name: data['name'] as String?,
      department: data['department'] as String?,
      departmentId: data['departmentId'] as String?,
      year: data['year'] as String?,
      batchStartYear: (data['batchStartYear'] as num?)?.toInt(),
      batchEndYear: (data['batchEndYear'] as num?)?.toInt(),
      deletedAt: _timestampOrNull(data['deletedAt']),
      deletedBy: data['deletedBy'] as String?,
      reason: data['reason'] as String?,
      retentionUntil: _timestampOrNull(data['retentionUntil']),
      restored: data['restored'] as bool? ?? false,
      permanentlyDeletedAt: _timestampOrNull(data['permanentlyDeletedAt']),
    );
  }
}

/// An `import_batches/{importId}` metadata row — the Batch Import history.
class ImportBatchMeta {
  const ImportBatchMeta({
    required this.importId,
    this.filename,
    this.departmentId,
    this.department,
    this.batchStartYear,
    this.batchEndYear,
    this.counts,
    this.createdBy,
    this.createdAt,
  });

  final String importId;
  final String? filename;
  final String? departmentId;
  final String? department;
  final int? batchStartYear;
  final int? batchEndYear;
  final ImportCounts? counts;
  final String? createdBy;
  final DateTime? createdAt;

  factory ImportBatchMeta.fromFirestore(String id, Map<String, dynamic> data) {
    return ImportBatchMeta(
      importId: id,
      filename: data['filename'] as String?,
      departmentId: data['departmentId'] as String?,
      department: data['department'] as String?,
      batchStartYear: (data['batchStartYear'] as num?)?.toInt(),
      batchEndYear: (data['batchEndYear'] as num?)?.toInt(),
      counts: data['counts'] is Map
          ? ImportCounts.fromFirestore(Map<String, dynamic>.from(data['counts'] as Map))
          : null,
      createdBy: data['createdBy'] as String?,
      createdAt: _timestampOrNull(data['createdAt']),
    );
  }
}

enum AdminActionResultOutcome { queued, applied }

/// Result of asking the admin service to perform a lifecycle action.
/// `queued` = Spark (admin_requests enqueued for scripts/process-admin.js);
/// `applied` = Blaze callable ran immediately (counts returned).
class AdminActionResult {
  const AdminActionResult.queued()
      : outcome = AdminActionResultOutcome.queued,
        added = 0,
        affected = 0,
        skipped = 0,
        counts = null;

  const AdminActionResult.applied({
    this.added = 0,
    this.affected = 0,
    this.skipped = 0,
    this.counts,
  }) : outcome = AdminActionResultOutcome.applied;

  final AdminActionResultOutcome outcome;
  final int added;
  final int affected;
  final int skipped;
  final ImportCounts? counts;

  bool get isQueued => outcome == AdminActionResultOutcome.queued;
}