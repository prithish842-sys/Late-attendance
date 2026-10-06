// Phase 2 SPARK FALLBACK — recompute escalation verdicts without a Cloud Function.
//
// On the Blaze plan, functions/index.js does this in real time via an onCreate
// trigger. Spark has no Cloud Functions, so this Admin SDK script reproduces the
// SAME verdict using the SAME core logic (functions/escalation-core.js). Run it
// after scans, or on a schedule, to refresh `escalation_queue`.
//
//   node scripts/process-escalation.js                 # current reset period, all students
//   node scripts/process-escalation.js --full          # recompute every period present
//
// Server-authoritative: runs with the service-account key (SECURITY.md §1 holds —
// the client only reads the verdict). Requires scripts/service-account/key.json.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { config as loadEnv } from "dotenv";
import { initializeApp, cert } from "firebase-admin/app";
import { getFirestore, FieldValue } from "firebase-admin/firestore";
import {
  periodKey,
  periodStart,
  computeEscalation,
  escalationDoc,
  monthlyStatusDoc,
} from "../functions/escalation-core.js";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
loadEnv({ path: path.join(ROOT, ".env") });

const KEY = path.join(ROOT, "scripts", "service-account", "key.json");
if (!fs.existsSync(KEY)) throw new Error(`Service account key missing: ${KEY}`);

const app = initializeApp({
  credential: cert(KEY),
  projectId: process.env.FIREBASE_PROJECT_ID || "late-attendance-5bf6d",
});
// This project's Firestore database id is literally "default" (not "(default)").
const db = getFirestore(app, "default");
db.settings({ ignoreUndefinedProperties: true });

async function settingsSnapshot() {
  const snap = await db.collection("settings").doc("default").get();
  const data = snap.exists ? snap.data() : {};
  const threshold =
    Number(data.escalationThreshold ?? 3) > 0 ? Number(data.escalationThreshold) : 3;
  return { threshold, resetPeriod: data.resetPeriod ?? "monthly" };
}

async function studentSnapshot(id) {
  const snap = await db.collection("students").doc(id).get();
  if (!snap.exists) return null;
  return { studentId: id, ...snap.data() };
}

/** Count every distinct student who has logs in the window, grouped by period. */
async function countsForWindow({ resetPeriod, after }) {
  const start = after ?? new Date(0);
  const logs = await db
    .collection("late_logs")
    .where("scanTimestamp", ">=", start)
    .get();
  const buckets = new Map(); // period -> Map(studentId -> count)
  for (const doc of logs.docs) {
    const d = doc.data();
    const period = periodKey(d.scanTimestamp?.toDate?.() ?? new Date(), resetPeriod);
    if (!buckets.has(period)) buckets.set(period, new Map());
    const m = buckets.get(period);
    m.set(d.studentId, (m.get(d.studentId) ?? 0) + 1);
  }
  return buckets;
}

async function run() {
  const { threshold, resetPeriod } = await settingsSnapshot();
  let buckets = await countsForWindow({ resetPeriod, after: periodStart(new Date(), resetPeriod) });

  const full = process.argv.includes("--full");
  if (full) {
    buckets = await countsForWindow({ resetPeriod, after: new Date(0) });
  }

  let written = 0;
  let monthlyWritten = 0;
  let skipped = 0;
  for (const [period, students] of buckets) {
    const isCalendarMonth = /^\d{4}-\d{2}$/.test(period);
    for (const [studentId, count] of students) {
      const student = await studentSnapshot(studentId);
      if (!student) {
        console.warn(`skip ${studentId} (no students doc)`);
        skipped++;
        continue;
      }
      // Phase 3 — monthly_student_status is upserted for EVERY late count
      // (incl. the 1st / "tracking" case). During a monthly reset the bucket
      // period IS the month; semester windows can't be split into months here,
      // so they rely on the live escalateLateLog trigger (documented above).
      if (isCalendarMonth) {
        await db
          .collection("monthly_student_status")
          .doc(`${studentId}_${period}`)
          .set(
            { ...monthlyStatusDoc(student, count, threshold, period), updatedAt: FieldValue.serverTimestamp() },
            { merge: true }
          );
        monthlyWritten++;
      }
      const verdict = computeEscalation(count, threshold);
      if (verdict.status === "tracking") continue; // 1st late → log only
      const docId = `${studentId}_${period}`;
      await db.collection("escalation_queue").doc(docId).set(
        escalationDoc(student, count, threshold, period),
        { merge: true }
      );
      written++;
      console.log(`escalation_queue/${docId} → ${verdict.status} (count=${count})`);
    }
  }
  console.log(`\nDone. ${written} escalation records written (${monthlyWritten} monthly status upserts, ${skipped} students skipped).`);
}

run().catch((err) => {
  console.error(`\n[process-escalation failed] ${err.message}`);
  process.exit(1);
});