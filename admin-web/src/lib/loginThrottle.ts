/**
 * Client-side sign-in attempt limiter for the admin web login (NEW_TASKS.md
 * C1) — the mirror of the Flutter LoginThrottle: at most LOGIN_MAX_ATTEMPTS
 * failures inside LOGIN_WINDOW_MS before sign-in is blocked for the remainder
 * of the window. Pure functions with an injectable clock; localStorage IO
 * stays in Login.tsx so this file unit-tests without a browser.
 *
 * Defence-in-depth only: Firebase Auth's own `too-many-requests` backstop is
 * the server-side guarantee.
 */
export const LOGIN_MAX_ATTEMPTS = 5;
export const LOGIN_WINDOW_MS = 15 * 60 * 1000;

/** Keep only failures still inside the window (oldest first). */
export function pruneFailures(failures: number[], now: number): number[] {
  return failures.filter((t) => now - t < LOGIN_WINDOW_MS);
}

/** Remaining lock in ms, or 0 when sign-in is allowed. */
export function lockedRemainingMs(failures: number[], now: number): number {
  const recent = pruneFailures(failures, now);
  if (recent.length < LOGIN_MAX_ATTEMPTS) return 0;
  const remaining = recent[0] + LOGIN_WINDOW_MS - now;
  return remaining > 0 ? remaining : 0;
}

/** Record a failure; returns the remaining lock in ms (0 = still free). */
export function recordFailure(failures: number[], now: number): number[] {
  return pruneFailures([...failures, now], now);
}

/** Plain-language lock message (DESIGN.md §5), rounded up to whole minutes. */
export function lockMessage(remainingMs: number): string {
  const minutes = Math.ceil(remainingMs / 60_000);
  if (minutes <= 1) {
    return "Too many failed sign-in attempts — try again in a moment.";
  }
  return `Too many failed sign-in attempts — try again in ${minutes} minutes.`;
}
