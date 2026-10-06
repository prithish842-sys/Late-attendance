// Pure building blocks for the Phase 3 weekly audit (docs-new-updates/NEW_TASKS.md).
//
// CommonJS like mail-core.js so both the Blaze Cloud Function
// (functions/index.js, require) and the Spark Admin-SDK runner
// (scripts/process-mail.js, ESM import) load the exact same logic. Everything
// here is stateless and testable (functions/test/weekly-audit-core.test.js).
//
// The client preview (lib/src/models/app_models.dart weeklyAuditOverview,
// weeklyAuditAttachmentNames, buildWeeklyAuditBodyPreview) mirrors these shapes
// so the Weekly Audit screen and the HOD mail preview show exactly what the
// server aggregates/sends. Keep both in parity, like yearTier does for reports.
//
// Weekly unit: a Monday→Sunday week (report weeks already start Monday).
// Repeated student = late more than once in the same week (repeatThreshold 2 —
// not a subjective "high" threshold, per NEW_UPDATES_PRD.md §Weekly Audit, so
// the count is the signal, not a magic number).

const { formatDate, normalizeToken, esc } = require("./mail-core.js");
const { reportWindow, addDays, MIME } = require("./report-core.js");

const CSS = {
  font: "Helvetica, Arial, sans-serif",
  ink: "#232323",
  navy: "#1B2A4A",
  maroon: "#8B1E1E",
  sand: "#E8E2D8",
  white: "#ffffff",
};

/** "YYYY-MM" for a Date (UTC) — the calendar month a weekly audit belongs to. */
function monthKeyOf(date) {
  const m = String(date.getUTCMonth() + 1).padStart(2, "0");
  return `${date.getUTCFullYear()}-${m}`;
}

/** Monday→Sunday week window. `startDate` (a Monday) is normalized back onto
 *  its own Monday; null/absent defaults to the current week. An explicitly
 *  provided non-date string returns null so callers abort with INVALID_RANGE
 *  (a mail must not silently report "now" when a caller passed garbage). */
function weeklyWindow({ startDate }) {
  const hasDate = startDate != null && String(startDate).trim() !== "";
  if (hasDate && typeof startDate !== "string") return null;
  if (hasDate && !/^\d{4}-\d{2}-\d{2}$/.test(startDate)) return null;
  return reportWindow({ periodType: "weekly", startDate: hasDate ? startDate : null });
}

/**
 * Aggregate one week of late rows (the loadReportRows weekly slice — a single
 * department when filtered) into the repeated-student audit.
 *
 * `monthKey` is the calendar month the week starts in; a student's monthCount
 * and lastLateDate are measured inside that same month so the view ties back
 * to the current-month escalation counter (1st logged / 2nd warning / 3rd
 * escalated, same calendar month — NEW_UPDATES_PRD.md §Escalation).
 *
 * Returns:
 * {
 *   monthKey, totalEvents, uniqueStudents, repeatedStudents,
 *   departments: [ { department, uniqueStudents, totalEvents, repeatedStudents,
 *                    students: [view...] } ]   // sorted uniqueStudents desc
 * }
 * view = { studentId, name, department, year, weeklyCount, monthCount,
 *          lastLateDate, repeated }
 */
