// Pure building blocks for the attendance reports (Phase 4 of docs/TASKS.md).
//
// CommonJS like mail-core.js so both the Blaze Cloud Function
// (functions/index.js, require) and the Spark Admin-SDK runner
// (scripts/generate-report.js, ESM import) load the exact same logic.
// Everything here is stateless and testable (functions/test/report-core.test.js).
//
// Reports are server-authoritative (docs/SECURITY.md §1, §8): the window, the
// late_logs→student join, the statistics and the Excel/PDF files are all
// produced here with admin privileges. The client only expresses *intent* — it
// enqueues a report_requests doc (Spark) or calls the generateReport callable
// (Blaze). ExcelJS / PDFKit are required lazily so the pure paths stay
// dependency-free, exactly like mail-core's attachment builders.

const { formatDate, normalizeToken } = require("./mail-core.js");

const CSS = {
  font: "Helvetica, Arial, sans-serif",
  ink: "#232323",
  navy: "#1B2A4A",
  maroon: "#8B1E1E",
  sand: "#E8E2D8",
  white: "#ffffff",
};

const MIME = {
  xlsx: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  pdf: "application/pdf",
};

const MONTH_NAMES = [
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December",
];

/** Start of the UTC day for a Date, or for a "YYYY-MM-DD" string. */
function parseDay(value) {
  if (value instanceof Date && !Number.isNaN(value.getTime())) {
    return new Date(Date.UTC(value.getUTCFullYear(), value.getUTCMonth(), value.getUTCDate()));
  }
  if (typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value)) {
    const [y, m, d] = value.split("-").map(Number);
    if (m >= 1 && m <= 12 && d >= 1 && d <= 31) return new Date(Date.UTC(y, m - 1, d));
  }
  return null;
}

function startOfDayUTC(date) {
  return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate()));
}

function addDays(date, days) {
  const d = new Date(date);
  d.setUTCDate(d.getUTCDate() + days);
  return d;
}

// Year tiers for report year filters (docs-new-updates/NEW_TASKS.md Phase 2).
// Stored 'year' strings on students are free-form ("3rd Year", "III", "1st",
// "2024-2027"...). Grade tiers: 3rd → 3, 2nd → 2, 1st → 1; batch strings (any
// 4-digit run, e.g. "2026" or "2024-2027") and anything unclassifiable → 0.
// This mirrors lib/src/models/app_models.dart `yearTier` EXACTLY — keep in
// parity or cross-platform filters diverge.
function yearTier(year) {
  const t = normalizeToken(year);
  if (!t || /\d{4}/.test(t)) return 0;
  if (t.includes("third") || t.includes("iiird") || t.includes("3rd") || t.includes("iii") || t.includes("3")) return 3;
  if (t.includes("second") || t.includes("iind") || t.includes("2nd") || t.includes("ii") || t.includes("2")) return 2;
  if (t.includes("first") || t.includes("1st") || t.includes("i") || t.includes("1")) return 1;
  return 0;
}

/** Human label for a year tier (3rd Year, 2nd Year, 1st Year, Other). */
function yearTierLabel(tier) {
  if (tier === 3) return "3rd Year";
  if (tier === 2) return "2nd Year";
  if (tier === 1) return "1st Year";
  return "Other";
}

/** Filename-safe tier token (3rd, 2nd, 1st, Other) — mirrors Dart reportTierToken. */
function reportTierToken(tier) {
  if (tier === 3) return "3rd";
  if (tier === 2) return "2nd";
  if (tier === 1) return "1st";
  return "Other";
}

/** Monday of the week containing `date` (report weeks start Monday). */
function mondayOf(date) {
  const d = startOfDayUTC(date);
  const day = d.getUTCDay(); // 0 = Sunday
  return addDays(d, day === 0 ? -6 : -(day - 1));
}

/** "YYYY-MM" → {year, month} (1-indexed), else null. */
function parseMonthInput(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}$/.test(value)) return null;
  const [year, month] = value.split("-").map(Number);
  if (month < 1 || month > 12) return null;
  return { year, month };
}

function monthName(m) {
  return MONTH_NAMES[m - 1] || String(m);
}

