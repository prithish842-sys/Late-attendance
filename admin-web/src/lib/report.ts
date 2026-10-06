/**
 * Client-side mirror of the report window / aggregation / fuzzy-match rules
 * the server uses (functions/report-core.js + report-generator.js, and the
 * Flutter app_models.dart). Dependency-free so it can be unit-tested in Vitest.
 * The server stays authoritative: the web app only previews, then enqueues a
 * report_requests intent (Spark) or calls generateReport (Blaze).
 */

export interface Department {
  id: string;
  name: string;
  hodEmail?: string | null;
}

export interface ReportRowLike {
  studentId: string;
  name: string;
  department: string;
  year?: string | null;
}

/** Inclusive local-day range a report covers. */
export interface DayWindow {
  start: Date;
  end: Date;
}

export type ReportPeriodType = "daily" | "weekly" | "monthly" | "custom";

export interface ReportFilters {
  periodType: ReportPeriodType;
  startDate: Date;
  endDate: Date;
  department: Department | null;
  year: string | null;
}

const MONTHS = [
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December",
];

function dayLabel(d: Date): string {
  return `${d.getDate()} ${MONTHS[d.getMonth()]} ${d.getFullYear()}`;
}

/**
 * Client-side mirror of report-core's window rules, for preview + intent only.
 * Weekly weeks start on Monday; monthly is the calendar month; custom clamps an
 * inverted range.
 */
export function reportWindowFor(
  periodType: ReportPeriodType,
  anchor: Date,
  customStart?: Date,
  customEnd?: Date,
): DayWindow {
  const a = anchor;
  switch (periodType) {
    case "daily":
      return { start: a, end: a };
    case "weekly": {
      const monday = new Date(a.getFullYear(), a.getMonth(), a.getDate() - ((a.getDay() + 6) % 7));
      const sunday = new Date(monday.getFullYear(), monday.getMonth(), monday.getDate() + 6);
      return { start: monday, end: sunday };
    }
    case "monthly": {
      const first = new Date(a.getFullYear(), a.getMonth(), 1);
      const last = new Date(a.getFullYear(), a.getMonth() + 1, 0);
      return { start: first, end: last };
    }
    case "custom": {
      const s = customStart ?? a;
      const e = customEnd ?? s;
      if (s.getTime() <= e.getTime()) return { start: s, end: e };
      return { start: e, end: s };
    }
  }
}

/** Human label for a report window, matching the app + report file naming. */
export function windowLabel(w: DayWindow, periodType: ReportPeriodType): string {
  switch (periodType) {
    case "daily":
      return dayLabel(w.start);
    case "weekly":
      return `${dayLabel(w.start)} - ${dayLabel(w.end)}`;
    case "monthly":
      return `${MONTHS[w.start.getMonth()]} ${w.start.getFullYear()}`;
    case "custom":
      return `${dayLabel(w.start)} - ${dayLabel(w.end)}`;
  }
}

/** "YYYY-MM-DD" key for a local day (payload / doc convention). */
export function dayKey(d: Date): string {
  const mm = String(d.getMonth() + 1).padStart(2, "0");
  const dd = String(d.getDate()).padStart(2, "0");
  return `${d.getFullYear()}-${mm}-${dd}`;
}

/** HH:MM in local time (display helper for scan rows). */
export function formatTime(d: Date): string {
  const hh = String(d.getHours()).padStart(2, "0");
  const mi = String(d.getMinutes()).padStart(2, "0");
  return `${hh}:${mi}`;
}

/**
 * Server-authoritative windows are UTC-day bounds (report-core.js parses dates
 * as UTC). The preview must query the exact same range so it matches the
 * downloaded file: local-day start -> +1 day, expressed in UTC.
 */
