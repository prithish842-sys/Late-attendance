import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/app_models.dart';
import '../services/connectivity_service.dart';
import '../services/escalation_service.dart';
import '../services/firestore_service.dart';
import '../services/offline_store.dart';
import '../services/perf_log.dart';
import '../services/scan_service.dart';
import '../services/sync_service.dart';
import '../theme/app_theme.dart';
import '../widgets/status_badge.dart';

/// After a successful scan: a full-bleed confirmation card with the student's
/// name, register number, department and year (the photo was removed at the
/// user's request) and the color-coded current-month late status, plus
/// `Confirm` (commit) and `Scan Next Student` (return to the scanner without
/// recording) — NEW_DESIGN.md §Verification.
/// The identity fields are grouped as one visual block, the late status as a
/// separate block below it (Miller's Law). No nested modals. Phase 5: when
/// offline the confirm QUEUES the scan and shows a navy "saved" state instead
/// of the green "recorded" one.
class VerifyScreen extends StatefulWidget {
  VerifyScreen({
    super.key,
    required this.firestore,
    required this.userId,
    required this.student,
    required this.scanMethod,
    ScanService? scan,
    this.sync,
    EscalationService? escalation,
  }) : scan =
           scan ??
           ScanService(
             firestore: firestore,
             offline: MemoryOfflineStore(),
             connectivity: ConnectivityService(),
           ),
       escalation = escalation ?? EscalationService.from(firestore);

  final FirestoreService firestore;
  final ScanService scan;
  final SyncService? sync;
  final String userId;
  final Student student;
  final String scanMethod;
  final EscalationService escalation;

  @override
  State<VerifyScreen> createState() => _VerifyScreenState();
}

class _VerifyScreenState extends State<VerifyScreen> {
  late Future<ScanSettings> _settingsFuture;
  int _count = 0;
  bool _alreadyToday = false;
  bool _recording = false;
  bool _queued = false;
  String? _confirmError;
  bool _recorded = false;
  EscalationVerdict? _verdict;
  StreamSubscription<int>? _countSub;
  StreamSubscription<bool>? _todaySub;
  StreamSubscription<EscalationVerdict?>? _verdictSub;

