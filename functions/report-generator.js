// Shared report orchestration — the stage between a report_requests intent and
// the final xlsx/pdf files. Used by BOTH runtime paths so behaviour never
// diverges (mirrors functions/mail-sender.js):
//
//   - Blaze: functions/index.js generateReport HttpsCallable calls generateReport().
//   - Spark: scripts/generate-report.js Admin-SDK runner calls generateReport().
//
// Server-authoritative only (docs/SECURITY.md §1, §8): reads late_logs,
// students and departments with admin privileges, applies the date-range /
// department / year filters, and returns the report rows, statistics and file
// buffers. The client never decides anything here — it only enqueues a
// report_requests intent (Spark) or calls the callable (Blaze).
//
// The Blaze caller stores the buffers in Cloud Storage under
// reports/{reportId}/ and records the report_logs audit row; the Spark runner
// writes the same buffers to the local reports/ folder and records the same
// audit row — so the two plans produce byte-identical reports.

const { normalizeToken, resolveDepartment, formatDate, formatTime } = require("./mail-core.js");
const { loadDepartments } = require("./mail-sender.js");
const {
  reportWindow,
  reportFileNameBase,
  yearTier,
  runReportStats,
  buildReportXlsx,
  buildReportPdf,
  MIME,
} = require("./report-core.js");

/**
 * Does a row's `department` display string belong to report filter `needle`?
 * Same fuzzy rule the mail pipeline uses (functions/mail-core.js
 * resolveDepartment): exact token match, OR the student's display string
 * resolves to a department reference doc whose id matches the needle. So a
 * report for "BSC-CS" includes students filed under "B.SC CS".
 */
function matchesDepartment(studentDepartment, needle, departments) {
  const studentToken = normalizeToken(studentDepartment);
  const needleToken = normalizeToken(needle);
  if (!studentToken || !needleToken) return false;
  if (studentToken === needleToken) return true;
  const resolved = resolveDepartment(studentDepartment, departments);
  return resolved ? normalizeToken(resolved.departmentId) === needleToken : false;
}

/** Filename stem = label slug + filters, so dept-filtered files never collide. */
function reportFileStem(request, fileNameBase) {
  const tag = [request.department, request.year]
    .filter(Boolean)
    .map(normalizeToken)
    .filter(Boolean)
    .join("-");
  return tag ? `${fileNameBase}-${tag}` : fileNameBase;
}

/**
 * Load the late_logs → students join for a report request, applying the
 * department and year filters. Year filtering uses tier semantics: a filter
 * that classifies into 1st/2nd/3rd (yearTier 1..3) matches every row in that
 * tier regardless of the exact stored string; a filter that doesn't classify
 * (4-digit batches, unrecognised labels) falls back to an exact token match.
 * Mirrors the Flutter `reportRows` dispatch so mail previews and reports agree.
 *
 * Returns { window, departments, resolved, deptTarget, yearTarget, tierTarget, rows }
 * or { window: null } for an invalid period/range.
 */
async function loadReportRows(db, request) {
  const window = reportWindow(request);
  if (!window) return { window: null };

  const departments = await loadDepartments(db);
  const resolved = request.department ? resolveDepartment(request.department, departments) : null;
  const deptTarget = request.department ? normalizeToken(resolved ? resolved.departmentId : request.department) : null;
  const yearTarget = request.year && request.year !== "" ? normalizeToken(request.year) : null;
  const tierTarget = yearTarget ? yearTier(request.year) : null;

  const logsSnap = await db.collection("late_logs")
    .where("scanTimestamp", ">=", window.start)
    .where("scanTimestamp", "<", window.end)
    .get();

  const studentsSnap = await db.collection("students").get();
  const studentMap = new Map(studentsSnap.docs.map((d) => [d.id, d.data() || {}]));

  const rows = [];
  for (const doc of logsSnap.docs) {
    const data = doc.data();
    const ts = data.scanTimestamp?.toDate ? data.scanTimestamp.toDate() : new Date();
    const studentId = String(data.studentId || doc.id.split("_")[0] || "");
    const student = studentMap.get(studentId) || {};
    const department = String(student.department || "");
    const year = String(student.year || "");
    if (deptTarget && !matchesDepartment(department, deptTarget, departments)) continue;
    if (tierTarget) {
      if (yearTier(year) !== tierTarget) continue;
    } else if (yearTarget) {
      if (!normalizeToken(year) || normalizeToken(year) !== yearTarget) continue;
    }
    rows.push({
      date: formatDate(ts),
      time: formatTime(ts),
      studentId,
      name: String(student.name || studentId),
      department,
      year,
    });
  }
  rows.sort((a, b) => (a.date + a.time).localeCompare(b.date + b.time) || a.name.localeCompare(b.name));

  return { window, departments, resolved, deptTarget, yearTarget, tierTarget, rows };
}

/**
 * Execute one report request. Returns:
 *   { status: "generated", periodType, label, startDate, endDate, stats,
 *     rowCount, fileStem, xlsxBase64, pdfBase64, files: [...] }
 *   { status: "dry-run", ... same minus the base64 payloads plus rowsPreview }
 *   { status: "abort", code, detail }              — nothing built
 *
 * With config.dryRun the xlsx/pdf buffers ARE built (proving generation works)
 * but are returned as `files` sizes only — nothing to persist or send.
 */
async function generateReport({ db, request, config = {} }) {
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

  const stats = runReportStats(rows);
  const fileNameBase = reportFileNameBase(window.label);
  const fileStem = reportFileStem(request, fileNameBase);

  const xlsx = await buildReportXlsx({ rows, stats, label: window.label });
  const pdf = await buildReportPdf({ rows, stats, label: window.label });
  const files = [
    { name: `${fileStem}.xlsx`, contentType: MIME.xlsx, sizeBytes: xlsx.byteLength },
    { name: `${fileStem}.pdf`, contentType: MIME.pdf, sizeBytes: pdf.byteLength },
  ];

  const head = {
    status: config.dryRun ? "dry-run" : "generated",
    periodType: window.periodType,
    label: window.label,
    startDate: window.start.toISOString(),
    endDate: window.end.toISOString(),
    stats,
    rowCount: rows.length,
    fileStem,
    files,
  };

  if (config.dryRun) {
    return { ...head, rowsPreview: rows.slice(0, 12) };
  }
  return { ...head, xlsxBase64: xlsx.toString("base64"), pdfBase64: pdf.toString("base64") };
}

/** Audit row schema shared by the Blaze callable and the Spark runner. */
function reportLogDoc({ request, result, reportId }) {
  return {
    reportId,
    requestedBy: request.requestedBy || null,
    periodType: result.periodType,
    startDate: result.startDate,
    endDate: result.endDate,
    label: result.label,
    department: request.department || null,
    year: request.year || null,
    stats: result.stats,
    files: result.files,
  };
}

module.exports = {
  matchesDepartment,
  reportFileStem,
  loadReportRows,
  generateReport,
  reportLogDoc,
};