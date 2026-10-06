// Shared execution for Phase 4 admin ops (docs-new-updates/NEW_TASKS.md).
//
// Like the Phase 3 senders, this is the one implementation both the Blaze Cloud
// Functions (functions/index.js callables) and the Spark fallback runner
// (scripts/process-admin.js, Admin SDK) invoke, so outcomes match on both plans.
// It performs the Firestore reads/writes — the *rules* of what may happen live
// in functions/admin-core.js (pure, heavily tested); this module just applies
// them to `db`.
//
// Never accepts admin decisions from a client directly: the app only enqueues
// intent (admin_requests on Spark / callables on Blaze). Server-authoritative
// writes + audit_logs evidence (NEW_SECURITY.md §1, §8).

const { FieldValue } = require("firebase-admin/firestore");
const {
  validateImportRows,
  studentSeedDoc,
  importBatchDoc,
  softDeleteDocs,
  restoreDocs,
  permanentDeleteDocs,
  auditLogDoc,
} = require("./admin-core.js");

const SOFT_DELETE_REASONS = ["pass_out", "manual"];

async function departmentDocs(db) {
  const snap = await db.collection("departments").get();
  return snap.docs.map((d) => ({ ...d.data(), id: d.id }));
}

async function currentStudentIds(db) {
  const snap = await db.collection("students").get();
  return snap.docs.map((d) => d.id);
}

/** Helper — apply a staged docs body to a doc ref, deleting omitted marker fields. */
function applyUpdate(ref, updateFields, clearFields) {
  const payload = { ...updateFields };
  for (const f of clearFields || []) payload[f] = FieldValue.delete();
  return ref.set(payload, { merge: true });
}

/**
 * Commit a validated import sheet. `request.rows` are the raw sheet rows the
 * client parsed and previewed; the SERVER re-validates them (departments +
 * current roster are loaded here) so a tampered payload can never inject bad
 * or duplicate students. Rows with errors are skipped, never half-written.
 * Idempotent by importId: an already-committed batch returns its summary.
 */
async function runCommitImportBatch({ db, request }) {
  const importId = request.importId;
  if (!importId) return { status: "abort", code: "MISSING_IMPORT_ID", detail: "An importId is required." };

  const existing = await db.collection("import_batches").doc(importId).get();
  if (existing.exists && existing.data().status === "committed") {
    return { status: "committed", importId, added: existing.data().counts?.committed ?? 0, skipped: existing.data().counts?.invalid ?? 0, counts: existing.data().counts, alreadyCommitted: true };
  }

  const [depts, existingIds] = await Promise.all([departmentDocs(db), currentStudentIds(db)]);
  const validation = validateImportRows(request.rows || [], { departmentDocs: depts, existingStudentIds: existingIds });
  if (validation.counts.rows === 0) {
    return { status: "abort", code: "EMPTY_SHEET", detail: "The sheet has no data rows to import." };
  }

  const at = new Date();
  const now = FieldValue.serverTimestamp();
  const batch = db.batch();
  let added = 0;
  for (const r of validation.rows) {
    if (!r.valid) continue;
    batch.set(
      db.collection("students").doc(r.registerNumber),
      studentSeedDoc({
        registerNumber: r.registerNumber,
        name: r.name,
        departmentId: r.departmentId,
        departmentName: r.departmentName,
        currentYear: r.currentYear,
        batchStartYear: r.batchStartYear,
        batchEndYear: r.batchEndYear,
        photoUrl: r.photoUrl,
        createdBy: request.requestedBy,
        at,
      })
    );
    added++;
  }
  batch.set(db.collection("import_batches").doc(importId), {
    ...importBatchDoc({
      importId,
      filename: request.filename,
      departmentId: request.departmentId,
      department: request.department,
      batchStartYear: validation.rows[0]?.batchStartYear ?? null,
      batchEndYear: validation.rows[0]?.batchEndYear ?? null,
      counts: validation.counts,
      createdBy: request.requestedBy,
      at,
    }),
    createdAt: now,
  });
  batch.set(db.collection("audit_logs").doc(), auditLogDoc({
    actorId: request.requestedBy,
    action: "import_batch",
    targetType: "import_batch",
    targetId: importId,
    at,
    metadata: { filename: request.filename, added, invalid: validation.counts.invalid },
  }));
  await batch.commit();

  return {
    status: "committed",
    importId,
    added,
    skipped: validation.counts.invalid,
    counts: validation.counts,
    alreadyCommitted: false,
  };
}

