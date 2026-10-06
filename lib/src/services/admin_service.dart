import 'package:cloud_functions/cloud_functions.dart';

import '../config/app_config.dart';
import '../models/app_models.dart';
import 'firestore_service.dart';

/// Phase 4 admin lifecycle operations (docs-new-updates/NEW_TASKS.md Phase 4).
///
/// Destructive state changes (student import/soft delete/restore/permanent
/// delete) are ALWAYS server-authoritative (SECURITY.md §1, NEW_SECURITY.md):
/// the client validates the preview locally for UX, sends raw intent, and the
/// server re-validates against fresh departments + the current roster, applies
/// the change and writes the audit/evidence rows.
///
///   - Spark (default): an `admin_requests` doc is created for
///     scripts/process-admin.js to consume (create is admin-gated in
///     firestore.rules).
///   - Blaze (`--dart-define=BLAZE_ENABLED=true`): calls the
///     `commitImportBatch` / `adminSoftDelete` / `adminRestore` /
///     `adminPermanentDelete` HttpsCallables (functions/index.js), which
///     enforce requireAdminRole server-side.
abstract class AdminService {
  Future<AdminActionResult> commitImportBatch({
    required String importId,
    required String filename,
    String departmentId,
    required String department,
    required List<ImportRow> rows,
    required String requestedBy,
  });

  Future<AdminActionResult> softDelete({
    required List<String> studentIds,
    required String reason,
    required String requestedBy,
  });

  Future<AdminActionResult> restore({
    required List<String> studentIds,
    required String requestedBy,
  });

  Future<AdminActionResult> permanentDelete({
    required List<String> studentIds,
    required String requestedBy,
  });

  factory AdminService.from(FirestoreService firestore) {
    return AppConfig.blazeEnabled
        ? CloudAdminService(firestore)
        : QueuedAdminService(firestore);
  }
}

/// Spark fallback — enqueue each intent into `admin_requests` for
/// scripts/process-admin.js to apply on the office machine.
class QueuedAdminService implements AdminService {
  const QueuedAdminService(this._firestore);

  final FirestoreService _firestore;

  @override
  Future<AdminActionResult> commitImportBatch({
    required String importId,
    required String filename,
    String departmentId = '',
    required String department,
    required List<ImportRow> rows,
    required String requestedBy,
  }) async {
    if (rows.isEmpty) {
      throw ArgumentError('Nothing to import — the sheet has no rows.');
    }
    await _firestore.enqueueAdminRequest(
      type: 'import_batch',
      importId: importId,
      filename: filename,
      departmentId: departmentId.isEmpty ? null : departmentId,
      department: department,
      rows: rows,
      requestedBy: requestedBy,
    );
    return const AdminActionResult.queued();
  }

  @override
  Future<AdminActionResult> softDelete({
    required List<String> studentIds,
    required String reason,
    required String requestedBy,
  }) async {
    if (studentIds.isEmpty) throw ArgumentError('No students selected.');
    await _firestore.enqueueAdminRequest(
      type: 'soft_delete',
      studentIds: studentIds,
      reason: reason,
      requestedBy: requestedBy,
    );
    return const AdminActionResult.queued();
  }

  @override
  Future<AdminActionResult> restore({
    required List<String> studentIds,
    required String requestedBy,
  }) async {
    if (studentIds.isEmpty) throw ArgumentError('No students selected.');
    await _firestore.enqueueAdminRequest(
      type: 'restore',
      studentIds: studentIds,
      requestedBy: requestedBy,
    );
    return const AdminActionResult.queued();
  }

  @override
  Future<AdminActionResult> permanentDelete({
    required List<String> studentIds,
    required String requestedBy,
  }) async {
    if (studentIds.isEmpty) throw ArgumentError('No students selected.');
    await _firestore.enqueueAdminRequest(
      type: 'permanent_delete',
      studentIds: studentIds,
      requestedBy: requestedBy,
    );
    return const AdminActionResult.queued();
  }
}

