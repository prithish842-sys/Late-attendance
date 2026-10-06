// Pure building blocks for the Phase 2 report mail (docs-new-updates/NEW_TASKS.md).
//
// CommonJS like mail-core.js so both the Blaze Cloud Function
// (functions/index.js, require) and the Spark Admin-SDK runner
// (scripts/process-mail.js, ESM import) load the exact same logic. Everything
// here is stateless and testable (functions/test/report-mail-core.test.js).
//
// The client preview (lib/src/models/app_models.dart buildReportMailBodyPreview
// + reportMailAttachmentNames) mirrors these shapes so what the HOD previews is
// exactly what the server sends. Keep both in parity.

const { formatDate, normalizeToken, esc } = require("./mail-core.js");
const { addDays, yearTier, yearTierLabel, reportTierToken, MIME } = require("./report-core.js");

const CSS = {
  font: "Helvetica, Arial, sans-serif",
  ink: "#232323",
  navy: "#1B2A4A",
  maroon: "#8B1E1E",
  sand: "#E8E2D8",
  white: "#ffffff",
};

/**
 * Attachment date-range key for a report window (half-open [start, end)):
 * a single day is just "YYYY-MM-DD", otherwise "start_to_end". The end shown
 * is inclusive — the window's exclusive end minus one day. Mirrors Dart
 * `reportMailRange`.
 */
function reportMailDateRange(window) {
  const start = window.start;
  const endInclusive = window.end > start ? addDays(window.end, -1) : start;
  const s = formatDate(start);
  const e = formatDate(endInclusive);
  return s === e ? s : `${s}_to_${e}`;
}

/**
 * Filename stem: "{dept_slug}_Late_Attendance_{range}" (NEW_REPORT_MAIL_WORKFLOW.
 * md). The slug is the canonical department id tokenized — "BSC-CS" → "bsccs",
 * so it matches the client preview exactly.
 */
function reportMailFileStem(department, range) {
  const slug = normalizeToken(department);
  return `${slug || "report"}_Late_Attendance_${range}`;
}

/** Subject line for the HOD report mail. */
function reportMailSubject(department, range) {
  return `Late Attendance Report - ${department} - ${range}`;
}

/**
 * Attachment names for a report mail, in send order:
 *   combined — one summary PDF + the Excel workbook
 *   split    — one PDF per present tier (3rd, 2nd, 1st, then Other) + workbook
 * Split PDFs follow the NEW_REPORT_MAIL_WORKFLOW.md naming <slug>_<tier>_Year_
 * <range>.pdf (e.g. bsccs_3rd_Year_2026-09-01_to_2026-09-30.pdf). Mirrors Dart
 * `reportMailAttachmentNames`.
 */
function reportMailAttachmentNames({ department, range, mode = "combined", tiers = [] }) {
  const stem = reportMailFileStem(department, range);
  if (mode !== "split") {
    return [
      { filename: `${stem}.xlsx`, contentType: MIME.xlsx },
      { filename: `${stem}.pdf`, contentType: MIME.pdf },
    ];
  }
  const slug = normalizeToken(department) || "report";
  const xlsx = { filename: `${stem}.xlsx`, contentType: MIME.xlsx };
  const pdfs = [...tiers]
    .sort((a, b) => b - a)
    .map((tier) => ({
      filename: `${slug}_${reportTierToken(tier)}_Year_${range}.pdf`,
      contentType: MIME.pdf,
    }));
  return [xlsx, ...pdfs];
}

/** Group report rows by year tier into [3, 2, 1, 0] (dropping empty tiers). */
function groupRowsByTier(rows) {
  const order = [3, 2, 1, 0];
  return order
    .map((tier) => ({
      tier,
      label: yearTierLabel(tier),
      entries: rows.filter((r) => yearTier(r.year) === tier),
    }))
    .filter((g) => g.entries.length > 0);
}