/** Two-stage stage 1 — soft delete (archive) a set of students. */
async function runSoftDelete({ db, request }) {
  const studentIds = Array.isArray(request.studentIds) ? request.studentIds : [];
  const reason = SOFT_DELETE_REASONS.includes(request.reason) ? request.reason : "manual";
  if (studentIds.length === 0) return { status: "abort", code: "NO_STUDENTS", detail: "Provide at least one studentId." };
  if (studentIds.length > 200) return { status: "abort", code: "TOO_MANY", detail: "Batch at most 200 students at a time." };

  const at = new Date();
  let deleted = 0;
  const skipped = [];
  const batch = db.batch();
  for (const studentId of studentIds) {
    const snap = await db.collection("students").doc(studentId).get();
    if (!snap.exists) {
      skipped.push({ studentId, reason: "not_found" });
      continue;
    }
    const student = { ...snap.data(), studentId };
    if (student.active === false) {
      skipped.push({ studentId, reason: "already_inactive" });
      continue;
    }
    const staged = softDeleteDocs({ student, deletedBy: request.deletedBy, reason, at });
    batch.update(db.collection("students").doc(studentId), staged.studentUpdate);
    batch.set(db.collection("deletion_records").doc(studentId), staged.deletionRecord);
    batch.set(db.collection("audit_logs").doc(), staged.auditLog);
    if (reason === "pass_out") {
      // Resolve the pending pass-out review notification the job created.
      batch.set(
        db.collection("pass_out_reviews").doc(studentId),
        { status: "soft_deleted", softDeletedAt: at, deletedBy: request.deletedBy, reason, updatedAt: at },
        { merge: true }
      );
    }
    deleted++;
  }
  if (deleted > 0) await batch.commit();
  return { status: "ok", deleted, skipped, reason };
}

/** Second half of the two-stage delete in reverse — bring a student back. */
async function runRestore({ db, request }) {
  const studentIds = Array.isArray(request.studentIds) ? request.studentIds : [];
  if (studentIds.length === 0) return { status: "abort", code: "NO_STUDENTS", detail: "Provide at least one studentId." };
  if (studentIds.length > 200) return { status: "abort", code: "TOO_MANY", detail: "Batch at most 200 students at a time." };

  const at = new Date();
  let restored = 0;
  const skipped = [];
  const batch = db.batch();
  for (const studentId of studentIds) {
    const record = await db.collection("deletion_records").doc(studentId).get();
    if (!record.exists) {
      skipped.push({ studentId, reason: "no_deletion_record" });
      continue;
    }
    const staged = restoreDocs({ studentId, restoredBy: request.restoredBy, at });
    await applyUpdate(db.collection("students").doc(studentId), staged.studentUpdate, staged.clearStudentFields);
    batch.delete(db.collection("deletion_records").doc(studentId));
    batch.set(
      db.collection("pass_out_reviews").doc(studentId),
      { status: "restored", restoredAt: at, restoredBy: request.restoredBy, updatedAt: at },
      { merge: true }
    );
    batch.set(db.collection("audit_logs").doc(), staged.auditLog);
    restored++;
  }
  if (restored > 0) await batch.commit();
  return { status: "ok", restored, skipped };
}

/** Terminate the deletion chain forever — the student doc (and its photoBase64) is removed. */
async function runPermanentDelete({ db, request }) {
  const studentIds = Array.isArray(request.studentIds) ? request.studentIds : [];
  if (studentIds.length === 0) return { status: "abort", code: "NO_STUDENTS", detail: "Provide at least one studentId." };
  if (studentIds.length > 200) return { status: "abort", code: "TOO_MANY", detail: "Batch at most 200 students at a time." };

  const at = new Date();
  let permanentlyDeleted = 0;
  const skipped = [];
  const batch = db.batch();
  for (const studentId of studentIds) {
    const record = await db.collection("deletion_records").doc(studentId).get();
    if (!record.exists) {
      skipped.push({ studentId, reason: "no_deletion_record" });
      continue;
    }
    const data = record.data();
    if (data.permanentlyDeletedAt) {
      skipped.push({ studentId, reason: "already_permanent" });
      continue;
    }
    const staged = permanentDeleteDocs({ studentId, requestedBy: request.requestedBy, at });
    batch.delete(db.collection("students").doc(studentId));
    batch.update(db.collection("deletion_records").doc(studentId), staged.deletionRecordUpdate);
    batch.set(db.collection("audit_logs").doc(), staged.auditLog);
    permanentlyDeleted++;
  }
  if (permanentlyDeleted > 0) await batch.commit();
  return { status: "ok", permanentlyDeleted, skipped };
}

module.exports = {
  SOFT_DELETE_REASONS,
  departmentDocs,
  currentStudentIds,
  runCommitImportBatch,
  runSoftDelete,
  runRestore,
  runPermanentDelete,
};