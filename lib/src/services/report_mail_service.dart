import 'package:cloud_functions/cloud_functions.dart';

import '../config/app_config.dart';
import '../models/app_models.dart';
import 'firestore_service.dart';

/// How the app sends a HOD attendance report (docs-new-updates/NEW_TASKS.md
/// Phase 2, NEW_REPORT_MAIL_WORKFLOW.md).
///
/// The mail itself is always server-authoritative (SECURITY.md §1, §8): the
/// server resolves the HOD recipient, rebuilds the filtered rows from
/// late_logs/students, attaches the PDF(s)/Excel and writes the `mail_logs`
/// audit row. The app only expresses *intent* — "send the September report for
/// B.Sc CS to its HOD" — exactly like a scan is an intent for the server to
/// count (docs/NOTES.md "Blaze switch").
///
///   - Spark (default): a `mail_queue` doc with `type:"report"` is created for
///     scripts/process-mail.js to process (same audit-gated create rule as the
///     escalation mail enqueue, firestore.rules).
///   - Blaze (`--dart-define=BLAZE_ENABLED=true`): calls the `sendReportMail`
///     HttpsCallable (functions/index.js) directly — same guard rails (role
///     pt_sir/admin) enforced server-side.
abstract class ReportMailService {
  Future<MailSendResult> sendReportMail({
    required ReportMailRequest request,
    required String requestedBy,
  });

  factory ReportMailService.from(FirestoreService firestore) {
    return AppConfig.blazeEnabled
        ? CloudReportMailService(firestore)
        : QueuedReportMailService(firestore);
  }
}

/// Spark fallback — enqueue the request into `mail_queue` (type "report") for
/// scripts/process-mail.js to process on the office machine.
class QueuedReportMailService implements ReportMailService {
  const QueuedReportMailService(this._firestore);

  final FirestoreService _firestore;

  @override
  Future<MailSendResult> sendReportMail({
    required ReportMailRequest request,
    required String requestedBy,
  }) async {
    await _firestore.enqueueReportMail(
      departmentId: request.department.id,
      department: request.department.name,
      periodType: request.periodType.name,
      startDate: dayKey(request.startDate),
      endDate: dayKey(request.endDate),
      attachmentMode: request.mode.name,
      year: request.year,
      requestedBy: requestedBy,
    );
    return const MailSendResult.queued();
  }
}

/// Blaze implementation — the Cloud Function sends immediately and records
/// `mail_logs`. The `firestore` argument keeps the factory call sites uniform;
/// the callable is the authoritative path on this plan.
class CloudReportMailService implements ReportMailService {
  const CloudReportMailService(FirestoreService firestore);

  @override
  Future<MailSendResult> sendReportMail({
    required ReportMailRequest request,
    required String requestedBy,
  }) async {
    final callable = FirebaseFunctions.instance.httpsCallable('sendReportMail');
    await callable.call({
      'departmentId': request.department.id,
      'periodType': request.periodType.name,
      'startDate': dayKey(request.startDate),
      'endDate': dayKey(request.endDate),
      'attachmentMode': request.mode.name,
      'year': request.year,
    });
    return const MailSendResult.sent();
  }
}