// Pass-out job — Phase 5 "pass-out job" (docs-new-updates/NEW_TASKS.md,
// NEW_WORKFLOW.md §6, NEW_ADMIN_WORKFLOW.md). ONE shared implementation for
// both runtime paths, like every scheduler:
//
//   - Blaze:  functions/index.js runPassOutJob onSchedule (daily 07:00 UTC).
//   - Spark:  scripts/process-pass-out-job.js Admin-SDK runner (schedule it
//             with Windows Task Scheduler / cron).
//
// The job materialises a `pass_out_reviews/{studentId}` notification doc for
// every ACTIVE student whose declared batch end year has been reached — the
// server-authoritative record behind the Admin "Pass-out Review" screen. It
// NEVER deletes or archives anyone: the admin reviews the list and triggers the
// lifecycle (adminSoftDelete reason "pass_out"), which the scheduler resolves
// by flipping the review doc to `soft_deleted` (admin-scheduler.js). The rule
// mirror is functions/admin-core.js passOutEligible / passOutReviewStudents.
//
// Idempotent: a student who already has a review doc (any status) is left
// untouched, so an hourly/daily re-run cannot duplicate or undo notifications.
// The run is recorded in `cron_jobs/{id}` (server-only, admin-readable).

const { FieldValue } = require("firebase-admin/firestore");
const {
  passOutReviewStudents,
  passOutNotificationDoc,
} = require("./admin-core.js");

const REVIEW_STATUSES = new Set(["pending_review", "soft_deleted", "restored"]);

/**
 * Execute the pass-out job once.
 *
 * config:
 *   requestedBy  audit-log actor label (defaults to "pass-out-job").
 *   dryRun       compute the plan (students due a notification) but write
 *                nothing, and skip the cron_jobs row.
 *
 * Returns { status, planned, created, alreadyNotified, hidden, summary }.
 */
async function runPassOutJob({ db, config = {}, now = new Date() }) {
  const studentsSnap = await db.collection("students").get();
  const students = studentsSnap.docs.map((d) => ({ ...d.data(), studentId: d.id }));

  const eligible = passOutReviewStudents(students, now);
  const existingSnap = await db.collection("pass_out_reviews").get();
  const existingIds = new Map(existingSnap.docs.map((d) => [d.id, d.data() || {}]));

  const planned = [];
  for (const s of eligible) {
    const doc = existingIds.get(s.studentId);
    if (doc && REVIEW_STATUSES.has(doc.status)) continue; // already notified/resolved
    planned.push({
      studentId: s.studentId,
      name: s.name,
      department: s.department,
      departmentId: s.departmentId ?? null,
      batchStartYear: s.batchStartYear ?? null,
      batchEndYear: s.batchEndYear ?? null,
    });
  }

  if (config.dryRun) {
    return { status: "dry-run", planned, summary: { pending: planned.length, alreadyNotified: eligible.length - planned.length } };
  }

  const created = [];
  const batch = db.batch();
  for (const p of planned) {
    batch.set(
      db.collection("pass_out_reviews").doc(p.studentId),
      passOutNotificationDoc({ student: p, at: now }),
      { merge: true }
    );
    created.push(p.studentId);
  }
  if (created.length > 0) await batch.commit();

  const jobId = "pass_out_review";
  await db.collection("cron_jobs").doc(jobId).set({
    type: "pass_out_review",
    jobId,
    status: "done",
    summary: { pending: planned.length, alreadyNotified: eligible.length - planned.length, created: created.length },
    created,
    requestedBy: config.requestedBy || "pass-out-job",
    ranAt: FieldValue.serverTimestamp(),
  });

  return {
    status: "done",
    planned,
    created,
    summary: { pending: planned.length, alreadyNotified: eligible.length - planned.length, created: created.length },
  };
}

module.exports = {
  REVIEW_STATUSES,
  runPassOutJob,
};