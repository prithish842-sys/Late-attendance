// Dependency-free unit tests for the pure escalation logic (functions/escalation-core.js).
// Run from the functions/ dir: node --test test/escalation-core.test.js
import test from "node:test";
import assert from "node:assert/strict";
import {
  periodKey,
  periodStart,
  periodEnd,
  semesterKey,
  computeEscalation,
  escalationDoc,
  monthlyStatus,
  monthlyStatusDoc,
} from "../escalation-core.js";

// Use UTC dates to keep IS test expectations timezone-independent in CI/local.
const utc = (y, m, d) => new Date(Date.UTC(y, m - 1, d));

test("periodKey: monthly reset is YYYY-MM", () => {
  assert.equal(periodKey(utc(2026, 9, 3)), "2026-09");
  assert.equal(periodKey(utc(2026, 12, 31)), "2026-12");
  assert.equal(periodKey(utc(2027, 1, 1)), "2027-01");
});

test("periodKey: month boundaries pad to two digits", () => {
  assert.equal(periodKey(utc(2026, 3, 15)), "2026-03");
});

test("periodStart/periodEnd: monthly window is the calendar month", () => {
  const mid = utc(2026, 9, 15);
  assert.equal(periodStart(mid).toISOString(), "2026-09-01T00:00:00.000Z");
  assert.equal(periodEnd(mid).toISOString(), "2026-10-01T00:00:00.000Z");
});

test("periodStart/periodEnd: month after a December scan rolls to next year", () => {
  const dec = utc(2026, 12, 25);
  assert.equal(periodStart(dec).toISOString(), "2026-12-01T00:00:00.000Z");
  assert.equal(periodEnd(dec).toISOString(), "2027-01-01T00:00:00.000Z");
});

test("semesterKey: Jan–Jun is S1, Jul–Dec is S2", () => {
  assert.equal(semesterKey(utc(2026, 1, 10)), "2026-S1");
  assert.equal(semesterKey(utc(2026, 6, 30)), "2026-S1");
  assert.equal(semesterKey(utc(2026, 7, 1)), "2026-S2");
  assert.equal(semesterKey(utc(2026, 12, 31)), "2026-S2");
});

test("semester window: S2 spans Jul 1 → Jan 1 next year", () => {
  const s2 = utc(2026, 11, 15);
  assert.equal(periodStart(s2, "semester").toISOString(), "2026-07-01T00:00:00.000Z");
  assert.equal(periodEnd(s2, "semester").toISOString(), "2027-01-01T00:00:00.000Z");
});

test("computeEscalation: 1st late is tracking only", () => {
  assert.deepEqual(computeEscalation(1, 3), {
    status: "tracking",
    warning: false,
    escalated: false,
  });
});

test("computeEscalation: 2nd late flags warning (not yet escalated)", () => {
  assert.deepEqual(computeEscalation(2, 3), {
    status: "warning",
    warning: true,
    escalated: false,
  });
});

test("computeEscalation: threshold reached escalates", () => {
  const d = computeEscalation(3, 3);
  assert.equal(d.status, "escalated");
  assert.equal(d.escalated, true);
  assert.equal(d.warning, false);
});

test("computeEscalation: beyond threshold stays escalated", () => {
  assert.equal(computeEscalation(7, 3).status, "escalated");
});

test("computeEscalation: respects a custom threshold (DECISIONS.md #2)", () => {
  assert.equal(computeEscalation(4, 5).status, "warning");
  assert.equal(computeEscalation(5, 5).status, "escalated");
});

test("computeEscalation: non-positive threshold falls back to default 3", () => {
  assert.equal(computeEscalation(2, 0).status, "warning");
  assert.equal(computeEscalation(3, 0).status, "escalated");
});

test("escalationDoc: includes period, student and verdict", () => {
  const doc = escalationDoc(
    { studentId: "26BSC001", name: "A", department: "BSC-CS", year: "II" },
    3,
    3,
    "2026-09"
  );
  assert.equal(doc.studentId, "26BSC001");
  assert.equal(doc.period, "2026-09");
  assert.equal(doc.count, 3);
  assert.equal(doc.threshold, 3);
  assert.equal(doc.status, "escalated");
  assert.equal(doc.escalated, true);
});

test("monthlyStatus: 1st late is logged, 2nd is warning, 3rd+ escalates (default threshold 3)", () => {
  assert.equal(monthlyStatus(1, 3), "logged");
  assert.equal(monthlyStatus(2, 3), "warning");
  assert.equal(monthlyStatus(3, 3), "escalated");
  assert.equal(monthlyStatus(7, 3), "escalated");
});

test("monthlyStatus: respects a custom threshold", () => {
  assert.equal(monthlyStatus(4, 5), "warning");
  assert.equal(monthlyStatus(5, 5), "escalated");
  assert.equal(monthlyStatus(1, 2), "logged");
  assert.equal(monthlyStatus(2, 2), "escalated");
});

test("monthlyStatus: non-positive threshold falls back to default 3", () => {
  assert.equal(monthlyStatus(2, 0), "warning");
  assert.equal(monthlyStatus(3, 0), "escalated");
});

test("monthlyStatusDoc: monthly counter row carries student, month and status", () => {
  const doc = monthlyStatusDoc(
    { studentId: "26BSC001", name: "A", department: "BSC-CS", year: "II" },
    2,
    3,
    "2026-09"
  );
  assert.equal(doc.studentId, "26BSC001");
  assert.equal(doc.monthKey, "2026-09");
  assert.equal(doc.lateCount, 2);
  assert.equal(doc.status, "warning");
});