/// Blaze implementation — the Cloud Functions run synchronously and return the
/// actual outcome (commit/affected/skipped counts) for the screen to confirm.
/// The `firestore` argument keeps the factory call sites uniform; the callable
/// is the authoritative path on this plan.
class CloudAdminService implements AdminService {
  const CloudAdminService(FirestoreService firestore);

  @override
  Future<AdminActionResult> commitImportBatch({
    required String importId,
    required String filename,
    String departmentId = '',
    required String department,
    required List<ImportRow> rows,
    required String requestedBy,
  }) async {
    if (rows.isEmpty) throw ArgumentError('Nothing to import — the sheet has no rows.');
    final callable = FirebaseFunctions.instance.httpsCallable('commitImportBatch');
    final result = await callable.call({
      'importId': importId,
      'filename': filename,
      if (departmentId.isNotEmpty) 'departmentId': departmentId,
      'department': department,
      'rows': rows
          .map((r) => {
                'registerNumber': r.registerNumber.trim().toUpperCase(),
                'name': r.name.trim(),
                'department': r.department.trim(),
                'currentYear': r.currentYear,
                'batchStartYear': r.batchStartYear,
                'batchEndYear': r.batchEndYear,
                'photoUrl': r.photoUrl,
              })
          .toList(),
    });
    final data = (result.data as Map?) ?? const <String, dynamic>{};
    ImportCounts? counts;
    if (data['counts'] is Map) {
      final c = Map<String, dynamic>.from(data['counts'] as Map);
      counts = ImportCounts(
        rows: (c['rows'] as num?)?.toInt() ?? 0,
        valid: (c['valid'] as num?)?.toInt() ?? 0,
        invalid: (c['invalid'] as num?)?.toInt() ?? 0,
        warnings: (c['warnings'] as num?)?.toInt() ?? 0,
      );
    }
    return AdminActionResult.applied(
      added: (data['committed'] as num?)?.toInt() ?? 0,
      counts: counts,
    );
  }

  @override
  Future<AdminActionResult> softDelete({
    required List<String> studentIds,
    required String reason,
    required String requestedBy,
  }) async {
    if (studentIds.isEmpty) throw ArgumentError('No students selected.');
    final callable = FirebaseFunctions.instance.httpsCallable('adminSoftDelete');
    final result = await callable.call({
      'studentIds': studentIds,
      'reason': reason,
      'requestedBy': requestedBy,
    });
    return _affectedResult(result.data);
  }

  @override
  Future<AdminActionResult> restore({
    required List<String> studentIds,
    required String requestedBy,
  }) async {
    if (studentIds.isEmpty) throw ArgumentError('No students selected.');
    final callable = FirebaseFunctions.instance.httpsCallable('adminRestore');
    final result = await callable.call({
      'studentIds': studentIds,
      'requestedBy': requestedBy,
    });
    return _affectedResult(result.data);
  }

  @override
  Future<AdminActionResult> permanentDelete({
    required List<String> studentIds,
    required String requestedBy,
  }) async {
    if (studentIds.isEmpty) throw ArgumentError('No students selected.');
    final callable = FirebaseFunctions.instance.httpsCallable('adminPermanentDelete');
    final result = await callable.call({
      'studentIds': studentIds,
      'requestedBy': requestedBy,
    });
    return _affectedResult(result.data);
  }

  AdminActionResult _affectedResult(dynamic raw) {
    final data = (raw as Map?) ?? const <String, dynamic>{};
    return AdminActionResult.applied(
      added: 0,
      affected: (data['affected'] as num?)?.toInt() ?? 0,
      skipped: (data['skipped'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Deterministic import id for a sheet — stable for the same uploaded bytes, so
/// re-committing the same file is an idempotent no-op server-side (the import
/// is keyed by importId), while different files get different ids.
String importIdForBytes(List<int> bytes) {
  var h1 = 0x811c9dc5;
  var h2 = 0x01000193;
  for (final b in bytes) {
    h1 = ((h1 ^ b) * 0x01000193) & 0xffffffff;
    h2 = ((h2 * 31) + b) & 0xffffffff;
  }
  return 'imp_${h1.toRadixString(16)}${h2.toRadixString(16)}';
}