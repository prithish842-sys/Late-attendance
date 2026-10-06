// Pure unit tests for functions/weekly-audit-core.js — the Phase 3 weekly
// aggregation (department grouping, repeated-student views, month-count and
// last-late-date windows), the attachment date-range/stem/subject naming, and
// the HOD audit HTML body. Run with `npm test` in functions/.
import test from "node:test";
import assert from "node:assert/strict";
import {
  monthKeyOf,
  weeklyWindow,
  weeklyAuditRange,
  weeklyAuditFileStem,
  weeklyAuditSubject,
  weeklyAuditAttachmentNames,
  aggregateWeeklyAudit,
  buildWeeklyAuditHtml,
} from "../weekly-audit-core.js";

const at = (y, m, d) => new Date(Date.UTC(y, m - 1, d));

const row = (studentId, name, department, year, date) => ({
  studentId,
  name,
  department,
  year,
  date,
});

test("monthKeyOf yields the calendar YYYY-MM of a UTC date", () => {
  assert.equal(monthKeyOf(at(2026, 9, 21)), "2026-09");
  assert.equal(monthKeyOf(at(2026, 12, 31)), "2026-12");
  assert.equal(monthKeyOf(at(2027, 1, 4)), "2027-01");
});

test("weeklyWindow normalizes a Monday and rejects garbage start dates", () => {
  const w = weeklyWindow({ startDate: "2026-09-21" });
  assert.ok(w, "valid week resolves");
  assert.equal(w.label, "2026-09-21 to 2026-09-27");
  // A non-Monday start snaps back onto its own Monday (reportWindow behaviour).
  const snapped = weeklyWindow({ startDate: "2026-09-23" });
  assert.equal(snapped.label, "2026-09-21 to 2026-09-27");
  // Explicit garbage → null (refuse); absent / empty → current week (default).
  assert.equal(weeklyWindow({ startDate: "not-a-date" }), null);
  assert.ok(weeklyWindow({ startDate: "" }), "empty start defaults to the current week");
  assert.ok(weeklyWindow({}), "absent start defaults to the current week");
});

test("weeklyAuditRange uses start_to_end (single-day edge case is start only)", () => {
  assert.equal(
    weeklyAuditRange({ start: at(2026, 9, 21), end: at(2026, 9, 28) }),
    "2026-09-21_to_2026-09-27"
  );
  // Half-open end minus one day → the inclusive Sunday.
  assert.equal(
    weeklyAuditRange({ start: at(2026, 10, 5), end: at(2026, 10, 12) }),
    "2026-10-05_to_2026-10-11"
  );
});

test("weeklyAuditFileStem slugs the department id", () => {
  assert.equal(
    weeklyAuditFileStem("BSC-CS", "2026-09-21_to_2026-09-27"),
    "bsccs_Weekly_Audit_2026-09-21_to_2026-09-27"
  );
  assert.equal(weeklyAuditFileStem("", "2026-09-21_to_2026-09-27"), "report_Weekly_Audit_2026-09-21_to_2026-09-27");
});

test("weeklyAuditSubject is the expected HOD subject line", () => {
  assert.equal(
    weeklyAuditSubject("B.Sc Computer Science", "2026-09-21_to_2026-09-27"),
    "Weekly Late Attendance Audit - B.Sc Computer Science - 2026-09-21_to_2026-09-27"
  );
});