export function utcRangeForWindow(w: DayWindow): { start: Date; end: Date } {
  const start = new Date(Date.UTC(w.start.getFullYear(), w.start.getMonth(), w.start.getDate()));
  const end = new Date(Date.UTC(w.end.getFullYear(), w.end.getMonth(), w.end.getDate()) + 86_400_000);
  return { start, end };
}

/** The dashboard's "today" - a browser-local day window. */
export function todayLocalRange(): { start: Date; end: Date } {
  const now = new Date();
  const start = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  return { start, end: new Date(start.getTime() + 86_400_000) };
}

/** Same alphanumeric normalization the server uses (mail-core normalizeToken). */
export function displayToken(s: string): string {
  return s.toLowerCase().replace(/[^a-z0-9]/g, "");
}

/**
 * Resolve a student's department display string ("B.SC CS") to a canonical
 * departments reference doc ("BSC-CS"). Same fuzzy rule as the server
 * (mail-core resolveDepartment / report-generator matchesDepartment). Returns
 * null when nothing matches or the display is ambiguous.
 */
export function findDepartment(departments: Department[], display: string): Department | null {
  const needle = displayToken(display);
  let match: Department | null = null;
  for (const d of departments) {
    if (displayToken(d.id) === needle || displayToken(d.name) === needle) {
      if (match !== null) return null;
      match = d;
    }
  }
  return match;
}

/**
 * Filter rows by department + year using the server's exact rules
 * (report-generator.js matchesDepartment + year token). Keeps the web preview
 * identical to the generated file.
 */
export function filterRows<T extends ReportRowLike>(
  rows: T[],
  dept: Department | null,
  year: string | null,
  departments: Department[],
): T[] {
  const yearToken = year ? displayToken(year) : null;
  return rows.filter((r) => {
    if (dept) {
      const stok = displayToken(r.department);
      if (stok === "") return false;
      if (stok !== displayToken(dept.id) && stok !== displayToken(dept.name)) {
        const resolved = findDepartment(departments, r.department);
        if (resolved === null || resolved.id !== dept.id) return false;
      }
    }
    if (yearToken !== null && displayToken(r.year ?? "") !== yearToken) return false;
    return true;
  });
}

export interface DepartmentLateTotal {
  department: string;
  count: number;
}

export interface ReportSummary {
  totalLateEntries: number;
  distinctStudents: number;
  byDepartment: DepartmentLateTotal[];
}

/** Same aggregation rule as functions/report-core.js runReportStats. */
export function summarizeReport(rows: { studentId: string; department: string }[]): ReportSummary {
  const byDepartment = new Map<string, number>();
  const students = new Set<string>();
  for (const r of rows) {
    students.add(r.studentId);
    const dep = r.department === "" ? "Unassigned" : r.department;
    byDepartment.set(dep, (byDepartment.get(dep) ?? 0) + 1);
  }
  const totals = [...byDepartment.entries()]
    .map(([department, count]) => ({ department, count }))
    .sort((a, b) => b.count - a.count || a.department.toLowerCase().localeCompare(b.department.toLowerCase()));
  return {
    totalLateEntries: rows.length,
    distinctStudents: students.size,
    byDepartment: totals,
  };
}

export type LateCountLevel = "ok" | "warn" | "escalate";

/**
 * Same severity mapping as functions/escalation-core.js computeEscalation:
 * count >= threshold -> escalate; count >= 2 -> warning; otherwise ok.
 * Color is always paired with explicit count text (DESIGN.md §6).
 */
export function lateCountLevel(count: number, threshold: number): LateCountLevel {
  if (count >= threshold) return "escalate";
  if (count >= 2) return "warn";
  return "ok";
}

/** Ordinal label for an escalation badge ("2nd time this month"). */
export function countLabel(count: number): string {
  if (count <= 0) return "No lates this month";
  const ord = ["", "1st", "2nd", "3rd", "4th", "5th", "6th", "7th", "8th", "9th", "10th"];
  const word = count < ord.length ? ord[count] : `${count}th`;
  return `${word} time this month`;
}