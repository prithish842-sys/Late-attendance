// Pure escalation decision logic — CommonJS so functions/index.js (require) and
// the Cloud both load it without ESM type juggling. Reflects DECISIONS.md #1
// (monthly reset, 1st of the month) and #2 (threshold configurable).

/** "YYYY-MM" period key for a date (monthly reset, DECISIONS.md #1). */
function periodKey(date, resetPeriod = "monthly") {
  if (resetPeriod === "semester") return semesterKey(date);
  const mm = String(date.getMonth() + 1).padStart(2, "0");
  return `${date.getFullYear()}-${mm}`;
}

/** Start of the reset period containing `date`, as a Date. */
function periodStart(date, resetPeriod = "monthly") {
  if (resetPeriod === "semester") {
    const [year, half] = semesterKey(date).split("-");
    return new Date(Date.UTC(Number(year), half === "S2" ? 6 : 0, 1));
  }
  return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), 1));
}

/** Start of the period AFTER the one containing `date` (exclusive upper bound). */
function periodEnd(date, resetPeriod = "monthly") {
  if (resetPeriod === "semester") {
    const [year, half] = semesterKey(date).split("-");
    const nextYear = Number(year) + (half === "S2" ? 1 : 0);
    return new Date(Date.UTC(nextYear, half === "S2" ? 0 : 6, 1));
  }
  const start = periodStart(date, resetPeriod);
  return new Date(Date.UTC(start.getUTCFullYear(), start.getUTCMonth() + 1, 1));
}

/** Jan–Jun => `{year}-S1`, Jul–Dec => `{year}-S2`. */
function semesterKey(date) {
  return `${date.getUTCFullYear()}-${date.getUTCMonth() < 6 ? "S1" : "S2"}`;
}

/**
 * The server-side escalation verdict:
 *   count <  2         -> tracking (log only)
 *   count == 2         -> warning flag
 *   count >= threshold -> escalated (escalation_queue entry)
 * Non-positive thresholds fall back to the documented default of 3
 * (DECISIONS.md #2).
 */
function computeEscalation(count, threshold) {
  const t = Number.isInteger(threshold) && threshold > 0 ? threshold : 3;
  if (count >= t) return { status: "escalated", warning: false, escalated: true };
  if (count >= 2) return { status: "warning", warning: true, escalated: false };
  return { status: "tracking", warning: false, escalated: false };
}

/**
 * Fields for the escalation_queue doc `{studentId}_{period}`. `student` is a
 * students/ doc snapshot {studentId, name, department, year, ...}.
 */
function escalationDoc(student, count, threshold, period) {
  const verdict = computeEscalation(count, threshold);
  return {
    studentId: student.studentId,
    name: student.name,
    department: student.department,
    year: student.year ?? null,
    period,
    count,
    threshold,
    warning: verdict.warning,
    escalated: verdict.escalated,
    status: verdict.status,
  };
}

/**
 * The monthly-lived counter status shown on the dashboard's active-counter
 * model (NEW_ARCHITECTURE.md §monthly_student_status). Same bucketing as
 * computeEscalation but with the 1-count name the monthly view uses:
 *   count == 1      -> logged    (1st late this calendar month — log only)
 *   count == 2      -> warning   (2nd late — warning flag)
 *   count >= 3      -> escalated (threshold reached — escalated)
 * Non-positive thresholds fall back to the documented default of 3.
 * NOTE: month boundaries make "warning" short-lived in practice, but the pure
 * mapping matches computeEscalation so both evergreen counters never disagree.
 */
function monthlyStatus(count, threshold) {
  const t = Number.isInteger(threshold) && threshold > 0 ? threshold : 3;
  if (count >= t) return "escalated";
  if (count >= 2) return "warning";
  return "logged";
}

/**
 * Fields for the monthly_student_status doc `{studentId}_{monthKey}` — the
 * per-student, per-calendar-month counter row (NEW_ARCHITECTURE.md §2.6).
 * `student` is a students/ doc snapshot {studentId, name, department, year, ...}.
 */
function monthlyStatusDoc(student, count, threshold, monthKey) {
  return {
    studentId: student.studentId,
    name: student.name,
    department: student.department,
    year: student.year ?? null,
    monthKey,
    lateCount: count,
    status: monthlyStatus(count, threshold),
  };
}

module.exports = {
  periodKey,
  periodStart,
  periodEnd,
  semesterKey,
  computeEscalation,
  escalationDoc,
  monthlyStatus,
  monthlyStatusDoc,
};