test("weeklyAuditAttachmentNames returns workbook first then the PDF", () => {
  const names = weeklyAuditAttachmentNames("BSC-CS", "2026-09-21_to_2026-09-27");
  assert.deepEqual(names.map((n) => n.filename), [
    "bsccs_Weekly_Audit_2026-09-21_to_2026-09-27.xlsx",
    "bsccs_Weekly_Audit_2026-09-21_to_2026-09-27.pdf",
  ]);
  assert.equal(names[0].contentType, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");
  assert.equal(names[1].contentType, "application/pdf");
});

test("aggregateWeeklyAudit groups by department and builds repeated views (threshold 2)", () => {
  const rows = [
    row("S1", "Ada", "BSC-CS", "3rd Year", "2026-09-21"),
    row("S1", "Ada", "BSC-CS", "3rd Year", "2026-09-22"),
    row("S2", "Ben", "BSC-CS", "1st Year", "2026-09-21"),
    row("S3", "Chi", "BSC-IT", "2nd Year", "2026-09-24"),
    row("S3", "Chi", "BSC-IT", "2nd Year", "2026-09-25"),
    row("S3", "Chi", "BSC-IT", "2nd Year", "2026-09-26"),
    row("S4", "Dee", "BSC-IT", "2nd Year", "2026-08-30"), // previous month, ignored today
  ];
  const audit = aggregateWeeklyAudit(rows, { monthKey: "2026-09", repeatThreshold: 2 });

  assert.equal(audit.totalEvents, 7);
  assert.equal(audit.uniqueStudents, 4);
  assert.equal(audit.repeatedStudents, 2); // S1 (2), S3 (3)

  // Departments sorted by uniqueStudents desc, then totalEvents desc →
  // BSC-IT (2 students / 4 events) before BSC-CS (2 students / 3 events).
  assert.deepEqual(audit.departments.map((d) => d.department), ["BSC-IT", "BSC-CS"]);

  const cs = audit.departments.find((d) => d.department === "BSC-CS");
  assert.equal(cs.uniqueStudents, 2);
  assert.equal(cs.totalEvents, 3);
  assert.equal(cs.repeatedStudents, 1);

  const ada = cs.students.find((s) => s.studentId === "S1");
  assert.equal(ada.repeated, true);
  assert.equal(ada.weeklyCount, 2);
  assert.equal(ada.monthCount, 2);
  assert.equal(ada.lastLateDate, "2026-09-22");

  const ben = cs.students.find((s) => s.studentId === "S2");
  assert.equal(ben.repeated, false);
  assert.equal(ben.weeklyCount, 1);
  assert.equal(ben.lastLateDate, "2026-09-21");

  const it = audit.departments.find((d) => d.department === "BSC-IT");
  assert.equal(it.students.length, 2);
  const chi = it.students.find((s) => s.studentId === "S3");
  assert.equal(chi.repeated, true);
  assert.equal(chi.weeklyCount, 3);
  assert.equal(chi.monthCount, 3);
  assert.equal(chi.lastLateDate, "2026-09-26");
  const dee = it.students.find((s) => s.studentId === "S4");
  assert.equal(dee.monthCount, 0); // the Aug entry is outside monthKey so excluded
  assert.equal(dee.lastLateDate, null);

  // Students in a department sort by name asc.
  assert.deepEqual(cs.students.map((s) => s.name), ["Ada", "Ben"]);
});

test("aggregateWeeklyAudit honors a custom repeat threshold", () => {
  const rows = [
    row("S1", "Ada", "BSC-CS", "3rd Year", "2026-09-21"),
    row("S1", "Ada", "BSC-CS", "3rd Year", "2026-09-22"),
    row("S1", "Ada", "BSC-CS", "3rd Year", "2026-09-23"),
    row("S2", "Ben", "BSC-CS", "1st Year", "2026-09-21"),
  ];
  const audit = aggregateWeeklyAudit(rows, { monthKey: "2026-09", repeatThreshold: 3 });
  assert.equal(audit.repeatedStudents, 1); // S1 (3 lates) is repeated at threshold 3
  assert.equal(audit.departments[0].students.find((s) => s.studentId === "S1").repeated, true);
  assert.equal(audit.departments[0].students.find((s) => s.studentId === "S2").repeated, false);

  // A lower threshold marks the same data with more repeats.
  const at2 = aggregateWeeklyAudit(rows, { monthKey: "2026-09", repeatThreshold: 2 });
  assert.equal(at2.repeatedStudents, 1);
  assert.equal(at2.departments[0].students.find((s) => s.studentId === "S1").repeated, true);
});

test("aggregateWeeklyAudit defaults an empty monthKey without crashing", () => {
  const rows = [row("S1", "Ada", "BSC-CS", "3rd Year", "2026-09-21")];
  const audit = aggregateWeeklyAudit(rows); // no monthKey → derived from now (still groups)
  assert.equal(audit.departments.length, 1);
  assert.equal(audit.uniqueStudents, 1);
});

test("buildWeeklyAuditHtml escapes input, lists only repeated students and totals counts", () => {
  const group = {
    department: 'BSC-CS" onload', // never rendered — only name used in header
    uniqueStudents: 2,
    totalEvents: 3,
    repeatedStudents: 1,
    students: [
      { studentId: 'S1","x', name: "<script>alert(1)</script>", department: "BSC-CS", year: "3rd Year", weeklyCount: 2, monthCount: 2, lastLateDate: "2026-09-22", repeated: true },
      { studentId: "S2", name: "Ben", department: "BSC-CS", year: "1st Year", weeklyCount: 1, monthCount: 1, lastLateDate: "2026-09-21", repeated: false },
    ],
  };
  const html = buildWeeklyAuditHtml({
    collegeName: "Sankara College of Science & Commerce",
    departmentName: "<B.Sc CS>",
    weekLabel: "2026-09-21 to 2026-09-27",
    group,
  });

  // Repeated student rendered; non-repeated student NOT in the table.
  assert.ok(!html.includes(">Ben<"), "non-repeated student is excluded from the table");

  // Escaped, not executed.
  assert.ok(!html.includes("<script>"), "name is escaped");
  assert.ok(html.includes("&lt;script&gt;"), "escaped name present");
  assert.ok(html.includes("&lt;B.Sc CS&gt;"), "departmentName escaped");

  // Department header uses its display string, student XSS cannot leak a title.
  assert.match(html, /Weekly Late Attendance Audit &mdash; &lt;B\.Sc CS&gt;/);

  // Counts.
  assert.match(html, /<strong>2 students<\/strong>/);
  assert.match(html, /<strong>3 occasions<\/strong>/);
  assert.match(html, /<strong>1 student<\/strong> were late more than once/);

  assert.match(html, /Sankara College of Science &amp; Commerce/);
  assert.match(html, /Dear HOD,/);
  assert.match(html, /Regards,/);
});

test("buildWeeklyAuditHtml shows a no-repeats note when nothing is repeated", () => {
  const group = {
    department: "BSC-CS",
    uniqueStudents: 1,
    totalEvents: 1,
    repeatedStudents: 0,
    students: [
      { studentId: "S1", name: "Ada", department: "BSC-CS", year: "3rd Year", weeklyCount: 1, monthCount: 1, lastLateDate: "2026-09-21", repeated: false },
    ],
  };
  const html = buildWeeklyAuditHtml({
    departmentName: "B.Sc Computer Science",
    weekLabel: "2026-09-21 to 2026-09-27",
    group,
  });
  assert.match(html, /was marked late more than once this week/);
  assert.match(html, /<strong>1 student<\/strong>/);
});