  @override
  void initState() {
    super.initState();
    // QA: closes the scan -> details span opened by ScanScreen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      PerfLog.stop('scan->verify-details');
      PerfLog.stop('manual-id->verify-details');
    });
    _settingsFuture = widget.scan.fetchSettings();
    // Seed from the offline cache so the badge still shows a count offline.
    _count = widget.scan.cachedPeriodCount(widget.student.studentId) ?? 0;
    // QA fix: keep the handles — without dispose() these listeners leaked
    // (one per verify screen visit, alive forever on a live Firestore stream).
    _countSub = widget.firestore.lateCountInPeriod(
      widget.student.studentId,
    ).listen((n) {
      if (mounted) setState(() => _count = n);
    });
    _todaySub = widget.firestore.alreadyRecordedToday(
      widget.student.studentId,
    ).listen((yes) {
      if (mounted) setState(() => _alreadyToday = yes);
    });
    _verdictSub = widget.escalation.verdictFor(
      widget.student.studentId,
    ).listen((v) {
      if (mounted) setState(() => _verdict = v);
    });
  }

  @override
  void dispose() {
    _countSub?.cancel();
    _todaySub?.cancel();
    _verdictSub?.cancel();
    super.dispose();
  }

  Future<void> _confirm() async {
    if (_recording || _recorded || _alreadyToday || _queued) return;
    setState(() {
      _recording = true;
      _confirmError = null;
    });
    // QA: span closed by the dashboard's today-list listener.
    PerfLog.startPending('submit->dashboard-update');
    try {
      final result = await widget.scan.recordLate(
        studentId: widget.student.studentId,
        studentName: widget.student.name,
        scannedBy: widget.userId,
        scanMethod: widget.scanMethod,
      );
      if (!mounted) return;
      if (result.outcome != RecordOutcome.recorded) {
        // No write reached the server, so the dashboard stream will never emit
        // for this span — close it here instead.
        PerfLog.stopPending();
      }
      setState(() {
        _recording = false;
        if (result.outcome == RecordOutcome.recorded) {
          _recorded = true;
        } else if (result.outcome == RecordOutcome.queued) {
          // Offline: the scan is safe in the local queue and will sync on
          // reconnect (SECURITY.md §3 — idempotent by deterministic doc id).
          _queued = true;
        } else {
          _alreadyToday = true;
          _confirmError = 'Already recorded as late today.';
        }
      });
    } on ScanRateLimitException {
      // Client submit cap (B5) — the ONLY caller-facing place this surfaces;
      // reset the button so the operator can simply wait and retry.
      if (!mounted) return;
      PerfLog.stopPending();
      setState(() {
        _recording = false;
        _confirmError =
            'Too many scans in the last minute — pause a moment, then try again.';
      });
    } on Object {
      // A non-offline Firestore failure rethrows out of ScanService (QA:
      // DNS dead -> `cloud_firestore/unknown`). It used to escape this async
      // gap unhandled, leaving the button on "Recording..." forever with no
      // message and no way to retry — reset and let the user try again.
      if (!mounted) return;
      PerfLog.stopPending();
      setState(() {
        _recording = false;
        _confirmError =
            'Could not save this scan. Check the connection and try again.';
      });
    }
  }

  void _scanNext() => Navigator.of(context).pop();

  void _backToDashboard() =>
      Navigator.of(context).popUntil((route) => route.isFirst);

  @override
  Widget build(BuildContext context) {
    final s = widget.student;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          'Verify student',
          style: GoogleFonts.inter(
            color: AppColors.navy900,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: FutureBuilder<ScanSettings>(
        future: _settingsFuture,
        builder: (context, snapshot) {
          final settings = snapshot.data ?? const ScanSettings();
          return ListView(
            padding: EdgeInsets.zero,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Identity block (Miller's Law — one group, not loose fields).
                    Text(
                      s.name,
                      style: GoogleFonts.fraunces(
                        fontSize: 28,
                        fontWeight: FontWeight.w600,
                        color: AppColors.navy900,
                        height: 1.15,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _identityBlock(s),
                    const SizedBox(height: 24),
                    // Status block — separate from the identity fields.
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _buildBadge(settings),
                    ),
                    if (_confirmError != null) ...[
                      const SizedBox(height: 14),
                      Text(
                        _confirmError!,
                        style: GoogleFonts.inter(
                          color: AppColors.statusEscalate,
                          fontSize: 14,
                        ),
                      ),
                    ],
                    const SizedBox(height: 30),
                    _buildActions(),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _identityBlock(Student s) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: AppColors.sand200),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          _row('Register No', chunkRegNumber(s.studentId), useTabular: true),
          _row('Department', s.department),
          if (s.year != null && s.year!.isNotEmpty) _row('Year', s.year!),
        ],
      ),
    );
  }

  /// Actions: before committing there are exactly two — `Confirm` (the only
  /// primary, full-width per Fitts's Law) and `Scan Next Student`. After a
  /// commit the end state confirms success (Peak-End Rule) and offers to keep
  /// scanning or head back to the dashboard.
  Widget _buildActions() {
    final committed = _recorded || _queued;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton(
          onPressed: committed
              ? _scanNext
              : (_recording || _alreadyToday)
              ? null
              : _confirm,
          child: committed ? const Text('Scan Next Student') : _submitLabel(),
        ),
        const SizedBox(height: 12),
        Center(
          child: TextButton(
            onPressed: committed ? _backToDashboard : _scanNext,
            child: Text(committed ? 'Back to Dashboard' : 'Scan Next Student'),
          ),
        ),
      ],
    );
  }

  Widget _submitLabel() {
    if (_recording) {
      return const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              color: Colors.white,
            ),
          ),
          SizedBox(width: 12),
          Text('Recording\u2026'),
        ],
      );
    }
    if (_alreadyToday) return const Text('Recorded today');
    return const Text('Confirm');
  }

  Widget _buildBadge(ScanSettings settings) {
    if (_queued) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.navy900,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          'Saved \u2014 will sync when back online',
          style: GoogleFonts.inter(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }
    if (_recorded) {
      // Prefer the count the ScanService just warmed (this scan → n+1); if the
      // server stream has already caught up use its higher value. Avoids a
      // brief "0th time" flash between recording and the stream re-emitting.
      final warmed = widget.scan.cachedPeriodCount(widget.student.studentId);
      final shown = warmed != null && warmed > _count ? warmed : _count;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.statusOk,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          'Recorded \u2014 ${ordinal(shown)} time this month',
          style: GoogleFonts.inter(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }
    // Prefer the server verdict when it exists (SECURITY.md §1 — the server
    // counts, the app only displays). Fall back to the prospective count only
    // until the Cloud Function / fallback runner has published a verdict.
    if (_verdict != null) {
      return StatusBadge.fromVerdict(_verdict!, settings: settings);
    }
    // Prospective count = current count + 1 (unless today already counted).
    final prospective = _alreadyToday ? _count : _count + 1;
    return StatusBadge(count: prospective, settings: settings);
  }

  Widget _row(String label, String value, {bool useTabular = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: GoogleFonts.inter(
                color: AppColors.ink900.withValues(alpha: 0.6),
                fontSize: 14,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: useTabular
                  ? tabular(
                      GoogleFonts.inter(fontSize: 16, color: AppColors.ink900),
                    )
                  : GoogleFonts.inter(fontSize: 16, color: AppColors.ink900),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}
