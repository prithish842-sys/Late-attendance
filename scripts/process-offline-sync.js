// Phase 5 SPARK FALLBACK — device-vs-server time validation for synced-offline
// scans without a Cloud Function.
//
// On the Blaze plan, functions/index.js escalateLateLog flags a synced-offline
// scan at write time (SECURITY.md §2). Spark has NO Cloud Functions, so this
// Admin SDK script is the equivalent: it scans recent `syncedOffline` late_logs,
// compares each `deviceTimestamp` against the server's `scanTimestamp`, and
// writes `offline_sync_flags/{logId}` when a scan has NO flag yet. Large
// mismatches are flagged for admin review — never trusted silently.
//
//   node scripts/process-offline-sync.js                 # assess + write flags
//   node scripts/process-offline-sync.js --dry-run       # assess, write nothing
//   node scripts/process-offline-sync.js --list          # synced logs + existing flags
//
// Requires scripts/service-account/key.json. The runner uses the Admin SDK and
// BYPASSES rules (SECURITY.md §8) — the client stays fully write-blocked on
// offline_sync_flags.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { config as loadEnv } from "dotenv";
import { initializeApp, cert } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { flagRecentOfflineSyncs } from "../functions/offline-sync-core.js";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
loadEnv({ path: path.join(ROOT, ".env") });

const KEY = path.join(ROOT, "scripts", "service-account", "key.json");
if (!fs.existsSync(KEY)) throw new Error(`Service account key missing: ${KEY}`);

const app = initializeApp({
  credential: cert(KEY),
  projectId: process.env.FIREBASE_PROJECT_ID || "late-attendance-5bf6d",
});
const db = getFirestore(app, "default"); // this project's Firestore database id is "default"

const fmt = (v) => (v ? v.toDate?.().toISOString?.() ?? String(v) : "–");

async function assess({ dryRun }) {
  const label = dryRun ? "DRY-RUN (nothing written)" : "PROCESS";
  const result = await flagRecentOfflineSyncs({ db, dryRun });

  console.log(`\n[${label}] recent synced-offline scans assessed by the server`);
  console.log(`  assessed: ${result.assessed}   flagged: ${result.flagged}   already: ${result.already}   out-of-window: ${result.skipped}`);

  if (result.assessments.length === 0) {
    console.log("  (no synced-offline scans to assess)");
  }
  for (const a of result.assessments) {
    const mark = a.flagged ? "FLAGGED" : "ok";
    console.log(`  ${mark}  ${a.logId || "(no id)"}`);
    console.log(`         device ${fmt(a.deviceTimestamp)}  ·  server ${fmt(a.scanTimestamp)}  ·  Δ ${a.discrepancyMinutes === null ? "n/a" : `${a.discrepancyMinutes} min`}  ·  ${a.reason}`);
  }
  console.log(dryRun ? "\nDry-run complete — no flags written." : `\n${result.flagged} scan(s) flagged for admin review.`);
}

async function list() {
  const since = new Date(Date.now() - 30 * 86400000);
  const synced = await db.collection("late_logs").where("syncedOffline", "==", true).get();
  console.log(`\nsynced-offline late_logs (last 30 days windowed client-side; ${synced.size} total):`);
  if (synced.size === 0) console.log("  (none)");
  const ids = [];
  for (const d of synced.docs) {
    const x = d.data();
    const stamp = x.scanTimestamp?.toDate?.();
    if (stamp && stamp < since) continue;
    ids.push(d.id);
    console.log(`  ${d.id} — ${x.studentId} — scan ${fmt(x.scanTimestamp)} — device ${fmt(x.deviceTimestamp)}`);
  }

  console.log(`\noffline_sync_flags (matching, ${ids.length} possible):`);
  if (ids.length === 0) return;
  for (const id of ids) {
    const flag = await db.collection("offline_sync_flags").doc(id).get();
    if (!flag.exists) {
      console.log(`  ${id} — (no flag yet)`);
      continue;
    }
    const f = flag.data();
    const mark = f.flagged ? "FLAGGED" : "ok";
    console.log(`  ${mark}  ${id} — Δ ${f.discrepancyMinutes === null || f.discrepancyMinutes === undefined ? "n/a" : `${f.discrepancyMinutes} min`} — ${f.reason} — assessed ${fmt(f.assessedAt)}`);
  }
}

async function main() {
  const flags = new Set(process.argv.slice(2).filter((a) => a.startsWith("--")));
  const positional = process.argv.slice(2).filter((a) => !a.startsWith("--"));
  const command = positional[0] || "process";

  if (flags.has("--list") || command === "list") return list();
  if (command !== "process") throw new Error("Unknown command. Use: process | list");

  await assess({ dryRun: flags.has("--dry-run") });
}

main().catch((err) => {
  console.error(`\n[process-offline-sync failed] ${err.message}`);
  process.exit(1);
});