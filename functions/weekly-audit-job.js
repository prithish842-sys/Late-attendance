// Weekly audit job — Phase 5 "weekly audit job" (docs-new-updates/NEW_TASKS.md,
// NEW_WORKFLOW.md §5). Like the rest of the automation, this is ONE shared
// implementation used by both runtime paths so behaviour never diverges:
//
//   - Blaze:  functions/index.js runWeeklyAuditJob onSchedule (Mon 06:00 UTC,
//             auditing the completed week).
//   - Spark:  scripts/process-weekly-audit-job.js Admin-SDK runner (run on a
//             schedule, e.g. Windows Task Scheduler / cron).
//
// The job mirrors the manual Weekly Audit flow start-to-finish for EVERY
// department that has late entries in the week: it loads the week's late rows,
// aggregates per department (weekly-audit-core.js), skips departments that
// already have a weekly_audit mail_logs row for that week (idempotent — a
// re-run cannot double-mail), then sends each due department's formal HOD mail
// through the exact same processQueuedWeeklyAudit as the app/queue. It never
// deletes anything and never registers a "no rows" department.
//
// The run is recorded in `cron_jobs/{id}` (server-only, admin-readable) for
// the audit trail / monitoring.

const { FieldValue } = require("firebase-admin/firestore");
const { formatDate, normalizeToken, resolveDepartment } = require("./mail-core.js");
const { loadDepartments } = require("./mail-sender.js");
const { loadReportRows } = require("./report-generator.js");
const {
  monthKeyOf,
  weeklyWindow,
  weeklyAuditRange,
  planWeeklyAuditDepartments,
  aggregateWeeklyAudit,
} = require("./weekly-audit-core.js");
const { processQueuedWeeklyAudit, DEFAULT_REPEAT_THRESHOLD } = require("./weekly-audit-sender.js");

/** Normalized department keys that already have a weekly_audit mail_logs row. */
async function alreadySentKeysForWeek(db, window) {
  const startIso = window.start.toISOString();
  const logs = await db.collection("mail_logs")
    .where("type", "==", "weekly_audit")
    .get();
  const keys = [];
  for (const d of logs.docs) {
    const x = d.data();
    if (x.startDate && x.startDate !== startIso) continue;
    if (x.departmentId) keys.push(normalizeToken(x.departmentId));
    if (x.department) keys.push(normalizeToken(x.department));
  }
  return keys;
}

/**
 * Execute the weekly audit job for one week.
 *
 * config:
 *   weekStartDate  "YYYY-MM-DD" (a Monday). Null/absent → the current week.
 *   repeatThreshold defaults to 2 (same default as the app).
 *   dryRun         build everything / compute the plan but send nothing and
 *                  write no cron_jobs row.
 *   requestedBy    audit-log actor label (defaults to "weekly-audit-job").
 *   collegeName    passed to the sender's mail body.
 *   apiKey/from    passed to the sender for the real Resend call.
 *
 * Returns { status, weekLabel, range, planned, summary } — planned exposes
 * { due, alreadySent, noHod } so callers (and tests) can see the plan plainly.
 */
async function runWeeklyAuditJob({ db, config = {} }) {
  const window = weeklyWindow({ startDate: config.weekStartDate || null });
  if (!window) {
    return {
      status: "abort",
      code: "INVALID_RANGE",
      detail: "The weekly audit job needs a Monday week start (startDate YYYY-MM-DD, defaults to the current week).",
    };
  }

  const repeatThreshold =
    Number.isInteger(config.repeatThreshold) && config.repeatThreshold > 0
      ? config.repeatThreshold
      : DEFAULT_REPEAT_THRESHOLD;

  const [depts, alreadySentKeys] = await Promise.all([
    loadDepartments(db),
    alreadySentKeysForWeek(db, window),
  ]);

  const loaded = await loadReportRows(db, {
    periodType: "weekly",
    startDate: formatDate(window.start),
  });
  const rows = loaded.window ? loaded.rows : [];

  // Per-department rolls from the week's rows. aggregateWeeklyAudit groups +
  // sorts by count; we enrich each with its departments doc (id + hodEmail).
  const audit = aggregateWeeklyAudit(rows, {
    monthKey: monthKeyOf(window.start),
    repeatThreshold,
  });
  const candidates = [];
  for (const group of audit.departments) {
    const resolved = resolveDepartment(group.department, depts);
    candidates.push({
      departmentId: resolved ? resolved.departmentId : null,
      departmentName: resolved ? resolved.name : group.department,
      hodEmail: resolved ? resolved.hodEmail : null,
      uniqueStudents: group.uniqueStudents,
      totalEvents: group.totalEvents,
      repeatedStudents: group.repeatedStudents,
    });
  }

  const planned = planWeeklyAuditDepartments({ candidates, alreadySentKeys, repeatThreshold });
  const range = weeklyAuditRange(window);

  if (config.dryRun) {
    return {
      status: "dry-run",
      weekLabel: window.label,
      range,
      weekStart: window.start.toISOString(),
      weekEnd: window.end.toISOString(),
      planned,
      summary: { due: planned.due.length, alreadySent: planned.alreadySent.length, noHod: planned.noHod.length },
    };
  }

  const results = [];
  const summary = { due: 0, alreadySent: 0, noHod: 0, sent: 0, failed: 0, skipped: 0 };
  for (const c of planned.due) {
    summary.due++;
    const mailRequestId = `weekly_audit_${normalizeToken(c.departmentId || c.departmentName) || "dept"}_${range}`;
    try {
      const result = await processQueuedWeeklyAudit({
        db,
        request: {
          departmentId: c.departmentId,
          department: c.departmentName,
          startDate: formatDate(window.start),
          requestedBy: config.requestedBy || "weekly-audit-job",
        },
        mailRequestId,
        config: {
          apiKey: config.apiKey,
          from: config.from,
          collegeName: config.collegeName,
          repeatThreshold,
        },
      });
      if (result.status === "sent") {
        summary.sent++;
        results.push({ departmentId: c.departmentId, departmentName: c.departmentName, status: "sent" });
      } else {
        summary.failed++;
        results.push({ departmentId: c.departmentId, departmentName: c.departmentName, status: "failed", code: result.code, detail: result.detail });
      }
    } catch (err) {
      summary.failed++;
      results.push({ departmentId: c.departmentId, departmentName: c.departmentName, status: "failed", error: err.message });
    }
  }
  summary.alreadySent = planned.alreadySent.length;
  summary.noHod = planned.noHod.length;
  summary.skipped = planned.due.length - results.length; // defensive; normally 0

  if (results.length > 0 || summary.alreadySent > 0 || summary.noHod > 0 || summary.failed > 0) {
    const jobId = `weekly_audit_${range}`;
    await db.collection("cron_jobs").doc(jobId).set({
      type: "weekly_audit",
      jobId,
      weekStart: window.start.toISOString(),
      weekEnd: window.end.toISOString(),
      weekLabel: window.label,
      range,
      status: summary.failed > 0 && summary.sent === 0 ? "failed" : summary.failed > 0 ? "partial" : "done",
      summary,
      results,
      requestedBy: config.requestedBy || "weekly-audit-job",
      ranAt: FieldValue.serverTimestamp(),
    });
  }

  return {
    status: "done",
    weekLabel: window.label,
    range,
    weekStart: window.start.toISOString(),
    weekEnd: window.end.toISOString(),
    planned,
    summary,
    results,
  };
}

module.exports = {
  alreadySentKeysForWeek,
  runWeeklyAuditJob,
};