function aggregateWeeklyAudit(rows, options = {}) {
  const { monthKey, repeatThreshold = 2 } = options;
  const key = monthKey || (rows.length ? monthKeyOf(new Date()) : "");
  const threshold = Number.isInteger(repeatThreshold) && repeatThreshold > 0 ? repeatThreshold : 2;

  const byDept = new Map(); // dept -> Map(studentId -> view)
  const deptRows = new Map(); // dept -> row count
  const deptsSeen = []; // insertion order for stable tie-breaks

  for (const r of rows || []) {
    const dept = r.department || "Unassigned";
    if (!byDept.has(dept)) {
      byDept.set(dept, new Map());
      deptRows.set(dept, 0);
      deptsSeen.push(dept);
    }
    deptRows.set(dept, deptRows.get(dept) + 1);

    const views = byDept.get(dept);
    let v = views.get(r.studentId);
    if (!v) {
      v = {
        studentId: r.studentId,
        registerNumber: r.studentId,
        name: r.name || r.studentId,
        department: dept,
        year: r.year || "",
        weeklyCount: 0,
        monthCount: 0,
        lastLateDate: null,
        repeated: false,
      };
      views.set(r.studentId, v);
    }
    v.weeklyCount += 1;
    if (r.date && r.date.startsWith(key)) {
      v.monthCount += 1;
      if (v.lastLateDate == null || r.date > v.lastLateDate) v.lastLateDate = r.date;
    }
  }

  const departments = deptsSeen.map((dept) => {
    const views = [...byDept.get(dept).values()];
    for (const v of views) v.repeated = v.weeklyCount >= threshold;
    views.sort((a, b) => String(a.name || "").localeCompare(String(b.name || "")));
    const uniqueStudents = views.length;
    const totalEvents = deptRows.get(dept);
    const repeatedStudents = views.filter((v) => v.repeated).length;
    return {
      department: dept,
      uniqueStudents,
      totalEvents,
      repeatedStudents,
      students: views,
    };
  });
  departments.sort(
    (a, b) =>
      b.uniqueStudents - a.uniqueStudents ||
      b.totalEvents - a.totalEvents ||
      a.department.localeCompare(b.department)
  );

  const totalEvents = (rows || []).length;
  const uniqueStudents = departments.reduce((n, d) => n + d.uniqueStudents, 0);
  const repeatedStudents = departments.reduce((n, d) => n + d.repeatedStudents, 0);

  return { monthKey: key, totalEvents, uniqueStudents, repeatedStudents, departments };
}

/**
 * Plan which departments still owe a weekly HOD audit mail (Phase 5 — the
 * weekly audit job). `candidates` are per-department rolls already computed by
 * the job (each: { departmentId, departmentName, hodEmail, uniqueStudents,
 * totalEvents, repeatedStudents }); `alreadySentKeys` are normalized tokens
 * (department id OR display name) that already have a weekly_audit mail_logs
 * row for this week.
 *
 * Returns { due, alreadySent, noHod } — due sorted by uniqueStudents desc then
 * totalEvents desc (NEW_AUDIT_WORKFLOW.md "sort departments by actual count").
 * A department that resolves no hodEmail is parked (noHod), never silently
 * dropped — the job reports it so an admin can fix the departments collection.
 */
function planWeeklyAuditDepartments({ candidates, alreadySentKeys = [] }) {
  const sent = new Set((alreadySentKeys || []).map(normalizeToken).filter(Boolean));
  const sortByCount = (a, b) =>
    b.uniqueStudents - a.uniqueStudents ||
    b.totalEvents - a.totalEvents ||
    String(a.departmentName || "").localeCompare(String(b.departmentName || ""));

  const due = [];
  const alreadySent = [];
  const noHod = [];
  for (const c of candidates || []) {
    const keys = [c.departmentId, c.departmentName].map(normalizeToken).filter(Boolean);
    if (keys.some((k) => sent.has(k))) {
      alreadySent.push(c);
      continue;
    }
    if (!c.hodEmail) {
      noHod.push(c);
      continue;
    }
    due.push(c);
  }
  due.sort(sortByCount);
  alreadySent.sort(sortByCount);
  noHod.sort(sortByCount);
  return { due, alreadySent, noHod };
}

/** Attachment range token for a weekly window (e.g. 2026-09-21_to_2026-09-27).
 *  Same inclusive-end rule as report mail dates. */
function weeklyAuditRange(window) {
  const start = formatDate(window.start);
  const end = formatDate(addDays(window.end, -1));
  return start === end ? start : `${start}_to_${end}`;
}

