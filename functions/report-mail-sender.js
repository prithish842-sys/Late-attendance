// Shared report-mail orchestration — the stage between the mail_queue intent and
// the Resend call. Used by BOTH runtime paths so behaviour never diverges:
//
//   - Blaze:  functions/index.js processMailQueue Cloud Function (or the
//             sendReportMail callable) calls processQueuedReportMail().
//   - Spark:  scripts/process-mail.js Admin-SDK runner calls
//             processQueuedReportMail().
//
// Server-authoritative only (docs/SECURITY.md §8, NEW_SECURITY.md): this runs
// with admin privileges, reads late_logs / students / departments via
// generateReport's loadReportRows, builds the Excel + PDF(s), sends via Resend,
// and writes the mail_logs audit record with type "report". The client only
// enqueues mail_queue requests and previews the expected shape locally
// (lib/.../app_models.dart buildReportMailBodyPreview + reportMailAttachmentNames).

const { FieldValue } = require("firebase-admin/firestore");
const {
  sendViaResend,
  mailLogDoc,
} = require("./mail-core.js");
const {
  runReportStats,
  buildReportXlsx,
  buildReportPdf,
  yearTier,
  yearTierLabel,
  MIME,
} = require("./report-core.js");
const { loadReportRows } = require("./report-generator.js");
const {
  reportMailDateRange,
  reportMailSubject,
  reportMailAttachmentNames,
  buildReportMailHtml,
} = require("./report-mail-core.js");
const { defaultFrom, resolveRequestDepartment } = require("./mail-sender.js");

/**
 * Execute one report mail request (a mail_queue doc with type "report").
 * Returns a stable status object for the queue processor to record:
 *   { status: "sent", resendId, to, mailLogId, subject, range, files, stats }
 *   { status: "abort", code, detail }            — not sent, no audit row
 *   { status: "dry-run", to, subject, ... }      — everything built, nothing sent
 */
async function processQueuedReportMail({ db, request, mailRequestId, config = {} }) {
  if (!request.periodType) {
    return {
      status: "abort",
      code: "INVALID_RANGE",
      detail: "Provide a report periodType: daily | weekly | monthly | custom.",
    };
  }

  const loaded = await loadReportRows(db, request);
  if (!loaded.window) {
    return {
      status: "abort",
      code: "INVALID_RANGE",
      detail:
        "periodType must be daily | weekly | monthly | custom, and custom needs a valid start ≤ end date range.",
    };
  }
  const { window, rows } = loaded;

  if (!request.departmentId && !request.department) {
    return {
      status: "abort",
      code: "NO_DEPARTMENT",
      detail: "Provide a report department (departmentId or department display string).",
    };
  }

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
      detail: "No late entries match this report request (no rows in this window for the department/year).",
    };
  }

  const range = reportMailDateRange(window);
  const mode = request.attachmentMode === "split" ? "split" : "combined";
  const stats = runReportStats(rows);
  const groups = [3, 2, 1, 0]
    .map((tier) => ({ tier, rows: rows.filter((r) => yearTier(r.year) === tier) }))
    .filter((g) => g.rows.length > 0);
  const presentTiers = new Set(groups.map((g) => g.tier));
  const names = reportMailAttachmentNames({
    department: resolved.departmentId || resolved.name,
    range,
    mode,
    tiers: presentTiers,
  });

  // Workbook first — names[0].pdf listing drives the send order (xlsx, then
  // the one combined PDF, or one PDF per tier in 3rd → 2nd → 1st → Other order).
  const xlsx = await buildReportXlsx({ rows, stats, label: window.label });
  const attachments = [
    {
      filename: names[0].filename,
      content: xlsx.toString("base64"),
      content_type: names[0].contentType,
    },
  ];

  if (mode === "split") {
    for (let i = 0; i < groups.length; i++) {
      const g = groups[i];
      const pdf = await buildReportPdf({
        rows: g.rows,
        stats: runReportStats(g.rows),
        label: `${window.label} — ${yearTierLabel(g.tier)}`,
      });
      attachments.push({
        filename: names[i + 1].filename,
        content: pdf.toString("base64"),
        content_type: MIME.pdf,
      });
    }
  } else {
    const pdf = await buildReportPdf({ rows, stats, label: window.label });
    attachments.push({
      filename: names[1].filename,
      content: pdf.toString("base64"),
      content_type: MIME.pdf,
    });
  }

  const subject = reportMailSubject(resolved.name, range);
  const html = buildReportMailHtml({
    collegeName: config.collegeName,
    departmentName: resolved.name,
    range,
    rows,
  });
  const to = config.toOverride || resolved.hodEmail;
  const from = config.from || defaultFrom();
  const distinctStudentIds = [...new Set(rows.map((r) => r.studentId))];

  if (config.dryRun) {
    return {
      status: "dry-run",
      to,
      subject,
      range,
      mode,
      departmentName: resolved.name,
      rowCount: rows.length,
      stats,
      tierGroups: groups.map((g) => ({ tier: g.tier, label: yearTierLabel(g.tier), count: g.rows.length })),
      studentsIncluded: distinctStudentIds,
      attachmentsPreview: attachments.map((a) => ({
        filename: a.filename,
        content_type: a.content_type,
        content_id: a.content_id || null,
        sizeBytes: Buffer.from(a.content, "base64").byteLength,
      })),
    };
  }

  const sent = await sendViaResend({ apiKey: config.apiKey, from, to, subject, html, attachments });
  const studentIds = distinctStudentIds;

  const logDoc = {
    ...mailLogDoc({
      departmentId: resolved.departmentId,
      department: resolved.name,
      period: window.label,
      to,
      subject,
      studentsIncluded: studentIds,
      triggeredBy: request.requestedBy || null,
      mailRequestId,
      resendId: sent.id,
    }),
    type: "report",
    label: range,
    startDate: window.start.toISOString(),
    endDate: window.end.toISOString(),
    files: names.map((n) => n.filename),
    attachmentMode: mode,
    rowCount: rows.length,
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
    files: logDoc.files,
    stats,
  };
}

module.exports = {
  processQueuedReportMail,
};