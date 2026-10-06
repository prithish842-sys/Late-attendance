// Pure retry/status policy for the mail_queue pipeline (Phase 5 of
// docs-new-updates/NEW_TASKS.md — "mail retry/status").
//
// CommonJS like mail-core.js so the Blaze Cloud Functions (functions/index.js,
// require) and the Spark Admin-SDK runner (scripts/process-mail.js, ESM
// import) apply the exact same retry decision, and everything here is
// stateless and testable (functions/test/mail-retry-core.test.js).
//
// Status lifecycle of a mail_queue doc (previously pending -> processed once ->
// failed; now pending -> processing -> sent | retry -> ... -> failed):
//
//   pending    the request is queued and has never run
//   processing a run claimed it (the claim is atomic, so two runners can't
//              double-send — process-mail.js / mail-queue-runner.js)
//   sent       Resend accepted the mail and a mail_logs audit row was written
//   retry      the send threw a TRANSIENT failure (network blip, Resend 429,
//              5xx); nextRetryAt says when it may be picked up again
//   failed     permanent — either an `abort` (validation refused to send:
//              NO_HOD_EMAIL / NO_ROWS / ...) or a transient error that burned
//              through maxAttempts. Never automatically retried afterwards.
//
// Transient vs permanent: an `abort` result is a *decision* the pipeline made
// about a request that is invalid as-is — retrying cannot change the answer,
// so it is permanent and gets no attempts. A thrown error from the Resend call
// (or a network failure reaching it) is what retry/backoff is for.

const MAIL_RETRY_DEFAULTS = {
  // Total run attempts before a transient failure becomes a permanent
  // "failed" (initial pending run counts as attempt 1).
  maxAttempts: 3,
  // Backoff: base * 2^(attempt-1), capped at maxDelayMs.
  baseDelayMs: 5 * 60 * 1000, // 5 minutes
  maxDelayMs: 60 * 60 * 1000, // 1 hour
};

function mailRetryPolicy(overrides) {
  const policy = { ...MAIL_RETRY_DEFAULTS, ...overrides };
  if (!Number.isInteger(policy.maxAttempts) || policy.maxAttempts < 1) policy.maxAttempts = MAIL_RETRY_DEFAULTS.maxAttempts;
  if (!Number.isFinite(policy.baseDelayMs) || policy.baseDelayMs < 0) policy.baseDelayMs = MAIL_RETRY_DEFAULTS.baseDelayMs;
  if (!Number.isFinite(policy.maxDelayMs) || policy.maxDelayMs <= policy.baseDelayMs) policy.maxDelayMs = MAIL_RETRY_DEFAULTS.maxDelayMs;
  return policy;
}

/** Exponential backoff delay for the Nth attempt (1-indexed). */
function backoffMs(attempt, policy = {}) {
  const p = mailRetryPolicy(policy);
  const n = Number.isInteger(attempt) && attempt >= 1 ? attempt : 1;
  return Math.min(p.baseDelayMs * Math.pow(2, n - 1), p.maxDelayMs);
}

/** When a retry becomes eligible: now + backoff for the given past attempts. */
function nextRetryAt(attemptsDone, policy = {}, now = new Date()) {
  const p = mailRetryPolicy(policy);
  const done = Number.isInteger(attemptsDone) && attemptsDone >= 1 ? attemptsDone : 1;
  return new Date(now.getTime() + backoffMs(done, p));
}

/**
 * Classify a failed mail run into permanent vs retriable.
 *
 *   - `result.status === "abort"` — the senders' explicit refusal (NO_HOD_EMAIL,
 *     NO_ROWS, NO_ESCALATED, NO_DEPARTMENT, INVALID_RANGE...). Retrying the same
 *     request cannot change the outcome → permanent, never retried.
 *   - `err.code === "RESEND_KEY_MISSING"` — a permanent configuration fault,
 *     not a blip → permanent (fix the server env and re-enqueue).
 *   - `err.code === "RESEND_API_ERROR"` — 429 and 5xx are transient (rate limit
 *     / provider outage); a 4xx request error is permanent.
 *   - anything else (fetch failure, timeout, unexpected) → retriable.
 *
 * Returns { retriable, reason }.
 */
function classifyMailFailure({ result, error }) {
  if (result && result.status === "abort") {
    return { retriable: false, reason: `${result.code}: ${result.detail}` };
  }
  if (error) {
    if (error.code === "RESEND_KEY_MISSING") {
      return { retriable: false, reason: error.message };
    }
    if (error.code === "RESEND_API_ERROR") {
      const status = Number(error.status);
      const transient = status === 429 || status >= 500;
      return { retriable: transient, reason: error.message, resendStatus: status };
    }
    return { retriable: true, reason: error.message || String(error) };
  }
  return { retriable: true, reason: "unknown mail failure" };
}

/**
 * True when a queue doc may be picked up again: it is pending, or it is a
 * retry whose backoff window has elapsed. `doc.attemptCount` counts runs done.
 */
function queueDocActionable(doc, now = new Date()) {
  const data = doc && doc.data ? doc.data() : doc; // accept a snapshot or plain map
  const status = data.status || "pending";
  if (status === "pending") return true;
  if (status !== "retry") return false;
  const due = data.nextRetryAt?.toDate ? data.nextRetryAt.toDate() : new Date(data.nextRetryAt || 0);
  return !Number.isNaN(due.getTime()) && due.getTime() <= now.getTime();
}

/**
 * How finish a failed run: after `attemptsDone` runs (the one just completed
 * included) and a classified failure, should the doc go to `retry` (with
 * nextRetryAt) or to permanent `failed`? Returns the status patch.
 *   { status: "retry", nextRetryAt, error, reason }
 *   { status: "failed", error, reason }
 */
function retryStatusForFailingRun({ attemptsDone, failure, policy, now = new Date() }) {
  const p = mailRetryPolicy(policy);
  const reason = failure.reason;
  if (!failure.retriable || attemptsDone >= p.maxAttempts) {
    return { status: "failed", error: reason, reason };
  }
  const at = nextRetryAt(attemptsDone, p, now);
  return {
    status: "retry",
    error: reason,
    reason,
    nextRetryAt: at,
    retryDelayMs: at.getTime() - now.getTime(),
  };
}

module.exports = {
  MAIL_RETRY_DEFAULTS,
  mailRetryPolicy,
  backoffMs,
  nextRetryAt,
  classifyMailFailure,
  queueDocActionable,
  retryStatusForFailingRun,
};