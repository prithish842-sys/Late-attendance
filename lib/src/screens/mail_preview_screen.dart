import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/app_models.dart';
import '../services/callable_errors.dart';
import '../services/firestore_service.dart';
import '../services/report_mail_service.dart';
import '../theme/app_theme.dart';
import 'hod_picker_screen.dart';

/// Send / Forward Report preview (docs-new-updates/NEW_REPORT_MAIL_WORKFLOW.md):
/// the staff member reviews the recipient, subject, formal body, year-wise
/// student list (3rd → 2nd → 1st) and the attachment file names before the
/// server sends. Confirming expresses *intent* only — the authoritative mail
/// and the mail_logs audit row are built server-side.
class MailPreviewScreen extends StatefulWidget {
  MailPreviewScreen({
    super.key,
    required this.firestore,
    required this.userId,
    required this.periodType,
    required this.startDate,
    required this.endDate,
    required this.initialDepartment,
    this.year,
    ReportMailService? mailService,
  }) : mailService = mailService ?? ReportMailService.from(firestore);

  final FirestoreService firestore;
  final String userId;
  final ReportPeriodType periodType;
  final DateTime startDate;
  final DateTime endDate;
  final String? year;
  final DepartmentInfo initialDepartment;
  final ReportMailService mailService;

  @override
  State<MailPreviewScreen> createState() => _MailPreviewScreenState();
}

class _MailPreviewScreenState extends State<MailPreviewScreen> {
  late DepartmentInfo _department;
  ReportMailMode _mode = ReportMailMode.combined;
  Future<List<ReportRow>>? _rowsFuture;
  bool _sending = false;
  MailSendResult? _result;

  @override
  void initState() {
    super.initState();
    _department = widget.initialDepartment;
    _rowsFuture = _loadRows();
  }

  Future<List<ReportRow>> _loadRows() {
    return widget.firestore.reportRows(
      start: widget.startDate,
      end: widget.endDate,
      department: _department,
      year: widget.year,
    );
  }

  Future<void> _changeHod() async {
    final departments = await widget.firestore.departments();
    if (!mounted) return;
    final picked = await Navigator.of(context).push<DepartmentInfo>(
      MaterialPageRoute(
        builder: (_) => HodPickerScreen(
          departments: departments,
          selectedId: _department.id,
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _department = picked;
      _rowsFuture = _loadRows();
    });
  }

  Future<void> _confirmSend() async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      final result = await widget.mailService.sendReportMail(
        request: ReportMailRequest(
          periodType: widget.periodType,
          startDate: widget.startDate,
          endDate: widget.endDate,
          department: _department,
          year: widget.year,
          mode: _mode,
        ),
        requestedBy: widget.userId,
      );
      if (!mounted) return;
      setState(() => _result = result);
    } on Exception catch (e) {
      if (!mounted) return;
      final rate = rateLimitOf(e);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            rate?.message ??
                'The report mail couldn\u2019t be sent \u2014 check the network and try again.',
            style: const TextStyle(fontSize: 14),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
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
          'Send / Forward Report',
          style: GoogleFonts.inter(
            color: AppColors.navy900,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: SafeArea(
        child: _result != null
            ? _successView()
            : Column(
                children: [
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                      children: [
                        _sectionLabel('Recipient'),
                        _recipientCard(),
                        const SizedBox(height: 14),
                        _sectionLabel('Subject'),
                        _subjectCard(),
                        const SizedBox(height: 14),
                        _sectionLabel('Message'),
                        FutureBuilder<List<ReportRow>>(
                          future: _rowsFuture,
                          builder: (context, snapshot) {
                            if (snapshot.connectionState == ConnectionState.waiting) {
                              return _miniCard(
                                child: const Center(
                                  child: Padding(
                                    padding: EdgeInsets.all(20),
                                    child: CircularProgressIndicator(
                                      color: AppColors.maroon900,
                                    ),
                                  ),
                                ),
                              );
                            }
                            if (snapshot.hasError) {
                              return _miniCard(
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Text(
                                    'Couldn\u2019t build the message preview.',
                                    textAlign: TextAlign.center,
                                    style: GoogleFonts.inter(
                                      color: AppColors.ink900.withValues(alpha: 0.7),
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                              );
                            }
                            final rows = snapshot.data ?? const <ReportRow>[];
                            return _messageCard(rows);
                          },
                        ),
                        const SizedBox(height: 14),
                        _sectionLabel('Attachment'),
                        _attachmentCard(),
                      ],
                    ),
                  ),
                  _bottomBar(),
                ],
              ),
      ),
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

  Widget _miniCard({required Widget child}) {
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: const BorderSide(color: AppColors.sand200, width: 1),
      ),
      child: child,
    );
  }

