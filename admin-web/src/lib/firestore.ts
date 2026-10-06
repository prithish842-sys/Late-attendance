/**
 * Firestore read/write surface for the admin web app. Every query here respects
 * the deployed firestore.rules (staff read-only across the board) and stays
 * within the single-field query shapes in firestore.indexes.json - no new
 * composite indexes are required.
 */
import {
  collection,
  doc,
  getDoc,
  getDocs,
  onSnapshot,
  orderBy,
  query,
  where,
  limit,
  updateDoc,
} from "firebase/firestore";
import { db } from "../fb";
import { dayKey, formatTime, type Department } from "./report";

export interface SettingsDoc {
  escalationThreshold: number;
  resetPeriod: string;
  lateCutoffTime: string | null;
}

export const DEFAULT_SETTINGS: SettingsDoc = {
  escalationThreshold: 3,
  resetPeriod: "monthly",
  lateCutoffTime: null,
};

export interface RosterStudent {
  name: string;
  department: string;
  year: string | null;
}

export interface StaffMember {
  name: string;
  role: string;
}

export interface ScanRow {
  logId: string;
  studentId: string;
  name: string;
  department: string;
  year: string | null;
  scannedBy: string;
  scannedByName: string;
  scanTimestamp: Date;
  scanMethod: string;
  syncedOffline: boolean;
  date: string;
  time: string;
}

export interface MailLogRow {
  id: string;
  department: string;
  period: string;
  to: string;
  subject: string;
  studentsIncluded: string[];
  triggeredBy: string;
  sentTimestamp: Date | null;
}

export interface ReportRequestRow {
  id: string;
  periodType: string;
  startDate: string;
  endDate: string;
  department: string | null;
  year: string | null;
  requestedBy: string;
  status: string;
  attemptCount: number;
  requestedAt: Date | null;
}

export interface ReportLogRow {
  id: string;
  reportId: string;
  requestedBy: string | null;
  label: string;
  department: string | null;
  year: string | null;
  totalLateEntries: number;
  distinctStudents: number;
  files: { name: string; sizeBytes: number }[];
  generatedAt: Date | null;
}

function toDate(v: unknown): Date {
  if (v instanceof Date) return v;
  if (v && typeof v === "object" && "toDate" in v && typeof (v as { toDate?: unknown }).toDate === "function") {
    try {
      return (v as { toDate: () => Date }).toDate();
    } catch {
      /* fall through to default */
    }
  }
  return new Date();
}

function str(v: unknown, fallback = ""): string {
  return typeof v === "string" ? v : fallback;
}

function numOrNull(v: unknown): number | null {
  return typeof v === "number" ? v : typeof v === "string" && v !== "" ? Number(v) || null : null;
}

// ---------------------------------------------------------------------------
// Settings (read by staff, written by admin - rules enforce both).
// ---------------------------------------------------------------------------

export async function loadSettings(): Promise<SettingsDoc> {
  try {
    const snap = await getDoc(doc(db, "settings", "default"));
    if (snap.exists()) {
      const d = snap.data();
      return {
        escalationThreshold: numOrNull(d.escalationThreshold) ?? DEFAULT_SETTINGS.escalationThreshold,
        resetPeriod: str(d.resetPeriod, DEFAULT_SETTINGS.resetPeriod),
        lateCutoffTime: d.lateCutoffTime == null ? null : str(d.lateCutoffTime, ""),
      };
    }
  } catch {
    // Fall back to defaults if the read fails.
  }
  return { ...DEFAULT_SETTINGS };
}

export async function saveSettings(update: Partial<SettingsDoc>): Promise<void> {
  await updateDoc(doc(db, "settings", "default"), update);
}

// ---------------------------------------------------------------------------
// Departments
// ---------------------------------------------------------------------------

// Tiny, nearly static reference data loaded on entry by BOTH Settings and
// Reports (B6). TTL-bounded promise memo: concurrent readers share one fetch,
// failures are never cached, and saveDepartmentHodEmail invalidates so an
// edit is visible on the very next read.
let departmentsPromise: Promise<Department[]> | null = null;
let departmentsFetchedAt = 0;
const DEPARTMENTS_TTL_MS = 5 * 60 * 1000;

