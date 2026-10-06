// Shared mail_queue execution — the ONE implementation both runtime paths use
// to turn a mail_queue doc into a sent mail (or a recorded failure/retry).
// Phase 5 "mail retry/status" (docs-new-updates/NEW_TASKS.md) lives here so the
// Blaze Cloud Function trigger, the Blaze retry schedule, and the Spark runner
// (scripts/process-mail.js) all behave identically:
//
//   - Blaze:  functions/index.js processMailQueue (onCreate) and retryMailQueue
//             (onSchedule) both call runMailQueueDoc() / runDueMailQueue().
//   - Spark:  scripts/process-mail.js calls runMailQueueDoc() / runDueMailQueue().
//
// Retry policy comes from functions/mail-retry-core.js (pure): transient send
// failures schedule a `retry` status with exponential backoff up to
// maxAttempts; abort verdicts from the senders are permanent `failed`. The
// claim is atomic (transaction), so two runners (or a runner racing the Blaze
// schedule) can never both send the same request.

const { FieldValue } = require("firebase-admin/firestore");
const { processQueuedMail } = require("./mail-sender.js");
const { processQueuedReportMail } = require("./report-mail-sender.js");
const { processQueuedWeeklyAudit } = require("./weekly-audit-sender.js");
const {
  classifyMailFailure,
  retryStatusForFailingRun,
  queueDocActionable,
} = require("./mail-retry-core.js");

/** Rebuild the sender intent from the stored mail_queue doc (by type). */
function requestFromQueueDoc(data) {
  const type = data.type || "escalation";
  if (type === "report") {
    return {
      type,
      departmentId: data.departmentId || null,
      department: data.department || null,
      periodType: data.periodType || null,
      startDate: data.startDate || null,
      endDate: data.endDate || null,
      year: data.year || null,
      attachmentMode: data.attachmentMode === "split" ? "split" : "combined",
      requestedBy: data.requestedBy || null,
    };
  }
  if (type === "weekly_audit") {
    return {
      type,
      departmentId: data.departmentId || null,
      department: data.department || null,
      startDate: data.startDate || null,
      requestedBy: data.requestedBy || null,
    };
  }
  return {
    type,
    departmentId: data.departmentId || null,
    department: data.department || null,
    studentIds: Array.isArray(data.studentIds) ? data.studentIds : [],
    period: data.period || null,
    requestedBy: data.requestedBy || null,
  };
}

function runSender({ db, request, mailRequestId, config }) {
  switch (request.type) {
    case "report":
      return processQueuedReportMail({ db, request, mailRequestId, config });
    case "weekly_audit":
      return processQueuedWeeklyAudit({ db, request, mailRequestId, config });
    default:
      return processQueuedMail({ db, request, mailRequestId, config });
  }
}

// --- duplicate suppression (QA Phase 8 rate limiting) -----------------------
//
// The app has no client-side debounce on "Send to HOD" / "Request report", so a
// double-tap (or an operator tapping again because nothing appeared to happen)
// enqueues two identical mail_queue docs. Without a guard both send, and the
// HOD gets the same mail twice. The runner therefore refuses to send an
// intent that an identical queue doc already sent inside a short window.

/** Long enough to swallow a double-submit, short enough to allow a re-send. */
const DUPLICATE_WINDOW_MS = 10 * 60 * 1000;

/**
 * Canonical key of a send intent. Two requests with the same key describe the
 * same mail: same type, same target department, same period/window and the
 * same payload (escalation: the exact student list).
 */
function intentKey(request) {
  const studentIds = Array.isArray(request.studentIds)
    ? [...request.studentIds].sort()
    : [];
  return [
    request.type || "escalation",
    request.departmentId || "",
    request.period || "",
    request.startDate || "",
    request.endDate || "",
    request.year || "",
    request.attachmentMode || "",
    studentIds.join(","),
  ].join("|");
}

/**
 * Look for a mail_queue doc with the same intent that was already SENT within
 * [windowMs]. Single-field `status == "sent"` query (automatic index — no new
 * composite index needed) plus an in-memory intent comparison, because queue
 * docs are the only place where both the original request fields and the
 * outcome live in the same shape.
 *
 * Returns { id, sentAt } of the duplicate or null.
 */
async function findRecentlySentDuplicate({
  db,
  request,
  nowMs,
  windowMs = DUPLICATE_WINDOW_MS,
  limit = 300,
}) {
  const snap = await db.collection("mail_queue").where("status", "==", "sent").limit(limit).get();
  const key = intentKey(request);
  for (const doc of snap.docs) {
    const data = doc.data();
    const processedAt = data.processedAt;
    if (!processedAt || typeof processedAt.toMillis !== "function") continue;
    const sentAt = processedAt.toMillis();
    if (nowMs - sentAt > windowMs) continue;
    if (intentKey(requestFromQueueDoc(data)) !== key) continue;
    return { id: doc.id, sentAt };
  }
  return null;
}

/**
 * Atomically claim a pending/due-retry doc so two runs never double-send.
 * Returns { claimed, attemptCount } — attemptCount is the run number after
 * this claim (1 on the first attempt, 2 on the first retry, ...).
 */
