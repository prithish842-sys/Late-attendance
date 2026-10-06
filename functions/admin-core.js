// Pure admin building blocks (Phase 4 — docs-new-updates/NEW_TASKS.md).
//
// CommonJS like escalation-core.js so the Blaze Cloud Function
// (functions/index.js, require), the Spark runner (scripts/process-admin.js,
// ESM import) and the Flutter client (lib/src/.../import_parser.dart mirrors the
// sheet rules EXACTLY) all agree on what a valid student import / lifecycle
// transition looks like.
//
// Everything here is stateless and testable (functions/test/admin-core.test.js).
// Destructive lifecycle writes stay server-authoritative (NEW_SECURITY.md §1):
// the client only enqueues *intent* (an admin_requests doc on Spark, or the
// commitImportBatch / adminSoftDelete / adminRestore / adminPermanentDelete
// HttpsCallables on Blaze). These functions stage the documents those paths
// persist; they never touch Firestore themselves.

const { normalizeToken, resolveDepartment } = require("./mail-core.js");

const ADMIN_ROLES = ["admin"];
const YEAR_MIN = 1990;
const YEAR_MAX = 2100;
const RETENTION_YEARS = 1;
const MAX_IMPORT_ROWS = 500;

/** Parse a sheet cell that should hold a year/current-year integer. */
function parseYearInt(value) {
  if (Number.isInteger(value)) return value;
  if (value === undefined || value === null || value === "") return null;
  const n = Number(String(value).trim());
  return Number.isFinite(n) && Number.isInteger(n) ? n : null;
}

/** Human display for a current-year integer (1 → "1st Year", …). */
function yearLabel(currentYear) {
  const y = Number.isInteger(currentYear) ? currentYear : null;
  if (y === 1) return "1st Year";
  if (y === 2) return "2nd Year";
  if (y === 3) return "3rd Year";
  if (y === 4) return "4th Year";
  return "Other";
}

/**
 * Validate the rows of an import sheet against the departments reference and
 * the current roster (NEW_ADMIN_WORKFLOW.md). Returns one result per input
 * row with a plain-language `errors`/`warnings` list; a row is `valid` only
 * when it has no errors. Rules:
 *   - register number required, no duplicates within the sheet;
 *   - register number must not already exist in `students`;
 *   - student name required;
 *   - department must resolve against the departments collection (token
 *     match, same rule as mail-core resolveDepartment) — unknown departments
 *     are an ERROR, not a silent "Unassigned";
 *   - currentYear, batchStartYear, batchEndYear must be integers; the batch
 *     years must span a sane 1990–2100 range with end ≥ start; a current
 *     year outside 1…(end−start+1) is only a warning;
 *   - an incoming register prefix (e.g. "24BCS001" → 2024) that disagrees
 *     with the declared batch start year is only a warning — register parsing
 *     is secondary to the declared batch years (NEW_DECISIONS.md #11).
 */
