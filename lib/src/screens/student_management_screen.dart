import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/app_models.dart';
import '../services/admin_service.dart';
import '../services/auth_service.dart';
import '../services/firestore_service.dart';
import '../theme/app_theme.dart';
import '../widgets/admin_gate.dart';

/// Phase 4 — Student Management (NEW_ADMIN_WORKFLOW.md): browse the master
/// roster, search by register number / name, filter by department and batch
/// year, and archive (soft-delete) students. Archiving is two-stage: it marks
/// the student `active:false` + writes a deletion_records evidence row — it
/// never deletes data outright (NEW_DECISIONS.md #12,#13). The actual write is
/// server-authoritative via AdminService (callable on Blaze, admin_requests on
/// Spark).
class StudentManagementScreen extends StatefulWidget {
  StudentManagementScreen({
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
  State<StudentManagementScreen> createState() => _StudentManagementScreenState();
}

class _StudentManagementScreenState extends State<StudentManagementScreen>
    with AdminGateMixin {
  @override
  AuthService get auth => widget.auth;

  late Future<List<Student>> _studentsFuture;
  List<DepartmentInfo> _departments = const [];
  String _departmentId = '';
  String? _year;
  String _query = '';
  final Set<String> _selected = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _studentsFuture = widget.firestore.allStudents();
    widget.firestore.departments().then((deps) {
      if (mounted) setState(() => _departments = deps);
    });
  }

  void _reload() {
    setState(() {
      _selected.clear();
      _studentsFuture = widget.firestore.allStudents();
    });
  }

  List<Student> _filter(List<Student> students) {
    final q = _query.trim().toLowerCase();
    return students.where((s) {
      if (!s.active) return false;
      if (_departmentId.isNotEmpty &&
          (s.departmentId ?? '') != _departmentId &&
          displayToken(s.department) != displayToken(_departmentId)) {
        return false;
      }
      // Year of study filter — compares normalized grade tiers so both data
      // shapes match: seeded rows store "1"/"2"/"3" and batch-imported rows
      // store "1st Year"/"2nd Year"/… (yearTier handles both). The old
      // batch-start-year filter matched a field only batch imports write, so
      // it always showed "no students match" on seeded data.
      if (_year != null && yearTier(s.year) != int.parse(_year!)) return false;
      if (q.isNotEmpty) {
        final haystack =
            '${s.studentId} ${s.registerNumber ?? ''} ${s.name}'.toLowerCase();
        if (!haystack.contains(q)) return false;
      }
      return true;
    }).toList()
      ..sort((a, b) => a.studentId.compareTo(b.studentId));
  }

  List<String> get _studyYears => ['1', '2', '3'];

  Future<void> _archiveSelected() async {
    if (_selected.isEmpty || _busy) return;
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const _ReasonDialog(),
    );
    if (reason == null || reason.isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      final result = await widget.admin.softDelete(
        studentIds: _selected.toList(),
        reason: reason,
        requestedBy: widget.userId,
      );
      if (!mounted) return;
      final n = _selected.length;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          result.isQueued
              ? 'Archiving $n ${n == 1 ? 'student' : 'students'} will be applied by the office service shortly.'
              : 'Archived ${result.affected} ${result.affected == 1 ? 'student' : 'students'} (${result.skipped} skipped).',
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
          'Student management',
          style: GoogleFonts.inter(
            color: AppColors.navy900,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh roster',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
            color: AppColors.navy900,
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: TextField(
              maxLength: 64,
              decoration: const InputDecoration(
                hintText: 'Search register number or name',
                prefixIcon: Icon(Icons.search),
                filled: true,
                counterText: '',
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _departmentId.isEmpty ? null : _departmentId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Department', filled: true),
                    items: [
                      const DropdownMenuItem<String>(value: null, child: Text('All')),
                      for (final d in _departments)
                        DropdownMenuItem(value: d.id, child: Text(d.name, overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: (v) => setState(() => _departmentId = v ?? ''),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _year,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Year of study', filled: true),
                    items: [
                      const DropdownMenuItem<String>(value: null, child: Text('All')),
                      for (final y in _studyYears)
                        DropdownMenuItem(value: y, child: Text('Year $y')),
                    ],
                    onChanged: (v) => setState(() => _year = v),
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: _buildBody()),
          if (_selected.isNotEmpty)
            _buildArchiveBar(),
        ],
      ),
    );
  }

  Widget _buildBody() {
    return FutureBuilder<List<Student>>(
      future: _studentsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return _errorView(snapshot.error);
        }
        final visible = _filter(snapshot.data ?? const []);
        if (visible.isEmpty) {
          return Center(
            child: Text(
              _query.isEmpty && _departmentId.isEmpty && _year == null
                  ? 'No students on file.'
                  : 'No students match the filters.',
              style: GoogleFonts.inter(
                color: AppColors.ink900.withValues(alpha: 0.6),
                fontSize: 14,
              ),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          itemCount: visible.length,
          separatorBuilder: (_, _) => const Divider(height: 1, color: AppColors.sand200),
          itemBuilder: (context, index) => _studentRow(visible[index]),
        );
      },
    );
  }

  Widget _studentRow(Student s) {
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
                      '${s.batchStartYear != null ? ' — batch ${s.batchStartYear}–${s.batchEndYear}' : ''}',
                      style: GoogleFonts.inter(
                        color: AppColors.ink900.withValues(alpha: 0.6),
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              if (s.year != null && s.year!.isNotEmpty)
                Text(
                  'Yr ${s.year}',
                  style: GoogleFonts.inter(
                    color: AppColors.navy900,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildArchiveBar() {
    return Container(
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
              'Archiving marks records inactive and stops new scans. '
              'Records can be restored from Recently Deleted.',
              style: GoogleFonts.inter(
                color: AppColors.ink900.withValues(alpha: 0.55),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.statusEscalate,
                side: const BorderSide(color: AppColors.statusEscalate),
                minimumSize: const Size.fromHeight(40),
              ),
              onPressed: _busy ? null : _archiveSelected,
              icon: const Icon(Icons.archive_outlined, size: 18),
              label: Text('Archive ${_selected.length} selected'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorView(Object? error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Couldn\u2019t load the roster. Check the network and try again.',
              style: GoogleFonts.inter(
                color: AppColors.ink900.withValues(alpha: 0.7),
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _reload, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

class _ReasonDialog extends StatefulWidget {
  const _ReasonDialog();

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  String _reason = 'manual';

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Why are these being archived?'),
      content: RadioGroup<String>(
        groupValue: _reason,
        onChanged: (v) => setState(() => _reason = v ?? 'manual'),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RadioListTile<String>(
              value: 'manual',
              title: Text('Manual (admin action)'),
            ),
            RadioListTile<String>(
              value: 'pass_out',
              title: Text('Passed out'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_reason),
          child: const Text('Archive'),
        ),
      ],
    );
  }
}