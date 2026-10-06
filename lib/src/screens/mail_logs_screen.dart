import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/app_models.dart';
import '../services/firestore_service.dart';
import '../theme/app_theme.dart';

/// Read-only HOD mail audit trail (Mail Logs, docs-new-updates/NEW_TASKS.md
/// Phase 2). The `mail_logs` collection is written exclusively by the send
/// pipeline (Cloud Function / Admin-SDK runner — firestore.rules); staff only
/// read it here. Escalation mails and report mails share the collection, so the
/// type badge keeps them distinguishable.
class MailLogsScreen extends StatefulWidget {
  const MailLogsScreen({super.key, required this.firestore});

  final FirestoreService firestore;

  @override
  State<MailLogsScreen> createState() => _MailLogsScreenState();
}

class _MailLogsScreenState extends State<MailLogsScreen> {
  late Future<List<MailLogEntry>> _logsFuture;

  @override
  void initState() {
    super.initState();
    _logsFuture = widget.firestore.recentMailLogs(limit: 60);
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
          'Mail Logs',
          style: GoogleFonts.inter(
            color: AppColors.navy900,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: SafeArea(
        child: FutureBuilder<List<MailLogEntry>>(
          future: _logsFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(
                child: CircularProgressIndicator(color: AppColors.maroon900),
              );
            }
            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_off, size: 34, color: AppColors.ink900),
                      const SizedBox(height: 10),
                      Text(
                        'Couldn\u2019t load the mail logs. Check the network and try again.',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.inter(
                          color: AppColors.ink900.withValues(alpha: 0.7),
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 6),
                      TextButton(
                        onPressed: () => setState(
                          () => _logsFuture = widget.firestore.recentMailLogs(limit: 60),
                        ),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              );
            }
            final logs = snapshot.data ?? const <MailLogEntry>[];
            if (logs.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'No mails sent yet. Reports, escalations and weekly audits addressed to HODs '
                    'will appear here.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                      color: AppColors.ink900.withValues(alpha: 0.7),
                      fontSize: 14,
                    ),
                  ),
                ),
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              itemCount: logs.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) => _logCard(logs[index]),
            );
          },
        ),
      ),
    );
  }

  Widget _logCard(MailLogEntry entry) {
    final report = entry.isReport;
    final weekly = entry.isWeeklyAudit;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: const BorderSide(color: AppColors.sand200, width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _badge(
                  weekly ? 'Weekly Audit' : (report ? 'Report' : 'Escalation'),
                  weekly
                      ? AppColors.statusWarn
                      : (report ? AppColors.maroon900 : AppColors.navy900),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    entry.department.isEmpty ? 'Unknown department' : entry.department,
                    style: GoogleFonts.inter(
                      color: AppColors.navy900,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  _fmtTime(entry.sentTimestamp),
                  style: tabular(GoogleFonts.inter(
                    color: AppColors.ink900.withValues(alpha: 0.6),
                    fontSize: 12,
                  )),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              entry.subject.isEmpty ? 'Late Attendance mail' : entry.subject,
              style: GoogleFonts.inter(color: AppColors.ink900, fontSize: 14),
            ),
            const SizedBox(height: 4),
            Text(
              'To: ${entry.to.isEmpty ? 'unknown' : entry.to}',
              style: GoogleFonts.inter(
                color: AppColors.ink900.withValues(alpha: 0.6),
                fontSize: 13,
              ),
            ),
            if (entry.label != null || entry.period.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  entry.label ?? 'Period: ${entry.period}',
                  style: GoogleFonts.inter(
                    color: AppColors.ink900.withValues(alpha: 0.6),
                    fontSize: 13,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '${entry.studentsIncluded} '
                '${entry.studentsIncluded == 1 ? 'student' : 'students'} reported',
                style: tabular(GoogleFonts.inter(
                  color: AppColors.maroon700,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                )),
              ),
            ),
            if (entry.files.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final name in entry.files)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Row(
                          children: [
                            const Icon(Icons.attach_file, size: 14, color: AppColors.ink900),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                name,
                                style: tabular(GoogleFonts.inter(
                                  color: AppColors.ink900.withValues(alpha: 0.7),
                                  fontSize: 12,
                                )),
                              ),
                            ),
                          ],
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

  Widget _badge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  String _fmtTime(DateTime? ts) {
    if (ts == null) return 'time unknown';
    final l = ts.toLocal();
    final mm = l.month.toString().padLeft(2, '0');
    final dd = l.day.toString().padLeft(2, '0');
    final hh = l.hour.toString().padLeft(2, '0');
    final mi = l.minute.toString().padLeft(2, '0');
    return '${l.year}-$mm-$dd $hh:$mi';
  }
}