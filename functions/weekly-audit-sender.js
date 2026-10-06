// Shared weekly-audit mail orchestration — the stage between the mail_queue
// intent and the Resend call. Used by BOTH runtime paths so behaviour never
// diverges (mirrors functions/report-mail-sender.js):
//
//   - Blaze:  functions/index.js processMailQueue Cloud Function (or the
//             sendWeeklyAuditMail callable) calls processQueuedWeeklyAudit().
//   - Spark:  scripts/process-mail.js Admin-SDK runner calls
//             processQueuedWeeklyAudit().
//
// Server-authoritative only (docs/SECURITY.md §8, NEW_SECURITY.md): this runs
// with admin privileges, reads late_logs / students / departments via
// loadReportRows, aggregates the week (weekly-audit-core.js), builds the
// Excel + PDF, sends via Resend, and writes the mail_logs audit record with
// type "weekly_audit" (audit history — NEW_AUDIT_WORKFLOW.md shows week,
// department, recipient, timestamp, status and attachment). The client only
// enqueues mail_queue requests and previews the expected shape locally
// (lib/.../app_models.dart weeklyAuditOverview + buildWeeklyAuditBodyPreview).

const { FieldValue } = require("firebase-admin/firestore");
const { sendViaResend, mailLogDoc } = require("./mail-core.js");
const { loadReportRows } = require("./report-generator.js");
const {
  monthKeyOf,
  weeklyAuditRange,
  weeklyAuditSubject,
  weeklyAuditAttachmentNames,
  aggregateWeeklyAudit,
  buildWeeklyAuditHtml,
  buildWeeklyAuditXlsx,
  buildWeeklyAuditPdf,
} = require("./weekly-audit-core.js");
const { defaultFrom, resolveRequestDepartment } = require("./mail-sender.js");

const DEFAULT_REPEAT_THRESHOLD = 2;

/**
 * Execute one weekly-audit mail request (a mail_queue doc with type
 * "weekly_audit"). Returns a stable status object for the queue processor to
 * record:
 *   { status: "sent", resendId, to, mailLogId, subject, range, files,
 *     weekLabel, stats }
 *   { status: "abort", code, detail }            — not sent, no audit row
 *   { status: "dry-run", to, subject, ... }      — everything built, nothing sent
 */
async function processQueuedWeeklyAudit({ db, request, mailRequestId, config = {} }) {
  if (!request.departmentId && !request.department) {
    return {
      status: "abort",
      code: "NO_DEPARTMENT",
      detail: "Provide a weekly-audit department (departmentId or department display string).",
    };
  }

  const loaded = await loadReportRows(db, {
    periodType: "weekly",
    startDate: request.startDate || null,
    department: request.departmentId || request.department,
  });
  if (!loaded.window) {
    return {
      status: "abort",
      code: "INVALID_RANGE",
      detail: "The weekly audit needs a Monday week start (startDate YYYY-MM-DD, defaults to the current week).",
    };
  }
  const { window, rows } = loaded;

  const resolved = await resolveRequestDepartment(db, request);
  if (!resolved || !resolved.hodEmail) {
    return {
      status: "abort",
      code: "NO_HOD_EMAIL",
      detail: `No HOD email resolvable for '${request.departmentId || request.department || "?"}' (check the departments collection).`,
    };
  }
  if (rows.length === 0) {
    return {
      status: "abort",
      code: "NO_ROWS",
      detail: "No late entries fall in this week for the department — nothing to audit yet.",
    };
  }

  const repeatThreshold =
    Number.isInteger(config.repeatThreshold) && config.repeatThreshold > 0
      ? config.repeatThreshold
      : DEFAULT_REPEAT_THRESHOLD;

  const monthKey = monthKeyOf(window.start);
  const audit = aggregateWeeklyAudit(rows, { monthKey, repeatThreshold });
  const group = audit.departments[0];
  const repeated = group.students.filter((s) => s.repeated);
  const range = weeklyAuditRange(window);
  const weekLabel = window.label;
  const names = weeklyAuditAttachmentNames(resolved.departmentId || resolved.name, range);

  const xlsx = await buildWeeklyAuditXlsx({ group, departmentName: resolved.name, weekLabel });
  const pdf = await buildWeeklyAuditPdf({ group, departmentName: resolved.name, weekLabel });
  const attachments = [
    {
      filename: names[0].filename,
      content: xlsx.toString("base64"),
      content_type: names[0].contentType,
    },
    {
      filename: names[1].filename,
      content: pdf.toString("base64"),
      content_type: names[1].contentType,
    },
  ];

  const subject = weeklyAuditSubject(resolved.name, range);
  const html = buildWeeklyAuditHtml({
    collegeName: config.collegeName,
    departmentName: resolved.name,
    weekLabel,
    group,
  });
  const to = config.toOverride || resolved.hodEmail;
  const from = config.from || defaultFrom();
  const repeatedIds = repeated.map((s) => s.studentId);
  const stats = {
    totalLateEntries: audit.totalEvents,
    distinctStudents: audit.uniqueStudents,
    repeatedStudents: audit.repeatedStudents,
  };

  if (config.dryRun) {
    return {
      status: "dry-run",
      to,
      subject,
      range,
      weekLabel,
      departmentName: resolved.name,
      rowCount: rows.length,
      stats,
      studentsIncluded: repeatedIds,
      attachmentsPreview: attachments.map((a) => ({
        filename: a.filename,
        content_type: a.content_type,
        content_id: a.content_id || null,
        sizeBytes: Buffer.from(a.content, "base64").byteLength,
      })),
    };
  }

  const sent = await sendViaResend({ apiKey: config.apiKey, from, to, subject, html, attachments });

  const logDoc = {
    ...mailLogDoc({
      departmentId: resolved.departmentId,
      department: resolved.name,
      period: weekLabel,
      to,
      subject,
      studentsIncluded: repeatedIds,
      triggeredBy: request.requestedBy || null,
      mailRequestId,
      resendId: sent.id,
    }),
    type: "weekly_audit",
    label: range,
    weekLabel,
    startDate: window.start.toISOString(),
    endDate: window.end.toISOString(),
    files: names.map((n) => n.filename),
    rowCount: rows.length,
    repeatedStudentCount: repeated.length,
    stats,
  };
  await db.collection("mail_logs").doc(mailRequestId).set({
    ...logDoc,
    sentTimestamp: FieldValue.serverTimestamp(),
  });

  return {
    status: "sent",
    resendId: sent.id,
    to,
    mailLogId: mailRequestId,
    subject,
    range,
    weekLabel,
    files: logDoc.files,
    stats,
  };
}

module.exports = {
  processQueuedWeeklyAudit,
  DEFAULT_REPEAT_THRESHOLD,
};