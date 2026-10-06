import 'package:firebase_auth/firebase_auth.dart';

/// Outcome of [AuthService.signIn]. `message == null` means success.
///
/// `countsAsFailure` marks credential failures that count toward the C1
/// 5-failures/15-min login ledger. Network errors and Firebase's own
/// `too-many-requests` throttle do NOT count — a flaky connection must never
/// lock the user out (review finding HIGH-3; mirrors admin-web's
/// describeAuthError.ts `signInFailure`).
class SignInOutcome {
  const SignInOutcome.success() : message = null, countsAsFailure = false;

  const SignInOutcome.failure(String this.message, {this.countsAsFailure = true});

  final String? message;
  final bool countsAsFailure;

  bool get ok => message == null;
}

/// Sign-in error codes where the attempt never reached the credentials check.
const nonLedgerSignInCodes = {'network-request-failed', 'too-many-requests'};

/// Thin wrapper over FirebaseAuth so screens depend on a small interface
/// (and tests can substitute a fake).
abstract class AuthService {
  Stream<String?> get userIdStream;
  String? get currentUserId;

  /// The signed-in user's role from their Firebase custom claim (pt_sir /
  /// admin — exactly two roles, NEW_SECURITY.md). Null when signed out or when
  /// the token has no role yet. The app NEVER hardcodes this: whatever claim
  /// the Firebase Auth account carries is what gates the UI.
  Future<String?> get currentUserRole;

  /// The signed-in account's email (for the account menu). Concrete default
  /// so existing test fakes keep compiling; FirebaseAuthService overrides it.
  String? get currentUserEmail => null;

  Future<SignInOutcome> signIn({required String email, required String password});
  Future<void> signOut();
}

/// Map a thrown [FirebaseAuthException] to a plain-language message
/// (DESIGN.md §5 — errors say what happened and what to do).
String describeAuthError(Object error) {
  if (error is FirebaseAuthException) {
    switch (error.code) {
      case 'invalid-email':
        return 'That doesn\u2019t look like a valid email address \u2014 check it and try again.';
      case 'user-disabled':
        return 'This account has been disabled. Contact the administrator.';
      case 'user-not-found':
      case 'invalid-credential':
      case 'wrong-password':
        return 'That email or password isn\u2019t right \u2014 check and try again.';
      case 'too-many-requests':
        return 'Too many attempts. Wait a minute and try again.';
      case 'network-request-failed':
        return 'No internet connection \u2014 check your network and try again.';
      default:
        return 'Sign-in failed. Check your details and try again.';
    }
  }
  return 'Sign-in failed. Check your details and try again.';
}

class FirebaseAuthService implements AuthService {
  FirebaseAuthService({FirebaseAuth? auth}) : _auth = auth ?? FirebaseAuth.instance;

  final FirebaseAuth _auth;

  @override
  Stream<String?> get userIdStream => _auth.authStateChanges().map((u) => u?.uid);

  @override
  String? get currentUserId => _auth.currentUser?.uid;

  @override
  String? get currentUserEmail => _auth.currentUser?.email;

  @override
  Future<String?> get currentUserRole async {
    final user = _auth.currentUser;
    if (user == null) return null;
    final result = await user.getIdTokenResult();
    return result.claims?['role'] as String?;
  }

  @override
  Future<SignInOutcome> signIn({required String email, required String password}) async {
    try {
      await _auth.signInWithEmailAndPassword(email: email, password: password);
      return const SignInOutcome.success();
    } catch (e) {
      final code = e is FirebaseAuthException ? e.code : '';
      return SignInOutcome.failure(
        describeAuthError(e),
        countsAsFailure: !nonLedgerSignInCodes.contains(code),
      );
    }
  }

  @override
  Future<void> signOut() => _auth.signOut();
}