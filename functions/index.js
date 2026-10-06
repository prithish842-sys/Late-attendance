// Escalation Cloud Function — Phase 2 of docs/TASKS.md.
//
// On ANY new late_log document write, this function recounts the student's
// late entries in the current reset period and writes the server-authoritative
// warning / escalation verdict (SECURITY.md §1 — clients never decide).
//
// Deployment note: this directory is not wired into firebase.json yet because
// Cloud Functions need the Blaze plan. When upgraded:
//   1. move `functions` into firebase.json ("functions": {"source": "functions"})
//   2. run: firebase deploy --only functions
//   3. flip the app config BLAZE_ENABLED to true (docs/NOTES.md "Blaze switch")
//
// The SPARK fallback that mirrors this behaviour while no function is deployed:
//   node scripts/process-escalation.js   (Admin SDK, same escalation-core logic)

const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { log } = require("firebase-functions/logger");
const { initializeApp } = require("firebase-admin/app");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const { getStorage } = require("firebase-admin/storage");
const {
  periodKey,
  periodStart,
  periodEnd,
  computeEscalation,
  escalationDoc,
  monthlyStatusDoc,
} = require("./escalation-core.js");
const { processQueuedMail } = require("./mail-sender.js");
const { processQueuedReportMail } = require("./report-mail-sender.js");
const { processQueuedWeeklyAudit } = require("./weekly-audit-sender.js");
const { generateReport, reportLogDoc } = require("./report-generator.js");
const {
  assessOfflineScan,
  offlineSyncFlagDoc,
} = require("./offline-sync-core.js");
const { ADMIN_ROLES } = require("./admin-core.js");
const {
  runCommitImportBatch,
  runSoftDelete,
  runRestore,
  runPermanentDelete,
} = require("./admin-scheduler.js");
const { mondayOf, addDays } = require("./report-core.js");
const { formatDate } = require("./mail-core.js");
const { runMailQueueDoc, runDueMailQueue } = require("./mail-queue-runner.js");
const { runWeeklyAuditJob } = require("./weekly-audit-job.js");
const { runPassOutJob } = require("./pass-out-job.js");
const { enforceRateLimit } = require("./rate-limit.js");

initializeApp();
// This project's Firestore database id is `default`, not Google's `(default)`
// (same id the scripts and the Flutter app use — see AppConfig.firestoreDatabaseId).
const db = getFirestore("default");

function mailLogId(period, department) {
  const tail = String(department || "dept").replace(/[^a-z0-9]/gi, "_").slice(0, 24);
  return `${tail}_${period}_${Date.now().toString(36)}`;
}

/** Sender config for the scheduled/triggered paths — the Resend key and the
 *  college name come from the function environment (SECURITY.md §6), never
 *  from a client. `from` is left to the senders' defaultFrom() which reads the
 *  same env. */
function schedulerConfig(requestedBy) {
  return {
    apiKey: process.env.RESEND_API_KEY,
    collegeName: process.env.COLLEGE_NAME,
    requestedBy,
  };
}