/**
 * Resolve the half-open [start, end) UTC window a report covers, plus a human
 * label for headers and filenames.
 *   daily   — `date` (falls back to startDate, then today)
 *   weekly  — Monday-start 7-day window (defaults to the current week)
 *   monthly — calendar month (from `month`, else the month of startDate/date/today)
 *   custom  — startDate..endDate inclusive (both required, start ≤ end)
 * Returns null for an unrecognized periodType or an invalid custom range, so
 * callers can refuse with a plain-language message instead of a crash.
 */
function reportWindow({ periodType, date, startDate, endDate, month }) {
  const now = new Date();
  switch (periodType) {
    case "daily": {
      const start = parseDay(date) || parseDay(startDate) || startOfDayUTC(now);
      return { start, end: addDays(start, 1), label: formatDate(start), periodType };
    }
    case "weekly": {
      // A startDate (already a Monday from the app) is normalized back onto its
      // own Monday, so callers get a clean Monday→Sunday week either way.
      const start = mondayOf(parseDay(startDate) || now);
      return {
        start,
        end: addDays(start, 7),
        label: `${formatDate(start)} to ${formatDate(addDays(start, 6))}`,
        periodType,
      };
    }
    case "monthly": {
      let year;
      let m;
      if (month !== undefined && month !== null && month !== "") {
        const parsed = parseMonthInput(month);
        if (!parsed) return null; // caller supplied an unreadable month — refuse
        year = parsed.year;
        m = parsed.month;
      } else {
        const base = parseDay(startDate) || parseDay(date) || startOfDayUTC(now);
        year = base.getUTCFullYear();
        m = base.getUTCMonth() + 1;
      }
      return {
        start: new Date(Date.UTC(year, m - 1, 1)),
        end: new Date(Date.UTC(year, m, 1)),
        label: `${monthName(m)} ${year}`,
        periodType,
      };
    }
    case "custom": {
      const start = parseDay(startDate);
      const endDay = parseDay(endDate);
      if (!start || !endDay || endDay < start) return null;
      return { start, end: addDays(endDay, 1), label: `${formatDate(start)} to ${formatDate(endDay)}`, periodType };
    }
    default:
      return null;
  }
}

/** "late-attendance-September-2026" style stem (filters appended by the caller). */
function reportFileNameBase(label) {
  const slug = String(label || "report")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return `late-attendance-${slug || "report"}`;
}

/** Row shape is { date, time, studentId, name, department, year }. */
function runReportStats(rows) {
  const byDepartment = new Map();
  const students = new Set();
  for (const r of rows) {
    const dep = r.department || "Unassigned";
    byDepartment.set(dep, (byDepartment.get(dep) || 0) + 1);
    students.add(r.studentId);
  }
  return {
    totalLateEntries: rows.length,
    distinctStudents: students.size,
    byDepartment: [...byDepartment.entries()]
      .map(([department, count]) => ({ department, count }))
      .sort((a, b) => b.count - a.count || a.department.localeCompare(b.department)),
  };
}

/**
 * Excel workbook: a "Late entries" sheet (one row per late entry, filterable)
 * plus a "Summary" sheet (period totals + department-wise counts). Uses exceljs
 * (ARCHITECTURE.md §1.4); required lazily like mail-core's builders.
 */
