// Pure unit tests for functions/report-mail-core.js — the report mail
// date-range/stem/attachment naming and the formal HOD HTML body built by
// functions/report-mail-sender.js. Run with `npm test` in functions/.
import test from "node:test";
import assert from "node:assert/strict";
import {
  reportMailDateRange,
  reportMailFileStem,
  reportMailSubject,
  reportMailAttachmentNames,
  groupRowsByTier,
  buildReportMailHtml,
} from "../report-mail-core.js";

const at = (y, m, d) => new Date(Date.UTC(y, m - 1, d));

test("reportMailDateRange: single day stays one date, wider windows use start_to_end", () => {
  assert.equal(reportMailDateRange({ start: at(2026, 9, 24), end: at(2026, 9, 25) }), "2026-09-24");
  assert.equal(
    reportMailDateRange({ start: at(2026, 9, 1), end: at(2026, 10, 1) }),
    "2026-09-01_to_2026-09-30"
  );
  assert.equal(
    reportMailDateRange({ start: at(2026, 9, 14), end: at(2026, 9, 21) }),
    "2026-09-14_to_2026-09-20"
  );
});

test("reportMailFileStem slugs the department id", () => {
  assert.equal(
    reportMailFileStem("BSC-CS", "2026-09-01_to_2026-09-30"),
    "bsccs_Late_Attendance_2026-09-01_to_2026-09-30"
  );
  assert.equal(reportMailFileStem("", "2026-09-24"), "report_Late_Attendance_2026-09-24");
});

test("reportMailSubject is the expected HOD subject line", () => {
  assert.equal(
    reportMailSubject("B.Sc Computer Science", "2026-09-01_to_2026-09-30"),
    "Late Attendance Report - B.Sc Computer Science - 2026-09-01_to_2026-09-30"
  );
});

test("reportMailAttachmentNames: combined = workbook + one summary PDF", () => {
  const names = reportMailAttachmentNames({
    department: "BSC-CS",
    range: "2026-09-01_to_2026-09-30",
    mode: "combined",
    tiers: new Set([3, 1]),
  });
  assert.deepEqual(names.map((n) => n.filename), [
    "bsccs_Late_Attendance_2026-09-01_to_2026-09-30.xlsx",
    "bsccs_Late_Attendance_2026-09-01_to_2026-09-30.pdf",
  ]);
});

test("reportMailAttachmentNames: split = workbook + one PDF per tier in 3rd→2nd→1st→Other order", () => {
  const names = reportMailAttachmentNames({
    department: "BSC-CS",
    range: "2026-09-01_to_2026-09-30",
    mode: "split",
    tiers: new Set([1, 3, 0]),
  });
  assert.deepEqual(names.map((n) => n.filename), [
    "bsccs_Late_Attendance_2026-09-01_to_2026-09-30.xlsx",
    "bsccs_3rd_Year_2026-09-01_to_2026-09-30.pdf",
    "bsccs_1st_Year_2026-09-01_to_2026-09-30.pdf",
    "bsccs_Other_Year_2026-09-01_to_2026-09-30.pdf",
  ]);
});

test("groupRowsByTier orders 3rd→2nd→1st→Other and drops empty tiers", () => {
  const rows = [
    { studentId: "A1", name: "Ada", year: "1st" },
    { studentId: "A2", name: "Ben", year: "III" },
    { studentId: "A3", name: "Chi", year: "2024-2027" },
    { studentId: "A4", name: "Dee", year: "2nd" },
  ];
  const groups = groupRowsByTier(rows);
  assert.deepEqual(groups.map((g) => g.label), ["3rd Year", "2nd Year", "1st Year", "Other"]);
  assert.deepEqual(groups.map((g) => g.entries.length), [1, 1, 1, 1]);
  assert.equal(groups[0].entries[0].studentId, "A2");
});

test("buildReportMailHtml orders year buckets, escapes input and totals entries", () => {
  const rows = [
    { studentId: 'A1", "x', name: "<script>alert(1)</script>", year: "3rd" },
    { studentId: "A2", name: "Ben", year: "1st Year" },
    { studentId: "A2", name: "Ben", year: "1st Year" },
    { studentId: "A3", name: "Chi", year: "2024" },
  ];
  const html = buildReportMailHtml({
    collegeName: "Sankara College of Science & Commerce",
    departmentName: "B.Sc Computer Science",
    range: "2026-09-01_to_2026-09-30",
    rows,
  });

  // Year buckets in 3rd → 1st → Other document order (no 2nd present).
  const idx3 = html.indexOf("3rd Year (1)");
  const idx1 = html.indexOf("1st Year (2)");
  const idx0 = html.indexOf("Other (1)");
  assert.ok(idx3 > -1 && idx1 > -1 && idx0 > -1, "all present tier headings appear");
  assert.ok(idx3 < idx1 && idx1 < idx0, "buckets ordered 3rd → 1st → Other");

  // Totals: 4 late entries across 3 distinct students.
  assert.match(html, /<strong>4 late entries<\/strong>/);
  assert.match(html, /<strong>3 students<\/strong>/);

  // student-controlled HTML is escaped, not executed.
  assert.ok(!html.includes("<script>"), "name is escaped");
  assert.ok(html.includes("&lt;script&gt;"), "escaped name present");

  assert.match(html, /Late Attendance Report &mdash; B\.Sc Computer Science/);
  assert.match(html, /Dear HOD,/);
  assert.match(html, /Regards,/);
  assert.ok(html.includes("Sankara College of Science &amp; Commerce"));
});

test("buildReportMailHtml renders a single-student report with singular wording", () => {
  const html = buildReportMailHtml({
    departmentName: "B.Sc Computer Science",
    range: "2026-09-24",
    rows: [{ studentId: "26BSC001", name: "Ada", year: "1st Year" }],
  });
  assert.match(html, /<strong>1 late entry<\/strong>/);
  assert.match(html, /<strong>1 student<\/strong>/);
  assert.match(html, /26BSC001<\/td>/);
  assert.match(html, /1st Year \(1\)/);
});