exports.escalateLateLog = onDocumentCreated("late_logs/{logId}", async (event) => {
  const data = event.data.data();
  const logId = event.params.logId;
  const studentId = String(data.studentId || logId.split("_")[0]);

  // Server time is authoritative (SECURITY.md §2).
  const scannedAt = data.scanTimestamp?.toDate ? data.scanTimestamp.toDate() : new Date();

  // Phase 5 — SECURITY.md §2: an offline scan carries deviceTimestamp +
  // syncedOffline:true; the SERVER compares that device clock against its own
  // receipt time and flags large mismatches for admin review instead of
  // trusting them silently. Writes offline_sync_flags/{logId} (server-only).
  if (data.syncedOffline === true) {
    const assessment = assessOfflineScan(logId, {
      ...data,
      scanTimestamp: data.scanTimestamp ?? scannedAt,
    });
    await db
      .collection("offline_sync_flags")
      .doc(logId)
      .set({ ...offlineSyncFlagDoc(assessment), assessedAt: FieldValue.serverTimestamp() });
    if (assessment.flagged) {
      log(`offline sync flagged ${logId}: ${assessment.reason} (${assessment.discrepancyMinutes} min)`);
    }
  }

  // Settings come from Firestore — never hardcoded (DECISIONS.md #2).
  const settingsSnap = await db.collection("settings").doc("default").get();
  const settings = settingsSnap.exists ? settingsSnap.data() : {};
  const threshold = settings.escalationThreshold ?? 3;
  const resetPeriod = settings.resetPeriod ?? "monthly";

  // Count within the reset period (DECISIONS.md #1).
  const start = periodStart(scannedAt, resetPeriod);
  const end = periodEnd(scannedAt, resetPeriod);
  const { count } = await db
    .collection("late_logs")
    .where("studentId", "==", studentId)
    .where("scanTimestamp", ">=", start)
    .where("scanTimestamp", "<", end)
    .count()
    .get();

  const decision = computeEscalation(count, threshold);
  log(`escalate ${studentId}: count=${count} threshold=${threshold} → ${decision.status}`);

  const studentSnap = await db.collection("students").doc(studentId).get();
  const student = studentSnap.exists
    ? { studentId, ...studentSnap.data() }
    : { studentId };

  // Phase 3 (NEW_UPDATES_PRD.md) — monthly-lived counter. The weekly audit UI
  // and the 1st/2nd/3rd+ monthly statuses read monthly_student_status, NOT raw
  // log counts, so this MUST be upserted for EVERY new log — even when the
  // escalation verdict is "tracking" (the 1st late of a month is what flips
  // logged → warning → escalated). monthKey comes from the calendar month the
  // scan happened in; the doc id is `{studentId}_{monthKey}` (dup key, §2.6).
  const monthKey = periodKey(scannedAt, "monthly");
  // The escalation query above counts within `resetPeriod` (monthly OR
  // semester); the monthly counter ALWAYS counts the calendar month regardless.
  let monthCount = count;
  if (resetPeriod !== "monthly") {
    const mStart = periodStart(scannedAt, "monthly");
    const mEnd = periodEnd(scannedAt, "monthly");
    ({ count: monthCount } = await db
      .collection("late_logs")
      .where("studentId", "==", studentId)
      .where("scanTimestamp", ">=", mStart)
      .where("scanTimestamp", "<", mEnd)
      .count()
      .get());
  }
  await db
    .collection("monthly_student_status")
    .doc(`${studentId}_${monthKey}`)
    .set(
      {
        ...monthlyStatusDoc(student, monthCount, threshold, monthKey),
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

  if (decision.status === "tracking") return; // 1st late -> log only

  await db
    .collection("escalation_queue")
    .doc(`${studentId}_${periodKey(scannedAt, resetPeriod)}`)
    .set(
      {
        ...escalationDoc(student, count, threshold, periodKey(scannedAt, resetPeriod)),
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
});

// ─────────────────────────────────────────────────────────────────────────────
// Phase 3 — HOD mail automation (docs/TASKS.md). Both endpoints share
// functions/mail-sender.js processQueuedMail(), so Blaze behaviour is exactly
// the Spark fallback behaviour.
//
//   sendEscalationMail  — HttpsCallable "endpoint": the app calls this with
//                         { departmentId?, department?, studentIds?, period? }
//                         from the Blaze MailService. Role-gated (pt_sir/admin).
//   processMailQueue    — onCreate trigger on mail_queue: processes queued mail
//                         requests (the docs/NOTES.md Blaze swap of the Spark
//                         `scripts/process-mail.js` runner). Used when a client
//                         (or script) writes a mail_queue request directly.
//
// The Resend API key lives ONLY in the function environment (SECURITY.md §6);
// on Spark the equivalent key sits in the .env read by scripts/process-mail.js.
// ─────────────────────────────────────────────────────────────────────────────

const MAIL_ALLOWED_ROLES = ["pt_sir", "admin"];

function restoreRequest(data) {
  return {
    departmentId: data.departmentId || null,
    department: data.department || null,
    studentIds: Array.isArray(data.studentIds) ? data.studentIds : [],
    period: data.period || periodKey(new Date(), "monthly"),
    requestedBy: data.requestedBy || null,
  };
}

// "send escalation mail for department X" — Phase 3 endpoint.
exports.sendEscalationMail = onCall(async (request) => {
  const role = request.auth?.token?.role;
  if (!MAIL_ALLOWED_ROLES.includes(role)) {
    throw new HttpsError(
      "permission-denied",
      "Only PT sir or an admin can send escalation mail (SECURITY.md §5, §8)."
    );
  }
  const mailRequest = restoreRequest(request.data || {});
  if (!mailRequest.departmentId && !mailRequest.department) {
    throw new HttpsError("invalid-argument", "Provide departmentId or department for the escalation mail.");
  }
  // After validation: malformed retries must not consume quota (review finding).
  await enforceRateLimit(db, { uid: request.auth.uid, bucket: "mail_send" });

  const mailRequestId = mailLogId(mailRequest.period, mailRequest.departmentId || mailRequest.department);
  const result = await processQueuedMail({
    db,
    request: { ...mailRequest, requestedBy: mailRequest.requestedBy || request.auth.uid },
    mailRequestId,
  });

  return { mailLogId: result.status === "sent" ? mailRequestId : null, ...result };
});

// Phase 2 (new updates) — HOD report mail. Same pattern as sendEscalationMail:
// a role-gated HttpsCallable the app uses on Blaze; on Spark the app instead
// enqueues a mail_queue doc with type "report" that scripts/process-mail.js
// consumes. Both paths share functions/report-mail-sender.js, so outcomes match.
exports.sendReportMail = onCall(async (request) => {
  const role = request.auth?.token?.role;
  if (!MAIL_ALLOWED_ROLES.includes(role)) {
    throw new HttpsError(
      "permission-denied",
      "Only PT sir or an admin can send report mail (NEW_SECURITY.md §5, §8)."
    );
  }
  const data = request.data || {};
  if (!data.departmentId && !data.department) {
    throw new HttpsError("invalid-argument", "Provide departmentId or department for the report mail.");
  }
  // After validation: malformed retries must not consume quota (review finding).
  await enforceRateLimit(db, { uid: request.auth.uid, bucket: "mail_send" });

  const mailRequest = {
    departmentId: data.departmentId || null,
    department: data.department || null,
    periodType: data.periodType || "monthly",
    startDate: data.startDate || null,
    endDate: data.endDate || null,
    year: data.year || null,
    attachmentMode: data.attachmentMode === "split" ? "split" : "combined",
    requestedBy: data.requestedBy || request.auth.uid,
  };

  const mailRequestId = mailLogId(mailRequest.periodType, mailRequest.departmentId || mailRequest.department);
  const result = await processQueuedReportMail({ db, request: mailRequest, mailRequestId });
  if (result.status === "abort") {
    throw new HttpsError("invalid-argument", `${result.code}: ${result.detail}`);
  }

  return { mailLogId: result.status === "sent" ? mailRequestId : null, ...result };
});

// Phase 3 (NEW_TASKS.md) — weekly HOD audit mail. Same pattern as the other two
// senders: a role-gated HttpsCallable the app uses on Blaze; on Spark the app
// instead enqueues a mail_queue doc with type "weekly_audit" that
// scripts/process-mail.js consumes. BOTH paths share functions/weekly-audit-sender.js.
exports.sendWeeklyAuditMail = onCall(async (request) => {
  const role = request.auth?.token?.role;
  if (!MAIL_ALLOWED_ROLES.includes(role)) {
    throw new HttpsError(
      "permission-denied",
      "Only PT sir or an admin can send the weekly audit mail (NEW_SECURITY.md §5, §8)."
    );
  }
  const data = request.data || {};
  if (!data.departmentId && !data.department) {
    throw new HttpsError("invalid-argument", "Provide departmentId or department for the weekly audit mail.");
  }
  // After validation: malformed retries must not consume quota (review finding).
  await enforceRateLimit(db, { uid: request.auth.uid, bucket: "mail_send" });

  const mailRequest = {
    departmentId: data.departmentId || null,
    department: data.department || null,
    startDate: data.startDate || null,
    requestedBy: data.requestedBy || request.auth.uid,
  };

  const mailRequestId = mailLogId("weekly", mailRequest.departmentId || mailRequest.department);
  const result = await processQueuedWeeklyAudit({ db, request: mailRequest, mailRequestId });
  if (result.status === "abort") {
    throw new HttpsError("invalid-argument", `${result.code}: ${result.detail}`);
  }

  return { mailLogId: result.status === "sent" ? mailRequestId : null, ...result };
});

// Blaze swap for the Spark queue runner — consumes mail_queue docs on create.
// Both this trigger and retryMailQueue (below) delegate to the SAME
// functions/mail-queue-runner.js, so the Blaze outcome (including the Phase 5
// retry/status lifecycle) is exactly the Spark outcome.
exports.processMailQueue = onDocumentCreated("mail_queue/{docId}", async (event) => {
  const doc = event.data.data();
  if (!doc || doc.status !== "pending") return; // not a fresh request

  const id = event.params.docId;
  const out = await runMailQueueDoc({ db, id, data: doc, config: schedulerConfig("mail-queue-trigger") });
  if (out.skipped) {
    log(`mail skipped for ${id}: ${out.reason}`);
  } else if (out.status === "sent") {
    log(`mail sent for ${id} → ${out.resendId} (${out.type || "escalation"}${out.range ? `, ${out.range}` : ""})`);
  } else if (out.status === "retry") {
    log(`mail retry queued for ${id} (attempt will retry in ${out.retryDelayMs} ms)`);
  } else {
    log(`mail failed for ${id} — ${out.error || `${out.code}: ${out.detail}`}`);
  }
});

// Phase 5 — retry/status sweep: hourly, pick up every mail_queue doc that is
// pending (a fallback for trigger crashes) or due for a retry (transient
// failures with exploded backoff) and process it through the shared runner.
exports.retryMailQueue = onSchedule({ schedule: "0 * * * *", timeZone: "UTC" }, async () => {
  const { results, rollup } = await runDueMailQueue({
    db,
    config: schedulerConfig("retry-mail-queue"),
  });
  log(`mail retry sweep: ${JSON.stringify(rollup)}`);
  for (const r of results) {
    if (r.skipped || r.status === "sent") continue;
    log(`mail ${r.status} for ${r.id}: ${r.error || `${r.code}: ${r.detail}`}`);
  }
});

// Phase 5 — weekly audit job: Monday 06:00 UTC audits the week that just ended
// (idempotent per department+week, so overlapping/re-run schedules cannot
// double-mail). All departments with late entries that have no weekly_audit
// mail_logs row yet get their formal HOD mail via weekly-audit-sender.js.
exports.runWeeklyAuditJob = onSchedule({ schedule: "0 6 * * 1", timeZone: "UTC" }, async () => {
  const previousMonday = addDays(mondayOf(new Date()), -7);
  const result = await runWeeklyAuditJob({
    db,
    config: {
      ...schedulerConfig("weekly-audit-job"),
      weekStartDate: formatDate(previousMonday),
    },
  });
  log(`weekly audit job: ${result.status} — ${result.range}: ${JSON.stringify(result.summary)}`);
});

// Phase 5 — pass-out job: daily 07:00 UTC, materialise pass-out review
// notifications for active students whose batch end year has been reached
// (NEW_WORKFLOW.md §6). NEVER deletes or archives — admin reviews and triggers
// the lifecycle (adminSoftDelete reason "pass_out").
exports.runPassOutJob = onSchedule({ schedule: "0 7 * * *", timeZone: "UTC" }, async () => {
  const result = await runPassOutJob({ db, config: schedulerConfig("pass-out-job") });
  log(`pass-out job: ${result.status} — ${JSON.stringify(result.summary)}`);
});

// ─────────────────────────────────────────────────────────────────────────────
// Phase 4 — Attendance reports (docs/TASKS.md). Fallback pattern matches
// Phase 3 exactly; both paths share functions/report-generator.js:
//
//   generateReport  — HttpsCallable "endpoint": the app calls this with
//                     { periodType, startDate, endDate, department?, year? }
//                     from the Blaze ReportService. Role-gated (pt_sir/admin).
//                     Writes the Excel/PDF into Cloud Storage under
//                     reports/{reportId}/ and returns short-lived signed URLs
//                     (STORAGE §7 — files are never public) + the stats.
//
// On Spark the equivalent of this endpoint is `scripts/generate-report.js`:
// the app enqueues a `report_requests` doc and the Admin-SDK runner writes the
// same files to the local reports/ folder. Signatures for both are published
// in docs/NOTES.md.
// ─────────────────────────────────────────────────────────────────────────────

const REPORT_ALLOWED_ROLES = ["pt_sir", "admin"];
const REPORT_SIGNED_URL_TTL_MS = 1000 * 60 * 60 * 24 * 30;

function restoreReportRequest(data) {
  return {
    periodType: data.periodType || null,
    startDate: data.startDate || null,
    endDate: data.endDate || null,
    department: data.department || null,
    year: data.year || null,
    requestedBy: data.requestedBy || null,
  };
}

exports.generateReport = onCall(async (request) => {
  const role = request.auth?.token?.role;
  if (!REPORT_ALLOWED_ROLES.includes(role)) {
    throw new HttpsError(
      "permission-denied",
      "Only PT sir or an admin can generate attendance reports (SECURITY.md §5, §8)."
    );
  }
  const reportRequest = restoreReportRequest(request.data || {});
  if (!["daily", "weekly", "monthly", "custom"].includes(reportRequest.periodType)) {
    throw new HttpsError("invalid-argument", "Provide a report periodType: daily | weekly | monthly | custom.");
  }
  // After validation: malformed retries must not consume quota (review finding).
  await enforceRateLimit(db, { uid: request.auth.uid, bucket: "report" });

  const result = await generateReport({
    db,
    request: { ...reportRequest, requestedBy: reportRequest.requestedBy || request.auth.uid },
  });
  if (result.status !== "generated") {
    throw new HttpsError("invalid-argument", `${result.code}: ${result.detail}`);
  }

  const reportId = `report_${Date.now().toString(36)}`;
  const bucket = getStorage().bucket();

  const save = async (name, base64, contentType) => {
    const file = bucket.file(`reports/${reportId}/${name}`);
    await file.save(Buffer.from(base64, "base64"), { contentType, resumable: false });
    return file;
  };

  try {
    const xlsx = await save(`${result.fileStem}.xlsx`, result.xlsxBase64, result.files[0].contentType);
    const pdf = await save(`${result.fileStem}.pdf`, result.pdfBase64, result.files[1].contentType);

    // Short-lived signed URLs — the app gets links, never the binary payload
    // (avoids the 10 MB callable limit and keeps files private to staff).
    let xlsxUrl = null;
    let pdfUrl = null;
    try {
      const expires = Date.now() + REPORT_SIGNED_URL_TTL_MS;
      [xlsxUrl, pdfUrl] = await Promise.all([
        xlsx.getSignedUrl({ action: "read", expires }),
        pdf.getSignedUrl({ action: "read", expires }),
      ]);
    } catch (signErr) {
      log(`signed-URL signing failed — falling back to object references: ${signErr.message}`);
    }

    await db
      .collection("report_logs")
      .doc(reportId)
      .set({
        ...reportLogDoc({ request: reportRequest, result, reportId }),
        generatedAt: FieldValue.serverTimestamp(),
      });

    return {
      reportId,
      label: result.label,
      startDate: result.startDate,
      endDate: result.endDate,
      stats: result.stats,
      storagePath: `reports/${reportId}/`,
      xlsxUrl,
      pdfUrl,
    };
  } catch (err) {
    log(`report storage failed for ${reportId}: ${err.message}`);
    throw new HttpsError(
      "internal",
      "The report was generated but the files couldn\u2019t be stored. Check cloud storage."
    );
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// Phase 4 — Admin (docs-new-updates/NEW_TASKS.md §Phase 4). Same pattern as the
// mail/report endpoints, but ADMIN-ONLY (NEW_SECURITY.md: exactly two roles,
// and only `admin` manages student master data):
//
//   commitImportBatch     — validates + commits an Excel import sheet (server
//                           re-validates departments/roster; rows with errors
//                           are skipped) and writes import_batches metadata.
//   adminSoftDelete       — two-stage stage 1: archive a set of students +
//                           write deletion_records evidence (DECISIONS #12).
//   adminRestore          — reverse the soft delete; the deletion record goes.
//   adminPermanentDelete  — remove the student docs (incl. their inline photo)
//                           forever; the deletion_records evidence is KEPT as
//                           retention/audit evidence (DECISIONS #13).
//
// On Spark the app writes the same intents to `admin_requests` and
// scripts/process-admin.js executes them with the SAME functions in
// functions/admin-scheduler.js. Pass-out review is a READ-ONLY, computed view
// over students (batchEndYear reached) — the callable never deletes anyone;
// the admin reviews and only then soft-deletes — see weekly-audit-core's note
// that pass-out must NOT auto-delete (NEW_UPDATES_PRD.md §Pass-out).
// ─────────────────────────────────────────────────────────────────────────────

function requireAdminRole(request) {
  const role = request.auth?.token?.role;
  if (!ADMIN_ROLES.includes(role)) {
    throw new HttpsError(
      "permission-denied",
      "Only an admin can manage student master data (NEW_SECURITY.md §5, §8)."
    );
  }
  return request.auth.uid;
}

exports.commitImportBatch = onCall(async (request) => {
  const requestedBy = requireAdminRole(request);
  const data = request.data || {};
  // Cheap invariants FIRST, mirroring admin-scheduler's abort codes, so
  // malformed retries don't burn the import quota (review finding).
  if (!data.importId) {
    throw new HttpsError("invalid-argument", "MISSING_IMPORT_ID: An importId is required.");
  }
  await enforceRateLimit(db, { uid: requestedBy, bucket: "import" });

  const result = await runCommitImportBatch({
    db,
    request: {
      importId: data.importId,
      filename: data.filename || null,
      departmentId: data.departmentId || null,
      department: data.department || null,
      rows: Array.isArray(data.rows) ? data.rows : [],
      requestedBy: data.requestedBy || requestedBy,
    },
  });
  if (result.status === "abort") {
    throw new HttpsError("invalid-argument", `${result.code}: ${result.detail}`);
  }
  return result;
});

exports.adminSoftDelete = onCall(async (request) => {
  const deletedBy = requireAdminRole(request);
  const data = request.data || {};
  if (!Array.isArray(data.studentIds) || data.studentIds.length === 0) {
    throw new HttpsError("invalid-argument", "NO_STUDENTS: Provide at least one studentId.");
  }
  // After validation: malformed retries must not consume quota (review finding).
  await enforceRateLimit(db, { uid: deletedBy, bucket: "admin_write" });

  const result = await runSoftDelete({
    db,
    request: {
      studentIds: Array.isArray(data.studentIds) ? data.studentIds : [],
      reason: data.reason,
      deletedBy: data.deletedBy || deletedBy,
    },
  });
  if (result.status === "abort") {
    throw new HttpsError("invalid-argument", `${result.code}: ${result.detail}`);
  }
  return result;
});

exports.adminRestore = onCall(async (request) => {
  const restoredBy = requireAdminRole(request);
  const data = request.data || {};
  if (!Array.isArray(data.studentIds) || data.studentIds.length === 0) {
    throw new HttpsError("invalid-argument", "NO_STUDENTS: Provide at least one studentId.");
  }
  // After validation: malformed retries must not consume quota (review finding).
  await enforceRateLimit(db, { uid: restoredBy, bucket: "admin_write" });

  const result = await runRestore({
    db,
    request: {
      studentIds: Array.isArray(data.studentIds) ? data.studentIds : [],
      restoredBy: data.restoredBy || restoredBy,
    },
  });
  if (result.status === "abort") {
    throw new HttpsError("invalid-argument", `${result.code}: ${result.detail}`);
  }
  return result;
});

exports.adminPermanentDelete = onCall(async (request) => {
  const requestedBy = requireAdminRole(request);
  const data = request.data || {};
  if (!Array.isArray(data.studentIds) || data.studentIds.length === 0) {
    throw new HttpsError("invalid-argument", "NO_STUDENTS: Provide at least one studentId.");
  }
  // After validation: malformed retries must not consume quota (review finding).
  await enforceRateLimit(db, { uid: requestedBy, bucket: "admin_write" });

  const result = await runPermanentDelete({
    db,
    request: {
      studentIds: Array.isArray(data.studentIds) ? data.studentIds : [],
      requestedBy: data.requestedBy || requestedBy,
    },
  });
  if (result.status === "abort") {
    throw new HttpsError("invalid-argument", `${result.code}: ${result.detail}`);
  }
  return result;
});