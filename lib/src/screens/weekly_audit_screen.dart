import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/app_models.dart';
import '../services/auth_service.dart';
import '../services/firestore_service.dart';
import '../services/weekly_audit_mail_service.dart';
import '../theme/app_theme.dart';
import '../widgets/escalated_rule.dart';
import 'weekly_audit_mail_preview_screen.dart';

const _mailRoles = {'pt_sir', 'admin'};

/// The Monday of the week containing `d` — the single week anchor the app sends
/// as the mail intent's startDate (functions/weekly-audit-core.js recomputes
/// the Monday→Sunday window server-side from that).
DateTime weeklyMonday(DateTime d) => DateTime(d.year, d.month, d.day - (d.weekday - 1));

/// Weekly audit screen (docs-new-updates/NEW_AUDIT_WORKFLOW.md, Phase 3):
/// PT sir / admin review each department's week before the Friday–Sunday HOD
/// mail-run. All staff can read the numbers; only pt_sir/admin can send, and
/// only for departments with an HOD email on file. The send button hands off to
/// the WeeklyAuditMailPreviewScreen — the server builds the authoritative mail.
class WeeklyAuditScreen extends StatefulWidget {
  WeeklyAuditScreen({
    super.key,
    required this.auth,
    required this.firestore,
    required this.userId,
    WeeklyAuditMailService? mail,
    DateTime? initialWeekStart,
    this.repeatThreshold = 2,
  })  : mail = mail ?? WeeklyAuditMailService.from(firestore),
        initialWeekStart = _weekAnchor(initialWeekStart);

  final AuthService auth;
  final FirestoreService firestore;
  final String userId;
  final WeeklyAuditMailService mail;
  final DateTime initialWeekStart;
  final int repeatThreshold;

  static DateTime _weekAnchor(DateTime? anchor) {
    if (anchor == null) return weeklyMonday(DateTime.now());
    return weeklyMonday(anchor);
  }

  @override
  State<WeeklyAuditScreen> createState() => _WeeklyAuditScreenState();
}

