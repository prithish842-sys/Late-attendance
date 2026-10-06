import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/app_models.dart';
import '../services/admin_service.dart';
import '../services/auth_service.dart';
import '../services/firestore_service.dart';
import '../theme/app_theme.dart';
import '../widgets/admin_gate.dart';

/// Phase 4 — Recently Deleted (NEW_DECISIONS.md #12,#13): two-stage deletion
/// evidence rows from `deletion_records`. A soft-deleted student can be
/// restored (undoes the soft delete instantly). Permanent deletion is a strict
/// two-step confirm and, once done, the student doc is gone — but this
/// evidence row is retained for the retention period, so the action remains
/// auditable. Writes are server-authoritative via AdminService.
class RecentlyDeletedScreen extends StatefulWidget {
  RecentlyDeletedScreen({
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
  State<RecentlyDeletedScreen> createState() => _RecentlyDeletedScreenState();
}

class _RecentlyDeletedScreenState extends State<RecentlyDeletedScreen>
    with AdminGateMixin {
  @override
  AuthService get auth => widget.auth;

  late Future<List<DeletionRecord>> _recordsFuture;
  final Set<String> _selected = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _recordsFuture = widget.firestore.deletionRecords();
  }

  void _reload() {
    setState(() {
      _selected.clear();
      _recordsFuture = widget.firestore.deletionRecords();
    });
  }

  Future<void> _restoreSelected() async {
    if (_selected.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final result = await widget.admin.restore(
        studentIds: _selected.toList(),
        requestedBy: widget.userId,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          result.isQueued
              ? 'Restore queued — the office service will apply it shortly.'
              : 'Restored ${result.affected} (${result.skipped} skipped).',
          style: GoogleFonts.inter(fontSize: 14),
        ),
      ));
      _reload();
    } on Exception {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('The restore couldn\u2019t be requested — check the network and try again.',
            style: TextStyle(fontSize: 14)),
      ));
    }
  }

  Future<void> _permanentDeleteSelected() async {
    if (_selected.isEmpty || _busy) return;
    final step1 = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Permanently delete these students?'),
        content: const Text(
          'Their student records are removed from the roster and can no longer '
          'be scanned or restored. The deletion evidence is kept for the '
          'retention period so this action stays auditable.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.statusEscalate),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (step1 != true || !mounted) return;
    final step2 = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Final confirmation'),
        content: Text(
          'This deletes ${_selected.length} ${_selected.length == 1 ? 'student' : 'students'} '
          'permanently. There is no undo. Proceed?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep them'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.statusEscalate),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Permanently delete'),
          ),
        ],
      ),
    );
    if (step2 != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final result = await widget.admin.permanentDelete(
        studentIds: _selected.toList(),
        requestedBy: widget.userId,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          result.isQueued
              ? 'Permanent deletion queued — the office service will apply it shortly.'
              : 'Permanently deleted ${result.affected} (${result.skipped} skipped).',
          style: GoogleFonts.inter(fontSize: 14),
        ),
      ));
      _reload();
    } on Exception {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('The delete couldn\u2019t be requested — check the network and try again.',
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
          'Recently deleted',
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
      body: FutureBuilder<List<DeletionRecord>>(
        future: _recordsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final restorable = (snapshot.data ?? const <DeletionRecord>[])
              .where((r) => !r.restored && !r.alreadyPermanent)
              .toList();
          final others = (snapshot.data ?? const <DeletionRecord>[])
              .where((r) => r.restored || r.alreadyPermanent)
              .toList();
          return Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                  children: [
                    if (snapshot.hasError)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          'Couldn\u2019t load deletion records. Check the network and refresh.',
                          style: GoogleFonts.inter(
                            color: AppColors.statusEscalate,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    if (restorable.isEmpty && others.isEmpty && !snapshot.hasError)
                      Padding(
                        padding: const EdgeInsets.only(top: 60),
                        child: Center(
                          child: Text(
                            'Nothing deleted yet. Archived students appear here.',
                            style: GoogleFonts.inter(
                              color: AppColors.ink900.withValues(alpha: 0.6),
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ),
                    if (restorable.isNotEmpty)
                      Text(
                        'Awaiting review',
                        style: GoogleFonts.inter(
                          color: AppColors.navy900,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    for (final r in restorable) _row(r, selectable: true),
                    if (others.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Text(
                        'Closed evidence',
                        style: GoogleFonts.inter(
                          color: AppColors.navy900,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      for (final r in others) _row(r, selectable: false),
                    ],
                  ],
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
                          'Permanent deletion is irreversible. Restoring is the '
                          'safe choice.',
                          style: GoogleFonts.inter(
                            color: AppColors.ink900.withValues(alpha: 0.55),
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            style: TextButton.styleFrom(
                              foregroundColor: AppColors.statusEscalate,
                              visualDensity: VisualDensity.compact,
                              minimumSize: const Size(0, 40),
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 8),
                            ),
                            onPressed: _busy ? null : _permanentDeleteSelected,
                            icon: const Icon(Icons.delete_forever_outlined, size: 16),
                            label: const Text('Delete permanently'),
                          ),
                        ),
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                              backgroundColor: AppColors.statusOk),
                          onPressed: _busy ? null : _restoreSelected,
                          icon: const Icon(Icons.restore),
                          label: Text('Restore ${_selected.length}'),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _row(DeletionRecord r, {required bool selectable}) {
    final checked = _selected.contains(r.studentId);
    final tag = r.alreadyPermanent
        ? 'permanently deleted'
        : r.restored
            ? 'restored'
            : 'soft-deleted';
    final tagColor = r.alreadyPermanent
        ? AppColors.statusEscalate
        : r.restored
            ? AppColors.statusOk
            : AppColors.statusWarn;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: selectable
            ? () => setState(() {
                  checked
                      ? _selected.remove(r.studentId)
                      : _selected.add(r.studentId);
                })
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              if (selectable) ...[
                Checkbox(
                  value: checked,
                  onChanged: (v) => setState(() {
                    v == true
                        ? _selected.add(r.studentId)
                        : _selected.remove(r.studentId);
                  }),
                  activeColor: AppColors.maroon900,
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            r.displayName,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              color: AppColors.ink900,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: tagColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            tag,
                            style: GoogleFonts.inter(
                              color: tagColor,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      chunkRegNumber(r.studentId),
                      style: GoogleFonts.inter(
                        color: AppColors.ink900.withValues(alpha: 0.6),
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      '${r.department ?? '-'}'
                      '${r.reason != null ? ' — ${r.reason!.replaceAll('_', ' ')}' : ''}'
                      '${r.deletedAt != null ? ' — deleted ${_day(r.deletedAt!)}' : ''}',
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

  static String _day(DateTime t) =>
      '${t.day.toString().padLeft(2, '0')}/${t.month.toString().padLeft(2, '0')}/${t.year}';
}