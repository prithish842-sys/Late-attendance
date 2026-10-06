import 'package:cloud_functions/cloud_functions.dart';

import '../config/app_config.dart';
import '../models/app_models.dart';
import 'firestore_service.dart';

/// How the app requests an attendance report (docs/NOTES.md "Blaze switch").
///
/// The report itself is always server-authoritative (SECURITY.md §1, §8): the
/// server resolves the window, joins late_logs with students, applies the
/// department/year filters, builds the Excel/PDF and records `report_logs`.
/// The app only expresses *intent* — "monthly report for B.Sc CS" — exactly
/// like a scan is an intent for the server to count.
///
///   - Spark (default): a `report_requests` doc is created (the only
///     client-writable Phase-4 path, firestore.rules). The Admin-SDK runner
///     (scripts/generate-report.js) consumes the queue and writes the files to
///     the office machine's reports/ folder.
///   - Blaze (`--dart-define=BLAZE_ENABLED=true`): calls the `generateReport`
///     HttpsCallable (functions/index.js) directly — same guard rails (role
///     pt_sir/admin) enforced server-side, files stored in Cloud Storage with
///     signed URLs returned.
abstract class ReportService {
  Future<ReportRequestResult> requestReport({
    required ReportFilters filters,
    required String requestedBy,
  });

  factory ReportService.from(FirestoreService firestore) {
    return AppConfig.blazeEnabled
        ? CloudReportService(firestore)
        : QueuedReportService(firestore);
  }
}

/// Spark fallback — enqueue the request into `report_requests` for
/// scripts/generate-report.js to process on the office machine.
class QueuedReportService implements ReportService {
  const QueuedReportService(this._firestore);

  final FirestoreService _firestore;

  @override
  Future<ReportRequestResult> requestReport({
    required ReportFilters filters,
    required String requestedBy,
  }) async {
    await _firestore.enqueueReportRequest(filters: filters, requestedBy: requestedBy);
    return const ReportRequestResult.queued();
  }
}

/// Blaze implementation — the Cloud Function generates immediately and
/// returns the storage paths/signed URLs. The `firestore` argument keeps the
/// factory call sites uniform; the callable is the authoritative path on this
/// plan.
class CloudReportService implements ReportService {
  const CloudReportService(FirestoreService firestore);

  @override
  Future<ReportRequestResult> requestReport({
    required ReportFilters filters,
    required String requestedBy,
  }) async {
    final callable = FirebaseFunctions.instance.httpsCallable('generateReport');
    final data = await callable.call({
      'periodType': filters.periodType.name,
      'startDate': dayKey(filters.startDate),
      'endDate': dayKey(filters.endDate),
      'department': filters.department?.id,
      'year': filters.year,
    });
    final map = data.data is Map
        ? Map<String, dynamic>.from(data.data as Map)
        : const <String, dynamic>{};
    return ReportRequestResult.generated(
      xlsxUrl: map['xlsxUrl'] as String?,
      pdfUrl: map['pdfUrl'] as String?,
      stats: map['stats'] == null
          ? null
          : ReportSummary.fromCallable(Map<String, dynamic>.from(map['stats'] as Map)),
    );
  }
}