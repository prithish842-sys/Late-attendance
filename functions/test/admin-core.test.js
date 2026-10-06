// Pure unit tests for functions/admin-core.js — the Phase 4 admin building
// blocks: import-sheet validation, pass-out eligibility, the object-staging for
// soft delete / restore / permanent delete, the seeded student docs and the
// import-batch metadata row. Run with `npm test` in functions/.
import test from "node:test";
import assert from "node:assert/strict";
import {
  MAX_IMPORT_ROWS,
  parseYearInt,
  yearLabel,
  validateImportRows,
  passOutEligible,
  passOutReviewStudents,
  auditLogDoc,
  softDeleteDocs,
  restoreDocs,
  permanentDeleteDocs,
  studentSeedDoc,
  importBatchDoc,
} from "../admin-core.js";

const at = (y, m, d) => new Date(Date.UTC(y, m - 1, d));

const depts = [
  { id: "BSC-CS", name: "B.Sc Computer Science", hodEmail: "hod-cs@college.edu" },
  { id: "BSC-BT", name: "B.Sc Biotechnology" },
];

const row = (overrides = {}) => ({
  registerNumber: "24BCS001",
  name: "Student Name",
  department: "B.Sc Computer Science",
  currentYear: 1,
  batchStartYear: 2024,
  batchEndYear: 2027,
  ...overrides,
});

test("parseYearInt accepts integers and numeric strings, rejects garbage", () => {
  assert.equal(parseYearInt(2024), 2024);
  assert.equal(parseYearInt("2024"), 2024);
  assert.equal(parseYearInt(""), null);
  assert.equal(parseYearInt("abc"), null);
  assert.equal(parseYearInt("2024.5"), null);
  assert.equal(parseYearInt(undefined), null);
});

test("yearLabel renders ordinal display strings", () => {
  assert.equal(yearLabel(1), "1st Year");
  assert.equal(yearLabel(2), "2nd Year");
  assert.equal(yearLabel(3), "3rd Year");
  assert.equal(yearLabel(4), "4th Year");
  assert.equal(yearLabel(0), "Other");
  assert.equal(yearLabel("2"), "Other");
});

test("a well-formed row validates as importable", () => {
  const { ok, counts, rows } = validateImportRows([row()], { departmentDocs: depts });
  assert.equal(ok, true);
  assert.deepEqual(counts, { rows: 1, valid: 1, invalid: 0, warnings: 0 });
  assert.equal(rows[0].valid, true);
  assert.equal(rows[0].departmentId, "BSC-CS");
  assert.equal(rows[0].hodEmail, "hod-cs@college.edu");
});

test("missing name, register number and department are hard errors", () => {
  const { ok, rows, counts } = validateImportRows(
    [row({ name: "", registerNumber: "", department: "" })],
    { departmentDocs: depts }
  );
  assert.equal(ok, false);
  assert.equal(counts.invalid, 1);
  assert.equal(rows[0].valid, false);
  const msg = rows[0].errors.join(" | ");
  assert.match(msg, /Register number is required/);
  assert.match(msg, /Student name is required/);
  assert.match(msg, /Department is required/);
});

test("an unknown department is an error that names the fix", () => {
  const { rows } = validateImportRows([row({ department: "B.Com (CA)" })], { departmentDocs: depts });
  assert.equal(rows[0].valid, false);
  assert.match(rows[0].errors[0], /not on file/);
});

test("duplicate register numbers within the sheet are errors; only the first counts", () => {
  const { ok, rows } = validateImportRows([row(), row({ name: "Second" })], { departmentDocs: depts });
  assert.equal(ok, false);
  assert.equal(rows[1].valid, false);
  assert.match(rows[1].errors[0], /Duplicate register number/);
});

test("register numbers already on file block re-import", () => {
  const { ok, rows } = validateImportRows([row()], {
    departmentDocs: depts,
    existingStudentIds: ["24BCS001"],
  });
  assert.equal(ok, false);
  assert.match(rows[0].errors[0], /already on file/);
});