/**
 * Build the professional report mail body. `rows` come from loadReportRows
 * (server-authoritative), each with { studentId, name, department, year }.
 * The student list is grouped by year tier (3rd → 2nd → 1st → Other) exactly
 * like the Flutter preview; everything user-derived is escaped.
 */
function buildReportMailHtml({ collegeName, departmentName, range, rows }) {
  const college = esc(collegeName || "Sankara College of Science & Commerce");
  const dept = esc(departmentName || "");
  const rangeLabel = esc(range || "");
  const totalLateEntries = rows.length;
  const distinctStudents = new Set(rows.map((r) => r.studentId)).size;

  const blocks = groupRowsByTier(rows).map((g) => tierBlock(g)).join("\n");

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
</head>
<body style="margin:0;background:${CSS.white};color:${CSS.ink};font-family:${CSS.font};">
  <div style="max-width:680px;margin:0 auto;padding:28px 24px;">
    <div style="border-bottom:3px solid ${CSS.maroon};padding-bottom:14px;margin-bottom:20px;">
      <div style="color:${CSS.navy};font-size:20px;font-weight:700;line-height:1.2;">${college}</div>
      <div style="color:${CSS.maroon};font-size:13px;font-weight:600;margin-top:4px;">Late Attendance Report &mdash; ${dept}${rangeLabel ? " &mdash; " + rangeLabel : ""}</div>
    </div>

    <p style="font-size:14px;line-height:1.6;margin:0 0 8px;">Dear HOD,</p>
    <p style="font-size:14px;line-height:1.6;margin:0 0 8px;">Please find the late attendance report for ${dept} covering ${rangeLabel}.</p>
    <p style="font-size:14px;line-height:1.6;margin:0 0 8px;">The following students were marked late during this period:</p>

    ${blocks}

    <p style="font-size:14px;line-height:1.6;margin:18px 0 0;">
      In total, <strong>${totalLateEntries} late entr${totalLateEntries === 1 ? "y" : "ies"}</strong> were recorded for
      <strong>${distinctStudents} ${distinctStudents === 1 ? "student" : "students"}</strong> in this period.
    </p>
    <p style="font-size:13px;line-height:1.6;margin:8px 0 0;color:#444;">The complete report is attached — a single PDF along with the Excel workbook. Please review the students listed and take whatever action the department deems appropriate.</p>
    <p style="font-size:13px;line-height:1.6;margin:18px 0 0;">Regards,<br>${college}</p>
    <p style="font-size:12px;line-height:1.6;margin:14px 0 0;color:#777;border-top:1px solid ${CSS.sand};padding-top:10px;">This is an automated report from the gate-duty attendance scanner. No reply is monitored.</p>
  </div>
</body>
</html>`;
}

function tierBlock(g) {
  const rowsLines = g.entries
    .map(
      (r, i) => `<tr>
          <td style="padding:6px 8px;font-size:12px;border-top:1px solid ${CSS.sand};${i === 0 ? "background:#FAFAF7;" : ""}">${esc(r.studentId)}</td>
          <td style="padding:6px 8px;font-size:12px;border-top:1px solid ${CSS.sand};${i === 0 ? "background:#FAFAF7;" : ""}">${esc(r.name)}</td>
        </tr>`
    )
    .join("\n");

  return `<table role="presentation" cellpadding="0" cellspacing="0" style="width:100%;border:1px solid ${CSS.sand};border-radius:4px;margin:14px 0;">
    <tr>
      <td colspan="2" style="padding:8px 10px;background:${CSS.navy};color:${CSS.white};font-size:12px;font-weight:700;">${esc(g.label)} (${g.entries.length})</td>
    </tr>
    ${rowsLines}
  </table>`;
}

module.exports = {
  reportMailDateRange,
  reportMailFileStem,
  reportMailSubject,
  reportMailAttachmentNames,
  groupRowsByTier,
  buildReportMailHtml,
};