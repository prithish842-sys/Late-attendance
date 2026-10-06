import 'package:cloud_functions/cloud_functions.dart';

import '../config/app_config.dart';
import '../models/app_models.dart';
import 'firestore_service.dart';

/// How the app sends the weekly audit to a department HOD
/// (docs-new-updates/NEW_TASKS.md Phase 3, NEW_AUDIT_WORKFLOW.md).
///
/// The mail is always server-authoritative (SECURITY.md §1, §8): the server
/// re-resolves the Monday→Sunday window, rebuilds the week's rows, aggregates
/// them (functions/weekly-audit-core.js), attaches the PDF + Excel and writes
/// the `mail_logs` audit row. The app only expresses *intent* — "send this
/// week's audit for B.Sc CS to its HOD" — exactly like a scan is an intent.
///
///   - Spark (default): a `mail_queue` doc with `type:"weekly_audit"` is created
///     for scripts/process-mail.js to process (the same audit-gated create rule
///     as the report/escalation mail enqueues, firestore.rules).
///   - Blaze (`--dart-define=BLAZE_ENABLED=true`): calls the `sendWeeklyAuditMail`
///     HttpsCallable (functions/index.js) directly — same guard rails (role
///     pt_sir/admin) enforced server-side.
abstract class WeeklyAuditMailService {
  Future<MailSendResult> sendWeeklyAuditMail({
    required WeeklyAuditMailRequest request,
    required String requestedBy,
  });

  factory WeeklyAuditMailService.from(FirestoreService firestore) {
    return AppConfig.blazeEnabled
        ? CloudWeeklyAuditMailService(firestore)
        : QueuedWeeklyAuditMailService(firestore);
  }
}

/// Spark fallback — enqueue the request into `mail_queue` (type "weekly_audit")
/// for scripts/process-mail.js to process on the office machine.
class QueuedWeeklyAuditMailService implements WeeklyAuditMailService {
  const QueuedWeeklyAuditMailService(this._firestore);

  final FirestoreService _firestore;

  @override
  Future<MailSendResult> sendWeeklyAuditMail({
    required WeeklyAuditMailRequest request,
    required String requestedBy,
  }) async {
    await _firestore.enqueueWeeklyAuditMail(
      departmentId: request.department.id,
      department: request.department.name,
      startDate: dayKey(request.weekStart),
      requestedBy: requestedBy,
    );
    return const MailSendResult.queued();
  }
}

/// Blaze implementation — the Cloud Function aggregates and sends immediately,
/// recording `mail_logs`. The `firestore` argument keeps the factory call sites
/// uniform; the callable is the authoritative path on this plan.
class CloudWeeklyAuditMailService implements WeeklyAuditMailService {
  const CloudWeeklyAuditMailService(FirestoreService firestore);

  @override
  Future<MailSendResult> sendWeeklyAuditMail({
    required WeeklyAuditMailRequest request,
    required String requestedBy,
  }) async {
    final callable = FirebaseFunctions.instance.httpsCallable('sendWeeklyAuditMail');
    await callable.call({
      'departmentId': request.department.id,
      'startDate': dayKey(request.weekStart),
    });
    return const MailSendResult.sent();
  }
}