function validateImportRows(rows, { departmentDocs = [], existingStudentIds = [] } = {}) {
  const seen = new Set();
  const results = (rows || []).slice(0, MAX_IMPORT_ROWS).map((raw) => {
    const registerNumber = String(raw.registerNumber ?? "").trim().toUpperCase();
    const name = String(raw.name ?? "").trim();
    const department = String(raw.department ?? "").trim();
    const currentYear = parseYearInt(raw.currentYear);
    const batchStartYear = parseYearInt(raw.batchStartYear);
    const batchEndYear = parseYearInt(raw.batchEndYear);
    const photoUrl = String(raw.photoUrl ?? "").trim() || null;

    const errors = [];
    const warnings = [];

    if (!registerNumber) errors.push("Register number is required.");
    // C4 cap: mirrors the client-side limit (real register numbers are 8 chars).
    if (registerNumber.length > 24) errors.push("Register number must be 24 characters or fewer.");
    if (seen.has(registerNumber)) errors.push(`Duplicate register number in sheet (${registerNumber}).`);
    seen.add(registerNumber);
    if (!registerNumber) {
      // skip duplicate/existing checks for an empty register — already errored
    } else if (existingStudentIds.includes(registerNumber)) {
      errors.push(`Register number ${registerNumber} is already on file.`);
    }

    if (!name) errors.push("Student name is required.");

    const dept = department ? resolveDepartment(department, departmentDocs) : null;
    if (!department) {
      errors.push("Department is required.");
    } else if (!dept) {
      errors.push(`Department "${department}" is not on file — add it in Admin › Departments first.`);
    }

    if (currentYear == null) errors.push("Current year must be a whole number.");
    else if (currentYear < 1) errors.push("Current year must be a positive whole number.");

    if (batchStartYear == null) errors.push("Batch start year must be a whole number.");
    else if (batchStartYear < YEAR_MIN || batchStartYear > YEAR_MAX) errors.push(`Batch start year out of range (${YEAR_MIN}–${YEAR_MAX}).`);

    if (batchEndYear == null) errors.push("Batch end year must be a whole number.");
    else if (batchEndYear < YEAR_MIN || batchEndYear > YEAR_MAX) errors.push(`Batch end year out of range (${YEAR_MIN}–${YEAR_MAX}).`);
    else if (batchStartYear != null && batchEndYear < batchStartYear) errors.push("Batch end year cannot be before the start year.");

    if (currentYear != null && batchStartYear != null && batchEndYear != null && batchEndYear >= batchStartYear) {
      const span = batchEndYear - batchStartYear + 1;
      if (currentYear < 1 || currentYear > span) {
        warnings.push(`Current year ${currentYear} is outside the batch ${batchStartYear}–${batchEndYear} (expected 1–${span}).`);
      }
    }

    // Register prefix hint — secondary to the declared batch years (#11).
    const prefixMatch = /^(\d{2})/.exec(registerNumber);
    if (prefixMatch && batchStartYear != null) {
      const prefixYear = 2000 + Number(prefixMatch[1]);
      if (prefixYear !== batchStartYear) {
        warnings.push(`Register "${registerNumber}" starts with the ${prefixYear} intake but the batch start year is ${batchStartYear}.`);
      }
    }

    return {
      registerNumber,
      name,
      department,
      departmentId: dept ? dept.departmentId : null,
      departmentName: dept ? dept.name : null,
      hodEmail: dept ? dept.hodEmail || null : null,
      currentYear,
      batchStartYear,
      batchEndYear,
      photoUrl,
      errors,
      warnings,
      valid: errors.length === 0 && registerNumber !== "" && name !== "",
    };
  });

  const counts = {
    rows: results.length,
    valid: results.filter((r) => r.valid).length,
    invalid: results.filter((r) => !r.valid).length,
    warnings: results.reduce((n, r) => n + r.warnings.length, 0),
  };
  return { ok: results.length > 0 && counts.invalid === 0, rows: results, counts };
}

/** Active student whose declared batch end year has been reached (or passed). */
function passOutEligible(student, now = new Date()) {
  if (!student || student.active === false) return false;
  const end = parseYearInt(student.batchEndYear);
  if (end == null) return false;
  return end <= now.getUTCFullYear();
}

/** Students ready for the pass-out / archive review, oldest batch first. */
function passOutReviewStudents(students, now = new Date()) {
  return (students || [])
    .filter((s) => passOutEligible(s, now))
    .sort((a, b) => (a.batchEndYear ?? 0) - (b.batchEndYear ?? 0) || String(a.studentId).localeCompare(String(b.studentId)));
}

/** Pass-out review notification doc for `pass_out_reviews/{studentId}`. Written
 *  by the pass-out job (server-only) so the Admin/Pass-out screen review has a
 *  server-authoritative record, and updated to `soft_deleted`/`restored` by the
 *  lifecycle schedulers. Never auto-deletes the student (NEW_ADMIN_WORKFLOW.md:
 *  "it must not auto-delete students"). */
function passOutNotificationDoc({ student, at, status = "pending_review" }) {
  return {
    studentId: String(student.studentId ?? ""),
    registerNumber: String(student.studentId ?? ""),
    name: student.name ?? "",
    department: student.department ?? "",
    departmentId: student.departmentId ?? null,
    year: student.year ?? null,
    currentYear: student.currentYear ?? null,
    batchStartYear: student.batchStartYear ?? null,
    batchEndYear: student.batchEndYear ?? null,
    status,
    createdAt: at,
    updatedAt: at,
  };
}

/** `audit_logs` evidence row (NEW_ARCHITECTURE.md §2). */
function auditLogDoc({ actorId, action, targetType, targetId, at, metadata = {} }) {
  return {
    actorId,
    action,
    targetType,
    targetId,
    timestamp: at,
    ...(Object.keys(metadata).length ? { metadata } : {}),
  };
}

/**
 * Stage the two-stage soft delete (NEW_DECISIONS.md #12): the student goes
 * inactive/archived and a `deletion_records/{studentId}` evidence row is
 * written so the admin can restore it later (or confirm permanent deletion
 * after the retention window — NEW_DECISIONS.md #13). Historical late_logs and
 * escalation evidence are NEVER touched.
 */
