import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/app_models.dart';
import '../services/admin_service.dart';
import '../services/auth_service.dart';
import '../services/callable_errors.dart';
import '../services/firestore_service.dart';
import '../services/import_parser.dart';
import '../theme/app_theme.dart';
import '../widgets/admin_gate.dart';

/// Phase 4 — Batch Import (NEW_ADMIN_WORKFLOW.md): pick an `.xlsx`, decode and
/// validate it with [validateImportRows] (the exact server mirror), preview the
/// per-row verdicts, then commit. The commit re-validates server-side against
/// fresh departments + the current roster, so rows accepted here can still be
/// rejected there (they are skipped, never half-written). Re-selecting the same
/// file yields the same [importIdForBytes], so a duplicate commit is an
/// idempotent no-op.
class BatchImportScreen extends StatefulWidget {
  BatchImportScreen({
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
  State<BatchImportScreen> createState() => _BatchImportScreenState();
}

class _BatchImportScreenState extends State<BatchImportScreen>
    with AdminGateMixin {
  @override
  AuthService get auth => widget.auth;

  /// C4: xlsx files are rejected before `readAsBytes` above this cap so a
  /// hostile "spreadsheet" can never balloon memory during decode.
  static const int _maxImportBytes = 5 * 1024 * 1024;

  String? _fileName;
  List<int>? _bytes;
  List<ImportRow>? _rows;
  List<DepartmentInfo> _departments = const [];
  List<String> _existingIds = const [];
  ImportSheetResult? _preview;
  bool _reading = false;
  bool _committing = false;

  @override
  void initState() {
    super.initState();
    widget.firestore.departments().then((deps) {
      if (mounted) setState(() => _departments = deps);
    });
    widget.firestore.allStudents().then((students) {
      if (mounted) setState(() => _existingIds = students.map((s) => s.studentId).toSet().toList());
    });
  }

  Future<void> _pick() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['xlsx'],
      );
      if (files.isEmpty || !mounted) return;
      final file = files.single;
      // C4: cap before readAsBytes (native pickers report size without I/O;
      // length() covers the rest) plus a belt-and-braces check on the bytes.
      final size = file.lengthSync() ?? await file.length();
      if (size != null && size > _maxImportBytes) {
        _rejectTooLarge();
        return;
      }
      final bytes = await file.readAsBytes();
      if (bytes.length > _maxImportBytes) {
        _rejectTooLarge();
        return;
      }
      setState(() {
        _fileName = file.name;
        _bytes = bytes;
        _preview = null;
        _reading = true;
      });
      // Decode + validate on the next frame so the spinner shows first.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final rows = readSheetRows(bytes);
      if (!mounted) return;
      setState(() {
        _reading = false;
        _rows = rows;
        _preview = rows.isEmpty
            ? null
            : validateImportRows(rows, departments: _departments, existingStudentIds: _existingIds);
      });
      if (rows.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No rows found — check the sheet has Register Number, Name and Department '
              'columns with a header row.', style: TextStyle(fontSize: 14)),
        ));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _reading = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('That file couldn\u2019t be opened as a spreadsheet.', style: TextStyle(fontSize: 14)),
      ));
    }
  }

  void _rejectTooLarge() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('That file is larger than 5 MB — import sheets must be under 5 MB.',
          style: TextStyle(fontSize: 14)),
    ));
  }

  Future<void> _commit() async {
    final preview = _preview;
    final bytes = _bytes;
    final fileName = _fileName;
    if (preview == null || bytes == null || fileName == null || _committing) return;
    if (_rows == null) return;
    final valid = preview.rows.where((r) => r.valid).toList();
    if (valid.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Commit this import?'),
        content: Text(
          '${valid.length} valid rows will be added; ${preview.counts.invalid} problem '
          'rows are skipped. This is recorded in the audit log.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Commit', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() => _committing = true);
    try {
      // The department for the batch row: derived from the first valid row (all
      // rows in the sheet should share one department; mixed sheets commit only
      // rows whose department resolves — each valid row carries its own).
      final firstDeptId = valid.firstWhere((r) => r.departmentId != null,
              orElse: () => valid.first)
          .departmentId;
      final department = _departments.where((d) => d.id == firstDeptId).map((d) => d.name).firstOrNull ?? '';
      final result = await widget.admin.commitImportBatch(
        importId: importIdForBytes(bytes),
        filename: fileName,
        departmentId: firstDeptId ?? '',
        department: department,
        rows: valid.map((r) => r.row).toList(),
        requestedBy: widget.userId,
      );
      if (!mounted) return;
      setState(() => _committing = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          result.isQueued
              ? 'Import queued — the office service will apply it shortly.'
              : 'Imported ${result.added} students.',
          style: GoogleFonts.inter(fontSize: 14),
        ),
      ));
      setState(() {
        _fileName = null;
        _bytes = null;
        _rows = null;
        _preview = null;
      });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() => _committing = false);
      final rate = rateLimitOf(e);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            rate?.message ??
                'The import couldn\u2019t be committed: ${e.toString()}.',
            style: const TextStyle(fontSize: 14)),
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
          'Batch import',
          style: GoogleFonts.inter(
            color: AppColors.navy900,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _reading ? null : _pick,
                    icon: const Icon(Icons.upload_file),
                    label: Text(_bytes == null ? 'Pick an Excel file' : 'Pick another file'),
                  ),
                ),
              ],
            ),
          ),
          if (_reading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            ),
          Expanded(
            child: _preview == null ? _buildHistory() : _buildPreview(),
          ),
          if (_preview != null && _preview!.counts.valid > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: AppColors.maroon900),
                onPressed: _committing ? null : _commit,
                icon: const Icon(Icons.check),
                label: Text('Commit ${_preview!.counts.valid} valid rows'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPreview() {
    final p = _preview!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      children: [
        Text(
          '${p.counts.valid} valid, ${p.counts.invalid} with problems, ${p.counts.warnings} warnings',
          style: GoogleFonts.inter(
            color: p.counts.invalid == 0 ? AppColors.statusOk : AppColors.statusWarn,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'The server re-validates on commit — rows it rejects are skipped, '
          'never half-written.',
          style: GoogleFonts.inter(
            color: AppColors.ink900.withValues(alpha: 0.55),
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 8),
        for (final row in p.rows.take(100)) _rowCard(row),
      ],
    );
  }

  Widget _rowCard(ImportRowResult r) {
    final hasProblems = r.errors.isNotEmpty;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: r.valid
            ? Colors.white
            : AppColors.sand200.withValues(alpha: 0.5),
        border: Border.all(
          color: hasProblems ? AppColors.statusEscalate : AppColors.sand200,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.row.registerNumber.isEmpty ? '(no register #)' : r.row.registerNumber,
                  style: GoogleFonts.inter(
                    color: AppColors.ink900,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  r.row.name.isEmpty ? '(no name)' : r.row.name,
                  style: GoogleFonts.inter(
                    color: AppColors.ink900.withValues(alpha: 0.7),
                    fontSize: 12.5,
                  ),
                ),
                Text(
                  '${r.row.department.isEmpty ? '-' : r.row.department}'
                  '${r.row.currentYear != null ? ', Year ${r.row.currentYear}' : ''}'
                  '${r.row.batchStartYear != null ? ', batch ${r.row.batchStartYear}–${r.row.batchEndYear}' : ''}',
                  style: GoogleFonts.inter(
                    color: AppColors.ink900.withValues(alpha: 0.6),
                    fontSize: 12,
                  ),
                ),
                for (final e in r.errors)
                  Text(
                    '· $e',
                    style: GoogleFonts.inter(
                      color: AppColors.statusEscalate,
                      fontSize: 12,
                    ),
                  ),
                for (final w in r.warnings)
                  Text(
                    '· $w',
                    style: GoogleFonts.inter(
                      color: AppColors.statusWarn,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
          Icon(
            r.valid ? Icons.check_circle_outline : Icons.error_outline,
            color: r.valid ? AppColors.statusOk : AppColors.statusEscalate,
            size: 20,
          ),
        ],
      ),
    );
  }

  Widget _buildHistory() {
    return FutureBuilder<List<ImportBatchMeta>>(
      future: widget.firestore.importBatches(),
      builder: (context, snapshot) {
        final metas = snapshot.data ?? const <ImportBatchMeta>[];
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          children: [
            Text(
              'Recent imports',
              style: GoogleFonts.inter(
                color: AppColors.navy900,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            if (metas.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 40),
                child: Center(
                  child: Text(
                    'No imports yet. Pick a file above to start.',
                    style: GoogleFonts.inter(
                      color: AppColors.ink900.withValues(alpha: 0.6),
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
            for (final m in metas)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: AppColors.sand200),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            m.filename ?? m.importId,
                            style: GoogleFonts.inter(
                              color: AppColors.ink900,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            '${m.counts?.committed} committed, ${m.counts?.rows} rows'
                            '${m.department != null ? ', ${m.department}' : ''}'
                            '${m.createdAt != null ? ', ${_day(m.createdAt!)}' : ''}',
                            style: GoogleFonts.inter(
                              color: AppColors.ink900.withValues(alpha: 0.6),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  static String _day(DateTime t) => '${t.day.toString().padLeft(2, '0')}/${t.month.toString().padLeft(2, '0')}/${t.year}';
}