async function fetchDepartments(): Promise<Department[]> {
  const snap = await getDocs(collection(db, "departments"));
  const list = snap.docs.map((d) => ({
    id: d.id,
    name: str(d.data().name, d.id),
    hodEmail: d.data().hodEmail == null ? null : str(d.data().hodEmail, ""),
  }));
  list.sort((a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase()));
  return list;
}

export async function loadDepartments(): Promise<Department[]> {
  const now = Date.now();
  if (departmentsPromise && now - departmentsFetchedAt < DEPARTMENTS_TTL_MS) {
    return departmentsPromise;
  }
  const attempt = fetchDepartments();
  departmentsPromise = attempt;
  departmentsFetchedAt = now;
  try {
    return await attempt;
  } catch (err) {
    if (departmentsPromise === attempt) {
      departmentsPromise = null;
      departmentsFetchedAt = 0;
    }
    throw err;
  }
}

export function invalidateDepartments(): void {
  departmentsPromise = null;
  departmentsFetchedAt = 0;
}

export async function saveDepartmentHodEmail(id: string, hodEmail: string): Promise<void> {
  await updateDoc(doc(db, "departments", id), { hodEmail });
  invalidateDepartments();
}

// ---------------------------------------------------------------------------
// Roster / staff name maps (joined into scan rows)
// ---------------------------------------------------------------------------

let rosterPromise: Promise<Map<string, RosterStudent>> | null = null;
let staffPromise: Promise<Map<string, StaffMember>> | null = null;

async function fetchRoster(): Promise<Map<string, RosterStudent>> {
  // B8 note: projecting out photo payloads would shrink this join read, but
  // firebase 12's modular API no longer exports select() — follow-up is the
  // planned photo → Storage migration (docs/ARCHITECTURE.md §Storage).
  const snap = await getDocs(collection(db, "students"));
  const map = new Map<string, RosterStudent>();
  for (const d of snap.docs) {
    map.set(d.id, {
      name: str(d.data().name, d.id),
      department: str(d.data().department, ""),
      year: d.data().year == null ? null : str(d.data().year, ""),
    });
  }
  return map;
}

async function fetchStaff(): Promise<Map<string, StaffMember>> {
  const snap = await getDocs(collection(db, "staff"));
  const map = new Map<string, StaffMember>();
  for (const d of snap.docs) {
    map.set(d.id, { name: str(d.data().name, d.id), role: str(d.data().role, "") });
  }
  return map;
}

export function loadRoster(): Promise<Map<string, RosterStudent>> {
  rosterPromise ??= fetchRoster();
  return rosterPromise;
}

export function loadStaff(): Promise<Map<string, StaffMember>> {
  staffPromise ??= fetchStaff();
  return staffPromise;
}

// ---------------------------------------------------------------------------
// late_logs - scan rows joined with roster + staff ("who scanned what, when")
// ---------------------------------------------------------------------------

function buildScanRow(
  logId: string,
  data: Record<string, unknown>,
  roster: Map<string, RosterStudent>,
  staff: Map<string, StaffMember>,
): ScanRow {
  const studentId = str(data.studentId, logId.split("_")[0] ?? "");
  const student = roster.get(studentId);
  const scannedBy = str(data.scannedBy, "");
  const scanned = staff.get(scannedBy);
  const ts = toDate(data.scanTimestamp);
  return {
    logId,
    studentId,
    name: student?.name ?? studentId,
    department: student?.department ?? "",
    year: student?.year ?? null,
    scannedBy,
    scannedByName: scanned?.name || (scannedBy === "" ? "\u2014" : scannedBy),
    scanTimestamp: ts,
    scanMethod: str(data.scanMethod, "scan"),
    syncedOffline: data.syncedOffline === true,
    date: dayKey(ts),
    time: formatTime(ts),
  };
}

async function rowsForLogs(
  docs: { id: string; data: () => Record<string, unknown> }[],
): Promise<ScanRow[]> {
  const [roster, staff] = await Promise.all([loadRoster(), loadStaff()]);
  const rows = docs.map((d) => buildScanRow(d.id, d.data(), roster, staff));
  rows.sort((a, b) => b.scanTimestamp.getTime() - a.scanTimestamp.getTime());
  return rows;
}

