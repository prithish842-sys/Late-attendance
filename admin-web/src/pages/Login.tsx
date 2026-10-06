import { useState } from "react";
import type { FormEvent } from "react";
import { Navigate } from "react-router-dom";
import { useAuth } from "../auth/AuthContext";
import { Crest } from "../components/Crest";
import { inputClass } from "../components/Ui";
import {
  lockMessage,
  lockedRemainingMs,
  recordFailure,
} from "../lib/loginThrottle";

// C1 attempt ledger: 5 failures / 15 min, mirrored from the Flutter app.
// localStorage is trivially clearable, so this is defence-in-depth only —
// Firebase Auth's own rate limiting remains the server-side backstop.
const ATTEMPTS_KEY = "login_attempts_v1";

function readFailures(): number[] {
  try {
    const raw = localStorage.getItem(ATTEMPTS_KEY);
    if (!raw) return [];
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed.filter((t): t is number => typeof t === "number");
  } catch {
    return [];
  }
}

function writeFailures(failures: number[]): void {
  try {
    if (failures.length === 0) localStorage.removeItem(ATTEMPTS_KEY);
    else localStorage.setItem(ATTEMPTS_KEY, JSON.stringify(failures));
  } catch {
    /* storage unavailable — the throttle degrades to Firebase's backstop */
  }
}

/** Email + password login. Fraunces for the college name (DESIGN.md §2), plain-language errors. */
export function Login() {
  const { user, loading, signIn } = useAuth();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (loading) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-cream-50">
        <span aria-label="Loading" className="h-6 w-6 animate-spin rounded-full border-2 border-sand-200 border-t-maroon-900" />
      </div>
    );
  }
  if (user) {
    return <Navigate to="/" replace />;
  }

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    if (busy) return;
    if (email.trim() === "" || password === "") {
      setError("Enter your email and password.");
      return;
    }
    const now = Date.now();
    const locked = lockedRemainingMs(readFailures(), now);
    if (locked > 0) {
      setError(lockMessage(locked));
      return;
    }
    setBusy(true);
    setError(null);
    const fail = await signIn(email.trim(), password);
    setBusy(false);
    if (fail) {
      if (fail.countsAsFailure) {
        const failures = recordFailure(readFailures(), now);
        writeFailures(failures);
        const remaining = lockedRemainingMs(failures, now);
        setError(remaining > 0 ? lockMessage(remaining) : fail.message);
      } else {
        // Network / Firebase's own throttle: show it, but never count it
        // toward our ledger (review finding: offline must not lock you out).
        setError(fail.message);
      }
    } else {
      writeFailures([]);
    }
  }

  return (
    <div className="flex min-h-screen flex-col bg-cream-50 px-6 py-3">
      <Crest size={44} />
      <div className="mx-auto flex w-full max-w-md flex-1 flex-col justify-center py-10">
        <h1 className="font-display text-[34px] font-semibold leading-tight tracking-[-0.01em] text-navy-900">
          Sankara College of Science &amp; Commerce
        </h1>
        <p className="mt-3 text-[17px] text-ink-900">Sign in to see the late attendance.</p>
        <form onSubmit={onSubmit} className="mt-8 flex flex-col gap-4">
          <label className="flex flex-col gap-1.5 text-sm text-ink-900/70">
            Email
            <input
              className={inputClass}
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="you@sankara.ac.in"
              autoComplete="email"
              autoCapitalize="none"
            />
          </label>
          <label className="flex flex-col gap-1.5 text-sm text-ink-900/70">
            Password
            <input
              className={inputClass}
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              autoComplete="current-password"
            />
          </label>
          {error ? <p className="text-sm text-status-escalate">{error}</p> : null}
          <button
            type="submit"
            disabled={busy}
            className="mt-2 flex h-13 items-center justify-center rounded-md bg-maroon-900 px-6 py-3.5 text-base font-semibold text-white hover:bg-maroon-700 disabled:bg-sand-200 disabled:text-ink-900/60"
            style={{ minHeight: 52 }}
          >
            {busy ? "Signing in\u2026" : "Sign in"}
          </button>
        </form>
      </div>
    </div>
  );
}