class _WeeklyAuditScreenState extends State<WeeklyAuditScreen> {
  late DateTime _weekStart;
  late Future<WeeklyAuditOverview> _overviewFuture;
  Future<List<DepartmentInfo>>? _departmentsFuture;
  int _tintThreshold = 3;
  bool? _canSend;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _weekStart = widget.initialWeekStart;
    _overviewFuture = _loadOverview();
    _departmentsFuture = widget.firestore.departments();
    _loadRole();
    _loadTintThreshold();
  }

  Future<void> _loadRole() async {
    final role = await widget.auth.currentUserRole;
    if (!mounted) return;
    setState(() => _canSend = _mailRoles.contains(role));
  }

  Future<void> _loadTintThreshold() async {
    var threshold = 3;
    try {
      threshold = (await widget.firestore.fetchSettings()).escalationThreshold;
    } catch (_) {
      // Settings unreachable — keep the monotonic default; the tint is cosmetic.
    }
    if (!mounted) return;
    setState(() => _tintThreshold = threshold);
  }

  Future<WeeklyAuditOverview> _loadOverview() {
    final end = DateTime(_weekStart.year, _weekStart.month, _weekStart.day + 6);
    return widget.firestore
        .reportRows(start: _weekStart, end: end)
        .then(
          (rows) => weeklyAuditOverview(
            rows,
            _weekStart,
            repeatThreshold: widget.repeatThreshold,
          ),
        );
  }

  void _shiftWeek(int delta) {
    setState(() {
      _query = '';
      _weekStart = DateTime(_weekStart.year, _weekStart.month, _weekStart.day + delta * 7);
      _overviewFuture = _loadOverview();
    });
  }

  void _goCurrentWeek() {
    setState(() {
      _query = '';
      _weekStart = weeklyMonday(DateTime.now());
      _overviewFuture = _loadOverview();
    });
  }

  void _retry() {
    // Start first, assign with a void closure: an arrow closure returning the
    // Future trips the debug setState assertion and skips markNeedsBuild, so
    // the FutureBuilder would keep the previous (failed) snapshot.
    final next = _loadOverview();
    setState(() {
      _overviewFuture = next;
    });
  }

  Future<void> _openMailPreview(DepartmentInfo dept, WeeklyAuditGroup group) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WeeklyAuditMailPreviewScreen(
          firestore: widget.firestore,
          userId: widget.userId,
          department: dept,
          weekStart: _weekStart,
          group: group,
          mailService: widget.mail,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  DepartmentInfo _resolveDept(List<DepartmentInfo> departments, WeeklyAuditGroup group) {
    final resolved = findDepartment(departments, group.department);
    if (resolved != null) return resolved;
    // No reference doc for this display string — nothing to send to.
    return DepartmentInfo(id: group.department, name: group.department);
  }

  bool _matchesQuery(WeeklyStudentView s) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return s.name.toLowerCase().contains(q) || s.studentId.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          'Weekly Audit',
          style: GoogleFonts.inter(
            color: AppColors.navy900,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            _weekNav(),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _weekNav() {
    final isCurrent = _weekStart.toUtc().difference(weeklyMonday(DateTime.now()).toUtc()).inDays == 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Previous week',
            onPressed: () => _shiftWeek(-1),
            icon: const Icon(Icons.chevron_left),
            color: AppColors.maroon700,
          ),
          Expanded(
            child: Column(
              children: [
                Text(
                  'Week ${weeklyAuditRange(_weekStart)}',
                  style: tabular(GoogleFonts.inter(
                    color: AppColors.navy900,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  )),
                ),
                if (!isCurrent)
                  TextButton(
                    onPressed: _goCurrentWeek,
                    child: const Text('This week'),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Next week',
            onPressed: () => _shiftWeek(1),
            icon: const Icon(Icons.chevron_right),
            color: AppColors.maroon700,
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    return FutureBuilder<WeeklyAuditOverview>(
      future: _overviewFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(color: AppColors.maroon900));
        }
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_off, size: 40, color: AppColors.ink900),
                  const SizedBox(height: 12),
                  Text(
                    'Couldn\u2019t load this week\u2019s audit. Check the network and try again.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                      color: AppColors.ink900.withValues(alpha: 0.7),
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(onPressed: _retry, child: const Text('Retry')),
                ],
              ),
            ),
          );
        }
        final overview = snapshot.data!;
        if (overview.departments.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'No late entries this week.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.ink900),
              ),
            ),
          );
        }
        return FutureBuilder<List<DepartmentInfo>>(
          future: _departmentsFuture,
          builder: (context, deptSnap) {
            final departments = deptSnap.data ?? const <DepartmentInfo>[];
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                _summaryCard(overview),
                const SizedBox(height: 14),
                if (overview.repeatedStudents > 0) _searchField(),
                const SizedBox(height: 8),
                for (final group in overview.departments) _deptCard(group, departments),
              ],
            );
          },
        );
      },
    );
  }

  Widget _summaryCard(WeeklyAuditOverview overview) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: AppColors.sand200),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _stat('${overview.uniqueStudents}', overview.uniqueStudents == 1 ? 'student late' : 'students late'),
          _stat('${overview.totalEvents}', overview.totalEvents == 1 ? 'entry' : 'entries'),
          _stat(
            '${overview.repeatedStudents}',
            'repeated (>=${widget.repeatThreshold} this week)',
          ),
        ],
      ),
    );
  }

  Widget _stat(String value, String label) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: tabular(GoogleFonts.inter(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            color: AppColors.maroon900,
            height: 1,
          )),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: GoogleFonts.inter(
            color: AppColors.ink900.withValues(alpha: 0.6),
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Widget _searchField() {
    return TextField(
      onChanged: (v) => setState(() => _query = v.trim()),
      maxLength: 64,
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search, size: 20, color: AppColors.ink900),
        hintText: 'Filter repeated students by name or register number',
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        counterText: '',
      ),
    );
  }

  Widget _deptCard(WeeklyAuditGroup group, List<DepartmentInfo> departments) {
    final dept = _resolveDept(departments, group);
    final hod = dept.hodEmail ?? '';
    final canSend = _canSend == true && hod.isNotEmpty;
    final visible = group.repeated.where(_matchesQuery).toList();
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: AppColors.sand200, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        dept.name,
                        style: GoogleFonts.inter(
                          color: AppColors.navy900,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${group.uniqueStudents} students, ${group.totalEvents} late entries, '
                        '${group.repeatedStudents} repeated this week',
                        style: tabular(GoogleFonts.inter(
                          color: AppColors.ink900.withValues(alpha: 0.6),
                          fontSize: 13,
                        )),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        hod.isEmpty ? 'No HOD email on file' : hod,
                        style: GoogleFonts.inter(
                          color: hod.isEmpty
                              ? AppColors.statusWarn
                              : AppColors.ink900.withValues(alpha: 0.6),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (canSend)
                  TextButton.icon(
                    onPressed: () => _openMailPreview(dept, group),
                    icon: const Icon(Icons.send_outlined, size: 16),
                    label: const Text('Send to HOD'),
                  ),
              ],
            ),
          ),
          if (group.repeated.isNotEmpty) ...[
            const Divider(height: 1, color: AppColors.sand200),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
              child: Text(
                'Repeated this week',
                style: GoogleFonts.inter(
                  color: AppColors.ink900.withValues(alpha: 0.5),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
            ),
            if (visible.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 2, 14, 12),
                child: Text(
                  'No student matches the filter.',
                  style: GoogleFonts.inter(
                    color: AppColors.ink900.withValues(alpha: 0.6),
                    fontSize: 13,
                  ),
                ),
              )
            else
              for (final s in visible) _studentRow(s),
            const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }

  Widget _studentRow(WeeklyStudentView s) {
    final status = s.monthStatus(_tintThreshold);
    final color = status == 'escalated'
        ? AppColors.statusEscalate
        : (status == 'warning' ? AppColors.statusWarn : AppColors.statusOk);
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
      child: Row(
        children: [
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
                Text(
                  '${chunkRegNumber(s.studentId)} '
                  '${s.year.isEmpty ? '' : ', Year ${s.year}'}',
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
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'W ${s.weekCount}',
                    style: tabular(GoogleFonts.inter(
                      color: AppColors.maroon700,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    )),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'M ${s.monthCount}',
                    style: tabular(GoogleFonts.inter(
                      color: color,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    )),
                  ),
                ],
              ),
              Text(
                'last late ${s.lastLateDate ?? '-'}',
                style: tabular(GoogleFonts.inter(
                  color: AppColors.ink900.withValues(alpha: 0.6),
                  fontSize: 12,
                )),
              ),
            ],
          ),
        ],
      ),
    );

    return status == 'escalated' ? EscalatedRule(child: row) : row;
  }
}