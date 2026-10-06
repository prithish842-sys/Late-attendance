import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/app_models.dart';
import '../services/auth_service.dart';
import '../services/callable_errors.dart';
import '../services/firestore_service.dart';
import '../services/mail_service.dart';
import '../theme/app_theme.dart';
import '../widgets/escalated_rule.dart';

const _mailRoles = {'pt_sir', 'admin'};

String _currentPeriod() {
  final now = DateTime.now();
  final mm = now.month.toString().padLeft(2, '0');
  return '${now.year}-$mm';
}

/// HOD escalation mail screen (docs/TASKS.md Phase 3). Read-only for all staff;
/// PT sir / admin additionally see a per-department "send mail" action.
/// One mail is produced per selected department — the server bundles that
/// department's escalated students (photos, late dates, xlsx + pdf report) into
/// a single mail to the HOD (functions/mail-sender.js), because that bundling
/// is exactly what the HOD asked for in the PRD. Multi-department selections
/// just enqueue one mail each. On Spark those are `mail_queue` requests consumed
/// by scripts/process-mail.js; on Blaze the Cloud Function sends immediately.
class EscalationScreen extends StatefulWidget {
  EscalationScreen({
    super.key,
    required this.auth,
    required this.firestore,
    required this.userId,
    MailService? mail,
    String? period,
  })  : mail = mail ?? MailService.from(firestore),
        period = period ?? _currentPeriod();

  final AuthService auth;
  final FirestoreService firestore;
  final String userId;
  final MailService mail;
  final String period;

  @override
  State<EscalationScreen> createState() => _EscalationScreenState();
}

