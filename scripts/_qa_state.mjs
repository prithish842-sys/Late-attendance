// scripts/_qa_state.mjs — QA ground-truth snapshot (Phase 8).
//
// Prints the Firestore truth that the UI claims to render, so live screens can
// be checked against it (escalation tiles, weekly audit grouping, dashboard
// today list, report counters, mail queue state).
//
//   node scripts/_qa_state.mjs            # human-readable summary
//   node scripts/_qa_state.mjs --json     # machine-readable JSON
//
// Requires scripts/service-account/key.json (Admin SDK). Read-only.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { config as loadEnv } from "dotenv";
import { initializeApp, cert } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
loadEnv({ path: path.join(ROOT, ".env") });

const KEY = path.join(ROOT, "scripts", "service-account", "key.json");
if (!fs.existsSync(KEY)) throw new Error(`Service account key missing: ${KEY}`);

const app = initializeApp({
  credential: cert(KEY),
  projectId: process.env.FIREBASE_PROJECT_ID || "late-attendance-5bf6d",
});
const db = getFirestore(app, "default");
db.settings({ ignoreUndefinedProperties: true });

const pad = (s, n) => String(s).padEnd(n);
const padL = (s, n) => String(s).padStart(n);

function localDate(d = new Date()) {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

function mondayOf(d = new Date()) {
  const x = new Date(d.getFullYear(), d.getMonth(), d.getDate());
  const shift = (x.getDay() + 6) % 7; // Mon=0
  x.setDate(x.getDate() - shift);
  return x;
}

function tsMs(v) {
  if (!v) return NaN;
  if (typeof v.toMillis === "function") return v.toMillis();
  if (v instanceof Date) return v.getTime();
  const n = new Date(v).getTime();
  return Number.isNaN(n) ? NaN : n;
}

async function main() {
  const asJson = process.argv.includes("--json");
  const out = {};

  const [settingsSnap, studentsSnap, logsSnap, escSnap, queueSnap, mailLogsSnap] =
    await Promise.all([
      db.collection("settings").doc("default").get(),
      db.collection("students").get(),
      db.collection("late_logs").get(),
      db.collection("escalation_queue").get(),
      db.collection("mail_queue").get(),
      db.collection("mail_logs").get(),
    ]);

  const settings = settingsSnap.exists ? settingsSnap.data() : {};
  const threshold =
    Number(settings.escalationThreshold ?? 3) > 0 ? Number(settings.escalationThreshold) : 3;
  out.settings = {
    escalationThreshold: threshold,
    resetPeriod: settings.resetPeriod ?? "monthly",
    // repeatThreshold defaults to 2 everywhere (settings has no field; the app
    // WeeklyAuditScreen/weeklyAuditOverview and functions/weekly-audit-core.js
    // all fall back to 2 — "late more than once in the same week").
    repeatThreshold: Number(settings.repeatThreshold ?? 2) > 0 ? Number(settings.repeatThreshold ?? 2) : 2,
  };

  // ---- students ----
  const students = studentsSnap.docs.map((d) => ({ id: d.id, ...d.data() }));
  const active = students.filter((s) => s.active !== false);
  out.students = {
    total: students.length,
    active: active.length,
    archived: students.length - active.length,
    byDepartment: Object.fromEntries(
      [...new Set(active.map((s) => s.departmentId ?? s.department ?? "?"))]
        .sort()
        .map((dep) => [dep, active.filter((s) => (s.departmentId ?? s.department ?? "?") === dep).length]),
    ),
    byYear: Object.fromEntries(
      [...new Set(active.map((s) => s.year ?? "?"))]
        .sort()
        .map((y) => [y, active.filter((s) => (s.year ?? "?") === y).length]),
    ),
  };

  // ---- late_logs ----
  // Docs are minimal: {studentId, scanMethod, scannedBy, syncedOffline,
  // deviceTimestamp, scanTimestamp}. The calendar date is the doc-id suffix
  // `{studentId}_{YYYY-MM-DD}`; department/name come from the students join.
  const logs = logsSnap.docs.map((d) => {
    const x = d.data();
    const idDate = d.id.includes("_") ? d.id.split("_").pop() : "";
    return { id: d.id, ...x, _date: idDate, _ts: tsMs(x.scanTimestamp) };
  });
  const month = localDate().slice(0, 7);
  const today = localDate();
  const inMonth = logs.filter((l) => l._date.startsWith(month));
  const todayLogs = logs.filter((l) => l._date === today);
  const perStudentMonth = {};
  for (const l of inMonth) {
    const k = l.studentId ?? "?";
    perStudentMonth[k] = (perStudentMonth[k] ?? 0) + 1;
  }
  const studentsById = Object.fromEntries(students.map((s) => [s.id, s]));
  out.lateLogs = {
    total: logs.length,
    thisMonth: month,
    thisMonthCount: inMonth.length,
    today,
    todayCount: todayLogs.length,
    todayList: todayLogs
      .map((l) => ({
        studentId: l.studentId,
        name: studentsById[l.studentId]?.name ?? "?",
        departmentId: studentsById[l.studentId]?.department ?? studentsById[l.studentId]?.departmentId ?? "?",
        year: studentsById[l.studentId]?.year ?? "?",
        time: Number.isFinite(l._ts) ? new Date(l._ts).toTimeString().slice(0, 5) : "?",
        scanMethod: l.scanMethod,
        syncedOffline: l.syncedOffline ?? false,
      }))
      .sort((a, b) => String(a.time).localeCompare(String(b.time))),
    perStudentMonth: Object.fromEntries(
      Object.entries(perStudentMonth).sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])),
    ),
    escalatedThisMonth: Object.entries(perStudentMonth)
      .filter(([, c]) => c >= threshold)
      .map(([id, c]) => ({ studentId: id, count: c, departmentId: studentsById[id]?.department ?? studentsById[id]?.departmentId ?? "?" }))
      .sort((a, b) => b.count - a.count),
  };

  // ---- escalation_queue: what the Escalations screen must render ----
  const esc = escSnap.docs.map((d) => ({ id: d.id, ...d.data() }));
  const period = month; // monthly reset period = YYYY-MM
  const escThis = esc.filter((e) => e.status === "escalated" && e.period === period);
  const tiles = {};
  for (const e of escThis) {
    const dept = e.department || "Unassigned";
    (tiles[dept] ??= []).push({ studentId: e.studentId, name: e.name ?? studentsById[e.studentId]?.name ?? "?", count: e.count });
  }
  out.escalationQueue = {
    period,
    totalDocs: esc.length,
    byStatus: Object.fromEntries(
      [...new Set(esc.map((e) => e.status ?? "?"))].map((s) => [s, esc.filter((e) => (e.status ?? "?") === s).length]),
    ),
    escalatedInPeriod: escThis.length,
    expectedTiles: Object.fromEntries(
      Object.entries(tiles)
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([dept, list]) => [
          dept,
          { count: list.length, students: list.sort((a, b) => b.count - a.count) },
        ]),
    ),
  };

  // ---- weekly audit window (current week, Mon..Sun) ----
  const wkStart = mondayOf();
  const wkEnd = new Date(wkStart.getFullYear(), wkStart.getMonth(), wkStart.getDate() + 7);
  const inWeek = logs.filter((l) => {
    const t = l._ts;
    return Number.isFinite(t) && t >= wkStart.getTime() && t < wkEnd.getTime();
  });
  const repeatThreshold = out.settings.repeatThreshold;
  const weekByDept = {};
  const weekPerStudent = {};
  for (const l of inWeek) {
    const dept = studentsById[l.studentId]?.department ?? studentsById[l.studentId]?.departmentId ?? "?";
    (weekByDept[dept] ??= new Set()).add(l.studentId);
    const k = l.studentId ?? "?";
    (weekPerStudent[k] ??= { count: 0, departmentId: dept });
    weekPerStudent[k].count += 1;
  }
  out.weeklyAudit = {
    weekStart: localDate(wkStart),
    weekEnd: localDate(new Date(wkEnd.getTime() - 1)),
    rowsInWeek: inWeek.length,
    departments: Object.fromEntries(
      Object.entries(weekByDept)
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([dept, set]) => [dept, { distinctStudents: set.size }]),
    ),
    repeatedStudents: Object.entries(weekPerStudent)
      .filter(([, v]) => v.count >= repeatThreshold)
      .map(([id, v]) => ({ studentId: id, name: studentsById[id]?.name ?? "?", count: v.count, departmentId: v.departmentId }))
      .sort((a, b) => b.count - a.count),
    repeatThreshold,
  };

  // ---- mail queue + logs (HOD trigger check) ----
  const mailQueue = queueSnap.docs.map((d) => ({ id: d.id, ...d.data() }));
  out.mailQueue = {
    total: mailQueue.length,
    byStatus: Object.fromEntries(
      [...new Set(mailQueue.map((m) => m.status ?? "?"))].map((s) => [s, mailQueue.filter((m) => (m.status ?? "?") === s).length]),
    ),
    recent: mailQueue
      .map((m) => ({
        id: m.id,
        type: m.type ?? m.mailType ?? m.kind ?? m.requestType ?? null,
        departmentId: m.departmentId,
        recipient: m.recipient,
        status: m.status,
        createdAt: m.createdAt?.toDate?.()?.toISOString?.() ?? (m.createdAt instanceof Date ? m.createdAt.toISOString() : null),
        error: m.error ? String(m.error).slice(0, 120) : null,
        duplicateOf: m.duplicateOf ?? null,
      }))
      .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)))
      .slice(0, 5),
  };
  out.mailLogs = { total: mailLogsSnap.size };

  // ---- every root collection's doc count (clean-slate / wipe verification) ----
  const rootCollections = await db.listCollections();
  out.collectionCounts = {};
  for (const col of rootCollections) {
    const c = await col.count().get();
    out.collectionCounts[col.id] = c.data().count;
  }

  if (asJson) {
    process.stdout.write(JSON.stringify(out, null, 2) + "\n");
    return;
  }

  console.log("== QA GROUND TRUTH ==");
  console.log(`settings: escalationThreshold=${threshold} resetPeriod=${out.settings.resetPeriod} repeatThreshold=${repeatThreshold}`);
  console.log(`students: total=${out.students.total} active=${out.students.active} archived=${out.students.archived}`);
  console.log(`  byDepartment: ${JSON.stringify(out.students.byDepartment)}`);
  console.log(`  byYear: ${JSON.stringify(out.students.byYear)}`);
  console.log(`late_logs: total=${out.lateLogs.total} ${month}=${out.lateLogs.thisMonthCount} today(${today})=${out.lateLogs.todayCount}`);
  for (const t of out.lateLogs.todayList) {
    console.log(`  today: ${t.studentId} ${t.name} ${t.departmentId} ${t.time} (${t.scanMethod})`);
  }
  console.log(`  perStudentMonth: ${JSON.stringify(out.lateLogs.perStudentMonth)}`);
  console.log(`  escalated(>=${threshold}) this month: ${JSON.stringify(out.lateLogs.escalatedThisMonth)}`);
  console.log(`escalation_queue: total=${out.escalationQueue.totalDocs} byStatus=${JSON.stringify(out.escalationQueue.byStatus)}`);
  console.log(`  escalated period=${period}: ${out.escalationQueue.escalatedInPeriod}`);
  for (const [dept, g] of Object.entries(out.escalationQueue.expectedTiles)) {
    console.log(`  TILE ${pad(dept, 10)} -> ${padL(g.count, 2)} escalated: ${g.students.map((s) => `${s.studentId}(${s.count})`).join(", ")}`);
  }
  if (Object.keys(out.escalationQueue.expectedTiles).length === 0) console.log("  (no escalated tiles for this period)");
  console.log(`weekly ${out.weeklyAudit.weekStart}..${out.weeklyAudit.weekEnd}: rows=${out.weeklyAudit.rowsInWeek}`);
  for (const [dept, v] of Object.entries(out.weeklyAudit.departments)) {
    console.log(`  DEPT ${pad(dept, 10)} distinctStudents=${v.distinctStudents}`);
  }
  console.log(`  repeated(>=${repeatThreshold}) this week: ${JSON.stringify(out.weeklyAudit.repeatedStudents)}`);
  console.log(`  perStudentWeek: ${JSON.stringify(Object.fromEntries(Object.entries(weekPerStudent).map(([k, v]) => [k, v.count])))}`);
  console.log(`mail_queue: total=${out.mailQueue.total} byStatus=${JSON.stringify(out.mailQueue.byStatus)} | mail_logs: ${out.mailLogs.total}`);
  for (const m of out.mailQueue.recent) {
    console.log(`  mail ${m.id} ${m.type} ${m.departmentId ?? ""} ${m.status} ${m.error ?? ""}${m.duplicateOf ? ` dupOf=${m.duplicateOf}` : ""}`);
  }
  console.log(`collectionCounts: ${JSON.stringify(out.collectionCounts)}`);
}

main().then(
  () => process.exit(0),
  (err) => {
    console.error(err?.message || err);
    process.exit(1);
  },
);