/** One-shot read of late_logs in a scanTimestamp range (single-field range). */
export async function loadScansBetween(start: Date, end: Date): Promise<ScanRow[]> {
  const q = query(collection(db, "late_logs"), where("scanTimestamp", ">=", start), where("scanTimestamp", "<", end));
  const snap = await getDocs(q);
  return rowsForLogs(snap.docs);
}

/** Live subscription for the dashboard's today view. Returns an unsubscribe fn. */
export function watchScansBetween(
  start: Date,
  end: Date,
  onRows: (rows: ScanRow[]) => void,
  onError: (e: unknown) => void,
): () => void {
  const q = query(collection(db, "late_logs"), where("scanTimestamp", ">=", start), where("scanTimestamp", "<", end));
  return onSnapshot(q, {
    next: (snap) => {
      rowsForLogs(snap.docs).then(onRows, onError);
    },
    error: onError,
  });
}

// ---------------------------------------------------------------------------
// Audit pages - mail_logs (server-only writes), report_requests + report_logs
// ---------------------------------------------------------------------------

function dataOf(d: { data(): Record<string, unknown> }): Record<string, unknown> {
  return d.data();
}

const strList = (v: unknown): string[] =>
  Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : [];

export async function loadMailLogs(max = 50): Promise<MailLogRow[]> {
  const q = query(collection(db, "mail_logs"), orderBy("sentTimestamp", "desc"), limit(max));
  const snap = await getDocs(q);
  return snap.docs.map((d) => {
    const data = dataOf(d);
    return {
      id: d.id,
      department: str(data.department, ""),
      period: str(data.period, ""),
      to: str(data.to, ""),
      subject: str(data.subject, ""),
      studentsIncluded: strList(data.studentsIncluded),
      triggeredBy: str(data.triggeredBy, ""),
      sentTimestamp: data.sentTimestamp == null ? null : toDate(data.sentTimestamp),
    };
  });
}

export async function loadReportRequests(max = 50): Promise<ReportRequestRow[]> {
  const q = query(collection(db, "report_requests"), orderBy("requestedAt", "desc"), limit(max));
  const snap = await getDocs(q);
  return snap.docs.map((d) => {
    const data = dataOf(d);
    return {
      id: d.id,
      periodType: str(data.periodType, ""),
      startDate: str(data.startDate, ""),
      endDate: str(data.endDate, ""),
      department: data.department == null ? null : str(data.department, ""),
      year: data.year == null ? null : str(data.year, ""),
      requestedBy: str(data.requestedBy, ""),
      status: str(data.status, "pending"),
      attemptCount: numOrNull(data.attemptCount) ?? 0,
      requestedAt: data.requestedAt == null ? null : toDate(data.requestedAt),
    };
  });
}

export async function fetchReportLogs(max = 50): Promise<ReportLogRow[]> {
  const q = query(collection(db, "report_logs"), orderBy("generatedAt", "desc"), limit(max));
  const snap = await getDocs(q);
  return snap.docs.map((d) => {
    const data = dataOf(d);
    const stats = (data.stats ?? {}) as Record<string, unknown>;
    return {
      id: d.id,
      reportId: str(data.reportId, d.id),
      requestedBy: data.requestedBy == null ? null : str(data.requestedBy, ""),
      label: str(data.label, ""),
      department: data.department == null ? null : str(data.department, ""),
      year: data.year == null ? null : str(data.year, ""),
      totalLateEntries: numOrNull(stats.totalLateEntries) ?? 0,
      distinctStudents: numOrNull(stats.distinctStudents) ?? 0,
      files: (Array.isArray(data.files) ? (data.files as unknown[]) : []).map(
        (f): { name: string; sizeBytes: number } => {
          const m = (f ?? {}) as Record<string, unknown>;
          return { name: str(m.name, ""), sizeBytes: numOrNull(m.sizeBytes) ?? 0 };
        },
      ),
      generatedAt: data.generatedAt == null ? null : toDate(data.generatedAt),
    };
  });
}