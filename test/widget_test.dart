import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:excel/excel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:late_attendance/src/models/app_models.dart';
import 'package:late_attendance/src/screens/admin_screen.dart';
import 'package:late_attendance/src/screens/batch_import_screen.dart';
import 'package:late_attendance/src/screens/dashboard_screen.dart';
import 'package:late_attendance/src/screens/hod_picker_screen.dart';
import 'package:late_attendance/src/screens/login_screen.dart';
import 'package:late_attendance/src/screens/mail_logs_screen.dart';
import 'package:late_attendance/src/screens/mail_preview_screen.dart';
import 'package:late_attendance/src/screens/pass_out_review_screen.dart';
import 'package:late_attendance/src/screens/recently_deleted_screen.dart';
import 'package:late_attendance/src/screens/reports_screen.dart';
import 'package:late_attendance/src/screens/scan_screen.dart';
import 'package:late_attendance/src/screens/student_management_screen.dart';
import 'package:late_attendance/src/screens/verify_screen.dart';
import 'package:late_attendance/src/screens/weekly_audit_screen.dart';
import 'package:late_attendance/src/services/admin_service.dart';
import 'package:late_attendance/src/services/auth_service.dart';
import 'package:late_attendance/src/services/connectivity_service.dart';
import 'package:late_attendance/src/services/firestore_service.dart';
import 'package:late_attendance/src/services/import_parser.dart';
import 'package:late_attendance/src/services/login_throttle.dart';
import 'package:late_attendance/src/services/mail_service.dart';
import 'package:late_attendance/src/services/offline_store.dart';
import 'package:late_attendance/src/services/photo_cache.dart';
import 'package:late_attendance/src/services/report_mail_service.dart';
import 'package:late_attendance/src/services/report_service.dart';
import 'package:late_attendance/src/services/scan_service.dart';
import 'package:late_attendance/src/services/sync_service.dart';
import 'package:late_attendance/src/theme/app_theme.dart';
import 'package:late_attendance/src/widgets/sankara_crest.dart';
import 'package:late_attendance/src/widgets/status_badge.dart';

