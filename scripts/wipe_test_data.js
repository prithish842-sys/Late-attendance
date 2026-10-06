// scripts/wipe_test_data.js — clean-slate wipe (real-data onboarding step 2).
//
// Deletes EVERY document in EVERY root Firestore collection except `settings`
// (config, not test data), removes the leftover test Firebase Auth users, and
// clears locally generated QA report files under reports/.
//
// Usage (from the repo root):
//   node scripts/wipe_test_data.js --dry-run   # preview counts only, no writes
//   node scripts/wipe_test_data.js             # wipe for real
//
// Requires scripts/service-account/key.json (Admin SDK: Firestore + Auth).
// The real PT/Admin Auth accounts and seed/ files are NOT touched — reseed
// departments/students afterwards with: node scripts/seed_project.js seed

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { config as loadEnv } from "dotenv";
import { initializeApp, cert } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { getFirestore } from "firebase-admin/firestore";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
loadEnv({ path: path.join(ROOT, ".env") });

const KEY = path.join(ROOT, "scripts", "service-account", "key.json");
if (!fs.existsSync(KEY)) throw new Error(`Service account key missing: ${KEY}`);

const app = initializeApp({
  credential: cert(KEY),
  projectId: process.env.FIREBASE_PROJECT_ID || "late-attendance-5bf6d",
});
const auth = getAuth(app);
const db = getFirestore(app, "default");
db.settings({ ignoreUndefinedProperties: true });

const KEEP = new Set(["settings"]);
// Leftover test logins (user-approved removal 2026-10-01): old PT placeholder,
// early "ptsir" test, and the G7 "hod" test user (HOD has no login — #16).
const REMOVE_EMAILS = new Set([
  "prithishrajmbsccs2024@sankara.ac.in",
  "ptsir@sankara.ac.in",
  "hod@sankara.ac.in",
]);

const dryRun = process.argv.includes("--dry-run");

async function countAll(col) {
  const snap = await col.count().get();
  return snap.data().count;
}

async function wipeCollection(col) {
  let total = 0;
  for (;;) {
    const snap = await col.limit(400).get();
    if (snap.empty) break;
    const batch = db.batch();
    for (const d of snap.docs) batch.delete(d.ref);
    await batch.commit();
    total += snap.size;
  }
  return total;
}

async function listAllUsers() {
  const users = [];
  let pageToken;
  do {
    const page = await auth.listUsers(1000, pageToken);
    users.push(...page.users);
    pageToken = page.pageToken;
  } while (pageToken);
  return users;
}

async function main() {
  console.log(`== WIPE ${dryRun ? "(dry-run)" : "(real)"} ==`);

  const cols = await db.listCollections();
  const plan = [];
  for (const col of cols) {
    plan.push({ id: col.id, count: KEEP.has(col.id) ? 0 : await countAll(col), kept: KEEP.has(col.id) });
  }

  let wipeTotal = 0;
  for (const p of plan) {
    if (p.kept) {
      console.log(`  KEEP ${p.id} (config, kept)`);
      continue;
    }
    if (dryRun) {
      console.log(`  would delete ${String(p.count).padStart(5)} docs  ${p.id}`);
      wipeTotal += p.count;
    } else if (p.count > 0) {
      const n = await wipeCollection(db.collection(p.id));
      console.log(`  deleted ${String(n).padStart(5)} docs  ${p.id}`);
      wipeTotal += n;
    } else {
      console.log(`  already 0       ${p.id}`);
    }
  }

  const users = await listAllUsers();
  const targets = users.filter((u) => REMOVE_EMAILS.has((u.email || "").toLowerCase()));
  console.log(`auth: ${users.length} users; ${targets.length} test user(s) to remove`);
  for (const u of targets) {
    if (dryRun) {
      console.log(`  would delete auth ${u.email} (uid ${u.uid})`);
    } else {
      await auth.deleteUser(u.uid);
      console.log(`  deleted auth ${u.email} (uid ${u.uid})`);
    }
  }
  const remaining = users.filter((u) => !REMOVE_EMAILS.has((u.email || "").toLowerCase()));
  console.log(`auth remaining after run: ${remaining.map((u) => u.email).join(", ") || "(none)"}`);

  const reportsDir = path.join(ROOT, "reports");
  const localFiles = fs.existsSync(reportsDir)
    ? fs.readdirSync(reportsDir).filter((f) => !f.startsWith("."))
    : [];
  if (dryRun) {
    console.log(`local reports/: ${localFiles.length} file(s) to remove`);
  } else {
    for (const f of localFiles) fs.rmSync(path.join(reportsDir, f));
    console.log(`local reports/: removed ${localFiles.length} file(s)`);
  }

  console.log(dryRun ? `DRY-RUN total docs that would be deleted: ${wipeTotal}` : `WIPED total docs deleted: ${wipeTotal}`);
}

main().then(
  () => process.exit(0),
  (err) => {
    console.error(`\n[wipe failed] ${err.message || err}`);
    process.exit(1);
  },
);