class _EscalationScreenState extends State<EscalationScreen> {
  late Future<List<EscalationGroup>> _groupsFuture;
  final Set<String> _selected = {};
  bool? _canSend;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _groupsFuture = widget.firestore.escalatedGroups(widget.period);
    _loadRole();
  }

  Future<void> _loadRole() async {
    final role = await widget.auth.currentUserRole;
    if (!mounted) return;
    setState(() => _canSend = _mailRoles.contains(role));
  }

  Future<void> _retry() {
    setState(() {
      _selected.clear();
      _groupsFuture = widget.firestore.escalatedGroups(widget.period);
    });
    return _groupsFuture;
  }

  Future<void> _send() async {
    final groups = await _groupsFuture;
    final targets = groups.where((g) => _selected.contains(g.department)).toList();
    if (targets.isEmpty || _sending) return;
    setState(() => _sending = true);

    // Send one-by-one, stopping at the first failure: retrying blindly would
    // either duplicate the successful sends or burn the hourly quota, and only
    // what actually went out may leave the selection (review finding HIGH-2).
    final sent = <String>[];
    String? rateMessage;
    String? errorMessage;
    for (final g in targets) {
      final dept = g.deptInfo;
      if (dept == null) continue;
      try {
        await widget.mail.requestEscalationMail(
          department: dept,
          period: widget.period,
          studentIds: g.students.map((e) => e.studentId).toList(),
          requestedBy: widget.userId,
        );
        sent.add(g.department);
      } on Exception catch (e) {
        final rate = rateLimitOf(e);
        rateMessage = rate?.message;
        errorMessage = 'The mail couldn\u2019t be requested \u2014 check the network and try again.';
        break;
      }
    }
    if (!mounted) return;
    final sentGroups = targets.where((g) => sent.contains(g.department)).toList();
    setState(() {
      _sending = false;
      _selected.removeAll(sent);
    });
    final messenger = ScaffoldMessenger.of(context);
    if (rateMessage != null || errorMessage != null) {
      final sentNames = sentGroups.map((g) => g.deptInfo?.name ?? g.department).join(', ');
      final sentNote = sentNames.isEmpty
          ? ''
          : ' Sent so far: $sentNames \u2014 select them again to resend.';
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${rateMessage ?? errorMessage}$sentNote',
            style: const TextStyle(fontSize: 14),
          ),
        ),
      );
      return;
    }
    final names = sentGroups.map((g) => g.deptInfo?.name ?? g.department).join(', ');
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          sentGroups.length == 1
              ? 'Mail requested for $names — the office will send it to ${sentGroups.first.deptInfo?.hodEmail ?? 'the HOD'}.'
              : 'Mail requested for $names.',
          style: GoogleFonts.inter(fontSize: 14),
        ),
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
          'Escalations',
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
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
            child: Row(
              children: [
                Text(
                  _monthLabel(widget.period),
                  style: GoogleFonts.inter(
                    color: AppColors.ink900.withValues(alpha: 0.7),
                    fontSize: 14,
                  ),
                ),
                const Spacer(),
                if (_canSend == true)
                  Text(
                    'Send to the HOD',
                    style: GoogleFonts.inter(
                      color: AppColors.maroon700,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(child: _buildBody()),
          _buildBottomBar(),
        ],
      ),
    );
  }

  Widget _buildBody() {
    return FutureBuilder<List<EscalationGroup>>(
      future: _groupsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(color: AppColors.maroon900));
        }
        if (snapshot.hasError) {
          return _MessagePanel(
            icon: Icons.cloud_off,
            message: 'Couldn\u2019t load the escalations. Check the network and try again.',
            action: TextButton(onPressed: _retry, child: const Text('Retry')),
          );
        }
        final groups = snapshot.data ?? const <EscalationGroup>[];
        if (groups.isEmpty) {
          return const _MessagePanel(
            icon: Icons.check_circle_outline,
            message: 'No escalated students this period.',
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            for (final g in groups) _groupCard(g),
          ],
        );
      },
    );
  }

  Widget _groupCard(EscalationGroup g) {
    final canSelect = _canSend == true && g.deptInfo != null;
    final hod = g.deptInfo?.hodEmail;
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
            padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
            child: Row(
              children: [
                if (canSelect)
                  Checkbox(
                    value: _selected.contains(g.department),
                    onChanged: _sending
                        ? null
                        : (v) => setState(() {
                              if (v == true) {
                                _selected.add(g.department);
                              } else {
                                _selected.remove(g.department);
                              }
                            }),
                  )
                else if (g.deptInfo == null)
                  const Padding(
                    padding: EdgeInsets.only(left: 16),
                    child: Icon(Icons.warning_amber_rounded, size: 20, color: AppColors.statusWarn),
                  ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        g.deptInfo?.name ?? g.department,
                        style: GoogleFonts.inter(
                          color: AppColors.navy900,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        hod ?? (g.deptInfo == null ? 'HOD not on file' : 'No HOD email on file'),
                        style: GoogleFonts.inter(
                          color: hod == null ? AppColors.statusWarn : AppColors.ink900.withValues(alpha: 0.6),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  '${g.students.length}',
                  style: tabular(GoogleFonts.inter(
                    color: AppColors.maroon700,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  )),
                ),
                const SizedBox(width: 4),
                Text(
                  'escalated',
                  style: GoogleFonts.inter(
                    color: AppColors.ink900.withValues(alpha: 0.6),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          for (final e in g.students) _studentRow(e),
        ],
      ),
    );
  }

  Widget _studentRow(EscalationEntry e) {
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Row(
        children: [
          _avatar(e.photoBase64, e.name),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  e.name,
                  style: GoogleFonts.inter(
                    color: AppColors.ink900,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  e.studentId,
                  style: tabular(GoogleFonts.inter(
                    color: AppColors.ink900.withValues(alpha: 0.6),
                    fontSize: 13,
                  )),
                ),
              ],
            ),
          ),
          Text(
            '${e.verdict.count} late',
            style: tabular(GoogleFonts.inter(
              color: e.verdict.isEscalated ? AppColors.statusEscalate : AppColors.statusWarn,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            )),
          ),
        ],
      ),
    );
    return e.verdict.isEscalated ? EscalatedRule(child: row) : row;
  }

  Widget _avatar(String? base64, String name) {
    if (base64 != null && base64.isNotEmpty) {
      try {
        return ClipOval(
          child: SizedBox(
            width: 44,
            height: 44,
            child: Image.memory(
              base64Decode(base64),
              fit: BoxFit.cover,
              errorBuilder: (c, e, s) => _initialCircle(name),
            ),
          ),
        );
      } catch (_) {
        return _initialCircle(name);
      }
    }
    return _initialCircle(name);
  }

  Widget _initialCircle(String name) {
    return Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: const BoxDecoration(color: AppColors.sand200, shape: BoxShape.circle),
      child: Text(
        name.isEmpty ? '?' : name.substring(0, 1).toUpperCase(),
        style: GoogleFonts.inter(
          color: AppColors.navy900,
          fontSize: 16,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    final selectedCount = _selected.length;
    final enabled = (_canSend == true) && selectedCount > 0 && !_sending;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_canSend == false && _canSend != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  'Escalation mail can only be sent by the gate office (PT sir / admin).',
                  style: GoogleFonts.inter(
                    color: AppColors.ink900.withValues(alpha: 0.7),
                    fontSize: 14,
                  ),
                ),
              ),
            FilledButton(
              onPressed: _canSend == true ? (enabled ? _send : null) : null,
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
                        Text('Requesting\u2026'),
                      ],
                    )
                  : const Text('Send escalation mail'),
            ),
          ],
        ),
      ),
    );
  }

  String _monthLabel(String period) {
    final parts = period.split('-');
    if (parts.length != 2) return period;
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    final m = int.tryParse(parts[1]);
    if (m == null || m < 1 || m > 12) return period;
    return '${months[m - 1]} ${parts[0]}';
  }
}

class _MessagePanel extends StatelessWidget {
  const _MessagePanel({required this.icon, required this.message, this.action});

  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: AppColors.ink900.withValues(alpha: 0.4)),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                color: AppColors.ink900.withValues(alpha: 0.7),
                fontSize: 15,
              ),
            ),
            if (action != null) ...[
              const SizedBox(height: 8),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}