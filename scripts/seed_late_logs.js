// Sample late_logs to exercise the escalation ladder (Phase 2 validation).
import { initializeApp, cert, deleteApp, getApps } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { getFirestore, FieldValue } from "firebase-admin/firestore";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { config as loadEnv } from "dotenv";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
loadEnv({ path: path.join(ROOT, ".env") });

const app = (getApps()[0] ?? initializeApp({ credential: cert(path.join(ROOT, "scripts", "service-account", "key.json")), projectId: process.env.FIREBASE_PROJECT_ID || "late-attendance-5bf6d" }));
const db = getFirestore(app, "default");
db.settings({ ignoreUndefinedProperties: true });

// scannedBy uid comes from the .env demo account (single source of truth).
const PT_SIR_EMAIL = process.env.FIREBASE_DEMO_PT_SIR_EMAIL;
if (!PT_SIR_EMAIL) {
  console.error("FIREBASE_DEMO_PT_SIR_EMAIL not set in .env — see .env.example");
  process.exit(1);
}
const PT_SIR = (await getAuth(app).getUserByEmail(PT_SIR_EMAIL)).uid;
const now = new Date();
const y = now.getFullYear();
const m = String(now.getMonth() + 1).padStart(2, "0");
const day = (d) => new Date(y, now.getMonth(), d, 8, 40, 0);
const pad = (d) => `${y}-${m}-${String(d).padStart(2, "0")}`;

const plan = [
  // 26BSC001: 1 late -> tracking
  { studentId: "26BSC001", dates: [1] },
  // 26BSC004: 2 lates -> warning
  { studentId: "26BSC004", dates: [2, 4] },
  // 26BSC008: 3 lates -> escalated (threshold 3)
  { studentId: "26BSC008", dates: [3, 7, 10] },
  // 26BSC010: 4 lates -> escalated, 1 above threshold
  { studentId: "26BSC010", dates: [5, 6, 8, 9] },
];

const existing = await db.collection("late_logs").get();
console.log(`existing late_logs: ${existing.size}`);
const writes = existing.docs.filter((d) => plan.some((p) => p.dates.some((dd) => d.id === `${p.studentId}_${pad(dd)}`)));
for (const d of writes) {
  await d.ref.delete();
  console.log(`cleared leftover ${d.id}`);
}

let created = 0;
for (const { studentId, dates } of plan) {
  for (const d of dates) {
    await db.collection("late_logs").doc(`${studentId}_${pad(d)}`).set({
      studentId,
      scannedBy: PT_SIR,
      scanTimestamp: FieldValue.serverTimestamp(),
      scanMethod: "barcode",
      syncedOffline: false,
      deviceTimestamp: day(d),
    });
    created++;
  }
}
console.log(`seeded ${created} late_logs`);
await deleteApp(app);