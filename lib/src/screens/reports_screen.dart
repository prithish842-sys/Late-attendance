import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/app_models.dart';
import '../services/auth_service.dart';
import '../services/callable_errors.dart';
import '../services/firestore_service.dart';
import '../services/perf_log.dart';
import '../services/report_pdf_builder.dart';
import '../services/report_service.dart';
import '../theme/app_theme.dart';
import 'hod_picker_screen.dart';
import 'mail_logs_screen.dart';
import 'mail_preview_screen.dart';
import 'report_pdf_viewer_screen.dart';

const _reportRoles = {'pt_sir', 'admin'};

const _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// Attendance reports screen (docs/TASKS.md Phase 4). Every staff member can
/// browse the data for any period/department/year as a live preview; only PT
/// sir / admin can generate the files. The PDF is built ON-DEVICE
/// (report_pdf_builder.dart + the `pdf` package) and opened in a viewer with
/// save/share — no office machine, no Blaze. The Excel file still comes from
/// the office-side queue as a secondary action, and the HOD mail flow is
/// unchanged. Department and year filters follow the same fuzzy rules the
/// server applies, so the preview always matches the generated files.
class ReportsScreen extends StatefulWidget {
  ReportsScreen({
    super.key,
    required this.auth,
    required this.firestore,
    required this.userId,
    ReportService? reports,
  }) : reports = reports ?? ReportService.from(firestore);

  final AuthService auth;
  final FirestoreService firestore;
  final String userId;
  final ReportService reports;

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  ReportPeriodType _periodType = ReportPeriodType.daily;
  late DateTime _anchor;
  late DateTime _customStart;
  late DateTime _customEnd;
  DepartmentInfo? _department;
  String? _year;
  bool? _canRequest;
  bool _busy = false;
  bool _pdfBusy = false;
  List<DepartmentInfo>? _departments;
  List<String>? _years;
  Future<ReportSummary>? _previewFuture;
  Timer? _previewDebounce;

  @override
  void dispose() {
    _previewDebounce?.cancel();
    // QA: flush the accumulated Firestore table when leaving the heaviest
    // query screen — without a call site the db-summary span never fires.
    PerfLog.dumpDb('reports');
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _anchor = DateTime(now.year, now.month, now.day);
    _customStart = _anchor;
    _customEnd = _anchor;
    _loadFilters();
    _loadRole();
    _previewFuture = _loadPreview();
  }

  Future<void> _loadRole() async {
    final role = await widget.auth.currentUserRole;
    if (!mounted) return;
    setState(() => _canRequest = _reportRoles.contains(role));
  }

  Future<void> _loadFilters() async {
    final depts = await widget.firestore.departments();
    final years = await widget.firestore.reportYears();
    if (!mounted) return;
    setState(() {
      _departments = depts;
      _years = years;
    });
  }

  ReportWindow get _window => reportWindowFor(
        _periodType,
        _anchor,
        customStart: _customStart,
        customEnd: _customEnd,
      );

  Future<ReportSummary> _loadPreview() async {
    final w = _window;
    PerfLog.start('report-preview');
    final rows = await widget.firestore.reportRows(
      start: w.start,
      end: w.end,
      department: _department,
      year: _year,
    );
    final summary = summarizeReport(rows);
    PerfLog.stop('report-preview');
    return summary;
  }

