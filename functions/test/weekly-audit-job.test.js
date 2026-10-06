// Phase 5 job planning tests: the weekly audit job's per-department plan
// (functions/weekly-audit-core.js planWeeklyAuditDepartments) and the pass-out
// notification doc builder (functions/admin-core.js passOutNotificationDoc).
// The idempotency/dedup rules live here — the db-touching schedulers
// (weekly-audit-job.js, pass-out-job.js) are thin over these pure pieces and
// the already-tested senders/admin-core helpers. Run with `npm test`.
import test from "node:test";
import assert from "node:assert/strict";
import { planWeeklyAuditDepartments } from "../weekly-audit-core.js";
import { passOutNotificationDoc } from "../admin-core.js";

const candidate = (over = {}) => ({
  departmentId: "BSC-CS",
  departmentName: "B.Sc Computer Science",
  hodEmail: "hod@example.com",
  uniqueStudents: 4,
  totalEvents: 7,
  repeatedStudents: 2,
  ...over,
});

test("planWeeklyAuditDepartments: due departments sorted by unique, then events", () => {
  const plan = planWeeklyAuditDepartments({
    candidates: [
      candidate({ departmentId: "BSC-IT", departmentName: "B.Sc IT", uniqueStudents: 2, totalEvents: 2, repeatedStudents: 1 }),
      candidate({ uniqueStudents: 4, totalEvents: 7 }),
      candidate({ departmentId: "BSC-PHY", departmentName: "B.Sc Physics", uniqueStudents: 4, totalEvents: 3, repeatedStudents: 2 }),
    ],
    alreadySentKeys: [],
  });
  assert.deepEqual(plan.due.map((c) => c.departmentId), ["BSC-CS", "BSC-PHY", "BSC-IT"]);
  assert.deepEqual(plan.alreadySent, []);
  assert.deepEqual(plan.noHod, []);
});

test("planWeeklyAuditDepartments: already-sent departments are excluded (idempotency)", () => {
  const plan = planWeeklyAuditDepartments({
    candidates: [candidate(), candidate({ departmentId: "BSC-IT", departmentName: "B.Sc IT" })],
    // The mail_logs dedup key may be the department id OR its display name.
    alreadySentKeys: ["bscit"],
  });
  assert.deepEqual(plan.due.map((c) => c.departmentId), ["BSC-CS"]);
  assert.deepEqual(plan.alreadySent.map((c) => c.departmentId), ["BSC-IT"]);
  assert.deepEqual(plan.noHod, []);

  const byName = planWeeklyAuditDepartments({
    candidates: [candidate()],
    alreadySentKeys: ["bsc-computerscience"],
  });
  assert.deepEqual(byName.due, []);
  assert.deepEqual(byName.alreadySent.length, 1);
});

test("planWeeklyAuditDepartments: departments without an HOD email are parked, not dropped", () => {
  const plan = planWeeklyAuditDepartments({
    candidates: [candidate(), candidate({ departmentId: "BSC-MAT", departmentName: "B.Sc Maths", hodEmail: null })],
    alreadySentKeys: [],
  });
  assert.deepEqual(plan.due.map((c) => c.departmentId), ["BSC-CS"]);
  assert.deepEqual(plan.noHod.map((c) => c.departmentId), ["BSC-MAT"]);
});

test("passOutNotificationDoc: server-authoritative pending_review notification for the pass-out job", () => {
  const student = {
    studentId: "24BCS001",
    name: "Ada Lovelace",
    department: "B.Sc Computer Science",
    departmentId: "BSC-CS",
    currentYear: 2,
    batchStartYear: 2024,
    batchEndYear: 2027,
  };
  const at = new Date("2026-09-25T07:00:00Z");
  const doc = passOutNotificationDoc({ student, at });
  assert.equal(doc.studentId, "24BCS001");
  assert.equal(doc.name, "Ada Lovelace");
  assert.equal(doc.batchEndYear, 2027);
  assert.equal(doc.status, "pending_review");
  assert.equal(doc.createdAt.getTime(), at.getTime());
  assert.equal(doc.updatedAt.getTime(), at.getTime());
});