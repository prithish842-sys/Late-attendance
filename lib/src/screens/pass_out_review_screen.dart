import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/app_models.dart';
import '../services/admin_service.dart';
import '../services/auth_service.dart';
import '../services/firestore_service.dart';
import '../theme/app_theme.dart';
import '../widgets/admin_gate.dart';

/// Phase 4 — Pass-out Review (NEW_ADMIN_WORKFLOW.md): a computed, read-only
/// list of still-active students whose batch has finished
/// (`active && batchEndYear <= current year`). This is a review surface only —
/// nothing is auto-deleted. The admin picks students (or "All in this batch")
/// and archives them with the `pass_out` reason, which is recorded and audited
/// like any other soft delete.
class PassOutReviewScreen extends StatefulWidget {
  PassOutReviewScreen({
    super.key,
    required this.auth,
    required this.firestore,
    required this.userId,
    AdminService? admin,
  }) : admin = admin ?? AdminService.from(firestore);

  final AuthService auth;
  final FirestoreService firestore;
  final String userId;
  final AdminService admin;

  @override
  State<PassOutReviewScreen> createState() => _PassOutReviewScreenState();
}

class _PassOutReviewScreenState extends State<PassOutReviewScreen>
    with AdminGateMixin {
  @override
  AuthService get auth => widget.auth;

  late Future<List<Student>> _studentsFuture;
  final Set<String> _selected = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _studentsFuture = widget.firestore.allStudents();
  }

void _reload() {
    setState(() {
      _studentsFuture = widget.firestore.allStudents();
    });
  }

  Future<bool> _confirmArchive() async {
    if (_selected.isEmpty || _busy) return false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          'Archive ${_selected.length} as passed out?',
          style: GoogleFonts.inter(
            color: AppColors.ink900,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          'These students are in finished batches. Archiving makes them '
          'inactive and stops new scans. Nothing is deleted — records can be '
          'restored later from Recently Deleted.',
          style: GoogleFonts.inter(
            color: AppColors.ink900.withValues(alpha: 0.7),
            fontSize: 14,
            height: 1.45,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep for now'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: AppColors.statusEscalate),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Archive'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _onArchivePressed() async {
    if (_selected.isEmpty || _busy) return;
    final ok = await _confirmArchive();
    if (!ok) return;
    await _archiveSelected();
  }

  Future<void> _archiveSelected() async {
    if (_selected.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final result = await widget.admin.softDelete(
        studentIds: _selected.toList(),
        reason: 'pass_out',
        requestedBy: widget.userId,
      );
      if (!mounted) return;
      final n = _selected.length;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          result.isQueued
              ? '$n archived for pass-out will be applied by the office service shortly.'
              : 'Archived ${result.affected} (${result.skipped} skipped) as passed out.',
          style: GoogleFonts.inter(fontSize: 14),
        ),
      ));
      _reload();
    } on Exception {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('The archive couldn\u2019t be requested — check the network and try again.',
            style: TextStyle(fontSize: 14)),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!roleChecked) return const AdminGateLoading();
    if (!adminAllowed) return const AdminDeniedView();
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          'Pass-out review',
          style: GoogleFonts.inter(
            color: AppColors.navy900,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
            color: AppColors.navy900,
          ),
        ],
      ),
      body: FutureBuilder<List<Student>>(
        future: _studentsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final due = (snapshot.data ?? const <Student>[])
              .where((s) => s.passOutDue)
              .toList()
            ..sort((a, b) => a.studentId.compareTo(b.studentId));
          return Column(
            children: [
              if (due.isEmpty)
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        'No finished batches to review. Students appear here once '
                        'their batch end year has passed.',
                        style: GoogleFonts.inter(
                          color: AppColors.ink900.withValues(alpha: 0.6),
                          fontSize: 14,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                  child: Text(
                    '${due.length} active ${due.length == 1 ? 'student' : 'students'} in '
                    'finished batches — review-only, nothing is deleted automatically.',
                    style: GoogleFonts.inter(
                      color: AppColors.ink900.withValues(alpha: 0.6),
                      fontSize: 13,
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                    itemCount: due.length,
                    separatorBuilder: (_, _) =>
                        const Divider(height: 1, color: AppColors.sand200),
                    itemBuilder: (context, index) => _row(due[index]),
                  ),
                ),
                if (_selected.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      border: Border(top: BorderSide(color: AppColors.sand200)),
                    ),
                    child: SafeArea(
                      top: false,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Passing out marks these records inactive and stops '
                            'new scans — they can be restored from Recently Deleted.',
                            style: GoogleFonts.inter(
                              color: AppColors.ink900.withValues(alpha: 0.55),
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.statusEscalate,
                              side: const BorderSide(
                                  color: AppColors.statusEscalate),
                              minimumSize: const Size.fromHeight(40),
                            ),
                            onPressed: _busy ? null : _onArchivePressed,
                            icon: const Icon(Icons.archive_outlined, size: 18),
                            label: Text('Archive ${_selected.length} as passed out'),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _row(Student s) {
    final checked = _selected.contains(s.studentId);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => setState(() {
          checked ? _selected.remove(s.studentId) : _selected.add(s.studentId);
        }),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              Checkbox(
                value: checked,
                onChanged: (v) => setState(() {
                  v == true
                      ? _selected.add(s.studentId)
                      : _selected.remove(s.studentId);
                }),
                activeColor: AppColors.maroon900,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.name,
                      style: GoogleFonts.inter(
                        color: AppColors.ink900,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      chunkRegNumber(s.studentId),
                      style: GoogleFonts.inter(
                        color: AppColors.ink900.withValues(alpha: 0.6),
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      '${s.department.isEmpty ? '-' : s.department}'
                      ' — batch ${s.batchStartYear}–${s.batchEndYear}',
                      style: GoogleFonts.inter(
                        color: AppColors.ink900.withValues(alpha: 0.6),
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}