  Widget _recipientCard() {
    return _miniCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.mark_email_unread_outlined, size: 20, color: AppColors.maroon700),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _department.name,
                    style: GoogleFonts.inter(
                      color: AppColors.ink900,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _department.hodEmail ?? 'No HOD email on file',
                    style: GoogleFonts.inter(
                      color: (_department.hodEmail ?? '').isEmpty
                          ? AppColors.ink900.withValues(alpha: 0.4)
                          : AppColors.ink900.withValues(alpha: 0.7),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            TextButton(onPressed: _sending ? null : _changeHod, child: const Text('Change')),
          ],
        ),
      ),
    );
  }

  Widget _subjectCard() {
    return _miniCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          reportMailSubject(
            department: _department.name,
            start: widget.startDate,
            end: widget.endDate,
          ),
          style: GoogleFonts.inter(color: AppColors.ink900, fontSize: 15),
        ),
      ),
    );
  }

  Widget _messageCard(List<ReportRow> rows) {
    final summary = summarizeReport(rows);
    final body = buildReportMailBodyPreview(
      department: _department.name,
      start: widget.startDate,
      end: widget.endDate,
      rows: rows,
      totalLateEntries: summary.totalLateEntries,
      distinctStudents: summary.distinctStudents,
    );
    return _miniCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${summary.totalLateEntries} late entries, ${summary.distinctStudents} '
              '${summary.distinctStudents == 1 ? 'student' : 'students'}',
              style: GoogleFonts.inter(
                color: AppColors.maroon700,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            const Divider(color: AppColors.sand200, height: 1),
            const SizedBox(height: 10),
            Text(body, style: GoogleFonts.inter(color: AppColors.ink900, fontSize: 13, height: 1.5)),
          ],
        ),
      ),
    );
  }

  Widget _attachmentCard() {
    return _miniCard(
      child: FutureBuilder<List<ReportRow>>(
        future: _rowsFuture,
        builder: (context, snapshot) {
          final rows = snapshot.data ?? const <ReportRow>[];
          final tiers = rows.map((r) => yearTier(r.year)).toSet();
          final names = reportMailAttachmentNames(
            department: _department.id,
            start: widget.startDate,
            end: widget.endDate,
            mode: _mode,
            tiers: tiers,
          );
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<ReportMailMode>(
                    segments: const [
                      ButtonSegment(value: ReportMailMode.combined, label: Text('Combined')),
                      ButtonSegment(value: ReportMailMode.split, label: Text('Split by year')),
                    ],
                    selected: {_mode},
                    onSelectionChanged: (selection) {
                      setState(() => _mode = selection.first);
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
                ),
                if (snapshot.connectionState == ConnectionState.waiting)
                  const Padding(
                    padding: EdgeInsets.only(top: 16),
                    child: Center(child: CircularProgressIndicator(color: AppColors.maroon900)),
                  )
                else if (snapshot.hasError)
                  const Padding(
                    padding: EdgeInsets.only(top: 14),
                    child: Text('Attachment names unavailable.'),
                  )
                else ...[
                  const SizedBox(height: 16),
                  for (final name in names)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          const Icon(Icons.attach_file, size: 16, color: AppColors.ink900),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              name,
                              style: tabular(GoogleFonts.inter(
                                color: AppColors.ink900.withValues(alpha: 0.75),
                                fontSize: 13,
                              )),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _bottomBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: FilledButton(
        onPressed: _sending ? null : _confirmSend,
        child: _sending
            ? const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
                  ),
                  SizedBox(width: 12),
                  Text('Sending\u2026'),
                ],
              )
            : const Text('Confirm Send'),
      ),
    );
  }

  Widget _successView() {
    final result = _result!;
    final queued = result.outcome == MailRequestOutcome.queued;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: const BoxDecoration(
                color: AppColors.statusOk,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check, color: Colors.white, size: 36),
            ),
            const SizedBox(height: 18),
            Text(
              queued ? 'Report queued for sending' : 'Report sent to the HOD',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                color: AppColors.ink900,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              queued
                  ? 'The office machine will send it to ${_department.hodEmail ?? _department.name} \u2014 check Mail Logs shortly.'
                  : '${_department.name} (${_department.hodEmail ?? 'no email'}) will receive the attached report.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                color: AppColors.ink900.withValues(alpha: 0.7),
                fontSize: 14,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 22),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }
}