test("bad batch geometry and out-of-range years are errors", () => {
  const endBefore = validateImportRows([row({ batchEndYear: 2023 })], { departmentDocs: depts });
  assert.equal(endBefore.rows[0].valid, false);
  assert.match(endBefore.rows[0].errors.join(" "), /Batch end year cannot be before/);

  const outOfRange = validateImportRows([row({ batchEndYear: 2400 })], { departmentDocs: depts });
  assert.equal(outOfRange.rows[0].valid, false);
  assert.match(outOfRange.rows[0].errors.join(" "), /out of range/);
});

test("a current year outside the batch span warns but does not block", () => {
  const { ok, rows, counts } = validateImportRows([row({ currentYear: 9 })], { departmentDocs: depts });
  assert.equal(ok, true, "warning-only rows still commit");
  assert.equal(rows[0].valid, true);
  assert.equal(counts.warnings, 1);
  assert.match(rows[0].warnings[0], /outside the batch 2024–2027/);
});

test("a register intake prefix that contradicts the batch start year warns (secondary to batch years)", () => {
  const { rows } = validateImportRows([row({ registerNumber: "22BCS001" })], { departmentDocs: depts });
  assert.equal(rows[0].valid, true);
  assert.match(rows[0].warnings[0], /starts with the 2022 intake/);
});

test("passOutEligible flags active students whose batch end year has passed, never inactive ones", () => {
  const active = { studentId: "24BCS001", name: "A", batchEndYear: 2027, active: true };
  assert.equal(passOutEligible(active, at(2026, 9, 1)), false, "batch still running in 2026");
  assert.equal(passOutEligible(active, at(2027, 9, 1)), true, "batch ends in 2027");
  assert.equal(passOutEligible(active, at(2028, 1, 1)), true, "batch long gone");
  assert.equal(passOutEligible({ ...active, active: false }, at(2028, 1, 1)), false, "already archived");
  assert.equal(passOutEligible({ studentId: "X", batchEndYear: null }, at(2028, 1, 1)), false, "no batch year");
  assert.equal(passOutEligible({ studentId: "Y", batchEndYear: 2025 }, at(2026, 1, 1)), true);
});

test("passOutReviewStudents returns only eligible students, oldest batch first", () => {
  const students = [
    { studentId: "26B", batchEndYear: 2029 },
    { studentId: "24A", batchEndYear: 2027 },
    { studentId: "25C", batchEndYear: 2027, active: false },
    { studentId: "23D", batchEndYear: 2026 },
    { studentId: "27E", batchEndYear: null },
  ];
  const out = passOutReviewStudents(students, at(2027, 6, 1));
  assert.deepEqual(
    out.map((s) => s.studentId),
    ["23D", "24A"]
  );
});

test("softDeleteDocs stages an evidence row that keeps the original student intact", () => {
  const student = { studentId: "24BCS001", name: "Student Name", department: "B.Sc Computer Science", year: "1st Year", batchEndYear: 2027 };
  const when = at(2027, 6, 1);
  const staged = softDeleteDocs({ student, deletedBy: "admin-1", reason: "pass_out", at: when });
  assert.equal(staged.studentUpdate.active, false);
  assert.equal(staged.studentUpdate.deletedBy, "admin-1");
  assert.equal(staged.deletionRecord.studentId, "24BCS001");
  assert.equal(staged.deletionRecord.restored, false);
  assert.equal(staged.deletionRecord.permanentlyDeletedAt, null);
  assert.deepEqual(staged.deletionRecord.originalStudentData, student, "unmodified snapshot for restore");
  assert.ok(staged.deletionRecord.retentionUntil > when, "retention is a year out");
  assert.equal(staged.auditLog.action, "soft_delete");
  assert.equal(staged.auditLog.targetId, "24BCS001");
  assert.deepEqual(staged.auditLog.metadata, { reason: "pass_out" });
});

