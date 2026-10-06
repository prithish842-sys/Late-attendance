// Phase 5 performance tests — large-volume correctness + generous wall-clock
// ceilings for the hot aggregation/build paths, so a slow-down of the pure
// pipeline (weekly audit, imports, pass-out scan, report mail) is caught while
// normal CI variance never trips a bound. These are correctness-first: the
// timing asserts are deliberately loose (seconds), they exist to catch O(n²)
// blow-ups, not to benchmark microsecond wins. Run with `npm test`.
import test from "node:test";
import assert from "node:assert/strict";
import { aggregateWeeklyAudit, buildWeeklyAuditHtml, planWeeklyAuditDepartments } from "../weekly-audit-core.js";
import { validateImportRows, passOutReviewStudents } from "../admin-core.js";
import { groupRowsByTier, buildReportMailHtml } from "../report-mail-core.js";
import { runReportStats, yearTier } from "../report-core.js";

const elapsed = (label, start, ceilingMs) => {
  const ms = performance.now() - start;
  assert.ok(ms < ceilingMs, `${label} took ${ms.toFixed(0)} ms (ceiling ${ceilingMs} ms)`);
  return ms;
};

const row = (studentId, name, department, year, date) => ({ studentId, name, department, year, date });

test("performance: weekly audit aggregation of ~15k late rows across 25 departments", () => {
  const depts = Array.from({ length: 25 }, (_, i) => `BSC-${String.fromCharCode(65 + (i % 26))}${Math.floor(i / 26) || ""}`);
  const rows = [];
  for (let d = 0; d < depts.length; d++) {
    // 600 rows per department across 400 students → every student appears 1-2
    // times, so half the department (200 students) clears repeatThreshold 2.
    for (let i = 0; i < 600; i++) {
      const studentId = `${depts[d]}${String((i % 400) + 1).padStart(3, "0")}`;
      rows.push(row(studentId, `Student ${d}-${i % 400}`, depts[d], `${((d + i) % 3) + 1}st Year`, `2026-09-${String((i % 7) + 21).padStart(2, "0")}`));
    }
  }
  const start = performance.now();
  const audit = aggregateWeeklyAudit(rows, { monthKey: "2026-09", repeatThreshold: 2 });
  elapsed("aggregateWeeklyAudit(15000)", start, 5000);

  assert.equal(audit.totalEvents, 15000);
  assert.equal(audit.uniqueStudents, 10000, "400 distinct students per department");
  assert.equal(audit.repeatedStudents, 5000, "200 repeated per department");
  assert.equal(audit.departments.length, 25);
  // Departments must be sorted by uniqueStudents desc, then totalEvents desc.
  for (let i = 1; i < audit.departments.length; i++) {
    const prev = audit.departments[i - 1];
    const cur = audit.departments[i];
    assert.ok(
      prev.uniqueStudents > cur.uniqueStudents ||
        (prev.uniqueStudents === cur.uniqueStudents && prev.totalEvents >= cur.totalEvents),
      "department sort order holds"
    );
  }
  // Every department carries exactly 400 distinct students, 200 repeated.
  assert.ok(audit.departments.every((dl) => dl.uniqueStudents === 400 && dl.repeatedStudents === 200));
});

test("performance: pass-out scan of 5000 students is linear, correct and oldest-batch-first", () => {
  const students = Array.from({ length: 5000 }, (_, i) => {
    const end = 2024 + (i % 5); // 2024..2028 → 2026..2028 eligible at year 2027
    return {
      studentId: `24${String(i + 1).padStart(5, "0")}`,
      name: `Student ${i}`,
      department: `BSC-${i % 3}`,
      batchStartYear: end - 2,
      batchEndYear: end,
      active: i % 100 !== 42, // a handful archived
    };
  });
  const now = new Date(Date.UTC(2027, 5, 1));
  const start = performance.now();
  const eligible = passOutReviewStudents(students, now);
  elapsed("passOutReviewStudents(5000)", start, 5000);

  const expected = students.filter((s) => s.active && s.batchEndYear <= 2027).length;
  assert.equal(eligible.length, expected);
  for (let i = 1; i < eligible.length; i++) {
    assert.ok(
      eligible[i - 1].batchEndYear <= eligible[i].batchEndYear,
      "students sort oldest batch first"
    );
  }
});

test("performance: import sheet capped at MAX_IMPORT_ROWS=500 even when 1000 rows are fed", () => {
  const depts = [{ id: "BSC-CS", name: "B.Sc Computer Science", hodEmail: "hod@x.com" }];
  const rows = Array.from({ length: 1000 }, (_, i) => ({
    registerNumber: `24BCS${String(i + 1).padStart(3, "0")}`,
    name: `Student ${i}`,
    department: "B.Sc Computer Science",
    currentYear: 1,
    batchStartYear: 2024,
    batchEndYear: 2027,
  }));
  const start = performance.now();
  const result = validateImportRows(rows, { departmentDocs: depts, existingStudentIds: [] });
  elapsed("validateImportRows(1000 -> 500)", start, 3000);

  assert.equal(result.counts.rows, 500, "only the first 500 are validated (NEW_ADMIN_WORKFLOW cap)");
  assert.equal(result.counts.valid, 500);
  assert.equal(result.counts.invalid, 0);
});

