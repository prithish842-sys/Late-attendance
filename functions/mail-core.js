// Pure building blocks for the HOD escalation mail (Phase 3 of docs/TASKS.md).
//
// CommonJS like escalation-core.js so both the Blaze Cloud Function
// (functions/index.js, require) and the Spark Admin-SDK runner
// (scripts/process-mail.js, ESM import) load the exact same logic.
//
// Everything here is stateless and testable (functions/test/mail-core.test.js).
// The Resend call goes out over plain fetch so no extra SDK is needed, and the
// Resend API key is NEVER accepted here from Flutter/Web — only from a
// server-side caller via `sendViaResend({ ..., apiKey })` (docs/SECURITY.md §6).

const CSS = {
  font: "Helvetica, Arial, sans-serif",
  ink: "#232323",
  navy: "#1B2A4A",
  maroon: "#8B1E1E",
  sand: "#E8E2D8",
  white: "#ffffff",
};

function esc(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** YYYY-MM-DD from a Date (UTC) — tabular, matches late_logs doc ids. */
function formatDate(date) {
  const y = date.getUTCFullYear();
  const m = String(date.getUTCMonth() + 1).padStart(2, "0");
  const d = String(date.getUTCDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
}

/** HH:MM from a Date (UTC). */
function formatTime(date) {
  const h = String(date.getUTCHours()).padStart(2, "0");
  const min = String(date.getUTCMinutes()).padStart(2, "0");
  return `${h}:${min}`;
}

/** Lowercase, alphanumerics-only token for fuzzy department matching. */
function normalizeToken(value) {
  return String(value || "").toLowerCase().replace(/[^a-z0-9]/g, "");
}

/**
 * Resolve a student's `department` display string against the `departments`
 * collection docs ({id, name, hodEmail}). Matches on the doc id OR its name
 * after normalization — so "B.SC CS" resolves to {id:"BSC-CS"}.
 * Returns null when nothing matches unambiguously.
 */
function resolveDepartment(studentDepartment, departmentDocs) {
  const needle = normalizeToken(studentDepartment);
  if (!needle) return null;
  let match = null;
  for (const d of departmentDocs || []) {
    const tokens = [d.id, d.name].map(normalizeToken);
    if (tokens.includes(needle)) {
      if (match) return null; // ambiguous — two departments both match
      match = { departmentId: d.id, name: d.name, hodEmail: d.hodEmail };
    }
  }
  return match;
}

/**
 * Build the professional escalation mail body. `students` is the escalated
 * bundle for one department, each with:
 *   { studentId, name, department, year, count, dates: [{date, time}],
 *     photo: { base64, mimeType } | null }
 * Photo references use cid: URLs backed by inline attachments (Resend
 * content_id), so photos are embedded but not hosted anywhere public.
 */
function buildMailHtml({ collegeName, departmentName, period, threshold, students }) {
  const college = esc(collegeName || "Sankara College of Science & Commerce");
  const dept = esc(departmentName || "");
  const periodLabel = esc(period || "");
  const t = Number.isInteger(threshold) && threshold > 0 ? threshold : 3;
  const n = students.length;

  const summaryBlock =
    n > 1
      ? `<table role="presentation" cellpadding="0" cellspacing="0" style="width:100%;border-collapse:collapse;margin:18px 0 6px;">
        <tr>
          <td style="padding:8px 10px;background:${CSS.navy};color:${CSS.white};font-size:12px;font-weight:700;">${n} students reached the escalation threshold this period</td>
        </tr>
      </table>`
      : "";

  const blocks = students.map((s) => studentBlock(s)).join("\n");

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
      <div style="color:${CSS.maroon};font-size:13px;font-weight:600;margin-top:4px;">Late Attendance Escalation &mdash; ${dept}${periodLabel ? " &mdash; " + periodLabel : ""}</div>
    </div>

    <p style="font-size:14px;line-height:1.6;margin:0 0 8px;">Dear HOD,</p>
    <p style="font-size:14px;line-height:1.6;margin:0 0 8px;">
      ${n === 1 ? `The following student has been late <strong>${n} or more times</strong> this period (<strong>threshold: ${t}</strong>).` : `The following <strong>${n} students</strong> have each been late <strong>${t} or more times</strong> this period.`}
      The late dates are listed below; a consolidated table is attached for your records.
    </p>

    ${summaryBlock}
    ${blocks}

    <p style="font-size:13px;line-height:1.6;margin:18px 0 0;color:#444;">These records were captured by the gate-duty attendance scanner. Please take whatever action the department deems appropriate.</p>
    <p style="font-size:12px;line-height:1.6;margin:14px 0 0;color:#777;border-top:1px solid ${CSS.sand};padding-top:10px;">This is an automated escalation report from ${college}. No reply is monitored.</p>
  </div>
</body>
</html>`;
}

function studentBlock(s) {
  const photo = s.photo?.base64
    ? `<img src="cid:photo_${esc(s.studentId)}" alt="Student photo" width="78" height="78" style="width:78px;height:78px;object-fit:cover;border:1px solid ${CSS.sand};border-radius:4px;display:block;">`
    : `<div style="width:78px;height:78px;background:${CSS.navy};color:${CSS.white};border-radius:4px;display:flex;align-items:center;justify-content:center;font-size:11px;text-align:center;padding:4px;box-sizing:border-box;">No photo on file</div>`;

  const year = s.year ? `<div style="font-size:13px;color:#555;margin-top:2px;">Year: ${esc(s.year)}</div>` : "";

  const datesTable =
    s.dates.length > 0
      ? `<table role="presentation" cellpadding="0" cellspacing="0" style="width:100%;border-collapse:collapse;margin-top:10px;">
        ${s.dates
          .map(
            (d, i) => `<tr>
          <td style="padding:6px 8px;font-size:12px;border-top:1px solid ${CSS.sand};${i === 0 ? "background:#FAFAF7;" : ""}">${esc(d.date)}</td>
          <td style="padding:6px 8px;font-size:12px;border-top:1px solid ${CSS.sand};${i === 0 ? "background:#FAFAF7;" : ""}">${esc(d.time)}</td>
        </tr>`
          )
          .join("\n")}
      </table>`
      : `<div style="font-size:12px;color:#777;margin-top:6px;">No individual dates recorded this period.</div>`;

  return `<table role="presentation" cellpadding="0" cellspacing="0" style="width:100%;border:1px solid ${CSS.sand};border-radius:4px;margin:14px 0;">
    <tr>
      <td style="padding:14px;width:110px;vertical-align:top;">${photo}</td>
      <td style="padding:14px 14px 14px 0;vertical-align:top;">
        <div style="color:${CSS.navy};font-size:16px;font-weight:700;">${esc(s.name)}</div>
        <div style="font-size:13px;color:#555;margin-top:2px;">Student ID: ${esc(s.studentId)}</div>
        <div style="font-size:13px;color:#555;margin-top:2px;">Department: ${esc(s.department || "—")}</div>
        ${year}
        <div style="margin-top:10px;display:inline-block;background:${CSS.maroon};color:${CSS.white};font-size:13px;font-weight:700;padding:4px 10px;border-radius:4px;">${esc(s.count)} late arrivals this period</div>
        ${datesTable}
      </td>
    </tr>
  </table>`;
}

/**
 * Excel (.xlsx) table of the escalated bundle, one row per student late date.
 * Columns: Student ID, Name, Department, Year, Late Count, Late Date, Time.
 * Uses exceljs (ARCHITECTURE.md §1.4); required lazily so the pure template
 * path stays dependency-free.
 */
async function buildXlsxAttachment(students, { departmentName }) {
  const ExcelJS = require("exceljs");
  const wb = new ExcelJS.Workbook();
  wb.creator = "Sankara Late Attendance Scanner";
  const ws = wb.addWorksheet(esc(departmentName || "Escalation").slice(0, 31) || "Escalation");
  ws.columns = [
    { header: "Student ID", key: "studentId", width: 14 },
    { header: "Name", key: "name", width: 28 },
    { header: "Department", key: "department", width: 20 },
    { header: "Year", key: "year", width: 8 },
    { header: "Late Count", key: "count", width: 12 },
    { header: "Late Date", key: "date", width: 14 },
    { header: "Late Time", key: "time", width: 10 },
  ];
  ws.getRow(1).font = { bold: true, color: { argb: "FFFFFFFF" } };
  ws.getRow(1).fill = { type: "pattern", pattern: "solid", fgColor: { argb: "FF1B2A4A" } };
  ws.getRow(1).alignment = { vertical: "middle" };
  for (const s of students) {
    const rowBase = {
      studentId: s.studentId,
      name: s.name,
      department: s.department || "",
      year: s.year || "",
      count: s.count,
    };
    const dates = s.dates.length ? s.dates : [{ date: "", time: "" }];
    for (const d of dates) {
      ws.addRow({ ...rowBase, date: d.date, time: d.time });
    }
  }
  ws.autoFilter = { from: { row: 1, column: 1 }, to: { row: ws.rowCount, column: 7 } };
  const buf = await wb.xlsx.writeBuffer();
  return Buffer.from(buf);
}

/** PDF table of the bundle via pdfkit (ARCHITECTURE.md §1.4). */
function buildPdfAttachment(students, { period, departmentName }) {
  const PDFDocument = require("pdfkit");
  return new Promise((resolve, reject) => {
    const doc = new PDFDocument({ size: "A4", margin: 40, info: { Title: `Late Attendance Escalation ${period}` } });
    const chunks = [];
    doc.on("data", (c) => chunks.push(c));
    doc.on("end", () => resolve(Buffer.concat(chunks)));
    doc.on("error", reject);

    doc.font("Helvetica-Bold").fontSize(14).fillColor(CSS.navy).text("Sankara College of Science & Commerce");
    doc.font("Helvetica").fontSize(10).fillColor(CSS.maroon).text(`Late Attendance Escalation — ${departmentName || ""} — ${period || ""}`, { continued: false });
    doc.moveDown(0.8);
    doc.font("Helvetica-Bold").fontSize(9).fillColor(CSS.ink).text(`Students escalated (threshold reached): ${students.length}`, { continued: false });
    doc.moveDown(0.6);

    const head = ["Student ID", "Name", "Department", "Year", "Late Count", "Late Dates"];
    const rowY = (y, cells, bold) => {
      const widths = [74, 130, 110, 34, 62, 150];
      let x = doc.page.margins.left;
      cells.forEach((cell, i) => {
        doc.font(bold ? "Helvetica-Bold" : "Helvetica").fontSize(8).fillColor(bold ? CSS.white : CSS.ink);
        doc.text(String(cell), x, y, { width: widths[i] - 6, lineBreak: false });
        x += widths[i];
      });
    };

    doc.rect(doc.page.margins.left, doc.y, 560, 16).fill(CSS.navy);
    rowY(doc.y + 4, head, true);
    doc.y += 20;
    for (const s of students) {
      const dates = s.dates.map((d) => `${d.date} ${d.time}`).join(", ") || "—";
      rowY(doc.y, [s.studentId, s.name, s.department || "", s.year || "", s.count, dates], false);
      doc.moveDown(0.5);
    }
    doc.end();
  });
}

/**
 * Send via the Resend REST API. `apiKey` comes from server env only
 * (docs/SECURITY.md §6). Returns the Resend response (has `id` on success).
 */
async function sendViaResend({ apiKey, from, to, subject, html, attachments = [] }) {
  if (!apiKey) {
    const err = new Error("RESEND_API_KEY is not set — refusing to send mail without a key (docs/SECURITY.md §6)");
    err.code = "RESEND_KEY_MISSING";
    throw err;
  }
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      authorization: `Bearer ${apiKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({ from, to, subject, html, attachments }),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const err = new Error(`Resend ${res.status}: ${JSON.stringify(data)}`);
    err.code = "RESEND_API_ERROR";
    err.status = res.status;
    throw err;
  }
  return data;
}

/** `mail_logs` audit document (docs/ARCHITECTURE.md §2). */
function mailLogDoc({ departmentId, department, period, to, subject, studentsIncluded, triggeredBy, mailRequestId, resendId }) {
  return {
    departmentId: departmentId ?? null,
    department,
    period,
    to,
    subject,
    studentsIncluded,
    triggeredBy,
    mailRequestId,
    resendId: resendId ?? null,
  };
}

module.exports = {
  esc,
  formatDate,
  formatTime,
  normalizeToken,
  resolveDepartment,
  buildMailHtml,
  buildXlsxAttachment,
  buildPdfAttachment,
  sendViaResend,
  mailLogDoc,
};