test("restoreDocs clears the archive fields via clearStudentFields", () => {
  const staged = restoreDocs({ studentId: "24BCS001", restoredBy: "admin-1", at: at(2027, 7, 1) });
  assert.equal(staged.studentUpdate.active, true);
  assert.equal(staged.studentUpdate.restoredAt.getTime(), at(2027, 7, 1).getTime());
  assert.deepEqual(staged.clearStudentFields, ["deletedAt", "archivedAt", "deletedBy", "reason"]);
  assert.equal(staged.auditLog.action, "restore");
});

test("permanentDeleteDocs flags the evidence row and never deletes it", () => {
  const staged = permanentDeleteDocs({ studentId: "24BCS001", requestedBy: "admin-1", at: at(2028, 6, 1) });
  assert.equal(staged.deletionRecordUpdate.permanentlyDeletedBy, "admin-1");
  assert.equal(staged.auditLog.action, "permanent_delete");
  assert.ok(staged.deletionRecordUpdate, "evidence row is updated, not removed (retention #13)");
});

test("studentSeedDoc writes the lifecycle-safe new-student shape", () => {
  const doc = studentSeedDoc({
    registerNumber: "24BCS001",
    name: "Student Name",
    departmentId: "BSC-CS",
    departmentName: "B.Sc Computer Science",
    currentYear: 1,
    batchStartYear: 2024,
    batchEndYear: 2027,
    photoUrl: null,
    createdBy: "admin-1",
    at: at(2026, 9, 1),
  });
  assert.equal(doc.studentId, "24BCS001");
  assert.equal(doc.registerNumber, "24BCS001");
  assert.equal(doc.department, "B.Sc Computer Science");
  assert.equal(doc.departmentName, "B.Sc Computer Science");
  assert.equal(doc.year, "1st Year");
  assert.equal(doc.active, true);
  assert.equal(doc.archivedAt, null);
  assert.equal(doc.deletedAt, null);
});

test("importBatchDoc records committed counts and the batch range", () => {
  const doc = importBatchDoc({
    importId: "imp_abc123",
    filename: "bsc-cs-2026.xlsx",
    departmentId: "BSC-CS",
    department: "B.Sc Computer Science",
    batchStartYear: 2024,
    batchEndYear: 2027,
    counts: { rows: 24, valid: 20, invalid: 4, warnings: 2 },
    createdBy: "admin-1",
    at: at(2026, 9, 1),
  });
  assert.equal(doc.status, "committed");
  assert.deepEqual(doc.counts, { rows: 24, valid: 20, invalid: 4, warnings: 2, committed: 20 });
  assert.equal(doc.batchEndYear, 2027);
});

test("auditLogDoc records actor, action, target and timestamp with optional metadata only when present", () => {
  const base = auditLogDoc({ actorId: "admin-1", action: "soft_delete", targetType: "student", targetId: "24BCS001", at: at(2026, 1, 1) });
  assert.equal(base.timestamp.getTime(), at(2026, 1, 1).getTime());
  assert.ok(!("metadata" in base), "no empty metadata key");
  const withMeta = auditLogDoc({ actorId: "admin-1", action: "soft_delete", targetType: "student", targetId: "24BCS001", at: at(2026, 1, 1), metadata: { reason: "pass_out" } });
  assert.deepEqual(withMeta.metadata, { reason: "pass_out" });
});

test("the sheet is capped at MAX_IMPORT_ROWS rows", () => {
  const rows = Array.from({ length: MAX_IMPORT_ROWS + 10 }, (_, i) => row({ registerNumber: `24BCS${String(i + 1).padStart(3, "0")}` }));
  const { counts } = validateImportRows(rows, { departmentDocs: depts });
  assert.equal(counts.rows, MAX_IMPORT_ROWS);
});