void main() {
  const settings = ScanSettings(); // threshold 3, monthly

  group('status badge severity', () {
    test('1st late is informational', () {
      expect(severityFor(1, settings), LateSeverity.ok);
      expect(severityColor(LateSeverity.ok), AppColors.statusOk);
    });

    test('2nd late is a warning', () {
      expect(severityFor(2, settings), LateSeverity.warn);
      expect(severityColor(LateSeverity.warn), AppColors.statusWarn);
    });

    test('3rd late (threshold) escalates', () {
      expect(severityFor(3, settings), LateSeverity.escalate);
      expect(severityFor(9, settings), LateSeverity.escalate);
      expect(severityColor(LateSeverity.escalate), AppColors.statusEscalate);
    });
  });

  group('ordinal copy', () {
    test('first three ordinals', () {
      expect(ordinal(1), '1st');
      expect(ordinal(2), '2nd');
      expect(ordinal(3), '3rd');
    });

    test('larger counts and teens', () {
      expect(ordinal(4), '4th');
      expect(ordinal(11), '11th');
      expect(ordinal(21), '21st');
    });
  });

  group('design tokens', () {
    test('core palette matches docs/DESIGN.md §1', () {
      expect(AppColors.maroon900, const Color(0xFF8B1E1E));
      expect(AppColors.maroon700, const Color(0xFFA82B2B));
      expect(AppColors.navy900, const Color(0xFF1B2A4A));
      expect(AppColors.cream50, const Color(0xFFFAF8F5));
      expect(AppColors.ink900, const Color(0xFF232323));
      expect(AppColors.sand200, const Color(0xFFE8E2D8));
    });

    test('status palette matches docs/DESIGN.md §1', () {
      expect(AppColors.statusOk, const Color(0xFF2E7D4F));
      expect(AppColors.statusWarn, const Color(0xFFC77A1F));
      expect(AppColors.statusEscalate, const Color(0xFF8B1E1E));
    });
  });

  group('LoginScreen', () {
    testWidgets('requires both email and password', (tester) async {
      final auth = _RecordingAuth();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: LoginScreen(auth: auth),
        ),
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pump();

      expect(find.text('Enter your email and password.'), findsOneWidget);
      expect(auth.signInCalls, 0);
    });

    testWidgets('submits trimmed Firebase email and password credentials', (
      tester,
    ) async {
      final auth = _RecordingAuth();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: LoginScreen(auth: auth),
        ),
      );

      await tester.enterText(
        find.byType(TextField).at(0),
        '  staff@sankara.ac.in  ',
      );
      await tester.enterText(find.byType(TextField).at(1), 'correct horse');
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pump();

      expect(auth.signInCalls, 1);
      expect(auth.lastEmail, 'staff@sankara.ac.in');
      expect(auth.lastPassword, 'correct horse');
    });

    testWidgets('locks after 5 failed attempts and stops calling Firebase', (
      tester,
    ) async {
      final auth = _RecordingAuth()
        ..result = const SignInOutcome.failure('Wrong email or password.');
      final throttle = LoginThrottle();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: LoginScreen(auth: auth, throttle: throttle),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'pt@sankara.ac.in');
      await tester.enterText(find.byType(TextField).at(1), 'nope');

      for (var i = 0; i < 5; i++) {
        await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
        await tester.pump();
      }
      expect(auth.signInCalls, 5);
      expect(
        find.textContaining('Too many failed sign-in attempts'),
        findsOneWidget,
      );

      // Locked: the next tap never reaches Firebase Auth.
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pump();
      expect(auth.signInCalls, 5);

      // A successful sign-in wipes the ledger (fresh window next failure).
      throttle.recordSuccess();
      expect(throttle.lockedRemaining(DateTime.now()), isNull);
    });
  });

  group('ScanScreen', () {
    testWidgets(
      'keeps the camera dominant and manual entry behind a text link',
      (tester) async {
        final store = _RecordingFirestore();
        await _pumpScanScreen(tester, store);

        expect(find.byKey(const Key('test-camera-surface')), findsOneWidget);
        expect(find.text('Enter ID manually'), findsOneWidget);
        expect(find.byKey(const Key('manual-student-id')), findsNothing);

        await tester.tap(find.text('Enter ID manually'));
        await tester.pump();

        expect(find.byKey(const Key('manual-student-id')), findsOneWidget);
        expect(find.text('Find student'), findsOneWidget);
      },
    );

    testWidgets(
      'camera scan verifies and records a late entry without a time gate',
      (tester) async {
        final store = _RecordingFirestore()..seededFind = _student('26BSC008');
        await _pumpScanScreen(tester, store);

        await tester.tap(find.byKey(const Key('test-camera-code')));
        await tester.pumpAndSettle();

        expect(find.text('Ada Lovelace'), findsOneWidget);
        expect(find.text('Confirm'), findsOneWidget);
        expect(find.text('Submit'), findsNothing);

        await tester.ensureVisible(
          find.widgetWithText(FilledButton, 'Confirm'),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
        await tester.pumpAndSettle();

        expect(store.recordCalls, 1);
        expect(store.lastScannedBy, 'staff-1');
        expect(store.lastScanMethod, 'barcode');
      },
    );

    testWidgets(
      'the 3s same-code cooldown collapses a repeat emission into one lookup',
      (tester) async {
        // seededFind stays null: the lookup resolves to "no student", so we
        // never leave the scan screen and _processing is false again while the
        // cooldown window is still open — only the cooldown can block the
        // second emission.
        final store = _RecordingFirestore();
        await _pumpScanScreen(tester, store);

        final emit = find.byKey(const Key('test-camera-code'));
        await tester.tap(emit);
        await tester.pumpAndSettle();
        expect(store.findCalls, 1);
        expect(
          find.textContaining('No student matches that ID'),
          findsOneWidget,
        );

        // Same barcode again immediately: one physical scan == one lookup.
        await tester.tap(emit);
        await tester.pumpAndSettle();
        expect(store.findCalls, 1);

        await tester.pumpWidget(const SizedBox()); // unmount → cancel timers
      },
    );

    testWidgets('manual fallback looks up the student in Firestore', (
      tester,
    ) async {
      final store = _RecordingFirestore()..seededFind = _student('26BSC010');
      await _pumpScanScreen(tester, store);

      await tester.tap(find.text('Enter ID manually'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('manual-student-id')),
        '26BSC010',
      );
      await tester.tap(find.text('Find student'));
      await tester.pumpAndSettle();

      expect(store.lastFindCode, '26BSC010');
      expect(find.text('Ada Lovelace'), findsOneWidget);
    });

    testWidgets(
      'Firestore lookup failure returns to a usable manual fallback',
      (tester) async {
        final store = _RecordingFirestore()
          ..findError = FirebaseException(
            code: 'permission-denied',
            plugin: 'cloud_firestore',
          );
        await _pumpScanScreen(tester, store);

        await tester.tap(find.byKey(const Key('test-camera-code')));
        await tester.pumpAndSettle();

        expect(
          find.text(
            'Student lookup failed. Check your connection or permissions and try again.',
          ),
          findsOneWidget,
        );
        // Fallback is now revealed automatically — no extra tap needed.
        expect(find.text('Enter ID manually'), findsNothing);
        expect(find.byKey(const Key('manual-student-id')), findsOneWidget);
      },
    );

    testWidgets('a failed barcode decode auto-reveals manual entry', (
      tester,
    ) async {
      final store = _RecordingFirestore();
      await _pumpScanScreen(tester, store);
      expect(find.byKey(const Key('manual-student-id')), findsNothing);

      await tester.tap(find.byKey(const Key('test-camera-error')));
      await tester.pump();

      expect(find.textContaining('Barcode not readable'), findsOneWidget);
      expect(find.byKey(const Key('manual-student-id')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'camera lookup miss falls back to typing the register number off the card',
      (tester) async {
        final store = _RecordingFirestore()
          ..findHandler = (code) => code == '24BSC0011' ? _student('26BSC011') : null;
        await _pumpScanScreen(tester, store);

        // Camera miss → manual entry revealed automatically.
        await tester.tap(find.byKey(const Key('test-camera-code')));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('No student matches that ID'),
          findsOneWidget,
        );
        expect(find.byKey(const Key('manual-student-id')), findsOneWidget);

        // Register number as printed on the card (typed uppercase by the
        // field's textCapitalization; normalization lives in the service).
        await tester.enterText(
          find.byKey(const Key('manual-student-id')),
          '24BSC0011',
        );
        await tester.tap(find.text('Find student'));
        await tester.pumpAndSettle();
        expect(store.lastFindCode, '24BSC0011');
        expect(find.text('Ada Lovelace'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('widgets', () {
    testWidgets('badge pairs explicit count text with color', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: StatusBadge(count: 2, settings: _badgeSettings)),
        ),
      );
      expect(find.text('2nd time this month'), findsOneWidget);
    });

    testWidgets('server verdict escalated overrides count copy', (
      tester,
    ) async {
      const verdict = EscalationVerdict(
        studentId: '26BSC008',
        period: '2026-09',
        count: 3,
        threshold: 3,
        status: 'escalated',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatusBadge.fromVerdict(verdict, settings: _badgeSettings),
          ),
        ),
      );
      expect(find.text('Escalated \u2014 threshold reached'), findsOneWidget);
    });

    testWidgets('server verdict warning renders warning copy', (tester) async {
      const verdict = EscalationVerdict(
        studentId: '26BSC004',
        period: '2026-09',
        count: 2,
        threshold: 3,
        status: 'warning',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatusBadge.fromVerdict(verdict, settings: _badgeSettings),
          ),
        ),
      );
      expect(find.text('2nd time \u2014 warning'), findsOneWidget);
    });

    testWidgets('crest renders at a small top-left size', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SankaraCrest(size: 40))),
      );
      final box = tester.getSize(find.byType(SankaraCrest));
      expect(box.width, 40);
      expect(box.height, 40);
    });
  });

  group('escalation verdict model', () {
    test('parses from escalation_queue fields', () {
      final v = EscalationVerdict.fromFirestore({
        'studentId': '26BSC008',
        'period': '2026-09',
        'count': 3,
        'threshold': 3,
        'status': 'escalated',
      });
      expect(v.isEscalated, isTrue);
      expect(v.isWarning, isFalse);
      expect(v.count, 3);
    });

    test('missing doc defaults to tracking (server not decided yet)', () {
      final v = EscalationVerdict.fromFirestore(const {});
      expect(v.isEscalated, isFalse);
      expect(v.isWarning, isFalse);
      expect(v.count, 0);
    });

    test('parses the department display string (escalation mail grouping)', () {
      final v = EscalationVerdict.fromFirestore({
        'studentId': '26BSC008',
        'period': '2026-09',
        'count': 3,
        'threshold': 3,
        'status': 'escalated',
        'department': 'B.SC CS',
      });
      expect(v.department, 'B.SC CS');
      expect(v.isEscalated, isTrue);
    });
  });

  group('department reference (Phase 3 mail)', () {
    const depts = [
      DepartmentInfo(
        id: 'BSC-CS',
        name: 'B.Sc Computer Science',
        hodEmail: 'hod@bsc.example',
      ),
      DepartmentInfo(id: 'BCA', name: 'BCA', hodEmail: 'hod@bca.example'),
    ];

    test('fromFirestore parses id/name/hodEmail', () {
      final d = DepartmentInfo.fromFirestore('BSC-CS', {
        'name': 'B.Sc Computer Science',
        'hodEmail': 'hoD@bsc.example',
      });
      expect(d.id, 'BSC-CS');
      expect(d.name, 'B.Sc Computer Science');
      expect(d.hodEmail, 'hoD@bsc.example');
    });

    test('matches a display string like the server token rule', () {
      expect(findDepartment(depts, 'B.SC CS')?.id, 'BSC-CS');
      expect(findDepartment(depts, 'bsc.cs')?.id, 'BSC-CS');
      expect(findDepartment(depts, 'B.Sc Computer Science')?.id, 'BSC-CS');
      expect(findDepartment(depts, 'BCA')?.id, 'BCA');
    });

    test('returns null when nothing matches', () {
      expect(findDepartment(depts, 'No Such Department'), isNull);
    });

    test('returns null on ambiguity', () {
      const dup = [
        DepartmentInfo(id: 'BSC-CS', name: 'B.Sc Computer Science'),
        DepartmentInfo(id: 'CS', name: 'B.Sc Computer Science'),
      ];
      expect(findDepartment(dup, 'B.Sc Computer Science'), isNull);
    });
  });

  group('QueuedMailService (Spark fallback)', () {
    test('enqueues a mail request and reports queued', () async {
      final store = _RecordingFirestore();
      final q = QueuedMailService(store);
      final result = await q.requestEscalationMail(
        department: const DepartmentInfo(
          id: 'BSC-CS',
          name: 'B.Sc Computer Science',
          hodEmail: 'hod@bsc.example',
        ),
        period: '2026-09',
        studentIds: const ['26BSC008', '26BSC010'],
        requestedBy: 'user-1',
      );
      expect(result.outcome, MailRequestOutcome.queued);
      expect(store.lastEnqueue?['departmentId'], 'BSC-CS');
      expect(store.lastEnqueue?['period'], '2026-09');
      expect(store.lastEnqueue?['studentIds'], ['26BSC008', '26BSC010']);
      expect(store.lastEnqueue?['requestedBy'], 'user-1');
      expect(store.lastEnqueue?['department'], 'B.Sc Computer Science');
    });
  });

  group('report window (Phase 4)', () {
    test('daily is the single anchor day', () {
      final w = reportWindowFor(ReportPeriodType.daily, DateTime(2026, 9, 24));
      expect(w.start, DateTime(2026, 9, 24));
      expect(w.end, DateTime(2026, 9, 24));
    });

    test('weekly snaps to a Monday start and 7 days', () {
      final w = reportWindowFor(ReportPeriodType.weekly, DateTime(2026, 9, 20));
      expect(w.start, DateTime(2026, 9, 14));
      expect(w.end, DateTime(2026, 9, 20));
    });

    test('weekly when the anchor is already a Monday', () {
      final w = reportWindowFor(ReportPeriodType.weekly, DateTime(2026, 9, 14));
      expect(w.start, DateTime(2026, 9, 14));
      expect(w.end, DateTime(2026, 9, 20));
    });

    test('monthly is the calendar month', () {
      final w = reportWindowFor(
        ReportPeriodType.monthly,
        DateTime(2026, 9, 15),
      );
      expect(w.start, DateTime(2026, 9, 1));
      expect(w.end, DateTime(2026, 9, 30));
    });

    test('monthly handles a December anchor across the year', () {
      final w = reportWindowFor(
        ReportPeriodType.monthly,
        DateTime(2026, 12, 10),
      );
      expect(w.start, DateTime(2026, 12, 1));
      expect(w.end, DateTime(2026, 12, 31));
    });

    test('custom uses the given bounds and clamps an inverted range', () {
      final w = reportWindowFor(
        ReportPeriodType.custom,
        DateTime(2026, 9, 24),
        customStart: DateTime(2026, 9, 1),
        customEnd: DateTime(2026, 9, 30),
      );
      expect(w.start, DateTime(2026, 9, 1));
      expect(w.end, DateTime(2026, 9, 30));

      final inverted = reportWindowFor(
        ReportPeriodType.custom,
        DateTime(2026, 9, 24),
        customStart: DateTime(2026, 9, 30),
        customEnd: DateTime(2026, 9, 1),
      );
      expect(inverted.start, DateTime(2026, 9, 1));
      expect(inverted.end, DateTime(2026, 9, 30));
    });

    test('dayKey formats the payload date', () {
      expect(dayKey(DateTime(2026, 9, 5)), '2026-09-05');
    });
  });

  group('report summary (Phase 4)', () {
    test('counts entries, distinct students, and sorts departments', () {
      final s = summarizeReport(const [
        ReportRow(
          date: '2026-09-01',
          time: '09:10',
          studentId: '26BSC008',
          name: 'A',
          department: 'B.SC CS',
        ),
        ReportRow(
          date: '2026-09-02',
          time: '09:12',
          studentId: '26BSC008',
          name: 'A',
          department: 'B.SC CS',
        ),
        ReportRow(
          date: '2026-09-03',
          time: '09:05',
          studentId: '26BSC010',
          name: 'B',
          department: 'BCA',
        ),
      ]);
      expect(s.totalLateEntries, 3);
      expect(s.distinctStudents, 2);
      expect(s.byDepartment[0].department, 'B.SC CS');
      expect(s.byDepartment[0].count, 2);
      expect(s.byDepartment[1].department, 'BCA');
    });

    test('blank department bucket is Unassigned', () {
      final s = summarizeReport(const [
        ReportRow(
          date: '2026-09-01',
          time: '09:10',
          studentId: '26BSC001',
          name: 'A',
          department: '',
        ),
      ]);
      expect(s.byDepartment.single.department, 'Unassigned');
    });
  });

  group('QueuedReportService (Spark fallback)', () {
    test('enqueues a report request and reports queued', () async {
      final store = _RecordingFirestore();
      final q = QueuedReportService(store);
      final result = await q.requestReport(
        filters: ReportFilters(
          periodType: ReportPeriodType.monthly,
          startDate: DateTime(2026, 9, 1),
          endDate: DateTime(2026, 9, 30),
          department: null,
          year: 'I',
        ),
        requestedBy: 'user-1',
      );
      expect(result.outcome, ReportRequestOutcome.queued);
      expect(store.lastReportRequest?['periodType'], 'monthly');
      expect(store.lastReportRequest?['startDate'], '2026-09-01');
      expect(store.lastReportRequest?['endDate'], '2026-09-30');
      expect(store.lastReportRequest?['year'], 'I');
      expect(store.lastReportRequest?['requestedBy'], 'user-1');
    });

    test('sends the canonical department id, not the display name', () async {
      final store = _RecordingFirestore();
      final q = QueuedReportService(store);
      await q.requestReport(
        filters: ReportFilters(
          periodType: ReportPeriodType.custom,
          startDate: DateTime(2026, 9, 1),
          endDate: DateTime(2026, 9, 10),
          department: DepartmentInfo(
            id: 'BSC-CS',
            name: 'B.Sc Computer Science',
          ),
        ),
        requestedBy: 'user-1',
      );
      expect(store.lastReportRequest?['department'], 'BSC-CS');
    });
  });

  group('PendingScan model (Phase 5)', () {
    test('round-trips through JSON (the Hive storage shape)', () {
      final original = _scan(studentId: '26BSC008');
      final json = PendingScan.fromJson(original.toJson());
      expect(json.studentId, '26BSC008');
      expect(json.studentName, 'Ada Lovelace');
      expect(json.scannedBy, 'staff-1');
      expect(json.scanMethod, 'barcode');
      expect(json.docId, '26BSC008_2026-09-24');
      expect(json.deviceTimestamp, original.deviceTimestamp);
    });

    test('fromJson tolerates missing fields defensively', () {
      final p = PendingScan.fromJson({
        'studentId': '26BSC010',
        'docId': '26BSC010_2026-09-24',
      });
      expect(p.studentId, '26BSC010');
      expect(p.docId, '26BSC010_2026-09-24');
      expect(
        p.deviceTimestamp.isBefore(
          DateTime.now().add(const Duration(minutes: 1)),
        ),
        isTrue,
      );
    });
  });

  group('MemoryOfflineStore (Phase 5)', () {
    test('roster + settings + counts round-trip and clear', () async {
      final store = MemoryOfflineStore();
      await store.cacheStudents([_student('26BSC008')]);
      await store.cacheSettings(const ScanSettings(escalationThreshold: 5));
      await store.cachePeriodCount('26BSC008', 2);

      expect(store.cachedStudents().single.studentId, '26BSC008');
      expect(store.cachedSettings()!.escalationThreshold, 5);
      expect(store.cachedPeriodCount('26BSC008'), 2);

      await store.clear();
      expect(store.cachedStudents(), isEmpty);
      expect(store.cachedSettings(), isNull);
      expect(store.cachedPeriodCount('26BSC008'), isNull);
    });

    test('pending queue is keyed by doc id and returns oldest-first', () async {
      final store = MemoryOfflineStore();
      await store.enqueueScan(_scan(studentId: '26BSC008'));
      await store.enqueueScan(_scan(studentId: '26BSC010'));
      // Re-queuing the same deterministic doc overwrites, never duplicates
      // (SECURITY.md §3).
      await store.enqueueScan(_scan(studentId: '26BSC008'));

      final pending = store.pendingScans();
      expect(pending.length, 2);
      expect(pending.first.studentId, '26BSC008');

      await store.removeScan('26BSC008_2026-09-24');
      expect(store.pendingScans().single.studentId, '26BSC010');
    });
  });

  group('ConnectivityService.looksLikeOffline (Phase 5)', () {
    test('Firestore network codes read as offline', () {
      expect(
        ConnectivityService.looksLikeOffline(
          FirebaseException(code: 'unavailable', plugin: 'cloud_firestore'),
        ),
        isTrue,
      );
      expect(
        ConnectivityService.looksLikeOffline(
          FirebaseException(
            code: 'network-request-failed',
            plugin: 'cloud_firestore',
          ),
        ),
        isTrue,
      );
      expect(
        ConnectivityService.looksLikeOffline(
          FirebaseException(
            code: 'deadline-exceeded',
            plugin: 'cloud_firestore',
          ),
        ),
        isTrue,
      );
      // QA (2026-09-28): a dead DNS resolver surfaces as `unknown`, not
      // `unavailable` — it must fall back to queueing, not rethrow.
      expect(
        ConnectivityService.looksLikeOffline(
          FirebaseException(code: 'unknown', plugin: 'cloud_firestore'),
        ),
        isTrue,
      );
    });

    test('permission and validation failures are NOT mistaken for offline', () {
      expect(
        ConnectivityService.looksLikeOffline(
          FirebaseException(
            code: 'permission-denied',
            plugin: 'cloud_firestore',
          ),
        ),
        isFalse,
      );
      expect(
        ConnectivityService.looksLikeOffline(StateError('bad state')),
        isFalse,
      );
    });

    test('socket-level errors read as offline', () {
      expect(
        ConnectivityService.looksLikeOffline(
          Exception('SocketException: connection refused'),
        ),
        isTrue,
      );
    });
  });

  group('ScanService — online path (Phase 5)', () {
    test(
      'records straight through to the server (unchanged Phase-1 semantics)',
      () async {
        final store = _RecordingFirestore();
        final service = _onlineScanService(store);
        final result = await service.recordLate(
          studentId: '26BSC008',
          studentName: 'Ada Lovelace',
          scannedBy: 'staff-1',
          scanMethod: 'barcode',
        );
        expect(result.outcome, RecordOutcome.recorded);
        expect(store.recordCalls, 1);
      },
    );

    test('warms the cached period count on a successful record', () async {
      final store = _RecordingFirestore();
      final offline = MemoryOfflineStore();
      final service = _onlineScanService(store, offline: offline);
      await service.recordLate(
        studentId: '26BSC008',
        studentName: 'A',
        scannedBy: 'staff-1',
        scanMethod: 'barcode',
      );
      expect(offline.cachedPeriodCount('26BSC008'), 1);
    });
  });

  group('ScanService — offline path (Phase 5)', () {
    test('queues instead of writing and reports queued', () async {
      final store = _RecordingFirestore();
      final offline = MemoryOfflineStore();
      final service = _offlineScanService(store, offline: offline);
      final result = await service.recordLate(
        studentId: '26BSC008',
        studentName: 'Ada Lovelace',
        scannedBy: 'staff-1',
        scanMethod: 'manual',
      );
      expect(result.outcome, RecordOutcome.queued);
      expect(store.recordCalls, 0);
      final pending = offline.pendingScans().single;
      expect(pending.studentId, '26BSC008');
      expect(pending.docId, '26BSC008_${dayKey(DateTime.now())}');
      expect(
        pending.deviceTimestamp.isAfter(
          DateTime.now().subtract(const Duration(minutes: 1)),
        ),
        isTrue,
      );
    });

    test('a Firestore network failure while "connected" also queues', () async {
      final store = _RecordingFirestore()
        ..recordError = FirebaseException(
          code: 'unavailable',
          plugin: 'cloud_firestore',
        );
      final offline = MemoryOfflineStore();
      final service = _onlineScanService(store, offline: offline);
      final result = await service.recordLate(
        studentId: '26BSC008',
        studentName: 'Ada Lovelace',
        scannedBy: 'staff-1',
        scanMethod: 'qr',
      );
      expect(result.outcome, RecordOutcome.queued);
      expect(offline.pendingScans().single.studentId, '26BSC008');
    });

    test('a permission-denied error is NOT queued (it rethrows)', () async {
      final store = _RecordingFirestore()
        ..recordError = FirebaseException(
          code: 'permission-denied',
          plugin: 'cloud_firestore',
        );
      final service = _onlineScanService(store);
      await expectLater(
        service.recordLate(
          studentId: '26BSC008',
          studentName: 'A',
          scannedBy: 'staff-1',
          scanMethod: 'qr',
        ),
        throwsA(isA<FirebaseException>()),
      );
    });

    test('findStudentByCode serves the cached roster when offline', () async {
      final store = _RecordingFirestore();
      final offline = MemoryOfflineStore();
      await offline.cacheStudents([_student('26BSC008')]);
      final service = _offlineScanService(store, offline: offline);
      expect(
        (await service.findStudentByCode('26BSC008'))?.studentId,
        '26BSC008',
      );
      expect(await service.findStudentByCode('26BSC999'), isNull);
    });

    test('findStudentByCode matches the cached register number offline', () async {
      final store = _RecordingFirestore();
      final offline = MemoryOfflineStore();
      await offline.cacheStudents([
        Student(
          studentId: '26BSC011',
          name: 'Ada Lovelace',
          department: 'B.SC CS',
          registerNumber: '24BSC0011',
        ),
      ]);
      final service = _offlineScanService(store, offline: offline);
      expect(
        (await service.findStudentByCode('24BSC0011'))?.studentId,
        '26BSC011',
      );
      // Lowercase manual typing is normalized.
      expect(
        (await service.findStudentByCode('24bsc0011'))?.studentId,
        '26BSC011',
      );
      expect(await service.findStudentByCode('99BSC0000'), isNull);
    });

    test('client submit cap allows 30 scans/min and rejects the 31st', () async {
      final store = _RecordingFirestore();
      final service = _offlineScanService(store);
      Future<RecordResult> submit() => service.recordLate(
        studentId: '26BSC008',
        studentName: 'Ada Lovelace',
        scannedBy: 'staff-1',
        scanMethod: 'barcode',
      );
      for (var i = 0; i < 30; i++) {
        await submit();
      }
      await expectLater(submit(), throwsA(isA<ScanRateLimitException>()));
    });
  });

  group('SyncService (Phase 5)', () {
    test('drains the queue oldest-first and reports remaining', () async {
      final store = _RecordingFirestore();
      final offline = MemoryOfflineStore();
      final scan = _offlineScanService(store, offline: offline);
      await scan.recordLate(
        studentId: '26BSC008',
        studentName: 'A',
        scannedBy: 'staff-1',
        scanMethod: 'barcode',
      );
      await scan.recordLate(
        studentId: '26BSC010',
        studentName: 'B',
        scannedBy: 'staff-1',
        scanMethod: 'barcode',
      );

      final sync = SyncService(
        scan: scan,
        offline: offline,
        connectivity: scan.connectivity,
      );
      final result = await sync.syncNow();

      expect(result.synced, 2);
      expect(result.remaining, 0);
      expect(store.synced.length, 2);
      expect(store.synced.first.studentId, '26BSC008');
      expect(offline.pendingScans(), isEmpty);
    });

    test('an already-recorded doc id drains as "synced" (idempotent, SECURITY.md §3)', () async {
      final store = _RecordingFirestore();
      final offline = MemoryOfflineStore();
      final scan = _offlineScanService(store, offline: offline);
      await scan.recordLate(
        studentId: '26BSC008',
        studentName: 'A',
        scannedBy: 'staff-1',
        scanMethod: 'barcode',
      );
      final queuedId = offline.pendingScans().single.docId;

      store.alreadyRecorded =
          true; // the deterministic doc already exists server-side
      final result = await SyncService(
        scan: scan,
        offline: offline,
        connectivity: scan.connectivity,
      ).syncNow();
      expect(result.synced, 1);
      expect(store.synced.single.docId, queuedId);
      expect(offline.pendingScans(), isEmpty);
    });

    test(
      'a transient sync failure leaves the queue intact for retry',
      () async {
        final store = _RecordingFirestore();
        final offline = MemoryOfflineStore();
        final scan = _offlineScanService(store, offline: offline);
        await scan.recordLate(
          studentId: '26BSC008',
          studentName: 'A',
          scannedBy: 'staff-1',
          scanMethod: 'barcode',
        );
        store.syncError = FirebaseException(
          code: 'deadline-exceeded',
          plugin: 'cloud_firestore',
        );

        final result = await SyncService(
          scan: scan,
          offline: offline,
          connectivity: scan.connectivity,
        ).syncNow();
        expect(result.synced, 0);
        expect(result.remaining, 1);
        expect(offline.pendingScans().length, 1);

        store.syncError = null;
        final retry = await SyncService(
          scan: scan,
          offline: offline,
          connectivity: scan.connectivity,
        ).syncNow();
        expect(retry.synced, 1);
        expect(offline.pendingScans(), isEmpty);
      },
    );
  });

  group('HiveOfflineStore (Phase 5)', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('late_hive_test_');
      Hive.init(temp.path);
    });

    tearDown(() async {
      await Hive.close();
      await temp.delete(recursive: true);
    });

    test(
      'round-trips roster, settings, counts and queue through real boxes',
      () async {
        final store = await HiveOfflineStore.open();
        await store.cacheStudents([_student('26BSC008')]);
        await store.cacheSettings(
          const ScanSettings(escalationThreshold: 4, resetPeriod: 'monthly'),
        );
        await store.cachePeriodCount('26BSC008', 2);
        await store.enqueueScan(_scan(studentId: '26BSC008'));
        await store.removeScan(
          '26BSC008_2026-09-24',
        ); // enqueue then remove → empty queue

        expect(store.cachedStudents().single.name, 'Ada Lovelace');
        expect(store.cachedSettings()!.escalationThreshold, 4);
        expect(store.cachedPeriodCount('26BSC008'), 2);
        expect(store.pendingScans(), isEmpty);

        // Reopen to prove persistence to disk.
        final reopened = await HiveOfflineStore.open();
        expect(reopened.cachedStudents().single.studentId, '26BSC008');
        expect(reopened.cachedPeriodCount('26BSC008'), 2);
        await reopened.clear();
        expect(reopened.cachedPeriodCount('26BSC008'), isNull);
      },
    );
  });

  group('PhotoCache (Phase 1)', () {
    test(
      'decodes and caches by studentId; a hit is a touch, not a duplicate',
      () {
        final cache = PhotoCache(maxEntries: 4, maxBytes: 1 << 20);
        expect(
          cache.bytesFor(_studentWithPhoto('26BSC008', _b64(8))),
          isNotNull,
        );
        expect(cache.length, 1);
        expect(
          cache.bytesFor(_studentWithPhoto('26BSC008', _b64(999))),
          isNotNull,
        );
        expect(cache.length, 1); // still one entry — the cached decode wins
      },
    );

    test('null for missing or unreadable photos, and nothing is cached', () {
      final cache = PhotoCache();
      expect(cache.bytesFor(_student('26BSC008')), isNull);
      expect(
        cache.bytesFor(_studentWithPhoto('26BSC008', 'not-base64!!')),
        isNull,
      );
      expect(cache.length, 0);
    });

    test('bounded by maxEntries (LRU eviction)', () {
      final cache = PhotoCache(maxEntries: 2, maxBytes: 1 << 20);
      for (final id in ['A1', 'A2', 'A3']) {
        cache.bytesFor(_studentWithPhoto(id, _b64(8)));
      }
      expect(cache.length, 2); // bound enforced, oldest dropped
      expect(cache.bytesFor(_studentWithPhoto('A3', _b64(8))), isNotNull);
      expect(cache.length, 2); // touch is not an insert
    });

    test('bounded by maxBytes, evicting least-recently-used', () {
      final cache = PhotoCache(maxEntries: 10, maxBytes: 100);
      cache.bytesFor(_studentWithPhoto('A', _b64(80)));
      expect(cache.length, 1);
      cache.bytesFor(_studentWithPhoto('B', _b64(80)));
      expect(cache.bytes, 80); // A (oldest 80B) evicted to respect the budget
      expect(cache.length, 1);
      expect(cache.bytesFor(_studentWithPhoto('B', _b64(80))), isNotNull);
    });

    test('clear resets the store', () {
      final cache = PhotoCache();
      cache.bytesFor(_studentWithPhoto('26BSC008', _b64(8)));
      cache.clear();
      expect(cache.isEmpty, isTrue);
      expect(cache.bytes, 0);
    });
  });

  group('Phase 1 model helpers', () {
    test('chunkRegNumber splits the trailing numeric run for display', () {
      expect(chunkRegNumber('26BSC008'), '26BSC 008');
      expect(chunkRegNumber('24BCS001'), '24BCS 001');
      expect(chunkRegNumber('26BSC'), '26BSC'); // no trailing run — verbatim
      expect(chunkRegNumber('12345'), '12345'); // all digits — verbatim
    });

    test('hhmm zero-pads the wall clock', () {
      expect(hhmm(DateTime(2026, 9, 24, 9, 5)), '09:05');
      expect(hhmm(DateTime(2026, 9, 24, 23, 45)), '23:45');
    });

    test('dayInLateDocId reads the deterministic doc-date suffix', () {
      expect(dayInLateDocId('26BSC008_2026-09-24'), '2026-09-24');
      expect(dayInLateDocId('nodate-suffix'), '');
    });

    test('LateLogEntry.fromPending builds a local-only pending row', () {
      final entry = LateLogEntry.fromPending(_scan(studentId: '26BSC008'));
      expect(entry.pending, isTrue);
      expect(entry.syncedOffline, isTrue);
      expect(entry.localTime, '09:01');
      expect(entry.studentId, '26BSC008');
    });
  });

  group('DashboardScreen (Phase 1)', () {
    testWidgets('renders the scan CTA, live count and today list', (
      tester,
    ) async {
      final store = _RecordingFirestore()
        ..todayLogsStream = Stream.value(const [
          LateLogEntry(
            studentId: '26BSC008',
            name: 'Ada Lovelace',
            department: 'B.SC CS',
            localTime: '09:05',
          ),
          LateLogEntry(
            studentId: '26BSC010',
            name: 'Grace Hopper',
            department: 'BCA',
            localTime: '09:12',
          ),
        ]);
      final scan = _onlineScanService(store, offline: MemoryOfflineStore());
      await tester.pumpWidget(
        MaterialApp(
          home: DashboardScreen(
            auth: _FakeAuth(),
            firestore: store,
            scan: scan,
            userId: 'user-1',
          ),
        ),
      );
      await tester.pump(); // deliver the stream value
      await tester.pump(); // render the setState frame

      expect(find.text('Scan Student'), findsOneWidget);
      expect(find.text('students marked late today'), findsOneWidget);
      expect(find.text('Ada Lovelace'), findsOneWidget);
      expect(find.text('Grace Hopper'), findsOneWidget);
      expect(find.text('26BSC 008'), findsOneWidget); // chunked register number
      expect(find.text('B.SC CS'), findsOneWidget);
      expect(find.text('saved offline'), findsNothing);

      await tester.pumpWidget(const SizedBox()); // unmount → cancel timers
    });

    testWidgets('admin dashboard hides the scan CTA + scan hint (PT keeps both)', (
      tester,
    ) async {
      final store = _RecordingFirestore(); // empty today list → empty state
      final scan = _onlineScanService(store, offline: MemoryOfflineStore());

      // Admin: no scan option anywhere on the dashboard.
      await tester.pumpWidget(
        MaterialApp(
          home: DashboardScreen(
            auth: _RoleAuth('admin'),
            firestore: store,
            scan: scan,
            userId: 'user-1',
          ),
        ),
      );
      await tester.pump(); // deliver role stream
      await tester.pump(); // render setState frame
      expect(
        find.byIcon(Icons.admin_panel_settings_outlined),
        findsOneWidget,
      ); // role resolved (hide is not a load-timing artifact)
      expect(find.text('Scan Student'), findsNothing);
      expect(find.text('Scan a student to add them here.'), findsNothing);

      // Full unmount — otherwise State is reused across pumpWidget calls and
      // the admin role would leak into the PT case below.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();

      // PT gate office: the scan CTA and empty-state hint stay.
      await tester.pumpWidget(
        MaterialApp(
          home: DashboardScreen(
            auth: _RoleAuth('pt_sir'),
            firestore: store,
            scan: scan,
            userId: 'user-1',
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Scan Student'), findsOneWidget);
      expect(find.text('Scan a student to add them here.'), findsOneWidget);

      await tester.pumpWidget(const SizedBox()); // unmount → cancel timers
    });

    testWidgets('merges queued offline scans dated today into count and list', (
      tester,
    ) async {
      final store = _RecordingFirestore()
        ..todayLogsStream = Stream.value(const [
          LateLogEntry(
            studentId: '26BSC008',
            name: 'Ada Lovelace',
            department: 'B.SC CS',
            localTime: '09:05',
          ),
        ]);
      final today = DateTime.now();
      final offline = MemoryOfflineStore();
      await offline.enqueueScan(
        PendingScan(
          studentId: '26BSC010',
          studentName: 'Grace Hopper',
          scannedBy: 'staff-1',
          scanMethod: 'qr',
          deviceTimestamp: today,
          docId: '26BSC010_${dayKey(today)}',
          queuedAt: today,
        ),
      );
      final scan = _onlineScanService(store, offline: offline);
      await tester.pumpWidget(
        MaterialApp(
          home: DashboardScreen(
            auth: _FakeAuth(),
            firestore: store,
            scan: scan,
            userId: 'user-1',
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('students marked late today'), findsOneWidget);
      expect(find.text('Grace Hopper'), findsOneWidget);
      expect(find.text('saved offline'), findsOneWidget); // pending row tag
      expect(
        find.text('1 saved offline and waiting to upload'),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'account menu shows the signed-in email + claim role and signs out',
      (tester) async {
        final store = _RecordingFirestore()
          ..todayLogsStream = Stream.value(const []);
        final auth = _LogoutAuth();
        final scan = _onlineScanService(store, offline: MemoryOfflineStore());
        await tester.pumpWidget(
          MaterialApp(
            home: DashboardScreen(
              auth: auth,
              firestore: store,
              scan: scan,
              userId: 'user-1',
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        // The menu (settings/account icon) — logout lives here, not "close
        // the app" (NEW request 1).
        await tester.tap(find.byTooltip('Account & sign out'));
        await tester.pumpAndSettle();

        // Identity comes from the Auth account (email) + custom claims
        // (role), never a value hardcoded into the app.
        expect(find.text('pt@sankara.ac.in'), findsOneWidget);
        expect(find.text('PT Sir'), findsOneWidget);

        await tester.tap(find.text('Sign out'));
        await tester.pumpAndSettle();
        expect(auth.signOutCalls, 1);

        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('VerifyScreen (Phase 1)', () {
    testWidgets('shows identity + status, submits, then confirms recorded', (
      tester,
    ) async {
      final store = _RecordingFirestore();
      final scan = _onlineScanService(store, offline: MemoryOfflineStore());
      await tester.pumpWidget(
        MaterialApp(
          home: VerifyScreen(
            firestore: store,
            scan: scan,
            userId: 'staff-1',
            student: _student('26BSC008'),
            scanMethod: 'barcode',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Ada Lovelace'), findsOneWidget);
      expect(find.text('26BSC 008'), findsOneWidget); // chunked register number
      expect(find.text('B.SC CS'), findsOneWidget);
      expect(
        find.text('1st time this month'),
        findsOneWidget,
      ); // prospective badge
      expect(find.text('Confirm'), findsOneWidget);
      expect(find.text('Scan Next Student'), findsOneWidget);

      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Confirm'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
      await tester.pumpAndSettle();

      expect(find.text('Recorded \u2014 1st time this month'), findsOneWidget);
      expect(
        find.widgetWithText(FilledButton, 'Scan Next Student'),
        findsOneWidget,
      );
      expect(find.text('Back to Dashboard'), findsOneWidget);
    });

    testWidgets('duplicate same-day scans are blocked at the UI', (
      tester,
    ) async {
      final store = _RecordingFirestore()
        ..alreadyTodayStream = Stream.value(true);
      final scan = _onlineScanService(store, offline: MemoryOfflineStore());
      await tester.pumpWidget(
        MaterialApp(
          home: VerifyScreen(
            firestore: store,
            scan: scan,
            userId: 'staff-1',
            student: _student('26BSC008'),
            scanMethod: 'barcode',
          ),
        ),
      );
      await tester.pumpAndSettle();

      final submit = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Recorded today'),
      );
      expect(submit.onPressed, isNull);
    });

    testWidgets(
      'a non-offline record failure recovers: error shown, Confirm re-enabled',
      (tester) async {
        final store = _RecordingFirestore()
          ..recordError = FirebaseException(
            code: 'internal',
            plugin: 'cloud_firestore',
          );
        await tester.pumpWidget(
          MaterialApp(
            home: VerifyScreen(
              firestore: store,
              scan: _onlineScanService(store),
              userId: 'staff-1',
              student: _student('26BSC008'),
              scanMethod: 'barcode',
            ),
          ),
        );
        await tester.pumpAndSettle();

        final confirm = find.widgetWithText(FilledButton, 'Confirm');
        await tester.ensureVisible(confirm);
        await tester.pumpAndSettle();
        await tester.tap(confirm);
        await tester.pumpAndSettle();

        expect(find.textContaining('Could not save this scan'), findsOneWidget);
        // Not stuck on "Recording...": the button is back and tappable.
        expect(find.widgetWithText(FilledButton, 'Confirm'), findsOneWidget);
        expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);

        // A retry stays inside the screen instead of throwing past it.
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        expect(find.textContaining('Could not save this scan'), findsOneWidget);
      },
    );
  });

  group('yearTier classifier (Phase 2 report mail)', () {
    test('classifies 1st/2nd/3rd spellings and roman numerals', () {
      expect(yearTier('1st Year'), 1);
      expect(yearTier('I'), 1);
      expect(yearTier('I Year'), 1);
      expect(yearTier('First Year'), 1);
      expect(yearTier('2nd Year'), 2);
      expect(yearTier('II'), 2);
      expect(yearTier('Second Year'), 2);
      expect(yearTier('3rd Year'), 3);
      expect(yearTier('III'), 3);
      expect(yearTier('Third Year'), 3);
      expect(yearTier('Year 2'), 2);
    });

    test('batch-year strings and blanks map to Other, never a grade', () {
      expect(yearTier('2024-2027'), 0);
      expect(yearTier('2026'), 0);
      expect(yearTier(null), 0);
      expect(yearTier(''), 0);
    });

    test('labels and tokens follow the 3rd/2nd/1st convention', () {
      expect(yearTierLabel(3), '3rd Year');
      expect(yearTierLabel(2), '2nd Year');
      expect(yearTierLabel(1), '1st Year');
      expect(yearTierLabel(0), 'Other');
      expect(reportTierToken(3), '3rd');
      expect(reportTierToken(2), '2nd');
      expect(reportTierToken(1), '1st');
      expect(reportTierToken(0), 'Other');
    });
  });

  group('report mail file names (Phase 2)', () {
    final start = DateTime(2026, 9, 1);
    final end = DateTime(2026, 9, 30);

    test('range is a single day for daily windows, start_to_end otherwise', () {
      expect(
        reportMailRange(DateTime(2026, 9, 24), DateTime(2026, 9, 24)),
        '2026-09-24',
      );
      expect(reportMailRange(start, end), '2026-09-01_to_2026-09-30');
    });

    test('combined = one Excel + one PDF for the whole window', () {
      final names = reportMailAttachmentNames(
        department: 'BSC-CS',
        start: start,
        end: end,
        mode: ReportMailMode.combined,
        tiers: const {1, 2, 3},
      );
      expect(names, [
        'bsccs_Late_Attendance_2026-09-01_to_2026-09-30.xlsx',
        'bsccs_Late_Attendance_2026-09-01_to_2026-09-30.pdf',
      ]);
    });

    test('split = one PDF per present year tier plus Excel (3rd first)', () {
      final names = reportMailAttachmentNames(
        department: 'BSC-CS',
        start: start,
        end: end,
        mode: ReportMailMode.split,
        tiers: const {3, 2, 1},
      );
      expect(names, [
        'bsccs_Late_Attendance_2026-09-01_to_2026-09-30.xlsx',
        'bsccs_3rd_Year_2026-09-01_to_2026-09-30.pdf',
        'bsccs_2nd_Year_2026-09-01_to_2026-09-30.pdf',
        'bsccs_1st_Year_2026-09-01_to_2026-09-30.pdf',
      ]);
    });

    test('split includes only the tiers actually present', () {
      final names = reportMailAttachmentNames(
        department: 'BSC-CS',
        start: start,
        end: end,
        mode: ReportMailMode.split,
        tiers: const {3, 0},
      );
      expect(names, [
        'bsccs_Late_Attendance_2026-09-01_to_2026-09-30.xlsx',
        'bsccs_3rd_Year_2026-09-01_to_2026-09-30.pdf',
        'bsccs_Other_Year_2026-09-01_to_2026-09-30.pdf',
      ]);
    });

    test('subject carries the department and the date range', () {
      expect(
        reportMailSubject(
          department: 'B.Sc Computer Science',
          start: start,
          end: end,
        ),
        'Late Attendance Report - B.Sc Computer Science - 2026-09-01_to_2026-09-30',
      );
    });
  });

  group('buildReportMailBodyPreview (Phase 2)', () {
    const rows = [
      ReportRow(
        date: '2026-09-01',
        time: '09:10',
        studentId: '26BSC001',
        name: 'Ada',
        department: 'B.SC CS',
        year: '3rd Year',
      ),
      ReportRow(
        date: '2026-09-01',
        time: '09:12',
        studentId: '26BSC002',
        name: 'Grace',
        department: 'B.SC CS',
        year: '2nd Year',
      ),
      ReportRow(
        date: '2026-09-02',
        time: '09:05',
        studentId: '26BSC003',
        name: 'Alan',
        department: 'B.SC CS',
        year: '1st Year',
      ),
    ];

    test('greets the HOD, lists year-wise names and totals', () {
      final body = buildReportMailBodyPreview(
        department: 'B.Sc Computer Science',
        start: DateTime(2026, 9, 1),
        end: DateTime(2026, 9, 30),
        rows: rows,
        totalLateEntries: 3,
        distinctStudents: 3,
      );
      expect(body, startsWith('Dear HOD,'));
      expect(body, contains('3rd Year (1)'));
      expect(body, contains('2nd Year (1)'));
      expect(body, contains('1st Year (1)'));
      expect(body, contains('26BSC001 - Ada'));
      expect(body, contains('26BSC003 - Alan'));
      expect(body, contains('3 late entries were recorded for 3 students'));
      expect(body, contains('Regards,'));
    });

    test('year buckets run 3rd before 2nd before 1st', () {
      final body = buildReportMailBodyPreview(
        department: 'B.Sc Computer Science',
        start: DateTime(2026, 9, 1),
        end: DateTime(2026, 9, 30),
        rows: const [
          ReportRow(
            date: '2026-09-01',
            time: '09:10',
            studentId: '26BSC001',
            name: 'Ada',
            department: 'B.SC CS',
            year: '1st Year',
          ),
          ReportRow(
            date: '2026-09-01',
            time: '09:12',
            studentId: '26BSC002',
            name: 'Grace',
            department: 'B.SC CS',
            year: '3rd Year',
          ),
          ReportRow(
            date: '2026-09-01',
            time: '09:13',
            studentId: '26BSC003',
            name: 'Alan',
            department: 'B.SC CS',
            year: '2nd Year',
          ),
        ],
        totalLateEntries: 3,
        distinctStudents: 3,
      );
      final third = body.indexOf('3rd Year');
      final second = body.indexOf('2nd Year');
      final first = body.indexOf('1st Year');
      expect(third.isNegative, isFalse);
      expect(third < second && second < first, isTrue);
    });
  });

  group('QueuedReportMailService (Phase 2 Spark fallback)', () {
    test(
      'enqueues a type=report mail_queue intent with filters and mode',
      () async {
        final store = _RecordingFirestore();
        final service = QueuedReportMailService(store);
        final result = await service.sendReportMail(
          request: ReportMailRequest(
            periodType: ReportPeriodType.monthly,
            startDate: DateTime(2026, 9, 1),
            endDate: DateTime(2026, 9, 30),
            department: const DepartmentInfo(
              id: 'BSC-CS',
              name: 'B.Sc Computer Science',
              hodEmail: 'hod@cs.example',
            ),
            year: '3',
            mode: ReportMailMode.split,
          ),
          requestedBy: 'user-1',
        );
        expect(result.outcome, MailRequestOutcome.queued);
        expect(store.lastReportMail?['type'], 'report');
        expect(store.lastReportMail?['departmentId'], 'BSC-CS');
        expect(store.lastReportMail?['department'], 'B.Sc Computer Science');
        expect(store.lastReportMail?['periodType'], 'monthly');
        expect(store.lastReportMail?['startDate'], '2026-09-01');
        expect(store.lastReportMail?['endDate'], '2026-09-30');
        expect(store.lastReportMail?['year'], '3');
        expect(store.lastReportMail?['attachmentMode'], 'split');
        expect(store.lastReportMail?['requestedBy'], 'user-1');
      },
    );
  });

  group('MailLogEntry (Phase 2 mail audit)', () {
    test('parses a report log with attachments and a timestamp', () {
      final e = MailLogEntry.fromFirestore('BSC_CS_2026-09', {
        'type': 'report',
        'department': 'B.Sc Computer Science',
        'to': 'hod@cs.example',
        'subject': 'Late Attendance Report - B.Sc Computer Science - 2026-09-01_to_2026-09-30',
        'period': '',
        'label': '2026-09-01_to_2026-09-30',
        'studentsIncluded': 3,
        'files': ['bsccs_Late_Attendance_2026-09-01_to_2026-09-30.pdf'],
        'sentTimestamp': {'_seconds': 1780310000},
      });
      expect(e.isReport, isTrue);
      expect(e.department, 'B.Sc Computer Science');
      expect(e.to, 'hod@cs.example');
      expect(e.label, '2026-09-01_to_2026-09-30');
      expect(e.studentsIncluded, 3);
      expect(e.files.single, contains('.pdf'));
      expect(e.sentTimestamp, isNotNull);
    });

    test('an untyped log defaults to escalation', () {
      final e = MailLogEntry.fromFirestore('x', {
        'subject': 'Late Attendance mail',
      });
      expect(e.isReport, isFalse);
      expect(e.type, 'escalation');
      expect(e.files, isEmpty);
      expect(e.sentTimestamp, isNull);
      expect(e.studentsIncluded, 0);
    });

    test('a cloud_firestore-style Timestamp object is parsed (not "time unknown")', () {
      final e = MailLogEntry.fromFirestore('x', {
        'subject': 'Late Attendance mail',
        'sentTimestamp': _TimestampLike(DateTime.utc(2026, 9, 28, 7, 4, 50)),
      });
      expect(e.sentTimestamp, DateTime.utc(2026, 9, 28, 7, 4, 50));
    });
  });

  group('HodPickerScreen (Phase 2 HOD search)', () {
    const depts = [
      DepartmentInfo(
        id: 'BSC-CS',
        name: 'B.Sc Computer Science',
        hodEmail: 'hod@cs.example',
      ),
      DepartmentInfo(id: 'BCA', name: 'BCA', hodEmail: 'hod@bca.example'),
      DepartmentInfo(id: 'NOEMAIL', name: 'No Email Dept'),
    ];

    testWidgets('search narrows the list by name', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: HodPickerScreen(departments: depts)),
      );
      await tester.pumpAndSettle();
      expect(find.text('BCA'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('hod-search')), 'bca');
      await tester.pumpAndSettle();
      expect(find.text('B.Sc Computer Science'), findsNothing);
      expect(find.text('BCA'), findsOneWidget);
    });

    testWidgets('picking a department returns it via Navigator.pop', (
      tester,
    ) async {
      DepartmentInfo? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  picked = await Navigator.of(context).push<DepartmentInfo>(
                    MaterialPageRoute(
                      builder: (_) => const HodPickerScreen(departments: depts),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('BCA'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm HOD'));
      await tester.pumpAndSettle();
      expect(picked?.id, 'BCA');
    });

    testWidgets('departments without a HOD email cannot be selected', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(home: HodPickerScreen(departments: depts)),
      );
      await tester.pumpAndSettle();
      expect(find.text('No HOD email on file'), findsOneWidget);
      await tester.tap(find.text('No Email Dept'));
      await tester.pumpAndSettle();
      final confirm = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Confirm HOD'),
      );
      expect(confirm.onPressed, isNull);
    });
  });

  group('MailPreviewScreen (Phase 2)', () {
    ReportRow row(String id, String name, String year) => ReportRow(
      date: '2026-09-01',
      time: '09:10',
      studentId: id,
      name: name,
      department: 'B.SC CS',
      year: year,
    );

    final rows = [
      row('26BSC001', 'Ada', '3rd Year'),
      row('26BSC002', 'Grace', '2nd Year'),
      row('26BSC003', 'Alan', '1st Year'),
    ];

    MailPreviewScreen screen(_RecordingFirestore store) => MailPreviewScreen(
      firestore: store,
      userId: 'user-1',
      periodType: ReportPeriodType.monthly,
      startDate: DateTime(2026, 9, 1),
      endDate: DateTime(2026, 9, 30),
      initialDepartment: const DepartmentInfo(
        id: 'BSC-CS',
        name: 'B.Sc Computer Science',
        hodEmail: 'hod@cs.example',
      ),
      mailService: QueuedReportMailService(store),
    );

    testWidgets('reviews recipient, subject, message and combined attachment', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final store = _RecordingFirestore()..seededRows = rows;
      await tester.pumpWidget(MaterialApp(home: screen(store)));
      await tester.pumpAndSettle();

      expect(find.text('B.Sc Computer Science'), findsOneWidget);
      expect(find.text('hod@cs.example'), findsOneWidget);
      // header must interpolate the summary fields, not the object
      // (`'$summary.totalLateEntries'` printed "Instance of 'ReportSummary'.").
      expect(find.text('3 late entries, 3 students'), findsOneWidget);
      expect(find.textContaining("Instance of 'ReportSummary'"), findsNothing);
      expect(
        find.textContaining('Late Attendance Report - B.Sc Computer Science'),
        findsOneWidget,
      );
      expect(find.textContaining('3rd Year (1)'), findsOneWidget);
      expect(find.textContaining('26BSC001 - Ada'), findsOneWidget);
      expect(
        find.textContaining(
          'bsccs_Late_Attendance_2026-09-01_to_2026-09-30.pdf',
        ),
        findsOneWidget,
      );
    });

    testWidgets('switching to split-by-year shows per-year attachment names', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final store = _RecordingFirestore()..seededRows = rows;
      await tester.pumpWidget(MaterialApp(home: screen(store)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Split by year'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('bsccs_3rd_Year_2026-09-01_to_2026-09-30.pdf'),
        findsOneWidget,
      );
      expect(
        find.textContaining('bsccs_2nd_Year_2026-09-01_to_2026-09-30.pdf'),
        findsOneWidget,
      );
      expect(
        find.textContaining('bsccs_1st_Year_2026-09-01_to_2026-09-30.pdf'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'bsccs_Late_Attendance_2026-09-01_to_2026-09-30.pdf',
        ),
        findsNothing,
      );
    });

    testWidgets('Confirm Send enqueues the intent and shows queued success', (
      tester,
    ) async {
      final store = _RecordingFirestore()..seededRows = rows;
      await tester.pumpWidget(MaterialApp(home: screen(store)));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Confirm Send'));
      await tester.pumpAndSettle();

      expect(store.lastReportMail?['type'], 'report');
      expect(store.lastReportMail?['departmentId'], 'BSC-CS');
      expect(store.lastReportMail?['attachmentMode'], 'combined');
      expect(find.text('Report queued for sending'), findsOneWidget);
    });
  });

  group('MailLogsScreen (Phase 2 mail logs)', () {
    testWidgets('renders report and escalation logs with badges', (
      tester,
    ) async {
      final store = _RecordingFirestore()
        ..seededMailLogs = [
          MailLogEntry(
            id: 'r1',
            type: 'report',
            department: 'B.Sc Computer Science',
            to: 'hod@cs.example',
            subject: 'Late Attendance Report - B.Sc Computer Science - 2026-09-01_to_2026-09-30',
            period: '',
            label: '2026-09-01_to_2026-09-30',
            studentsIncluded: 3,
            files: const ['bsccs_Late_Attendance_2026-09-01_to_2026-09-30.pdf'],
            sentTimestamp: DateTime.utc(2026, 9, 30, 10),
          ),
          MailLogEntry(
            id: 'e1',
            type: 'escalation',
            department: 'BCA',
            to: 'hod@bca.example',
            subject: '[Escalated] Late Attendance - BCA - 2026-09',
            period: '2026-09',
            studentsIncluded: 2,
            sentTimestamp: DateTime.utc(2026, 9, 15, 9),
          ),
        ];
      await tester.pumpWidget(
        MaterialApp(home: MailLogsScreen(firestore: store)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Report'), findsOneWidget);
      expect(find.text('Escalation'), findsOneWidget);
      expect(find.textContaining('hod@cs.example'), findsOneWidget);
      expect(find.text('3 students reported'), findsOneWidget);
      expect(find.text('2 students reported'), findsOneWidget);
      expect(
        find.textContaining(
          'bsccs_Late_Attendance_2026-09-01_to_2026-09-30.pdf',
        ),
        findsOneWidget,
      );
    });

    testWidgets('empty state when nothing has been sent', (tester) async {
      final store = _RecordingFirestore();
      await tester.pumpWidget(
        MaterialApp(home: MailLogsScreen(firestore: store)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('No mails sent yet'), findsOneWidget);
    });

    testWidgets('weekly audit logs get a dedicated badge', (tester) async {
      final store = _RecordingFirestore()
        ..seededMailLogs = [
          MailLogEntry(
            id: 'w1',
            type: 'weekly_audit',
            department: 'BCA',
            to: 'hod@bca.example',
            subject:
                'Weekly Late Attendance Audit - BCA - 2026-09-21_to_2026-09-27',
            period: '',
            label: '2026-09-21_to_2026-09-27',
            studentsIncluded: 2,
            files: const [
              'bca_Weekly_Audit_2026-09-21_to_2026-09-27.xlsx',
              'bca_Weekly_Audit_2026-09-21_to_2026-09-27.pdf',
            ],
            sentTimestamp: DateTime.utc(2026, 9, 27, 17, 30),
          ),
        ];
      await tester.pumpWidget(
        MaterialApp(home: MailLogsScreen(firestore: store)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Weekly Audit'), findsOneWidget);
      expect(
        find.textContaining('bca_Weekly_Audit_2026-09-21_to_2026-09-27.xlsx'),
        findsOneWidget,
      );
      expect(find.text('2 students reported'), findsOneWidget);
    });
  });

  group('weekly audit helpers (Phase 3)', () {
    final monday = DateTime(2026, 9, 21);

    ReportRow row(
      String id,
      String name,
      String dept,
      String date, {
      String? year,
    }) => ReportRow(
      date: date,
      time: '09:05',
      studentId: id,
      name: name,
      department: dept,
      year: year,
    );

    test('weeklyMonday anchors any weekday to that week\'s Monday', () {
      expect(weeklyMonday(DateTime(2026, 9, 21)), DateTime(2026, 9, 21));
      expect(weeklyMonday(DateTime(2026, 9, 25)), DateTime(2026, 9, 21));
      expect(weeklyMonday(DateTime(2026, 9, 27)), DateTime(2026, 9, 21));
      expect(weeklyMonday(DateTime(2026, 9, 28)), DateTime(2026, 9, 28));
    });

    test('monthKey produces the calendar-month key', () {
      expect(monthKey(DateTime(2026, 9, 21)), '2026-09');
      expect(monthKey(DateTime(2026, 10, 1)), '2026-10');
    });

    test(
      'weeklyAuditOverview groups, sorts, and respects the month window',
      () {
        final rows = [
          // BCA — Ada repeated across the month boundary.
          row('A', 'Ada', 'BCA', '2026-09-28', year: '3rd Year'),
          row('A', 'Ada', 'BCA', '2026-10-01', year: '3rd Year'),
          row('G', 'Grace', 'BCA', '2026-10-02', year: '2nd Year'),
          // PHYSICS — 1 student, 3 events (ties with CS on unique, wins on events).
          row('P', 'Priya', 'PHYSICS', '2026-09-29', year: '1st Year'),
          row('P', 'Priya', 'PHYSICS', '2026-09-30', year: '1st Year'),
          row('P', 'Priya', 'PHYSICS', '2026-10-01', year: '1st Year'),
          // B.SC CS — 1 student, 2 events.
          row('C', 'Alan', 'B.SC CS', '2026-09-28', year: '1st Year'),
          row('C', 'Alan', 'B.SC CS', '2026-09-29', year: '1st Year'),
        ];

        final overview = weeklyAuditOverview(rows, DateTime(2026, 9, 28));
        expect(overview.monthKey, '2026-09');
        expect(overview.totalEvents, 8);
        expect(overview.uniqueStudents, 4);
        expect(overview.repeatedStudents, 3);
        expect(overview.departments.map((d) => d.department), [
          'BCA',
          'PHYSICS',
          'B.SC CS',
        ]);

        final bca = overview.departments[0];
        expect(bca.uniqueStudents, 2);
        expect(bca.repeatedStudents, 1);
        expect(bca.students.map((s) => s.name), ['Ada', 'Grace']);
        final ada = bca.students.first;
        expect(ada.weekCount, 2);
        expect(
          ada.monthCount,
          1,
        ); // the Oct 1 row sits outside the September month window
        expect(ada.lastLateDate, '2026-09-28');
        expect(ada.repeated, isTrue);
      },
    );

    test('repeat threshold is honored and configurable', () {
      final rows = [
        row('A', 'Ada', 'BCA', '2026-09-21'),
        row('A', 'Ada', 'BCA', '2026-09-22'),
        row('P', 'Priya', 'BCA', '2026-09-21'),
        row('P', 'Priya', 'BCA', '2026-09-22'),
        row('P', 'Priya', 'BCA', '2026-09-23'),
      ];
      final atTwo = weeklyAuditOverview(rows, monday);
      expect(atTwo.repeatedStudents, 2);
      final atThree = weeklyAuditOverview(rows, monday, repeatThreshold: 3);
      expect(atThree.repeatedStudents, 1);
      expect(atThree.departments.single.repeated.single.name, 'Priya');
    });

    test('range, subject and attachment file names mirror the server', () {
      expect(weeklyAuditRange(monday), '2026-09-21_to_2026-09-27');
      expect(
        weeklyAuditSubject(department: 'BCA', weekStart: monday),
        'Weekly Late Attendance Audit - BCA - 2026-09-21_to_2026-09-27',
      );
      expect(weeklyAuditAttachmentNames(department: 'BCA', weekStart: monday), [
        'bca_Weekly_Audit_2026-09-21_to_2026-09-27.xlsx',
        'bca_Weekly_Audit_2026-09-21_to_2026-09-27.pdf',
      ]);
    });

    test('buildWeeklyAuditBodyPreview lists repeated students and totals', () {
      final group = WeeklyAuditGroup(
        department: 'BCA',
        uniqueStudents: 1,
        totalEvents: 2,
        repeatedStudents: 1,
        students: const [
          WeeklyStudentView(
            studentId: '26BSC001',
            name: 'Ada',
            department: 'BCA',
            year: '3rd Year',
            monthKey: '2026-09',
            weekCount: 2,
            monthCount: 2,
            repeated: true,
            lastLateDate: '2026-09-22',
          ),
        ],
      );
      final body = buildWeeklyAuditBodyPreview(
        department: 'BCA',
        weekStart: monday,
        group: group,
      );
      expect(body, contains('Dear HOD,'));
      expect(
        body,
        contains(
          'Ada (26BSC001) - year 3rd Year - 2 this week, 2 this month, last late 2026-09-22',
        ),
      );
      expect(body, contains('of whom 1 were late more than once'));

      final emptyGroup = WeeklyAuditGroup(
        department: 'BCA',
        uniqueStudents: 1,
        totalEvents: 1,
        repeatedStudents: 0,
        students: const [],
      );
      expect(
        buildWeeklyAuditBodyPreview(
          department: 'BCA',
          weekStart: monday,
          group: emptyGroup,
        ),
        contains('No student was marked late more than once this week.'),
      );
    });

    test('MailLogEntry.isWeeklyAudit distinguishes audit rows', () {
      const weekly = MailLogEntry(
        id: 'w1',
        type: 'weekly_audit',
        department: 'BCA',
        to: 'hod@bca.example',
        subject: 'Weekly Late Attendance Audit',
        period: '',
      );
      expect(weekly.isWeeklyAudit, isTrue);
      expect(weekly.isReport, isFalse);
    });
  });

  group('ReportsScreen preview filters (Phase 4 regression)', () {
    const csDept = DepartmentInfo(
      id: 'BSC-CS',
      name: 'B.Sc Computer Science',
      hodEmail: 'hod@cs.example',
    );
    const itDept = DepartmentInfo(
      id: 'BSC-IT',
      name: 'B.Sc Information Technology',
      hodEmail: 'hod@it.example',
    );

    ReportRow row(String id, String dept, String year) => ReportRow(
      date: '2026-09-28',
      time: '09:10',
      studentId: id,
      name: id,
      department: dept,
      year: year,
    );

    testWidgets('preview shows the result of the latest control change', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final store = _RecordingFirestore()
        ..filterReportRows = true
        ..seededDepartments = [csDept, itDept]
        ..seededRows = [
          row('26BSC010', 'B.Sc Computer Science', '1st Year'),
          row('26BSC008', 'B.Sc Computer Science', '3rd Year'),
          row('26BIT001', 'B.Sc Information Technology', '1st Year'),
        ];
      await tester.pumpWidget(
        MaterialApp(
          home: ReportsScreen(
            auth: _FakeAuth(),
            firestore: store,
            userId: 'user-1',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Initial preview: every seeded row.
      expect(find.text('3 students'), findsOneWidget);
      expect(store.lastReportDepartment, isNull);
      expect(store.lastReportYear, isNull);

      // Department filter: the card must reflect THIS change, not the previous
      // one (regression: `setState(() => _previewFuture = _loadPreview())`
      // returned a Future, tripping the debug assertion so the new future
      // never reached the FutureBuilder).
      await tester.tap(find.text('All departments'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(DropdownMenuItem<String>, 'B.Sc Computer Science'),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(store.lastReportDepartment?.id, 'BSC-CS');
      expect(find.text('2 students'), findsOneWidget);
      expect(find.text('B.Sc Information Technology'), findsNothing);

      // Year filter on top: only the 1st-year CS row remains.
      await tester.tap(find.text('All years'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(DropdownMenuItem<String>, '1st Year'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(store.lastReportYear, '1');
      expect(find.text('1 student'), findsOneWidget);
      // once in the dropdown button + once in the breakdown row.
      expect(find.text('B.Sc Computer Science'), findsNWidgets(2));
    });
  });

  group('WeeklyAuditScreen (Phase 3)', () {
    final monday = DateTime(2026, 9, 21);
    const bca = DepartmentInfo(
      id: 'BCA',
      name: 'BCA',
      hodEmail: 'hod@bca.example',
    );
    const cs = DepartmentInfo(
      id: 'BSC-CS',
      name: 'B.Sc Computer Science',
      hodEmail: 'hod@cs.example',
    );

    List<ReportRow> matchedRows() => [
      ReportRow(
        date: '2026-09-21',
        time: '09:05',
        studentId: '26BSC001',
        name: 'Ada',
        department: 'BCA',
        year: '3rd Year',
      ),
      ReportRow(
        date: '2026-09-22',
        time: '09:06',
        studentId: '26BSC001',
        name: 'Ada',
        department: 'BCA',
        year: '3rd Year',
      ),
      ReportRow(
        date: '2026-09-22',
        time: '09:07',
        studentId: '26BSC002',
        name: 'Grace',
        department: 'BCA',
        year: '2nd Year',
      ),
      ReportRow(
        date: '2026-09-23',
        time: '09:05',
        studentId: '26BSC003',
        name: 'Alan',
        department: 'B.SC CS',
        year: '1st Year',
      ),
      ReportRow(
        date: '2026-09-24',
        time: '09:08',
        studentId: '26BSC003',
        name: 'Alan',
        department: 'B.SC CS',
        year: '1st Year',
      ),
      ReportRow(
        date: '2026-09-23',
        time: '09:05',
        studentId: '26BSC004',
        name: 'Priya',
        department: 'PHYSICS',
        year: '1st Year',
      ),
      ReportRow(
        date: '2026-09-24',
        time: '09:09',
        studentId: '26BSC004',
        name: 'Priya',
        department: 'PHYSICS',
        year: '1st Year',
      ),
    ];

    WeeklyAuditScreen screen(_RecordingFirestore store) => WeeklyAuditScreen(
      auth: _FakeAuth(),
      firestore: store,
      userId: 'user-1',
      initialWeekStart: monday,
    );

    testWidgets('shows the week window, summary and per-department repeats', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final store = _RecordingFirestore()
        ..seededRows = matchedRows()
        ..seededDepartments = [bca, cs];
      await tester.pumpWidget(MaterialApp(home: screen(store)));
      await tester.pumpAndSettle();

      expect(find.text('Week 2026-09-21_to_2026-09-27'), findsOneWidget);
      expect(find.text('4'), findsOneWidget); // unique students
      expect(find.text('7'), findsOneWidget); // late entries
      expect(find.text('3'), findsOneWidget); // repeated this week
      expect(find.text('repeated (>=2 this week)'), findsOneWidget);
      expect(find.text('BCA'), findsOneWidget);
      expect(find.text('B.Sc Computer Science'), findsOneWidget);
      expect(
        find.text('No HOD email on file'),
        findsOneWidget,
      ); // PHYSICS has no ref doc
      expect(find.text('Ada'), findsOneWidget);
      expect(find.text('Alan'), findsOneWidget);
      expect(find.text('Priya'), findsOneWidget);
      expect(find.text('Grace'), findsNothing); // only repeated rows are listed
      expect(find.text('W 2'), findsNWidgets(3));
    });

    testWidgets('search filters the repeated student list', (tester) async {
      tester.view.physicalSize = const Size(800, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final store = _RecordingFirestore()
        ..seededRows = matchedRows()
        ..seededDepartments = [bca, cs];
      await tester.pumpWidget(MaterialApp(home: screen(store)));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'ada');
      await tester.pumpAndSettle();

      expect(find.text('Ada'), findsOneWidget);
      expect(find.text('Alan'), findsNothing);
      expect(find.text('Priya'), findsNothing);
    });

    testWidgets('Send to HOD opens the preview flow for pt_sir/admin', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final store = _RecordingFirestore()
        ..seededRows = matchedRows()
        ..seededDepartments = [bca, cs];
      await tester.pumpWidget(MaterialApp(home: screen(store)));
      await tester.pumpAndSettle();

      expect(find.text('Send to HOD'), findsNWidgets(2));
      await tester.tap(find.text('Send to HOD').first); // BCA sorts first
      await tester.pumpAndSettle();

      expect(find.text('Weekly Audit Mail'), findsOneWidget);
      expect(find.text('hod@bca.example'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm Send'));
      await tester.pumpAndSettle();

      expect(store.lastWeeklyMail?['type'], 'weekly_audit');
      expect(store.lastWeeklyMail?['departmentId'], 'BCA');
      expect(store.lastWeeklyMail?['startDate'], '2026-09-21');
      expect(find.text('Weekly audit queued for sending'), findsOneWidget);
    });
  });

  group('Phase 4 — admin import validation mirrors the server', () {
    const cs = DepartmentInfo(id: 'BSC-CS', name: 'B.Sc CS');
    const bca = DepartmentInfo(id: 'BCA', name: 'BCA');

    ImportRow row({
      String reg = '26BSC001',
      String name = 'Ada Lovelace',
      String dept = 'B.Sc CS',
      int? curr = 3,
      int? start = 2024,
      int? end = 2027,
    }) => ImportRow(
      registerNumber: reg,
      name: name,
      department: dept,
      currentYear: curr,
      batchStartYear: start,
      batchEndYear: end,
    );

    ImportSheetResult validate(
      List<ImportRow> rows, {
      List<String> existing = const [],
    }) => validateImportRows(
      rows,
      departments: const [cs, bca],
      existingStudentIds: existing,
    );

    test('a clean row is valid with the correct year label', () {
      final r = validate([row()]);
      expect(r.counts.rows, 1);
      expect(r.counts.valid, 1);
      expect(r.counts.invalid, 0);
      expect(r.rows.single.valid, isTrue);
      expect(r.rows.single.departmentId, 'BSC-CS');
      expect(importYearLabel(3), '3rd Year');
      expect(importYearLabel(1), '1st Year');
      expect(importYearLabel(9), 'Other');
    });

    test('duplicate register numbers in the sheet are errors; only the first counts', () {
      final r = validate([row(), row(reg: '26BSC001', name: 'Grace')]);
      expect(r.counts.valid, 1);
      expect(r.counts.invalid, 1);
      expect(r.rows[1].valid, isFalse);
      expect(r.rows[1].errors, anyElement(contains('Duplicate')));
    });

    test('register numbers already on the roster are errors', () {
      final r = validate([row()], existing: ['26BSC001']);
      expect(r.rows.single.valid, isFalse);
      expect(r.rows.single.errors.single, contains('already on file'));
    });

    test('an unknown department is an error with actionable wording', () {
      final r = validate([row(dept: 'Economics')]);
      expect(r.rows.single.valid, isFalse);
      expect(r.rows.single.errors.single, contains('not on file'));
    });

    test('invalid years are errors and reversed ranges are errors', () {
      final bad = validate([row(start: 1970)]);
      expect(bad.rows.single.valid, isFalse);
      expect(bad.rows.single.errors, contains(contains('out of range')));

      final reversed = validate([row(start: 2027, end: 2024)]);
      expect(
        reversed.rows.single.errors,
        anyElement(contains('before the start year')),
      );
    });

    test(
      'register prefix that contradicts the batch year is only a warning',
      () {
        final r = validate([row(reg: '24BCS001', start: 2026, end: 2029)]);
        expect(r.rows.single.valid, isTrue);
        expect(r.rows.single.warnings, isNotEmpty);
        expect(r.counts.warnings, 1);
      },
    );

    test('a current year outside the batch span is only a warning', () {
      final r = validate([row(curr: 5, start: 2024, end: 2027)]);
      expect(r.rows.single.valid, isTrue);
      expect(r.rows.single.warnings, anyElement(contains('outside the batch')));
    });

    test('more than the cap (500) is truncated to the cap', () {
      final r = validate(
        List.generate(
          520,
          (i) => row(reg: '26BSC${(i + 1).toString().padLeft(3, '0')}'),
        ),
      );
      expect(r.counts.rows, 500);
    });

    test(
      'readSheetRows decodes a real xlsx generated by the excel package',
      () {
        final workbook = Excel.createExcel();
        final sheet = workbook['Sheet1'];
        sheet.appendRow([
          TextCellValue('Register Number'),
          TextCellValue('Student Name'),
          TextCellValue('Department'),
          TextCellValue('Current Year'),
          TextCellValue('Batch Start Year'),
          TextCellValue('Batch End Year'),
        ]);
        sheet.appendRow([
          TextCellValue('26BSC001'),
          TextCellValue('Ada Lovelace'),
          TextCellValue('B.Sc CS'),
          IntCellValue(3),
          IntCellValue(2024),
          IntCellValue(2027),
        ]);
        final bytes = workbook.encode();
        expect(bytes, isNotNull);
        final rows = readSheetRows(bytes!);
        expect(rows, hasLength(1));
        expect(rows.single.registerNumber, '26BSC001');
        expect(rows.single.batchEndYear, 2027);
        expect(rows.single.currentYear, 3);
      },
    );

    test(
      'readSheetRows is empty when headers are missing or bytes are corrupt',
      () {
        expect(readSheetRows([1, 2, 3]), isEmpty);
        final workbook = Excel.createExcel();
        workbook['Sheet1'].appendRow([
          TextCellValue('Name'),
          TextCellValue('Age'),
        ]);
        workbook['Sheet1'].appendRow([TextCellValue('Ada'), IntCellValue(36)]);
        expect(readSheetRows(workbook.encode()!), isEmpty);
      },
    );

    test('import ids are deterministic per file and differ between files', () {
      const a = [1, 2, 3];
      const b = [1, 2, 4];
      expect(importIdForBytes(a), importIdForBytes(a));
      expect(importIdForBytes(a), isNot(importIdForBytes(b)));
      expect(importIdForBytes(a).startsWith('imp_'), isTrue);
    });
  });

  group('Phase 4 — pass-out eligibility and lifecycle models', () {
    test('passOutDue requires active and a finished batch', () {
      final now = DateTime.now();
      Student s({bool active = true, int? end}) => Student(
        studentId: '26BSC001',
        name: 'Ada',
        department: 'B.Sc CS',
        active: active,
        batchEndYear: end,
      );
      expect(s(end: now.year - 1).passOutDue, isTrue);
      expect(s(end: now.year + 1).passOutDue, isFalse);
      expect(s(end: null).passOutDue, isFalse);
      expect(s(active: false, end: now.year - 1).passOutDue, isFalse);
    });

    test('missing active on a legacy doc defaults to active', () {
      final s = Student.fromFirestore('26BSC001', {
        'name': 'Ada',
        'department': 'B.Sc CS',
      });
      expect(s.active, isTrue);
      expect(s.passOutDue, isFalse);
      final archived = Student.fromFirestore('26BSC001', {
        'name': 'Ada',
        'department': 'B.Sc CS',
        'active': false,
        'batchEndYear': 2025,
      });
      expect(archived.active, isFalse);
      expect(archived.passOutDue, isFalse);
    });

    test('DeletionRecord parses evidence and flags permanent deletions', () {
      final record = DeletionRecord.fromFirestore('26BSC001', {
        'name': 'Ada',
        'deletedAt': DateTime(2026, 9, 1),
        'reason': 'pass_out',
        'restored': false,
        'permanentlyDeletedAt': DateTime(2026, 9, 10),
      });
      expect(record.studentId, '26BSC001');
      expect(record.reason, 'pass_out');
      expect(record.alreadyPermanent, isTrue);
      final restored = DeletionRecord.fromFirestore('26BSC002', {
        'restored': true,
      });
      expect(restored.alreadyPermanent, isFalse);
      expect(restored.deletedAt, isNull);
    });

    test('ImportBatchMeta + counts parse the server shape', () {
      final meta = ImportBatchMeta.fromFirestore('imp_abc', {
        'filename': 'roster.xlsx',
        'counts': {
          'rows': 12,
          'valid': 11,
          'invalid': 1,
          'warnings': 2,
          'committed': 11,
        },
        'department': 'B.Sc CS',
      });
      expect(meta.counts?.committed, 11);
      expect(meta.counts?.invalid, 1);
      expect(meta.department, 'B.Sc CS');
      expect(meta.filename, 'roster.xlsx');
    });

    test('AdminActionResult queued vs applied shapes', () {
      const queued = AdminActionResult.queued();
      expect(queued.isQueued, isTrue);
      expect(queued.affected, 0);
      const applied = AdminActionResult.applied(affected: 3, skipped: 1);
      expect(applied.isQueued, isFalse);
      expect(applied.affected, 3);
    });
  });

  group('Phase 4 — admin screens', () {
    final bsc = DepartmentInfo(id: 'BSC-CS', name: 'B.Sc CS');

    Widget studentScreen(_RecordingFirestore store) => MaterialApp(
      home: StudentManagementScreen(
        auth: _RoleAuth('admin'),
        firestore: store,
        userId: 'user-1',
      ),
    );

    testWidgets('the admin hub is denied to pt_sir and shown to admin', (
      tester,
    ) async {
      final store = _RecordingFirestore();
      await tester.pumpWidget(
        MaterialApp(
          home: AdminScreen(
            auth: _RoleAuth('pt_sir'),
            firestore: store,
            userId: 'user-1',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Admin access only.'), findsOneWidget);
      expect(find.text('Batch import'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();

      await tester.pumpWidget(
        MaterialApp(
          home: AdminScreen(
            auth: _RoleAuth('admin'),
            firestore: store,
            userId: 'user-1',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Admin access only.'), findsNothing);
      expect(find.text('Batch import'), findsOneWidget);
      expect(find.text('Pass-out review'), findsOneWidget);
      expect(find.text('Recently deleted'), findsOneWidget);
    });

    testWidgets('V2: every admin sub-screen self-guards against pt_sir', (
      tester,
    ) async {
      final store = _RecordingFirestore()..seededDepartments = [bsc];
      Future<void> expectDenied(Widget screen) async {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await tester.pumpWidget(MaterialApp(home: screen));
        await tester.pumpAndSettle();
        expect(find.text('Admin access only.'), findsOneWidget);
      }

      await expectDenied(StudentManagementScreen(
        auth: _RoleAuth('pt_sir'),
        firestore: store,
        userId: 'user-1',
      ));
      await expectDenied(BatchImportScreen(
        auth: _RoleAuth('pt_sir'),
        firestore: store,
        userId: 'user-1',
      ));
      await expectDenied(PassOutReviewScreen(
        auth: _RoleAuth('pt_sir'),
        firestore: store,
        userId: 'user-1',
      ));
      await expectDenied(RecentlyDeletedScreen(
        auth: _RoleAuth('pt_sir'),
        firestore: store,
        userId: 'user-1',
      ));
    });

    testWidgets(
      'student management lists, filters and archives via an admin intent',
      (tester) async {
        final store = _RecordingFirestore()
          ..seededDepartments = [bsc]
          ..seededStudents = [
            Student(
              studentId: '26BSC001',
              name: 'Ada Lovelace',
              department: 'B.Sc CS',
              year: '3rd Year',
              batchStartYear: 2024,
              batchEndYear: 2027,
            ),
            Student(
              studentId: '26BSC002',
              name: 'Alan Turing',
              department: 'B.Sc CS',
            ),
          ];
        await tester.pumpWidget(studentScreen(store));
        await tester.pumpAndSettle();
        expect(find.text('Ada Lovelace'), findsOneWidget);
        expect(find.text('Alan Turing'), findsOneWidget);

        await tester.enterText(find.byType(TextField), 'ada');
        await tester.pumpAndSettle();
        expect(find.text('Ada Lovelace'), findsOneWidget);
        expect(find.text('Alan Turing'), findsNothing);

        await tester.enterText(find.byType(TextField), '');
        await tester.pumpAndSettle();
        await tester.tap(find.text('Ada Lovelace'));
        await tester.pumpAndSettle();
        expect(find.text('Archive 1 selected'), findsOneWidget);

        await tester.tap(find.text('Archive 1 selected'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Archive'));
        await tester.pumpAndSettle();

        expect(store.lastAdminRequest?['type'], 'soft_delete');
        expect(store.lastAdminRequest?['studentIds'], ['26BSC001']);
        expect(store.lastAdminRequest?['reason'], 'manual');
        expect(store.lastAdminRequest?['requestedBy'], 'user-1');
      },
    );

    testWidgets(
      'year-of-study filter shows exactly that year (seed + import formats)',
      (tester) async {
        final store = _RecordingFirestore()
          ..seededDepartments = [bsc]
          ..seededStudents = [
            // Seed format ("1") — the shape all 136 roster students have.
            Student(studentId: '24BSC001', name: 'Year One A', department: 'B.Sc CS', year: '1'),
            Student(studentId: '24BSC002', name: 'Year One B', department: 'B.Sc CS', year: '1'),
            Student(studentId: '24BSC003', name: 'Year Two', department: 'B.Sc CS', year: '2'),
            // Batch-import format ("3rd Year") — must match Year 3 too.
            Student(studentId: '24BSC004', name: 'Year Three', department: 'B.Sc CS', year: '3rd Year'),
            // No year at all — never matches a selected year.
            Student(studentId: '24BSC005', name: 'No Year', department: 'B.Sc CS'),
          ];
        await tester.pumpWidget(studentScreen(store));
        await tester.pumpAndSettle();
        expect(find.text('Year of study'), findsOneWidget); // new dropdown
        expect(find.text('Batch start year'), findsNothing); // old bug surface
        expect(find.text('No Year'), findsOneWidget); // no filter yet

        // Department dropdown is [0]; "Year of study" is [1].
        final yearDropdown = find.byType(DropdownButtonFormField<String>).at(1);
        await tester.tap(yearDropdown);
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(DropdownMenuItem<String>, 'Year 1'));
        await tester.pumpAndSettle();
        expect(find.text('Year One A'), findsOneWidget);
        expect(find.text('Year One B'), findsOneWidget);
        expect(find.text('Year Two'), findsNothing);
        expect(find.text('Year Three'), findsNothing);
        expect(find.text('No Year'), findsNothing);

        await tester.tap(yearDropdown);
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(DropdownMenuItem<String>, 'Year 3'));
        await tester.pumpAndSettle();
        expect(find.text('Year Three'), findsOneWidget); // "3rd Year" matches
        expect(find.text('Year One A'), findsNothing);
        expect(find.text('Year One B'), findsNothing);
        expect(find.text('Year Two'), findsNothing);

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'pass-out review surfaces finished batches and archives as pass_out',
      (tester) async {
        final store = _RecordingFirestore()
          ..seededStudents = [
            Student(
              studentId: '26BSC001',
              name: 'Ada Lovelace',
              department: 'B.Sc CS',
              active: true,
              batchStartYear: 2022,
              batchEndYear: 2025,
            ),
            Student(
              studentId: '26BSC002',
              name: 'Alan Turing',
              department: 'B.Sc CS',
              batchStartYear: 2024,
              batchEndYear: 2027,
            ),
          ];
        await tester.pumpWidget(
          MaterialApp(
            home: PassOutReviewScreen(
              auth: _RoleAuth('admin'),
              firestore: store,
              userId: 'user-1',
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Ada Lovelace'), findsOneWidget);
        expect(find.text('Alan Turing'), findsNothing);

        await tester.tap(find.text('Ada Lovelace'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Archive 1 as passed out'));
        await tester.pumpAndSettle();
        expect(find.text('Archive 1 as passed out?'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, 'Archive'));
        await tester.pumpAndSettle();

        expect(store.lastAdminRequest?['type'], 'soft_delete');
        expect(store.lastAdminRequest?['reason'], 'pass_out');
        expect(store.lastAdminRequest?['studentIds'], ['26BSC001']);
      },
    );

    testWidgets(
      'recently deleted restores and runs the two-step permanent delete',
      (tester) async {
        final store = _RecordingFirestore()
          ..seededDeletionRecords = [
            DeletionRecord(
              studentId: '26BSC001',
              name: 'Ada Lovelace',
              registerNumber: '26BSC001',
              department: 'B.Sc CS',
              deletedAt: DateTime(2026, 9, 1),
              reason: 'pass_out',
              retentionUntil: DateTime(2027, 9, 1),
            ),
            DeletionRecord(
              studentId: '26BSC002',
              name: 'Alan Turing',
              registerNumber: '26BSC002',
              deletedAt: DateTime(2026, 8, 1),
              restored: true,
            ),
          ];
        await tester.pumpWidget(
          MaterialApp(
            home: RecentlyDeletedScreen(
              auth: _RoleAuth('admin'),
              firestore: store,
              userId: 'user-1',
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Awaiting review'), findsOneWidget);
        expect(find.text('Closed evidence'), findsOneWidget);
        expect(find.text('soft-deleted'), findsOneWidget);
        expect(find.text('restored'), findsOneWidget);

        await tester.tap(find.text('Ada Lovelace'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Restore 1'));
        await tester.pumpAndSettle();
        expect(store.lastAdminRequest?['type'], 'restore');
        expect(store.lastAdminRequest?['studentIds'], ['26BSC001']);

        // Let the restore confirmation snackbar auto-dismiss so the bottom action
        // bar is tappable again.
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Ada Lovelace'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete permanently'));
        await tester.pumpAndSettle();
        expect(find.text('Permanently delete these students?'), findsOneWidget);
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();
        expect(find.text('Final confirmation'), findsOneWidget);
        await tester.tap(
          find.widgetWithText(FilledButton, 'Permanently delete'),
        );
        await tester.pumpAndSettle();
        expect(store.lastAdminRequest?['type'], 'permanent_delete');
        expect(store.lastAdminRequest?['studentIds'], ['26BSC001']);
      },
    );

    testWidgets('the batch import screen lists past import batches', (
      tester,
    ) async {
      final store = _RecordingFirestore()
        ..seededImportBatches = [
          ImportBatchMeta(
            importId: 'imp_1',
            filename: 'roster-2026.xlsx',
            department: 'B.Sc CS',
            counts: const ImportCounts(
              rows: 10,
              valid: 9,
              invalid: 1,
              warnings: 2,
              committed: 9,
            ),
            createdBy: 'user-1',
          ),
        ];
      await tester.pumpWidget(
        MaterialApp(
          home: BatchImportScreen(
            auth: _RoleAuth('admin'),
            firestore: store,
            userId: 'user-1',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('roster-2026.xlsx'), findsOneWidget);
      expect(find.text('9 committed, 10 rows, B.Sc CS'), findsOneWidget);
    });
  });
}

Future<void> _pumpScanScreen(
  WidgetTester tester,
  _RecordingFirestore store,
) async {
  final scan = _onlineScanService(store);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: ScanScreen(
        auth: _FakeAuth(),
        firestore: store,
        scan: scan,
        userId: 'staff-1',
        scannerViewBuilder: (controller, onBarcode, onDetectError) => ColoredBox(
          key: const Key('test-camera-surface'),
          color: Colors.black,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  key: const Key('test-camera-code'),
                  onPressed: () => onBarcode('890123456008'),
                  child: const Text('Simulate scan'),
                ),
                TextButton(
                  key: const Key('test-camera-error'),
                  onPressed: () => onDetectError(FormatException('bad frame')),
                  child: const Text('Simulate decode failure'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

class _RecordingAuth implements AuthService {
  SignInOutcome? result;
  String? lastEmail;
  String? lastPassword;
  int signInCalls = 0;

  @override
  String? get currentUserId => null;

  @override
  String? get currentUserEmail => null;

  @override
  Future<String?> get currentUserRole async => null;

  @override
  Stream<String?> get userIdStream => const Stream.empty();

  @override
  Future<SignInOutcome> signIn({
    required String email,
    required String password,
  }) async {
    signInCalls++;
    lastEmail = email;
    lastPassword = password;
    return result ?? const SignInOutcome.success();
  }

  @override
  Future<void> signOut() async {}
}

Student _student(String id) =>
    Student(studentId: id, name: 'Ada Lovelace', department: 'B.SC CS');

/// Minimal AuthService for screens that hold the reference (dashboard pushes
/// reports/escalations, which we do not open in these tests).
class _FakeAuth implements AuthService {
  @override
  String? get currentUserId => 'user-1';

  @override
  String? get currentUserEmail => 'pt@sankara.ac.in';

  @override
  Future<String?> get currentUserRole async => 'pt_sir';

  @override
  Stream<String?> get userIdStream =>
      Stream<String?>.fromIterable(const ['user-1']);

  @override
  Future<void> signOut() async {}

  @override
  Future<SignInOutcome> signIn({
    required String email,
    required String password,
  }) async =>
      const SignInOutcome.success();
}

/// Role-parameterized AuthService for the Phase 4 admin-gated screens.
class _RoleAuth implements AuthService {
  _RoleAuth(this.role);

  final String? role;

  @override
  String? get currentUserId => 'user-1';

  @override
  String? get currentUserEmail => null;

  @override
  Future<String?> get currentUserRole async => role;

  @override
  Stream<String?> get userIdStream =>
      Stream<String?>.fromIterable(const ['user-1']);

  @override
  Future<void> signOut() async {}

  @override
  Future<SignInOutcome> signIn({
    required String email,
    required String password,
  }) async =>
      const SignInOutcome.success();
}

/// Sign-out counter for the account-menu test (NEW request 1).
class _LogoutAuth extends _FakeAuth {
  int signOutCalls = 0;

  @override
  Future<void> signOut() async {
    signOutCalls++;
  }
}

Student _studentWithPhoto(String id, String base64) => Student(
  studentId: id,
  name: 'Ada Lovelace',
  department: 'B.SC CS',
  photoBase64: base64,
);

/// Base64 for an [n]-byte payload (PhotoCache tests don't need valid images).
String _b64(int n) => base64Encode(Uint8List.fromList(List<int>.filled(n, 7)));

PendingScan _scan({String studentId = '26BSC008', String? docId}) {
  return PendingScan(
    studentId: studentId,
    studentName: 'Ada Lovelace',
    scannedBy: 'staff-1',
    scanMethod: 'barcode',
    deviceTimestamp: DateTime(2026, 9, 24, 9, 1, 30),
    docId: docId ?? '${studentId}_2026-09-24',
    queuedAt: DateTime(2026, 9, 24, 9, 1, 31),
  );
}

ScanService _offlineScanService(
  _RecordingFirestore store, {
  MemoryOfflineStore? offline,
}) {
  final o = offline ?? MemoryOfflineStore();
  return ScanService(
    firestore: store,
    offline: o,
    connectivity: ConnectivityService(
      check: () async => const [ConnectivityResult.none],
      changes: () => const Stream.empty(),
    ),
  );
}

ScanService _onlineScanService(
  _RecordingFirestore store, {
  MemoryOfflineStore? offline,
}) {
  final o = offline ?? MemoryOfflineStore();
  return ScanService(
    firestore: store,
    offline: o,
    connectivity: ConnectivityService(
      check: () async => const [ConnectivityResult.wifi],
      changes: () => const Stream.empty(),
    ),
  );
}

/// Records the enqueue calls and late records for the service tests.
/// Duck-typed stand-in for cloud_firestore's Timestamp (exposes toDate()).
class _TimestampLike {
  _TimestampLike(this._dt);
  final DateTime _dt;
  DateTime toDate() => _dt;
}

class _RecordingFirestore implements FirestoreService {
  Map<String, dynamic>? lastEnqueue;
  Map<String, dynamic>? lastReportRequest;
  Map<String, dynamic>? lastReportMail;
  Map<String, dynamic>? lastWeeklyMail;
  int recordCalls = 0;
  int findCalls = 0;
  bool alreadyRecorded = false;
  Object? recordError;
  Object? syncError;
  Object? findError;
  String? lastFindCode;
  String? lastScannedBy;
  String? lastScanMethod;
  Stream<List<LateLogEntry>>? todayLogsStream;
  Stream<bool>? alreadyTodayStream;
  List<DepartmentInfo> seededDepartments = const [];
  List<ReportRow> seededRows = const [];
  bool filterReportRows = false;
  int reportRowsCalls = 0;
  DepartmentInfo? lastReportDepartment;
  String? lastReportYear;
  List<MailLogEntry> seededMailLogs = const [];
  List<DeletionRecord> seededDeletionRecords = const [];
  List<ImportBatchMeta> seededImportBatches = const [];
  List<Student> seededStudents = const [];
  Student? seededFind;
  /// Code-aware lookup override (wins over [seededFind]) — lets one flow see a
  /// camera miss and a manual-entry hit with the same fake.
  Student? Function(String code)? findHandler;
  Map<String, dynamic>? lastAdminRequest;
  final _synced = <PendingScan>[];
  List<PendingScan> get synced => List.unmodifiable(_synced);

  @override
  Stream<bool> alreadyRecordedToday(String studentId) =>
      alreadyTodayStream ?? const Stream.empty();

  @override
  Stream<List<LateLogEntry>> todayLateLogs() =>
      todayLogsStream ?? const Stream.empty();

  @override
  Future<void> enqueueMailRequest({
    required String departmentId,
    required String department,
    required String period,
    required List<String> studentIds,
    required String requestedBy,
  }) async {
    lastEnqueue = {
      'departmentId': departmentId,
      'department': department,
      'period': period,
      'studentIds': studentIds,
      'requestedBy': requestedBy,
    };
  }

  @override
  Future<void> enqueueReportRequest({
    required ReportFilters filters,
    required String requestedBy,
  }) async {
    lastReportRequest = {
      'periodType': filters.periodType.name,
      'startDate': dayKey(filters.startDate),
      'endDate': dayKey(filters.endDate),
      'department': filters.department?.id,
      'year': filters.year,
      'requestedBy': requestedBy,
    };
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
    lastReportMail = {
      'type': 'report',
      'departmentId': departmentId,
      'department': department,
      'periodType': periodType,
      'startDate': startDate,
      'endDate': endDate,
      'attachmentMode': attachmentMode,
      'year': year,
      'requestedBy': requestedBy,
    };
  }

  @override
  Future<void> enqueueWeeklyAuditMail({
    required String departmentId,
    required String department,
    required String startDate,
    required String requestedBy,
  }) async {
    lastWeeklyMail = {
      'type': 'weekly_audit',
      'departmentId': departmentId,
      'department': department,
      'startDate': startDate,
      'requestedBy': requestedBy,
    };
  }

  @override
  Future<List<MailLogEntry>> recentMailLogs({int limit = 40}) async =>
      seededMailLogs;

  @override
  Future<List<DepartmentInfo>> departments() async => seededDepartments;

  @override
  Future<List<EscalationGroup>> escalatedGroups(String period) async => [];

  @override
  Stream<EscalationVerdict?> escalationVerdict(String studentId) =>
      const Stream.empty();

  @override
  Future<ScanSettings> fetchSettings() async => const ScanSettings();

  @override
  Future<Student?> findStudentByCode(String code) async {
    findCalls++;
    final error = findError;
    if (error != null) throw error;
    lastFindCode = code;
    final handler = findHandler;
    if (handler != null) return handler(code);
    return seededFind;
  }

  @override
  Stream<int> lateCountInPeriod(String studentId) => const Stream.empty();

  @override
  Future<RecordResult> recordLate({
    required String studentId,
    required String scannedBy,
    required String scanMethod,
  }) async {
    final error = recordError;
    if (error != null) throw error;
    recordCalls++;
    lastScannedBy = scannedBy;
    lastScanMethod = scanMethod;
    return const RecordResult.recorded();
  }

  @override
  Future<List<ReportRow>> reportRows({
    required DateTime start,
    required DateTime end,
    DepartmentInfo? department,
    String? year,
  }) async {
    reportRowsCalls++;
    lastReportDepartment = department;
    lastReportYear = year;
    if (!filterReportRows) return seededRows;
    var out = seededRows;
    if (department != null) {
      out = out.where((r) => r.department == department.name).toList();
    }
    if (year != null) {
      final tier = yearTier(year);
      out = out.where((r) => yearTier(r.year ?? '') == tier).toList();
    }
    return out;
  }

  @override
  Future<List<String>> reportYears() async => seededRows
      .map((r) => r.year ?? '')
      .where((y) => y.isNotEmpty)
      .toSet()
      .toList();

  @override
  Future<List<Student>> allStudents() async => seededStudents;

  @override
  Future<RecordResult> syncOfflineScan({required PendingScan scan}) async {
    final error = syncError;
    if (error != null) throw error;
    _synced.add(scan);
    return alreadyRecorded
        ? const RecordResult.alreadyRecorded()
        : const RecordResult.recorded();
  }

  @override
  Future<List<DeletionRecord>> deletionRecords({int limit = 200}) async =>
      seededDeletionRecords;

  @override
  Future<List<ImportBatchMeta>> importBatches({int limit = 50}) async =>
      seededImportBatches;

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
    lastAdminRequest = {
      'type': type,
      'importId': importId,
      'filename': filename,
      'departmentId': departmentId,
      'department': department,
      'rows': rows?.map((r) => r.registerNumber).toList(),
      'studentIds': studentIds,
      'reason': reason,
      'requestedBy': requestedBy,
    };
  }
}

const _badgeSettings = ScanSettings();