async function claimQueueDoc(docRef, data) {
  const attemptsBefore = Number.isInteger(data.attemptCount) ? data.attemptCount : 0;
  const attemptCount = attemptsBefore + 1;

  let claimed = false;
  await docRef.firestore.runTransaction(async (txn) => {
    const snap = await txn.get(docRef);
    if (!snap.exists) return;
    const docData = snap.data();
    const s = docData.status || "pending";
    const claimable =
      s === "pending" || (s === "retry" && queueDocActionable(docData));
    if (!claimable) return;
    txn.update(docRef, {
      status: "processing",
      attemptCount: FieldValue.increment(1),
      processingAt: FieldValue.serverTimestamp(),
      lastAttemptAt: FieldValue.serverTimestamp(),
    });
    claimed = true;
  });
  return claimed ? attemptCount : 0;
}

/**
 * Execute one mail_queue doc end-to-end and record the durable status, exactly
 * as both paths should:
 *
 *   - sent    → status "sent" + resendId/mailLogId (+ the senders already wrote
 *               the mail_logs audit row)
 *   - abort   → status "failed" (permanent, never retried)
 *   - throw   → transient → status "retry" with nextRetryAt (backoff), or
 *               status "failed" once maxAttempts is spent
 *
 * config: { apiKey, from, collegeName, dryRun, retryPolicy, now }.
 * Returns a stable result object that callers may print/list.
 */
async function runMailQueueDoc({ db, id, data, config = {} }) {
  const ref = db.collection("mail_queue").doc(id);

  if (config.dryRun) {
    const request = requestFromQueueDoc(data);
    const result = await runSender({ db, request, mailRequestId: id, config: { ...config, dryRun: true } });
    return { id, type: request.type, dryRun: true, result };
  }

  const attemptCount = await claimQueueDoc(ref, data);
  if (!attemptCount) {
    return { id, skipped: true, reason: `status could not be claimed from '${data.status || "pending"}'` };
  }

  const request = requestFromQueueDoc(data);

  // Rate limit: suppress an identical intent an earlier doc already sent.
  const nowMs =
    config.now instanceof Date
      ? config.now.getTime()
      : typeof config.now === "number"
        ? config.now
        : Date.now();
  const duplicate = await findRecentlySentDuplicate({ db, request, nowMs });
  if (duplicate) {
    await ref.update({
      status: "failed",
      error: `duplicate request — an identical mail was already sent by mail_queue/${duplicate.id} within the ${Math.round(
        DUPLICATE_WINDOW_MS / 60000,
      )} min rate-limit window`,
      duplicateOf: duplicate.id,
      processedAt: FieldValue.serverTimestamp(),
    });
    return {
      id,
      type: request.type,
      status: "failed",
      suppressedDuplicate: true,
      duplicateOf: duplicate.id,
    };
  }

  try {
    const result = await runSender({ db, request, mailRequestId: id, config });
    if (result.status === "sent") {
      await ref.update({
        status: "sent",
        resendId: result.resendId,
        mailLogId: result.mailLogId,
        processedAt: FieldValue.serverTimestamp(),
      });
      return { id, type: request.type, status: "sent", resendId: result.resendId, to: result.to, range: result.range || null };
    }
    // The senders returned an abort verdict (NO_HOD_EMAIL / NO_ROWS / ...):
    // the request is unprocessable as-is, so this is a permanent failure.
    const failure = classifyMailFailure({ result, policy: config.retryPolicy });
    const outcome = retryStatusForFailingRun({ attemptsDone: attemptCount, failure, policy: config.retryPolicy });
    await ref.update({
      status: outcome.status,
      error: outcome.error,
      processedAt: FieldValue.serverTimestamp(),
      ...(outcome.status === "retry" ? { nextRetryAt: outcome.nextRetryAt } : {}),
    });
    return { id, type: request.type, status: outcome.status, code: result.code, detail: result.detail, retryDelayMs: outcome.retryDelayMs ?? null };
  } catch (err) {
    const failure = classifyMailFailure({ error: err, policy: config.retryPolicy });
    const outcome = retryStatusForFailingRun({ attemptsDone: attemptCount, failure, policy: config.retryPolicy });
    await ref.update({
      status: outcome.status,
      error: outcome.error,
      processedAt: FieldValue.serverTimestamp(),
      ...(outcome.status === "retry" ? { nextRetryAt: outcome.nextRetryAt } : {}),
    });
    return { id, type: request.type, status: outcome.status, error: outcome.error, retryDelayMs: outcome.retryDelayMs ?? null };
  }
}

/**
 * Process every pending OR due-retry mail_queue doc (the Spark runner default,
 * and the body of the Blaze retryMailQueue schedule). Returns the per-doc
 * results plus a small rollup.
 */
async function runDueMailQueue({ db, config = {} }) {
  const snap = await db.collection("mail_queue").get();
  const docs = snap.docs.filter((d) => queueDocActionable(d.data(), config.now));
  const results = [];
  const rollup = { processed: 0, sent: 0, failed: 0, retry: 0, skipped: 0, suppressed: 0 };
  for (const doc of docs) {
    const out = await runMailQueueDoc({ db, id: doc.id, data: doc.data(), config });
    results.push(out);
    if (out.skipped) rollup.skipped++;
    else if (out.suppressedDuplicate) { rollup.processed++; rollup.suppressed++; }
    else if (out.status === "sent") { rollup.processed++; rollup.sent++; }
    else if (out.status === "retry") { rollup.processed++; rollup.retry++; }
    else { rollup.processed++; rollup.failed++; }
  }
  return { results, rollup };
}

module.exports = {
  requestFromQueueDoc,
  intentKey,
  findRecentlySentDuplicate,
  claimQueueDoc,
  runMailQueueDoc,
  runDueMailQueue,
};