async function buildReportXlsx({ rows, stats, label }) {
  const ExcelJS = require("exceljs");
  const wb = new ExcelJS.Workbook();
  wb.creator = "Sankara Late Attendance Scanner";

  const sheetName = String(label || "Attendance Report")
    .replace(/[\\/?*[\]:]/g, "-")
    .slice(0, 31) || "Attendance Report";

  const data = wb.addWorksheet(sheetName);
  data.columns = [
    { header: "Date", key: "date", width: 14 },
    { header: "Time", key: "time", width: 10 },
    { header: "Student ID", key: "studentId", width: 14 },
    { header: "Name", key: "name", width: 30 },
    { header: "Department", key: "department", width: 22 },
    { header: "Year", key: "year", width: 10 },
  ];
  data.getRow(1).font = { bold: true, color: { argb: "FFFFFFFF" } };
  data.getRow(1).fill = { type: "pattern", pattern: "solid", fgColor: { argb: "FF1B2A4A" } };
  data.getRow(1).alignment = { vertical: "middle" };
  for (const r of rows) {
    data.addRow({
      date: r.date,
      time: r.time,
      studentId: r.studentId,
      name: r.name,
      department: r.department,
      year: r.year,
    });
  }
  data.autoFilter = { from: { row: 1, column: 1 }, to: { row: data.rowCount, column: 6 } };

  const summary = wb.addWorksheet("Summary");
  summary.columns = [
    { header: "Metric", key: "metric", width: 26 },
    { header: "Value", key: "value", width: 34 },
  ];
  summary.getRow(1).font = { bold: true, color: { argb: "FFFFFFFF" } };
  summary.getRow(1).fill = { type: "pattern", pattern: "solid", fgColor: { argb: "FF1B2A4A" } };
  summary.addRow({ metric: "Summary", value: "" });
  summary.addRow({ metric: "Report period", value: label });
  summary.addRow({ metric: "Total late entries", value: stats.totalLateEntries });
  summary.addRow({ metric: "Distinct students", value: stats.distinctStudents });
  summary.addRow({ metric: "", value: "" });
  summary.addRow({ metric: "Department", value: "Late entries" });
  summary.getRow(6).font = { bold: true, color: { argb: "FF1B2A4A" } };
  for (const d of stats.byDepartment) {
    summary.addRow({ metric: d.department, value: d.count });
  }

  const buf = await wb.xlsx.writeBuffer();
  return Buffer.from(buf);
}

/**
 * PDF report: header, summary counts and a dense per-entry table that pages
 * automatically (pdfkit — ARCHITECTURE.md §1.4). Empty reports get a friendly
 * note instead of a bare table.
 */
function buildReportPdf({ rows, stats, label }) {
  const PDFDocument = require("pdfkit");
  return new Promise((resolve, reject) => {
    const doc = new PDFDocument({ size: "A4", margin: 40, info: { Title: `Late Attendance Report ${label}` } });
    const chunks = [];
    doc.on("data", (c) => chunks.push(c));
    doc.on("end", () => resolve(Buffer.concat(chunks)));
    doc.on("error", reject);

    const pageBottom = doc.page.height - doc.page.margins.bottom;
    const widths = [64, 46, 70, 148, 110, 40];
    const head = ["Date", "Time", "Student ID", "Name", "Department", "Year"];

    const drawRow = (y, cells, bold) => {
      if (bold) {
        doc.rect(doc.page.margins.left, y, doc.page.width - doc.page.margins.left - doc.page.margins.right, 16).fill(CSS.navy);
      }
      let x = doc.page.margins.left;
      cells.forEach((cell, i) => {
        doc
          .font(bold ? "Helvetica-Bold" : "Helvetica")
          .fontSize(8)
          .fillColor(bold ? CSS.white : CSS.ink);
        doc.text(String(cell), x, y + (bold ? 4 : 2), { width: widths[i] - 6, lineBreak: false });
        x += widths[i];
      });
      return y + (bold ? 16 : 12);
    };

    doc.font("Helvetica-Bold").fontSize(14).fillColor(CSS.navy).text("Sankara College of Science & Commerce");
    doc.font("Helvetica").fontSize(10).fillColor(CSS.maroon).text(`Late Attendance Report — ${label}`, { continued: false });
    doc.moveDown(0.7);
    doc
      .font("Helvetica-Bold")
      .fontSize(9)
      .fillColor(CSS.ink)
      .text(`${stats.totalLateEntries} late entries · ${stats.distinctStudents} students`, { continued: false });
    doc.moveDown(0.6);

    if (rows.length === 0) {
      doc
        .font("Helvetica")
        .fontSize(10)
        .fillColor(CSS.ink)
        .text("No late entries in this period.", { continued: false });
      doc.end();
      return;
    }

    let y = drawRow(doc.y, head, true);
    for (const r of rows) {
      if (y > pageBottom - 20) {
        doc.addPage();
        y = drawRow(doc.page.margins.top, head, true);
      }
      y = drawRow(y, [r.date, r.time, r.studentId, r.name, r.department, r.year], false);
    }
    doc.end();
  });
}

module.exports = {
  MIME,
  MONTH_NAMES,
  parseDay,
  addDays,
  reportWindow,
  reportFileNameBase,
  yearTier,
  yearTierLabel,
  reportTierToken,
  runReportStats,
  buildReportXlsx,
  buildReportPdf,
};