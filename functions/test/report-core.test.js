// Pure unit tests for functions/report-core.js — window math, filename stems,
// statistics and the Excel/PDF builders. Run with `npm test` in functions/.
const test = require("node:test");
const assert = require("node:assert/strict");
const {
  reportWindow,
  reportFileNameBase,
  yearTier,
  runReportStats,
  buildReportXlsx,
  buildReportPdf,
} = require("../report-core.js");

const at = (y, m, d) => new Date(Date.UTC(y, m - 1, d));

test("daily window is the single UTC day", () => {
  const w = reportWindow({ periodType: "daily", date: "2026-09-24" });
  assert.equal(w.label, "2026-09-24");
  assert.equal(w.start.toISOString(), at(2026, 9, 24).toISOString());
  assert.equal(w.end.toISOString(), at(2026, 9, 25).toISOString());
});

test("daily falls back to a Date object", () => {
  const w = reportWindow({ periodType: "daily", date: at(2026, 9, 24) });
  assert.equal(w.label, "2026-09-24");
});

test("weekly starts on Monday and spans 7 days", () => {
  const w = reportWindow({ periodType: "weekly", startDate: "2026-09-18" });
  assert.equal(w.start.toISOString(), at(2026, 9, 14).toISOString()); // Mon
  assert.equal(w.end.toISOString(), at(2026, 9, 21).toISOString());
  assert.equal(w.label, "2026-09-14 to 2026-09-20");
});

test("weekly defaults to the current week without a start date", () => {
  const w = reportWindow({ periodType: "weekly", startDate: null });
  assert.equal(w.start.getUTCDay(), 1); // Monday
  assert.equal((w.end.getTime() - w.start.getTime()) / 86400000, 7);
});

test("monthly window is the calendar month", () => {
  const w = reportWindow({ periodType: "monthly", month: "2026-09" });
  assert.equal(w.label, "September 2026");
  assert.equal(w.start.toISOString(), at(2026, 9, 1).toISOString());
  assert.equal(w.end.toISOString(), at(2026, 10, 1).toISOString());
});

test("monthly falls back to the month of startDate", () => {
  const w = reportWindow({ periodType: "monthly", startDate: "2026-02-15" });
  assert.equal(w.label, "February 2026");
  assert.equal(w.end.toISOString(), at(2026, 3, 1).toISOString());
});

test("monthly rejects an invalid YYYY-MM", () => {
  assert.equal(reportWindow({ periodType: "monthly", month: "2026-99" }), null);
});

test("custom window is inclusive of the end date", () => {
  const w = reportWindow({ periodType: "custom", startDate: "2026-09-01", endDate: "2026-09-30" });
  assert.equal(w.start.toISOString(), at(2026, 9, 1).toISOString());
  assert.equal(w.end.toISOString(), at(2026, 10, 1).toISOString());
  assert.equal(w.label, "2026-09-01 to 2026-09-30");
});

test("custom refuses an inverted range", () => {
  assert.equal(reportWindow({ periodType: "custom", startDate: "2026-09-30", endDate: "2026-09-01" }), null);
});

test("custom requires both dates", () => {
  assert.equal(reportWindow({ periodType: "custom", startDate: "2026-09-01", endDate: null }), null);
});

test("unknown period type returns null", () => {
  assert.equal(reportWindow({ periodType: "fortnightly" }), null);
});

test("filename stem slugs the label", () => {
  assert.equal(reportFileNameBase("September 2026"), "late-attendance-september-2026");
  assert.equal(reportFileNameBase("2026-09-14 to 2026-09-20"), "late-attendance-2026-09-14-to-2026-09-20");
  assert.equal(reportFileNameBase(null), "late-attendance-report");
});

test("stats count entries, distinct students and per-department totals", () => {
  const stats = runReportStats([
    { studentId: "26BSC001", name: "A", department: "B.SC CS" },
    { studentId: "26BSC001", name: "A", department: "B.SC CS" },
    { studentId: "26BSC004", name: "B", department: "BCA" },
  ]);
  assert.equal(stats.totalLateEntries, 3);
  assert.equal(stats.distinctStudents, 2);
  assert.deepEqual(stats.byDepartment, [
    { department: "B.SC CS", count: 2 },
    { department: "BCA", count: 1 },
  ]);
});

test("stats sort departments by count descending then name", () => {
  const stats = runReportStats([
    { studentId: "1", department: "AA" },
    { studentId: "2", department: "BB" },
    { studentId: "3", department: "BB" },
  ]);
  assert.deepEqual(stats.byDepartment.map((d) => d.department), ["BB", "AA"]);
});

test("stats bucket blank department as Unassigned", () => {
  const stats = runReportStats([{ studentId: "1", department: "" }, { studentId: "2", department: "" }]);
  assert.deepEqual(stats.byDepartment, [{ department: "Unassigned", count: 2 }]);
});

test("xlsx builder returns a zipped workbook buffer", async () => {
  const buf = await buildReportXlsx({
    rows: [{ date: "2026-09-24", time: "09:15", studentId: "26BSC001", name: "A", department: "B.SC CS", year: "I" }],
    stats: runReportStats([]),
    label: "September 2026",
  });
  assert.ok(Buffer.isBuffer(buf));
  assert.equal(buf.readUInt32LE(0), 0x04034b50); // PK\x03\x04
});

test("pdf builder returns a %PDF buffer (empty report still builds)", async () => {
  const buf = await buildReportPdf({
    rows: [{ date: "2026-09-24", time: "09:15", studentId: "26BSC001", name: "A", department: "B.SC CS", year: "I" }],
    stats: runReportStats([]),
    label: "September 2026",
  });
  assert.ok(Buffer.isBuffer(buf));
  assert.equal(buf.toString("latin1", 0, 5), "%PDF-");
});

// Year tier classifier — mirrors lib/src/models/app_models.dart `yearTier`.
test("yearTier classifies 3rd/2nd/1st spellings and roman numerals", () => {
  assert.equal(yearTier("3rd Year"), 3);
  assert.equal(yearTier("Third Year"), 3);
  assert.equal(yearTier("III"), 3);
  assert.equal(yearTier("3rd"), 3);
  assert.equal(yearTier("2nd Year"), 2);
  assert.equal(yearTier("Second Year"), 2);
  assert.equal(yearTier("II"), 2);
  assert.equal(yearTier("1st Year"), 1);
  assert.equal(yearTier("First Year"), 1);
  assert.equal(yearTier("I"), 1);
  assert.equal(yearTier("Year 2"), 2);
});

test("yearTier maps four-digit batch strings and blanks to Other (0)", () => {
  assert.equal(yearTier("2024-2027"), 0);
  assert.equal(yearTier("2026"), 0);
  assert.equal(yearTier(""), 0);
  assert.equal(yearTier(null), 0);
  assert.equal(yearTier("N/A"), 0);
  assert.equal(yearTier(undefined), 0);
});