  void _onControlsChanged() {
    // Rate limit: rapid control changes (chips, sliders, typing) collapse into
    // one preview query per 300 ms instead of one Firestore read each.
    _previewDebounce?.cancel();
    _previewDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      // Start the query first and assign it with a void closure: an arrow
      // `() => _previewFuture = _loadPreview()` returns the Future, which trips
      // the debug setState assertion and skips markNeedsBuild, leaving the
      // FutureBuilder on the previous preview (the newest result never shows).
      final next = _loadPreview();
      setState(() {
        _previewFuture = next;
      });
    });
  }

  Future<void> _pickDay({required bool isStart}) async {
    final current = isStart ? _customStart : _customEnd;
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (isStart) {
        _customStart = picked;
      } else {
        _customEnd = picked;
      }
    });
    _onControlsChanged();
  }

  Future<void> _pickAnchor() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _anchor,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked == null || !mounted) return;
    setState(() => _anchor = picked);
    _onControlsChanged();
  }

  Future<void> _pickMonth() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _anchor,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked == null || !mounted) return;
    setState(() => _anchor = DateTime(picked.year, picked.month, 1));
    _onControlsChanged();
  }

  String _dayLabel(DateTime d) => '${d.day} ${_monthNames[d.month - 1]} ${d.year}';

  String _windowLabel() {
    final w = _window;
    switch (_periodType) {
      case ReportPeriodType.daily:
        return _dayLabel(w.start);
      case ReportPeriodType.weekly:
        return '${_dayLabel(w.start)} – ${_dayLabel(w.end)}';
      case ReportPeriodType.monthly:
        return '${_monthNames[w.start.month - 1]} ${w.start.year}';
      case ReportPeriodType.custom:
        return '${_dayLabel(w.start)} – ${_dayLabel(w.end)}';
    }
  }

  Future<void> _generate() async {
    if (_busy) return;
    final w = _window;
    setState(() => _busy = true);
    try {
      final result = await widget.reports.requestReport(
        filters: ReportFilters(
          periodType: _periodType,
          startDate: w.start,
          endDate: w.end,
          department: _department,
          year: _year,
        ),
        requestedBy: widget.userId,
      );
      if (!mounted) return;
      final message = switch (result.outcome) {
        ReportRequestOutcome.queued =>
          'Excel requested — the office machine will generate it (PDFs are built in-app now).',
        ReportRequestOutcome.generated =>
          result.stats == null
              ? 'Report generated.'
              : 'Report generated — ${result.stats!.totalLateEntries} late entries.',
      };
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message, style: GoogleFonts.inter(fontSize: 14))),
      );
    } on Exception catch (e) {
      if (!mounted) return;
      final rate = rateLimitOf(e);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            rate?.message ??
                'The report couldn\u2019t be requested - check the network and try again.',
            style: const TextStyle(fontSize: 14),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// In-app PDF (NEW request 3): rows are re-queried with the SAME filters the
  /// preview shows, rendered on-device by report_pdf_builder.dart, then opened
  /// in the viewer where PT sir can read, print or save/share it. No office
  /// machine, no queue, no Blaze — works fully on the Spark plan.
  Future<void> _generatePdf() async {
    if (_pdfBusy || _busy) return;
    final w = _window;
    setState(() => _pdfBusy = true);
    try {
      PerfLog.start('report-pdf-build');
      final rows = await widget.firestore.reportRows(
        start: w.start,
        end: w.end,
        department: _department,
        year: _year,
      );
      final summary = summarizeReport(rows);
      final label = _pdfLabel();
      final bytes = await buildReportPdfBytes(
        rows: rows,
        stats: summary,
        label: label,
      );
      PerfLog.stop('report-pdf-build');
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ReportPdfViewerScreen(
            bytes: bytes,
            fileName: reportPdfFileName(label),
            periodLabel: _windowLabel(),
          ),
        ),
      );
    } on Exception {
      PerfLog.stop('report-pdf-build');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'The PDF couldn\u2019t be built — check the network and try again.',
            style: TextStyle(fontSize: 14),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _pdfBusy = false);
    }
  }

  /// Title/file-name label: window plus the active filters, matching the
  /// mail report naming (report-generator.js label).
  String _pdfLabel() {
    final parts = <String>[_windowLabel()];
    final dept = _department;
    if (dept != null) parts.add(dept.name);
    final year = _year;
    if (year != null && year.isNotEmpty) {
      parts.add(switch (year) {
        '1' => '1st Year',
        '2' => '2nd Year',
        '3' => '3rd Year',
        _ => year,
      });
    }
    return parts.join(' — ');
  }

  /// Phase 2 (new updates): send / forward the current window to a HOD. When a
  /// department filter is already active its HOD is preselected; otherwise the
  /// HOD search opens first. The preview screen refreshes its rows whenever the
  /// recipient changes, so the mail always matches the previewed report.
  Future<void> _sendOrForward() async {
    if (_canRequest != true || _busy) return;
    final w = _window;
    final DepartmentInfo dept;
    final current = _department;
    if (current != null) {
      dept = current;
    } else {
      final depts = await widget.firestore.departments();
      if (!mounted) return;
      if (depts.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'No departments on file \u2014 the HOD report can\u2019t be addressed yet.',
              style: TextStyle(fontSize: 14),
            ),
          ),
        );
        return;
      }
      final picked = await Navigator.of(context).push<DepartmentInfo>(
        MaterialPageRoute(builder: (_) => HodPickerScreen(departments: depts)),
      );
      if (picked == null || !mounted) return;
      dept = picked;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MailPreviewScreen(
          firestore: widget.firestore,
          userId: widget.userId,
          periodType: _periodType,
          startDate: w.start,
          endDate: w.end,
          year: _year,
          initialDepartment: dept,
        ),
      ),
    );
  }

  void _openMailLogs() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MailLogsScreen(firestore: widget.firestore),
      ),
    );
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
          'Reports',
          style: GoogleFonts.inter(
            color: AppColors.navy900,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Mail Logs',
            icon: const Icon(Icons.mail_outline, color: AppColors.navy900),
            onPressed: _openMailLogs,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _buildBody()),
            _buildBottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
      children: [
        _sectionLabel('Report period'),
        SegmentedButton<ReportPeriodType>(
          segments: const [
            ButtonSegment(value: ReportPeriodType.daily, label: Text('Daily')),
            ButtonSegment(value: ReportPeriodType.weekly, label: Text('Weekly')),
            ButtonSegment(value: ReportPeriodType.monthly, label: Text('Monthly')),
            ButtonSegment(value: ReportPeriodType.custom, label: Text('Custom')),
          ],
          selected: {_periodType},
          onSelectionChanged: (selection) {
            setState(() => _periodType = selection.first);
            _onControlsChanged();
          },
          style: SegmentedButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: AppColors.navy900,
            selectedBackgroundColor: AppColors.maroon900,
            selectedForegroundColor: Colors.white,
            side: const BorderSide(color: AppColors.sand200),
            textStyle: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 12),
        ..._periodFields(),
        const SizedBox(height: 8),
        _sectionLabel('Filters'),
        _buildFilterRow(),
        const SizedBox(height: 16),
        _sectionLabel('Preview'),
        _buildPreview(),
      ],
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Text(
        text,
        style: GoogleFonts.inter(
          color: AppColors.navy900,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  List<Widget> _periodFields() {
    switch (_periodType) {
      case ReportPeriodType.daily:
        return [_dateTile('Report date', _dayLabel(_anchor), _pickAnchor)];
      case ReportPeriodType.weekly:
        return [_dateTile('Week starting', _dayLabel(_anchor), _pickAnchor)];
      case ReportPeriodType.monthly:
        return [_dateTile('Month', '${_monthNames[_anchor.month - 1]} ${_anchor.year}', _pickMonth)];
      case ReportPeriodType.custom:
        return [
          _dateTile('From', _dayLabel(_customStart), () => _pickDay(isStart: true)),
          _dateTile('To', _dayLabel(_customEnd), () => _pickDay(isStart: false)),
        ];
    }
  }

  Widget _dateTile(String label, String display, VoidCallback onTap) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: const BorderSide(color: AppColors.sand200, width: 1),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              const Icon(Icons.calendar_today_outlined, size: 18, color: AppColors.maroon700),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: GoogleFonts.inter(
                    color: AppColors.ink900.withValues(alpha: 0.7),
                    fontSize: 14,
                  ),
                ),
              ),
              Text(
                display,
                style: tabular(GoogleFonts.inter(
                  color: AppColors.ink900,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                )),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFilterRow() {
    final deptItems = [
      const DropdownMenuItem(value: '', child: Text('All departments')),
      for (final d in _departments ?? const <DepartmentInfo>[])
        DropdownMenuItem(value: d.id, child: Text(d.name)),
    ];
    // 1st / 2nd / 3rd (NEW_TASKS.md Phase 2 "1st/2nd/3rd filter") filter by
    // grade tier; raw distinct values that aren't grade tiers (e.g. a
    // "2024-2027" batch label) are appended as exact-match options so nothing
    // already stored becomes unfilterable.
    final yearItems = [
      const DropdownMenuItem(value: '', child: Text('All years')),
      const DropdownMenuItem(value: '1', child: Text('1st Year')),
      const DropdownMenuItem(value: '2', child: Text('2nd Year')),
      const DropdownMenuItem(value: '3', child: Text('3rd Year')),
      for (final y in (_years ?? const <String>[]).where((y) => yearTier(y) == 0))
        DropdownMenuItem(value: y, child: Text(y)),
    ];
    return Column(
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey('dept-${_department?.id ?? ''}'),
          initialValue: _department?.id ?? '',
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Department'),
          items: deptItems,
          onChanged: _departments == null
              ? null
              : (v) {
                  final wanted = (v ?? '').isEmpty
                      ? null
                      : _departments!.firstWhere((d) => d.id == v);
                  setState(() => _department = wanted);
                  _onControlsChanged();
                },
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: ValueKey('year-$_year'),
          initialValue: _year ?? '',
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Year'),
          items: yearItems,
          onChanged: _years == null
              ? null
              : (v) {
                  setState(() => _year = (v ?? '').isEmpty ? null : v);
                  _onControlsChanged();
                },
        ),
      ],
    );
  }

  Widget _buildPreview() {
    return FutureBuilder<ReportSummary>(
      future: _previewFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Card(
            margin: EdgeInsets.zero,
            elevation: 0,
            color: Colors.white,
            child: Padding(
              padding: EdgeInsets.all(28),
              child: Center(
                child: CircularProgressIndicator(color: AppColors.maroon900),
              ),
            ),
          );
        }
        if (snapshot.hasError) {
          return Card(
            margin: EdgeInsets.zero,
            elevation: 0,
            color: Colors.white,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const Icon(Icons.cloud_off, size: 34, color: AppColors.ink900),
                  const SizedBox(height: 10),
                  Text(
                    'Couldn\u2019t load the preview. Check the network and try again.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                      color: AppColors.ink900.withValues(alpha: 0.7),
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextButton(
                    onPressed: () {
                      final next = _loadPreview();
                      setState(() {
                        _previewFuture = next;
                      });
                    },
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          );
        }
        return _summaryCard(snapshot.data ?? const ReportSummary(
              totalLateEntries: 0,
              distinctStudents: 0,
              byDepartment: [],
            ));
      },
    );
  }

  Widget _summaryCard(ReportSummary summary) {
    final entries = summary.totalLateEntries;
    final students = summary.distinctStudents;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: const BorderSide(color: AppColors.sand200, width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _windowLabel(),
              style: GoogleFonts.inter(
                color: AppColors.ink900.withValues(alpha: 0.6),
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '$entries',
                  style: tabular(GoogleFonts.inter(
                    color: AppColors.maroon700,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                  )),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    entries == 1 ? 'late entry' : 'late entries',
                    style: GoogleFonts.inter(
                      color: AppColors.ink900,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
            Text(
              '$students ${students == 1 ? 'student' : 'students'}',
              style: GoogleFonts.inter(
                color: AppColors.ink900.withValues(alpha: 0.7),
                fontSize: 14,
              ),
            ),
            if (summary.byDepartment.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Divider(color: AppColors.sand200, height: 1),
              const SizedBox(height: 4),
              for (final d in summary.byDepartment)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          d.department,
                          style: GoogleFonts.inter(color: AppColors.ink900, fontSize: 14),
                        ),
                      ),
                      Text(
                        '${d.count}',
                        style: tabular(GoogleFonts.inter(
                          color: AppColors.maroon700,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        )),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_canRequest == false)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                'Reports can only be generated by the gate office (PT sir / admin).',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  color: AppColors.ink900.withValues(alpha: 0.7),
                ),
              ),
            ),
          FilledButton(
            onPressed: _canRequest == true
                ? ((_busy || _pdfBusy) ? null : _generatePdf)
                : null,
            child: _pdfBusy
                ? const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
                      ),
                      SizedBox(width: 12),
                      Text('Building PDF\u2026'),
                    ],
                  )
                : const Text('Generate PDF'),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: _canRequest == true ? ((_busy || _pdfBusy) ? null : _sendOrForward) : null,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 52),
              foregroundColor: AppColors.maroon700,
              side: const BorderSide(color: AppColors.sand200, width: 1.2),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              textStyle: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            child: const Text('Send / Forward Report'),
          ),
          if (_canRequest == true)
            TextButton(
              onPressed: _busy || _pdfBusy ? null : _generate,
              child: _busy
                  ? const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.maroon700),
                        ),
                        SizedBox(width: 10),
                        Text('Requesting\u2026'),
                      ],
                    )
                  : const Text('Request Excel from the office'),
            ),
        ],
      ),
    );
  }
}