function softDeleteDocs({ student, deletedBy, reason = "manual", at, retentionYears = RETENTION_YEARS }) {
  const studentId = String(student.studentId ?? student.id ?? "");
  const retentionUntil = new Date(at.getTime() + retentionYears * 365.25 * 24 * 60 * 60 * 1000);
  return {
    studentUpdate: {
      active: false,
      archivedAt: at,
      deletedAt: at,
      deletedBy,
      reason,
    },
    deletionRecord: {
      studentId,
      registerNumber: String(student.studentId ?? ""),
      name: student.name ?? "",
      department: student.department ?? "",
      departmentId: student.departmentId ?? null,
      year: student.year ?? null,
      batchStartYear: student.batchStartYear ?? null,
      batchEndYear: student.batchEndYear ?? null,
      deletedAt: at,
      deletedBy,
      reason,
      retentionUntil,
      originalStudentData: student,
      restored: false,
      permanentlyDeletedAt: null,
      permanentlyDeletedBy: null,
    },
    auditLog: auditLogDoc({
      actorId: deletedBy,
      action: "soft_delete",
      targetType: "student",
      targetId: studentId,
      at,
      metadata: { reason },
    }),
  };
}

/** Stage the restore (second half of the two-stage delete in reverse). */
function restoreDocs({ studentId, restoredBy, at }) {
  return {
    studentUpdate: { active: true, restoredAt: at },
    clearStudentFields: ["deletedAt", "archivedAt", "deletedBy", "reason"],
    auditLog: auditLogDoc({
      actorId: restoredBy,
      action: "restore",
      targetType: "student",
      targetId: studentId,
      at,
    }),
  };
}

/**
 * Stage final permanent deletion. Photos are stored inline (photoBase64) in
 * the student doc, so removing the doc IS the photo storage cleanup — there is
 * no separate object to purge while the base64 fallback is active (STORAGE §7).
 * The deletion_records row is kept (never deleted) as the audit/retention
 * evidence required by NEW_DECISIONS.md #13.
 */
function permanentDeleteDocs({ studentId, requestedBy, at }) {
  return {
    deletionRecordUpdate: {
      permanentlyDeletedAt: at,
      permanentlyDeletedBy: requestedBy,
    },
    auditLog: auditLogDoc({
      actorId: requestedBy,
      action: "permanent_delete",
      targetType: "student",
      targetId: studentId,
      at,
      metadata: { requestedBy },
    }),
  };
}

/**
 * Document body for a freshly imported student (NEW_ARCHITECTURE.md §students).
 * `studentId` equals the register number (doc id) — scans resolve by it.
 */
function studentSeedDoc({ registerNumber, name, departmentId, departmentName, currentYear, batchStartYear, batchEndYear, photoUrl, createdBy, at }) {
  return {
    studentId: registerNumber,
    registerNumber,
    name,
    departmentId: departmentId ?? null,
    department: departmentName || "Unassigned",
    departmentName: departmentName ?? null,
    year: yearLabel(currentYear),
    currentYear: currentYear ?? null,
    batchStartYear: batchStartYear ?? null,
    batchEndYear: batchEndYear ?? null,
    photoUrl: photoUrl || null,
    active: true,
    archivedAt: null,
    deletedAt: null,
    createdAt: at,
    updatedAt: at,
    createdBy,
  };
}

/** `import_batches/{importId}` metadata row (NEW_ARCHITECTURE.md §2). */
function importBatchDoc({ importId, filename, departmentId, department, batchStartYear, batchEndYear, counts, createdBy, at }) {
  return {
    importId,
    filename: filename ?? null,
    departmentId: departmentId ?? null,
    department: department ?? null,
    batchStartYear,
    batchEndYear,
    counts: { ...counts, committed: counts.valid },
    status: "committed",
    createdBy,
    createdAt: at,
  };
}

module.exports = {
  ADMIN_ROLES,
  YEAR_MIN,
  YEAR_MAX,
  RETENTION_YEARS,
  MAX_IMPORT_ROWS,
  parseYearInt,
  yearLabel,
  validateImportRows,
  passOutEligible,
  passOutReviewStudents,
  passOutNotificationDoc,
  auditLogDoc,
  softDeleteDocs,
  restoreDocs,
  permanentDeleteDocs,
  studentSeedDoc,
  importBatchDoc,
  normalizeToken,
};