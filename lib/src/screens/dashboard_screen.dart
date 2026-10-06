import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/app_models.dart';
import '../services/auth_service.dart';
import '../services/firestore_service.dart';
import '../services/perf_log.dart';
import '../services/scan_service.dart';
import '../services/sync_service.dart';
import '../theme/app_theme.dart';
import '../widgets/offline_strip.dart';
import '../widgets/sankara_crest.dart';
import 'admin_screen.dart';
import 'escalation_screen.dart';
import 'reports_screen.dart';
import 'scan_screen.dart';
import 'weekly_audit_screen.dart';

const _weekdayNames = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday',
];
const _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July',
  'August', 'September', 'October', 'November', 'December',
];

/// PT Sir's home after sign-in (NEW_DESIGN.md §Dashboard, NEW_TASKS.md Phase 1).
///
/// One primary action — the full-width [Scan Student] card — is pinned in the
/// thumb zone (Fitts's Law); today's live date/time, count and today-list are
/// secondary and quieter (Hick's Law). The today list is a live LOCAL-day
/// query over late_logs, so the next local calendar day naturally resets the
/// view back to zero without deleting any history (NEW_DECISIONS.md §4);
/// queued offline scans dated today are merged in locally so the count stays
/// truthful until SyncService uploads them.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    required this.auth,
    required this.firestore,
    required this.scan,
    required this.userId,
    this.sync,
  });

  final AuthService auth;
  final FirestoreService firestore;
  final ScanService scan;
  final SyncService? sync;
  final String userId;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late final ScanService _scan;

  List<LateLogEntry> _server = const [];
  bool _isAdmin = false;
  String? _role;
  String? _email;
  bool _signingOut = false;

  StreamSubscription<List<LateLogEntry>>? _todaySub;
  StreamSubscription<bool>? _onlineSub;
  StreamSubscription<SyncResult>? _syncSub;
  Timer? _midnight;

  @override
  void initState() {
    super.initState();
    _scan = widget.scan;
    _resubscribeToday();
    _scheduleMidnightRollover();
    // QA fix: no 1 Hz whole-screen timer any more — the clock ticks inside
    // _ClockLine, which rebuilds only itself.
    // Re-merge pending offline scans whenever connectivity or the sync loop
    // changes the queue shape (drain on reconnect, transient failures, etc.).
    _onlineSub = _scan.onlineStream.listen((_) {
      if (mounted) setState(() {});
    });
    _syncSub = widget.sync?.onSync.listen((_) {
      if (mounted) setState(() {});
    });
    _loadAccount();
  }

  Future<void> _loadAccount() async {
    // Role comes ONLY from the signed-in Firebase Auth account's custom
    // claims — never a value hardcoded in the app (NEW_SECURITY.md §4).
    final role = await widget.auth.currentUserRole;
    if (!mounted) return;
    setState(() {
      _role = role;
      _isAdmin = role == 'admin';
      _email = widget.auth.currentUserEmail;
    });
  }

  /// Signs out of Firebase Auth. AuthGate's auth-state stream flips to null
  /// on its own, so the navigator shows the login screen — no manual routing.
  Future<void> _signOut() async {
    if (_signingOut) return;
    setState(() => _signingOut = true);
    try {
      await widget.auth.signOut();
    } on Object {
      if (!mounted) return;
      setState(() => _signingOut = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Couldn\u2019t sign out — check the connection and try again.',
            style: TextStyle(fontSize: 14),
          ),
        ),
      );
    }
  }

  String get _roleLabel {
    final r = _role;
    if (r == null) return 'Signed in';
    return switch (r) {
      'pt_sir' => 'PT Sir',
      'admin' => 'Admin',
      'hod' => 'HOD',
      _ => r,
    };
  }

  @override
  void dispose() {
    _todaySub?.cancel();
    _onlineSub?.cancel();
    _syncSub?.cancel();
    _midnight?.cancel();
    // QA: surface the session's Firestore call table when the shell closes.
    PerfLog.dumpDb('dashboard');
    super.dispose();
  }

  /// (Re)subscribe to the today list. A new subscription recomputes the local
  /// calendar-day window, which is the whole "daily reset" — a view reset.
  void _resubscribeToday() {
    _todaySub?.cancel();
    _todaySub = widget.firestore.todayLateLogs().listen((entries) {
      // QA: first emission after a submit closes the submit -> dashboard span.
      PerfLog.stopPending();
      if (!mounted) return;
      setState(() => _server = entries);
    });
  }

  /// At the next local midnight the dashboard moves to the new day's window:
  /// the view resets to zero while historical logs stay untouched.
  void _scheduleMidnightRollover() {
    _midnight?.cancel();
    final now = DateTime.now();
    final next = DateTime(now.year, now.month, now.day + 1);
    _midnight = Timer(next.difference(now) + const Duration(seconds: 1), () {
      if (!mounted) return;
      _resubscribeToday();
      _scheduleMidnightRollover();
    });
  }

  /// Server logs + queued scans dated today, newest first. Pending rows are
  /// tagged (["saved offline"]) so they are not mistaken for uploaded records.
  List<LateLogEntry> _merged() {
    final today = dayKey(DateTime.now());
    final merged = List<LateLogEntry>.of(_server);
    for (final pending in _scan.pendingScans()) {
      if (dayInLateDocId(pending.docId) == today) {
        merged.add(LateLogEntry.fromPending(pending));
      }
    }
    merged.sort((a, b) => b.localTime.compareTo(a.localTime));
    return merged;
  }

  Future<void> _openScanner() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ScanScreen(
          auth: widget.auth,
          firestore: widget.firestore,
          scan: widget.scan,
          sync: widget.sync,
          userId: widget.userId,
        ),
      ),
    );
    // Back from the scan flow — the server stream updates the list by itself,
    // but re-merge in case scans were queued while offline.
    if (mounted) setState(() {});
  }

  Future<void> _openEscalations() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EscalationScreen(
          auth: widget.auth,
          firestore: widget.firestore,
          userId: widget.userId,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openReports() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReportsScreen(
          auth: widget.auth,
          firestore: widget.firestore,
          userId: widget.userId,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openWeeklyAudit() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WeeklyAuditScreen(
          auth: widget.auth,
          firestore: widget.firestore,
          userId: widget.userId,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openAdmin() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AdminScreen(
          auth: widget.auth,
          firestore: widget.firestore,
          userId: widget.userId,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final merged = _merged();
    final pendingToday = merged.where((e) => e.pending).length;
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(),
            OfflineStrip(scan: _scan, sync: widget.sync),
            _buildDateTime(DateTime.now()),
            _buildTodaySummary(merged.length, pendingToday),
            _buildWeeklySuggestion(DateTime.now()),
            Expanded(
              child: _buildTodayList(merged),
            ),
            // Scan is a PT-gate-office action only — hidden for admins
            // (decision: admin side has no scan option anywhere).
            if (!_isAdmin) _buildScanCta(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 4),
      child: Row(
        children: [
          const SankaraCrest(size: 38),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Late Attendance',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                color: AppColors.navy900,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Attendance reports',
            onPressed: _openReports,
            icon: const Icon(Icons.insert_chart_outlined),
            color: AppColors.navy900,
          ),
          IconButton(
            tooltip: 'Escalations & HOD mail',
            onPressed: _openEscalations,
            icon: const Icon(Icons.mark_email_read_outlined),
            color: AppColors.navy900,
          ),
          IconButton(
            tooltip: 'Weekly audit',
            onPressed: _openWeeklyAudit,
            icon: const Icon(Icons.fact_check_outlined),
            color: AppColors.navy900,
          ),
          if (_isAdmin)
            IconButton(
              tooltip: 'Admin',
              onPressed: _openAdmin,
              icon: const Icon(Icons.admin_panel_settings_outlined),
              color: AppColors.maroon900,
            ),
          PopupMenuButton<String>(
            tooltip: 'Account & sign out',
            onSelected: (value) {
              if (value == 'sign-out') _signOut();
            },
            icon: const Icon(Icons.account_circle_outlined, color: AppColors.navy900),
            color: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: const BorderSide(color: AppColors.sand200),
            ),
            itemBuilder: (_) => [
              PopupMenuItem<String>(
                enabled: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _email ?? 'Signed in',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.ink900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _roleLabel,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: AppColors.ink900.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem<String>(
                value: 'sign-out',
                child: Row(
                  children: [
                    const Icon(Icons.logout, size: 18, color: AppColors.maroon700),
                    const SizedBox(width: 10),
                    Text(
                      _signingOut ? 'Signing out\u2026' : 'Sign out',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.maroon700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDateTime(DateTime now) {
    // QA fix: the ticking part lives in its own state widget. The dashboard
    // used to setState() the WHOLE screen (header, strip, list, photos) every
    // second just to advance the clock.
    return _ClockLine(now: now);
  }

  Widget _buildTodaySummary(int count, int pendingToday) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: AppColors.sand200),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            '$count',
            style: tabular(GoogleFonts.inter(
              fontSize: 42,
              fontWeight: FontWeight.w700,
              color: AppColors.maroon900,
              height: 1,
            )),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  count == 1 ? 'student marked late today' : 'students marked late today',
                  style: GoogleFonts.inter(
                    color: AppColors.ink900,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (pendingToday > 0)
                  Text(
                    pendingToday == 1
                        ? '1 saved offline and waiting to upload'
                        : '$pendingToday saved offline and waiting to upload',
                    style: GoogleFonts.inter(
                      color: AppColors.navy900,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTodayList(List<LateLogEntry> entries) {
    if (entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.event_available_outlined,
                size: 42,
                color: AppColors.navy900.withValues(alpha: 0.35),
              ),
              const SizedBox(height: 12),
              Text(
                'No students marked late yet today.',
                style: GoogleFonts.inter(
                  color: AppColors.ink900.withValues(alpha: 0.7),
                  fontSize: 15,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              if (!_isAdmin)
                Text(
                  'Scan a student to add them here.',
                  style: GoogleFonts.inter(
                    color: AppColors.ink900.withValues(alpha: 0.5),
                    fontSize: 13,
                  ),
                  textAlign: TextAlign.center,
                ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      itemCount: entries.length,
      separatorBuilder: (_, _) => const Divider(height: 1, color: AppColors.sand200),
      itemBuilder: (context, index) => _TodayRow(entry: entries[index]),
    );
  }

  /// Friday–Sunday nudge toward the weekly audit review before the HOD mail-run
  /// (NEW_AUDIT_WORKFLOW.md): quiet, tinted, one-line — day-gated, never noise.
  Widget _buildWeeklySuggestion(DateTime now) {
    final auditDay = now.weekday >= DateTime.friday;
    if (!auditDay) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Material(
        color: AppColors.sand200,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _openWeeklyAudit,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.fact_check_outlined, size: 18, color: AppColors.maroon700),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Weekly audit \u2014 review each department before the HOD mail-run.',
                    style: GoogleFonts.inter(
                      color: AppColors.navy900,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Icon(Icons.chevron_right, size: 18, color: AppColors.maroon700),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The single prominent action (Hick's Law) and the largest tappable element
  /// on the screen, fixed in the thumb zone (Fitts's Law). Maroon is the one
  /// 10% accent — nothing else on the dashboard competes with it.
  Widget _buildScanCta() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 16),
      child: Material(
        color: AppColors.maroon900,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _openScanner,
          child: Container(
            constraints: const BoxConstraints(minHeight: 122),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.qr_code_scanner,
                  size: 54,
                  color: Colors.white,
                ),
                const SizedBox(width: 18),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Scan Student',
                      style: GoogleFonts.inter(
                        color: Colors.white,
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Barcode \u00b7 QR \u00b7 or enter register number',
                      style: GoogleFonts.inter(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TodayRow extends StatelessWidget {
  const _TodayRow({required this.entry});

  final LateLogEntry entry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        entry.name,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                          color: AppColors.ink900,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (entry.pending) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.navy900,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'saved offline',
                          style: GoogleFonts.inter(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  chunkRegNumber(entry.studentId),
                  style: tabular(GoogleFonts.inter(
                    color: AppColors.ink900.withValues(alpha: 0.6),
                    fontSize: 13,
                  )),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                entry.localTime,
                style: tabular(GoogleFonts.inter(
                  color: AppColors.ink900,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                )),
              ),
              if (entry.department.isNotEmpty)
                Text(
                  entry.department,
                  style: GoogleFonts.inter(
                    color: AppColors.ink900.withValues(alpha: 0.6),
                    fontSize: 12,
                  ),
                ),
              if (entry.year != null && entry.year!.isNotEmpty)
                Text(
                  'Year ${entry.year}',
                  style: GoogleFonts.inter(
                    color: AppColors.ink900.withValues(alpha: 0.6),
                    fontSize: 12,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
/// QA fix: the dashboard clock is its own leaf widget with its own 1 s timer.
/// The previous design called `setState` on the whole dashboard every second
/// (rebuilding the header, status strip, summary, suggestion and the full
/// photo list) just to advance the seconds readout.
class _ClockLine extends StatefulWidget {
  const _ClockLine({required this.now});

  final DateTime now;

  @override
  State<_ClockLine> createState() => _ClockLineState();
}

class _ClockLineState extends State<_ClockLine> {
  late DateTime _now = widget.now;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = _now;
    final dateLine = '${_weekdayNames[now.weekday - 1]}, ${now.day} '
        '${_monthNames[now.month - 1]} ${now.year}';
    final clock =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  dateLine,
                  style: GoogleFonts.inter(
                    color: AppColors.navy900,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Live attendance log for today',
                  style: GoogleFonts.inter(
                    color: AppColors.ink900.withValues(alpha: 0.6),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          Text(
            clock,
            style: tabular(GoogleFonts.inter(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              color: AppColors.ink900,
              height: 1,
            )),
          ),
        ],
      ),
    );
  }
}