test("performance: report mail body for 6000 late entries groups by tier and escapes", () => {
  const rows = [];
  for (let i = 0; i < 6000; i++) {
    rows.push({
      studentId: `24BCS${String(i + 1).padStart(4, "0")}`,
      name: `Student <${i}>`,
      department: "B.Sc Computer Science",
      year: ["1st", "2nd", "III", "2024-2027"][i % 4],
    });
  }
  const start = performance.now();
  const groups = groupRowsByTier(rows);
  const html = buildReportMailHtml({
    collegeName: "Sankara College of Science & Commerce",
    departmentName: "B.Sc Computer Science",
    range: "2026-09-01_to_2026-09-30",
    rows,
  });
  elapsed("groupRowsByTier + buildReportMailHtml(6000)", start, 5000);

  assert.deepEqual(groups.map((g) => g.label), ["3rd Year", "2nd Year", "1st Year", "Other"]);
  assert.equal(groups.reduce((n, g) => n + g.entries.length, 0), 6000);
  assert.ok(!html.includes("<Student"), "student names are HTML-escaped");
  assert.match(html, /6000 late entries/);
});

test("performance: runReportStats over 10k rows buckets departments and counts distinct students", () => {
  const rows = [];
  for (let i = 0; i < 10000; i++) {
    rows.push({
      date: "2026-09-01",
      time: "08:30",
      studentId: `S${i}`,
      name: `Student ${i}`,
      department: `Dept ${i % 12}`,
      year: "1st",
    });
  }
  const start = performance.now();
  const stats = runReportStats(rows);
  elapsed("runReportStats(10000)", start, 3000);

  assert.equal(stats.totalLateEntries, 10000);
  assert.equal(stats.distinctStudents, 10000);
  assert.equal(stats.byDepartment.length, 12);
});

test("performance: weekly audit HTML repeats table for 2000 repeated students", () => {
  const group = {
    department: "BSC-CS",
    uniqueStudents: 2100,
    totalEvents: 4600,
    repeatedStudents: 2000,
    students: Array.from({ length: 2100 }, (_, i) => ({
      studentId: `24BCS${String(i + 1).padStart(4, "0")}`,
      registerNumber: `24BCS${String(i + 1).padStart(4, "0")}`,
      name: `Student ${i}`,
      department: "BSC-CS",
      year: "1st Year",
      weeklyCount: i < 2000 ? 3 : 1,
      monthCount: i < 2000 ? 3 : 1,
      lastLateDate: "2026-09-22",
      repeated: i < 2000,
    })),
  };
  const start = performance.now();
  const html = buildWeeklyAuditHtml({
    departmentName: "B.Sc Computer Science",
    weekLabel: "2026-09-21 to 2026-09-27",
    group,
  });
  elapsed("buildWeeklyAuditHtml(2100 students)", start, 5000);
  assert.match(html, /2100 students/);
  assert.match(html, /4600 occasions/);
});

test("performance: weekly audit job plan over 60 candidate departments", () => {
  const candidates = Array.from({ length: 60 }, (_, i) => ({
    departmentId: `DEPT-${i}`,
    departmentName: `Department ${i}`,
    hodEmail: i % 7 === 0 ? null : `hod${i}@x.com`, // ~8 parked without HOD
    uniqueStudents: (i * 37) % 500,
    totalEvents: (i * 53) % 900,
    repeatedStudents: (i * 11) % 40,
  }));
  // Mark every other department as already sent so the plan exercises both paths.
  const sentKeys = candidates.filter((_, i) => i % 2 === 0).map((c) => c.departmentId.toLowerCase().replace(/[^a-z0-9]/g, ""));
  const start = performance.now();
  const plan = planWeeklyAuditDepartments({ candidates, alreadySentKeys: sentKeys });
  elapsed("planWeeklyAuditDepartments(60)", start, 1000);

  assert.equal(plan.due.length + plan.alreadySent.length + plan.noHod.length, 60);
  assert.equal(plan.alreadySent.length, 30);
  assert.ok(plan.noHod.every((c) => c.hodEmail == null));
  assert.ok(plan.due.every((c) => c.hodEmail != null));
});

test("performance: yearTier classification stays linear over a large roster", () => {
  const years = Array.from({ length: 50000 }, (_, i) => ["1st", "2nd", "III", "II", "2024-2027", "I"][i % 6]);
  const start = performance.now();
  let sum = 0;
  for (const y of years) sum += yearTier(y);
  elapsed("yearTier(50000)", start, 3000);
  assert.ok(sum > 0, "tiers classified");
});