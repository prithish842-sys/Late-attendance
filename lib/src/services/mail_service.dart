import 'package:cloud_functions/cloud_functions.dart';

import '../config/app_config.dart';
import '../models/app_models.dart';
import 'firestore_service.dart';

/// How the app requests an HOD escalation mail (docs/NOTES.md "Blaze switch").
///
/// The *decision* of what is sent is always server-authoritative: the server
/// resolves departments/HOD emails, bundles the escalated students, attaches the
/// late-dates report, and writes `mail_logs` (SECURITY.md §1, §5). The app only
/// expresses *intent* — "notify B.Sc CS about these students" — exactly like a
/// scan is an intent for the server to count.
///
///   - Spark (default): a mail `mail_queue` doc is created (the only
///     client-writable Phase-3 path, firestore.rules). The Admin-SDK runner
///     (scripts/process-mail.js) consumes the queue and sends via Resend.
///   - Blaze (`--dart-define=BLAZE_ENABLED=true`): calls the `sendEscalationMail`
///     HttpsCallable (functions/index.js) directly — same guard rails (role
///     pt_sir/admin, escalation_queue data it owns) enforced server-side.
abstract class MailService {
  Future<MailSendResult> requestEscalationMail({
    required DepartmentInfo department,
    required String period,
    required List<String> studentIds,
    required String requestedBy,
  });

  factory MailService.from(FirestoreService firestore) {
    return AppConfig.blazeEnabled
        ? CloudMailService(firestore)
        : QueuedMailService(firestore);
  }
}

/// Spark fallback — enqueue the request into `mail_queue` for
/// scripts/process-mail.js to process.
class QueuedMailService implements MailService {
  const QueuedMailService(this._firestore);

  final FirestoreService _firestore;

  @override
  Future<MailSendResult> requestEscalationMail({
    required DepartmentInfo department,
    required String period,
    required List<String> studentIds,
    required String requestedBy,
  }) async {
    await _firestore.enqueueMailRequest(
      departmentId: department.id,
      department: department.name,
      period: period,
      studentIds: studentIds,
      requestedBy: requestedBy,
    );
    return const MailSendResult.queued();
  }
}

/// Blaze implementation — the Cloud Function sends immediately and records
/// `mail_logs`. The `firestore` argument keeps the factory call sites uniform;
/// the callable is the authoritative path on this plan.
class CloudMailService implements MailService {
  const CloudMailService(FirestoreService firestore);

  @override
  Future<MailSendResult> requestEscalationMail({
    required DepartmentInfo department,
    required String period,
    required List<String> studentIds,
    required String requestedBy,
  }) async {
    final callable = FirebaseFunctions.instance.httpsCallable('sendEscalationMail');
    await callable.call({
      'departmentId': department.id,
      'period': period,
      'studentIds': studentIds,
    });
    return const MailSendResult.sent();
  }
}