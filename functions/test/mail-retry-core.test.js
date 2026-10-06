// Pure unit tests for functions/mail-retry-core.js — the Phase 5 mail
// retry/status policy: exponential backoff, next-retry scheduling, the
// transient-vs-permanent failure classification, and the queue pick-up rule.
// Run with `npm test` in functions/.
import test from "node:test";
import assert from "node:assert/strict";
import {
  MAIL_RETRY_DEFAULTS,
  mailRetryPolicy,
  backoffMs,
  nextRetryAt,
  classifyMailFailure,
  queueDocActionable,
  retryStatusForFailingRun,
} from "../mail-retry-core.js";

test("mailRetryPolicy defaults and sanitizes overrides", () => {
  assert.equal(MAIL_RETRY_DEFAULTS.maxAttempts, 3);
  assert.equal(mailRetryPolicy({}).maxAttempts, 3);
  assert.equal(mailRetryPolicy({ maxAttempts: 5 }).maxAttempts, 5);
  assert.equal(mailRetryPolicy({ maxAttempts: 0 }).maxAttempts, 3, "non-positive falls back");
  assert.equal(mailRetryPolicy({ maxAttempts: "x" }).maxAttempts, 3, "non-integer falls back");
  // A max delay must stay above the base, otherwise the cap makes no sense.
  assert.equal(mailRetryPolicy({ baseDelayMs: 60000, maxDelayMs: 1000 }).maxDelayMs, MAIL_RETRY_DEFAULTS.maxDelayMs);
});

test("backoffMs explodes from the base and caps at maxDelayMs", () => {
  const policy = { baseDelayMs: 1000, maxDelayMs: 4000 };
  assert.equal(backoffMs(1, policy), 1000);
  assert.equal(backoffMs(2, policy), 2000);
  assert.equal(backoffMs(3, policy), 4000);
  assert.equal(backoffMs(4, policy), 4000, "capped, never unlimited");
  assert.equal(backoffMs(0, policy), 1000, "degenerate attempt counts clamp to attempt 1");
});

test("nextRetryAt schedules now + backoff for the attempts already done", () => {
  const now = new Date("2026-09-25T06:00:00Z");
  const policy = { baseDelayMs: 1000, maxDelayMs: 8000 };
  assert.equal(nextRetryAt(1, policy, now).toISOString(), "2026-09-25T06:00:01.000Z");
  assert.equal(nextRetryAt(2, policy, now).toISOString(), "2026-09-25T06:00:02.000Z");
});

test("classifyMailFailure treats sender aborts as permanent", () => {
  const failure = classifyMailFailure({ result: { status: "abort", code: "NO_HOD_EMAIL", detail: "no HOD" } });
  assert.equal(failure.retriable, false);
  assert.match(failure.reason, /NO_HOD_EMAIL/);
  // Every abort code is deterministic-permanent, not a blip.
  for (const code of ["NO_HOD_EMAIL", "NO_ROWS", "NO_ESCALATED", "NO_DEPARTMENT", "INVALID_RANGE"]) {
    assert.equal(classifyMailFailure({ result: { status: "abort", code } }).retriable, false, code);
  }
});

test("classifyMailFailure treats missing Resend key as permanent config error", () => {
  const err = new Error("RESEND_API_KEY is not set");
  err.code = "RESEND_KEY_MISSING";
  assert.equal(classifyMailFailure({ error: err }).retriable, false);
});

test("classifyMailFailure treats Resend 429 and 5xx as transient, 4xx as permanent", () => {
  const mk = (status, message) => {
    const err = new Error(message);
    err.code = "RESEND_API_ERROR";
    err.status = status;
    return err;
  };
  assert.equal(classifyMailFailure({ error: mk(429, "rate limited") }).retriable, true, "429 retries");
  assert.equal(classifyMailFailure({ error: mk(500, "provider error") }).retriable, true, "5xx retries");
  assert.equal(classifyMailFailure({ error: mk(503, "unavailable") }).retriable, true, "503 retries");
  assert.equal(classifyMailFailure({ error: mk(400, "rejected") }).retriable, false, "bad request is permanent");
  assert.equal(classifyMailFailure({ error: mk(422, "unprocessable") }).retriable, false, "422 is permanent");
});

test("classifyMailFailure treats any other throw (network/fetch) as retriable", () => {
  assert.equal(classifyMailFailure({ error: new Error("fetch failed") }).retriable, true);
  assert.equal(classifyMailFailure({ error: new TypeError("socket hang up") }).retriable, true);
});

test("queueDocActionable: pending is always actionable, retry only once its window passes", () => {
  const now = new Date("2026-09-25T06:00:00Z");
  const due = new Date("2026-09-25T05:00:00Z");
  const future = new Date("2026-09-25T07:00:00Z");
  const toDate = (d) => ({ toDate: () => d });

  assert.equal(queueDocActionable({ status: "pending" }, now), true);
  assert.equal(queueDocActionable({ status: "retry", nextRetryAt: toDate(due) }, now), true, "backoff elapsed");
  assert.equal(queueDocActionable({ status: "retry", nextRetryAt: toDate(future) }, now), false, "backoff not elapsed");
  assert.equal(queueDocActionable({ status: "retry" }, now), true, "missing nextRetryAt is treated as due");
  assert.equal(queueDocActionable({ status: "sent" }, now), false);
  assert.equal(queueDocActionable({ status: "failed" }, now), false);
  assert.equal(queueDocActionable({ status: "processing" }, now), false, "claimed runs are never double-started");

  // Accepts a snapshot-shaped object too ({ data() }).
  const snapshot = { data: () => ({ status: "pending" }) };
  assert.equal(queueDocActionable(snapshot, now), true);
});

test("retryStatusForFailingRun moves transient failures to retry with backoff", () => {
  const now = new Date("2026-09-25T06:00:00Z");
  const policy = { baseDelayMs: 1000, maxDelayMs: 8000 };
  const outcome = retryStatusForFailingRun({
    attemptsDone: 2,
    failure: { retriable: true, reason: "fetch failed" },
    policy,
    now,
  });
  assert.equal(outcome.status, "retry");
  assert.equal(outcome.retryDelayMs, 2000);
  assert.equal(outcome.nextRetryAt.getTime(), now.getTime() + 2000);
});

test("retryStatusForFailingRun burns attempts: permanent failures and the cap are terminal", () => {
  const now = new Date("2026-09-25T06:00:00Z");
  const policy = { baseDelayMs: 1000, maxDelayMs: 8000, maxAttempts: 3 };
  const permanent = retryStatusForFailingRun({
    attemptsDone: 1,
    failure: { retriable: false, reason: "NO_HOD_EMAIL: no HOD" },
    policy,
    now,
  });
  assert.equal(permanent.status, "failed");
  assert.equal(permanent.error, "NO_HOD_EMAIL: no HOD");

  const capped = retryStatusForFailingRun({
    attemptsDone: 3,
    failure: { retriable: true, reason: "fetch failed" },
    policy,
    now,
  });
  assert.equal(capped.status, "failed", "maxAttempts spent → permanent");
  assert.equal(capped.retryDelayMs, undefined);
});