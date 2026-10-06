// Sliding-window rate limiter for the callable endpoints (NEW_TASKS.md
// Production Hardening B5). Counters live in `rate_limits/{uid}_{bucket}` —
// written only by the Admin SDK, so Firestore rules never expose them to
// clients (firestore.rules has no match for the collection → default deny).
//
// Every check prunes events older than the window, so a counter doc stays
// bounded at `max` entries no matter how old it gets.
const { HttpsError } = require("firebase-functions/v2/https");

// Per-uid caps. Windows are generous: these guard against runaway loops and
// abuse, not against a legitimate busy session. `mail_send` covers ALL three
// mail callables, and the app legitimately sends per-department batches (up to
// 7 escalation + weekly/report in one sitting), so 30/h keeps bulk sends
// working while still bounding abuse (raised from the review finding: 10/h
// could lock a normal escalation+weekly morning into resource-exhausted).
const LIMITS = {
  // mail_send covers sendEscalationMail + sendReportMail + sendWeeklyAuditMail.
  mail_send: { max: 30, windowMs: 60 * 60 * 1000 },
  report: { max: 10, windowMs: 60 * 60 * 1000 },
  import: { max: 5, windowMs: 60 * 60 * 1000 },
  // admin_write covers adminSoftDelete + adminRestore + adminPermanentDelete.
  admin_write: { max: 30, windowMs: 60 * 60 * 1000 },
};

/**
 * Pure decision step (unit-testable without Firestore): prune the stored
 * event timestamps to the current window and allow iff under `max`.
 * Returns `{ allowed, retryAfterSec, events }` where `events` is the pruned
 * list the caller should persist when allowed.
 */
function slidingWindowCheck(events, max, windowMs, now) {
  const recent = (Array.isArray(events) ? events : []).filter(
    (t) => typeof t === "number" && now - t < windowMs
  );
  if (recent.length >= max) {
    // The list may be out of chronological order (timestamps are captured
    // before the transaction round-trip), so wait on the OLDEST event.
    const oldest = Math.min(...recent);
    const retryAfterSec = Math.max(1, Math.ceil((windowMs - (now - oldest)) / 1000));
    return { allowed: false, retryAfterSec, events: recent };
  }
  return { allowed: true, retryAfterSec: 0, events: recent };
}

/**
 * Enforce the limit for `uid` on `bucket`. Atomically (transaction) records
 * `now` when the action is allowed; throws `resource-exhausted` when not.
 * Unknown buckets or explicit max/window are programmer errors, not user
 * errors, so they throw a plain Error.
 */
async function enforceRateLimit(db, { uid, bucket, max, windowMs, now }) {
  const limit = LIMITS[bucket] || {};
  const cap = max != null ? max : limit.max;
  const window = windowMs != null ? windowMs : limit.windowMs;
  if (!uid) throw new Error("enforceRateLimit: uid is required");
  if (!cap || !window) {
    throw new Error(`enforceRateLimit: unknown bucket "${bucket}"`);
  }
  const at = now != null ? now : Date.now();

  const ref = db.collection("rate_limits").doc(`${uid}_${bucket}`);
  const decision = await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const check = slidingWindowCheck(
      snap.exists ? snap.data().events : null,
      cap,
      window,
      at
    );
    if (!check.allowed) return check;
    check.events.push(at);
    tx.set(ref, { events: check.events, windowMs: window, updatedAt: at });
    return check;
  });

  if (!decision.allowed) {
    throw new HttpsError(
      "resource-exhausted",
      `Rate limit exceeded for this action — try again in ${decision.retryAfterSec}s.`,
      { retryAfterSec: decision.retryAfterSec }
    );
  }
  return true;
}

module.exports = { LIMITS, slidingWindowCheck, enforceRateLimit };