/** Filename stem: "{dept_slug}_Weekly_Audit_{range}". */
function weeklyAuditFileStem(department, range) {
  const slug = normalizeToken(department);
  return `${slug || "report"}_Weekly_Audit_${range}`;
}

/** Subject line for the weekly HOD audit mail. */
function weeklyAuditSubject(department, range) {
  return `Weekly Late Attendance Audit - ${department} - ${range}`;
}

/** Attachment names in send order: workbook first, then the PDF. */
function weeklyAuditAttachmentNames(department, range) {
  const stem = weeklyAuditFileStem(department, range);
  return [
    { filename: `${stem}.xlsx`, contentType: MIME.xlsx },
    { filename: `${stem}.pdf`, contentType: MIME.pdf },
  ];
}

/**
 * Formal HOD mail for a department's weekly audit. `group` is one department
 * from aggregateWeeklyAudit (server-authoritative). Repeated students
 * (late more than once this week) drive the table — the exact repeated-student
 * view columns from NEW_AUDIT_WORKFLOW.md. Everything user-derived is escaped.
 */
function buildWeeklyAuditHtml({ collegeName, departmentName, weekLabel, group }) {
  const college = esc(collegeName || "Sankara College of Science & Commerce");
  const dept = esc(departmentName || "");
  const label = esc(weekLabel || "");
  const repeated = (group?.students || []).filter((s) => s.repeated);
  const unique = group?.uniqueStudents ?? 0;
  const events = group?.totalEvents ?? 0;
  const repeats = group?.repeatedStudents ?? 0;

  const table = repeated.length
    ? `<table role="presentation" cellpadding="0" cellspacing="0" style="width:100%;border-collapse:collapse;margin:14px 0;">
        <tr>
          <td style="padding:8px 10px;background:${CSS.navy};color:${CSS.white};font-size:12px;font-weight:700;">Student ID</td>
          <td style="padding:8px 10px;background:${CSS.navy};color:${CSS.white};font-size:12px;font-weight:700;">Name</td>
          <td style="padding:8px 10px;background:${CSS.navy};color:${CSS.white};font-size:12px;font-weight:700;">Year</td>
          <td style="padding:8px 10px;background:${CSS.navy};color:${CSS.white};font-size:12px;font-weight:700;">Lates this week</td>
          <td style="padding:8px 10px;background:${CSS.navy};color:${CSS.white};font-size:12px;font-weight:700;">Lates this month</td>
          <td style="padding:8px 10px;background:${CSS.navy};color:${CSS.white};font-size:12px;font-weight:700;">Last late</td>
        </tr>
        ${repeated
          .map(
            (s, i) => `<tr>
          <td style="padding:6px 8px;font-size:12px;border-top:1px solid ${CSS.sand};${i === 0 ? "background:#FAFAF7;" : ""}">${esc(s.studentId)}</td>
          <td style="padding:6px 8px;font-size:12px;border-top:1px solid ${CSS.sand};${i === 0 ? "background:#FAFAF7;" : ""}">${esc(s.name)}</td>
          <td style="padding:6px 8px;font-size:12px;border-top:1px solid ${CSS.sand};${i === 0 ? "background:#FAFAF7;" : ""}">${esc(s.year || "—")}</td>
          <td style="padding:6px 8px;font-size:12px;border-top:1px solid ${CSS.sand};${i === 0 ? "background:#FAFAF7;" : ""}">${s.weeklyCount}</td>
          <td style="padding:6px 8px;font-size:12px;border-top:1px solid ${CSS.sand};${i === 0 ? "background:#FAFAF7;" : ""}">${s.monthCount}</td>
          <td style="padding:6px 8px;font-size:12px;border-top:1px solid ${CSS.sand};${i === 0 ? "background:#FAFAF7;" : ""}">${esc(s.lastLateDate || "—")}</td>
        </tr>`
          )
          .join("\n")}
      </table>`
    : `<p style="font-size:14px;line-height:1.6;margin:14px 0 0;">No student was marked late more than once this week.</p>`;

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
      <div style="color:${CSS.maroon};font-size:13px;font-weight:600;margin-top:4px;">Weekly Late Attendance Audit &mdash; ${dept}${label ? " &mdash; " + label : ""}</div>
    </div>

    <p style="font-size:14px;line-height:1.6;margin:0 0 8px;">Dear HOD,</p>
    <p style="font-size:14px;line-height:1.6;margin:0 0 8px;">Please find the weekly late-attendance audit for ${dept} covering ${label}.</p>
    <p style="font-size:14px;line-height:1.6;margin:0 0 8px;">The students listed below were each late <strong>more than once</strong> during this week:</p>

    ${table}

    <p style="font-size:14px;line-height:1.6;margin:18px 0 0;">
      In total, <strong>${unique} ${unique === 1 ? "student" : "students"}</strong> were marked late on
      <strong>${events} ${events === 1 ? "occasion" : "occasions"}</strong> this week, of whom
      <strong>${repeats} ${repeats === 1 ? "student" : "students"}</strong> were late more than once.
    </p>
    <p style="font-size:13px;line-height:1.6;margin:8px 0 0;color:#444;">The complete week data is attached as a PDF along with the Excel workbook. The month column reflects the same calendar-month escalation window used by the attendance scanner (1st late logged, 2nd warning, 3rd+ escalated).</p>
    <p style="font-size:13px;line-height:1.6;margin:18px 0 0;">Regards,<br>${college}</p>
    <p style="font-size:12px;line-height:1.6;margin:14px 0 0;color:#777;border-top:1px solid ${CSS.sand};padding-top:10px;">This is an automated weekly audit from the gate-duty attendance scanner. No reply is monitored.</p>
  </div>
</body>
</html>`;
}

/**
 * Excel workbook for a department's weekly audit: one row per repeated
 * student with the audit view columns. Uses exceljs (ARCHITECTURE.md §1.4);
 * required lazily like the other attachment builders.
 */
async function buildWeeklyAuditXlsx({ group, departmentName, weekLabel }) {
  const ExcelJS = require("exceljs");
  const repeated = (group?.students || []).filter((s) => s.repeated);
  const wb = new ExcelJS.Workbook();
  wb.creator = "Sankara Late Attendance Scanner";
  const ws = wb.addWorksheet(esc(departmentName || "Weekly Audit").slice(0, 31) || "Weekly Audit");
  ws.columns = [
    { header: "Name", key: "name", width: 28 },
    { header: "Register No", key: "registerNumber", width: 16 },
    { header: "Department", key: "department", width: 22 },
    { header: "Year", key: "year", width: 10 },
    { header: "Weekly Late Count", key: "weeklyCount", width: 18 },
    { header: "Month Late Count", key: "monthCount", width: 18 },
    { header: "Last Late Date", key: "lastLateDate", width: 16 },
  ];
  ws.getRow(1).font = { bold: true, color: { argb: "FFFFFFFF" } };
  ws.getRow(1).fill = { type: "pattern", pattern: "solid", fgColor: { argb: "FF1B2A4A" } };
  ws.getRow(1).alignment = { vertical: "middle" };
  for (const v of repeated) {
    ws.addRow({
      name: v.name,
      registerNumber: v.registerNumber,
      department: v.department,
      year: v.year || "",
      weeklyCount: v.weeklyCount,
      monthCount: v.monthCount,
      lastLateDate: v.lastLateDate || "",
    });
  }
  ws.autoFilter = { from: { row: 1, column: 1 }, to: { row: ws.rowCount, column: 7 } };

  const summary = wb.addWorksheet("Summary");
  summary.columns = [
    { header: "Metric", key: "metric", width: 26 },
    { header: "Value", key: "value", width: 30 },
  ];
  summary.getRow(1).font = { bold: true, color: { argb: "FFFFFFFF" } };
  summary.getRow(1).fill = { type: "pattern", pattern: "solid", fgColor: { argb: "FF1B2A4A" } };
  summary.addRow({ metric: "Weekly audit", value: "" });
  summary.addRow({ metric: "Week", value: weekLabel || "" });
  summary.addRow({ metric: "Unique late students", value: group?.uniqueStudents ?? 0 });
  summary.addRow({ metric: "Total late events", value: group?.totalEvents ?? 0 });
  summary.addRow({ metric: "Students late more than once", value: group?.repeatedStudents ?? 0 });

  const buf = await wb.xlsx.writeBuffer();
  return Buffer.from(buf);
}

/** PDF of the weekly audit (pdfkit — ARCHITECTURE.md §1.4): summary counts
 *  plus a repeated-student table matching the mail body. */
function buildWeeklyAuditPdf({ group, departmentName, weekLabel }) {
  const PDFDocument = require("pdfkit");
  const repeated = (group?.students || []).filter((s) => s.repeated);
  return new Promise((resolve, reject) => {
    const doc = new PDFDocument({
      size: "A4",
      margin: 40,
      info: { Title: `Weekly Late Attendance Audit ${weekLabel || ""}` },
    });
    const chunks = [];
    doc.on("data", (c) => chunks.push(c));
    doc.on("end", () => resolve(Buffer.concat(chunks)));
    doc.on("error", reject);

    doc.font("Helvetica-Bold").fontSize(14).fillColor(CSS.navy).text("Sankara College of Science & Commerce");
    doc.font("Helvetica").fontSize(10).fillColor(CSS.maroon).text(`Weekly Late Attendance Audit — ${departmentName || ""}${weekLabel ? " — " + weekLabel : ""}`, { continued: false });
    doc.moveDown(0.8);
    doc
      .font("Helvetica-Bold")
      .fontSize(9)
      .fillColor(CSS.ink)
      .text(`${group?.uniqueStudents || 0} students · ${group?.totalEvents || 0} late events · ${group?.repeatedStudents || 0} late more than once`, { continued: false });
    doc.moveDown(0.6);

    if (repeated.length === 0) {
      doc.font("Helvetica").fontSize(10).fillColor(CSS.ink).text("No student was marked late more than once this week.", { continued: false });
      doc.end();
      return;
    }

    const head = ["Name", "Register No", "Department", "Year", "Late (week)", "Late (month)", "Last late"];
    const widths = [120, 66, 92, 34, 60, 60, 62];
    const pageBottom = doc.page.height - doc.page.margins.bottom;

    const drawRow = (y, cells, bold) => {
      if (bold) {
        doc.rect(doc.page.margins.left, y, doc.page.width - doc.page.margins.left - doc.page.margins.right, 16).fill(CSS.navy);
      }
      let x = doc.page.margins.left;
      cells.forEach((cell, i) => {
        doc.font(bold ? "Helvetica-Bold" : "Helvetica").fontSize(8).fillColor(bold ? CSS.white : CSS.ink);
        doc.text(String(cell), x, y + (bold ? 4 : 2), { width: widths[i] - 6, lineBreak: false });
        x += widths[i];
      });
      return y + (bold ? 16 : 12);
    };

    let y = drawRow(doc.y, head, true);
    for (const v of repeated) {
      if (y > pageBottom - 20) {
        doc.addPage();
        y = drawRow(doc.page.margins.top, head, true);
      }
      y = drawRow(
        y,
        [
          v.name,
          v.registerNumber,
          v.department,
          v.year || "—",
          v.weeklyCount,
          v.monthCount,
          v.lastLateDate || "—",
        ],
        false
      );
    }
    doc.end();
  });
}

module.exports = {
  monthKeyOf,
  weeklyWindow,
  weeklyAuditRange,
  weeklyAuditFileStem,
  weeklyAuditSubject,
  weeklyAuditAttachmentNames,
  planWeeklyAuditDepartments,
  aggregateWeeklyAudit,
  buildWeeklyAuditHtml,
  buildWeeklyAuditXlsx,
  buildWeeklyAuditPdf,
};