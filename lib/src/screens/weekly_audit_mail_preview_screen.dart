import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/app_models.dart';
import '../services/callable_errors.dart';
import '../services/firestore_service.dart';
import '../services/weekly_audit_mail_service.dart';
import '../theme/app_theme.dart';

/// Weekly audit mail preview (docs-new-updates/NEW_AUDIT_WORKFLOW.md): PT sir /
/// admin review the HOD recipient, subject, the repeated-students message and
/// the PDF + Excel attachment names before confirming. Confirming expresses
/// *intent* only — `weekStart` (the Monday) is sent; the server re-aggregates
/// the week server-authoritatively and sends the authoritative mail + mail_logs
/// row (functions/weekly-audit-sender.js).
class WeeklyAuditMailPreviewScreen extends StatefulWidget {
  WeeklyAuditMailPreviewScreen({
    super.key,
    required this.firestore,
    required this.userId,
    required this.department,
    required this.weekStart,
    required this.group,
    WeeklyAuditMailService? mailService,
  }) : mailService = mailService ?? WeeklyAuditMailService.from(firestore);

  final FirestoreService firestore;
  final String userId;
  final DepartmentInfo department;
  final DateTime weekStart;
  final WeeklyAuditGroup group;
  final WeeklyAuditMailService mailService;

  @override
  State<WeeklyAuditMailPreviewScreen> createState() => _WeeklyAuditMailPreviewScreenState();
}

class _WeeklyAuditMailPreviewScreenState extends State<WeeklyAuditMailPreviewScreen> {
  bool _sending = false;
  MailSendResult? _result;

  Future<void> _confirmSend() async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      final result = await widget.mailService.sendWeeklyAuditMail(
        request: WeeklyAuditMailRequest(
          department: widget.department,
          weekStart: widget.weekStart,
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
                'The weekly audit mail couldn\u2019t be sent \u2014 check the network and try again.',
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
    final group = widget.group;
    final repeated = group.repeated;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          'Weekly Audit Mail',
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
                        _messageCard(repeated),
                        const SizedBox(height: 14),
                        _sectionLabel('Attachment'),
                        _attachmentCard(),
                      ],
                    ),
                  ),
                  _bottomBar(group),
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
    final hod = widget.department.hodEmail ?? '';
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
                    widget.department.name,
                    style: GoogleFonts.inter(
                      color: AppColors.ink900,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hod,
                    style: GoogleFonts.inter(
                      color: AppColors.ink900.withValues(alpha: 0.7),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
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
          weeklyAuditSubject(
            department: widget.department.name,
            weekStart: widget.weekStart,
          ),
          style: GoogleFonts.inter(color: AppColors.ink900, fontSize: 15),
        ),
      ),
    );
  }

  Widget _messageCard(List<WeeklyStudentView> repeated) {
    final body = buildWeeklyAuditBodyPreview(
      department: widget.department.name,
      weekStart: widget.weekStart,
      group: widget.group,
    );
    return _miniCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.group.uniqueStudents} students, ${widget.group.totalEvents} late entries, '
              '${repeated.length} repeated this week',
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
    final names = weeklyAuditAttachmentNames(
      department: widget.department.id,
      weekStart: widget.weekStart,
    );
    return _miniCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
        ),
      ),
    );
  }

  Widget _bottomBar(WeeklyAuditGroup group) {
    final enabled = !_sending && group.totalEvents > 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: FilledButton(
        onPressed: enabled ? _confirmSend : null,
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
    final hod = widget.department.hodEmail ?? widget.department.name;
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
              queued ? 'Weekly audit queued for sending' : 'Weekly audit sent to the HOD',
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
                  ? 'The office machine will send it to $hod \u2014 check Mail Logs shortly.'
                  : '${widget.department.name} ($hod) will receive the attached audit.',
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