import '../config/app_config.dart';
import '../models/app_models.dart';
import 'firestore_service.dart';

/// How the app obtains the escalation verdict for a student.
///
/// The verdict itself is ALWAYS server-authoritative (docs/SECURITY.md §1) — the
/// app only reads and displays it. This abstraction exists so the *read path*
/// can differ between plans without touching call sites:
///
///   - Spark (default): `escalation_queue` is populated by the Admin-SDK runner
///     (scripts/process-escalation.js). The app reads that collection directly.
///   - Blaze: `myCloudEscalationService` is the hop-in replacement when
///     `--dart-define=BLAZE_ENABLED=true` is set — same method signature, so the
///     Cloud Function (functions/index.js) can own the queue and this service
///     can still share/derive from it without call-site changes.
///
/// Build with Blaze routing:  flutter build apk --dart-define=BLAZE_ENABLED=true
abstract class EscalationService {
  Stream<EscalationVerdict?> verdictFor(String studentId);

  /// Picks the implementation for the current plan. The single config flag is
  /// AppConfig.blazeEnabled (`--dart-define=BLAZE_ENABLED=true`); flipping it
  /// routes the SAME call site to the Blaze implementation with zero rewrites.
  factory EscalationService.from(FirestoreService firestore) {
    return AppConfig.blazeEnabled
        ? CloudEscalationService(firestore)
        : FirestoreEscalationService(firestore);
  }
}

/// Spark fallback — reads `escalation_queue` populated by the Admin-SDK runner
/// (scripts/process-escalation.js). Server-authoritative, read-only client.
class FirestoreEscalationService implements EscalationService {
  const FirestoreEscalationService(this._firestore);

  final FirestoreService _firestore;

  @override
  Stream<EscalationVerdict?> verdictFor(String studentId) {
    return _firestore.escalationVerdict(studentId);
  }
}

/// Blaze implementation. The Cloud Function (functions/index.js) owns the
/// escalation_queue via an onCreate trigger; the verdict is read from the same
/// documents the function writes — identical app code, backed by the server
/// trigger instead of the runner.
class CloudEscalationService implements EscalationService {
  const CloudEscalationService(this._firestore);

  final FirestoreService _firestore;

  @override
  Stream<EscalationVerdict?> verdictFor(String studentId) {
    return _firestore.escalationVerdict(studentId);
  }
}