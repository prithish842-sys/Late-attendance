/**
 * Map a thrown sign-in error to a plain-language message (DESIGN.md §5 -
 * errors describe what happened and what to do). Mirrors the Flutter
 * auth_service.dart describeAuthError.
 */
export function authErrorCode(error: unknown): string {
  return typeof error === "object" && error !== null && "code" in error
    ? String((error as { code?: unknown }).code ?? "")
    : "";
}

// Codes where the sign-in never reached the credentials check, so they must
// NOT count toward the 5-failures/15-min login ledger (review finding:
// a flaky network would otherwise lock the user out). Mirrors Flutter's
// NON_LEDGER_SIGN_IN_CODES.
const NON_LEDGER_CODES = new Set(["auth/network-request-failed", "auth/too-many-requests"]);

export interface SignInFailure {
  message: string;
  code: string;
  countsAsFailure: boolean;
}

/** Classify a thrown sign-in error for the login ledger (C1). */
export function signInFailure(error: unknown): SignInFailure {
  const code = authErrorCode(error);
  return {
    message: describeAuthError(error),
    code,
    countsAsFailure: !NON_LEDGER_CODES.has(code),
  };
}

export function describeAuthError(error: unknown): string {
  const code = authErrorCode(error);
  switch (code) {
    case "auth/invalid-email":
      return "That doesn\u2019t look like a valid email address \u2014 check it and try again.";
    case "auth/user-disabled":
      return "This account has been disabled. Contact the administrator.";
    case "auth/user-not-found":
    case "auth/invalid-credential":
    case "auth/wrong-password":
    case "auth/invalid-login-credentials":
      return "That email or password isn\u2019t right \u2014 check and try again.";
    case "auth/too-many-requests":
      return "Too many attempts. Wait a minute and try again.";
    case "auth/network-request-failed":
      return "No internet connection \u2014 check your network and try again.";
    default:
      return "Sign-in failed. Check your details and try again.";
  }
}