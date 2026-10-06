// Phase 5 SPARK FALLBACK — pass-out job without a Cloud Function.
//
// On the Blaze plan, functions/index.js runPassOutJob runs on a daily schedule.
// Spark has NO Cloud Functions, so this Admin SDK script is the equivalent
// scheduled runner, using the SAME logic (functions/pass-out-job.js
// runPassOutJob). It materialises `pass_out_reviews/{studentId}` notification
// docs for every ACTIVE student whose batch end year has been reached — the
// server-authoritative record behind the Admin "Pass-out Review" screen. It
// NEVER deletes or archives anyone (NEW_ADMIN_WORKFLOW.md): the admin reviews
// the list and triggers soft-delete (reason "pass_out"), which flips the review
// doc to `soft_deleted`.
//
//   node scripts/process-pass-out-job.js         # create notifications
//   node scripts/process-pass-out-job.js --dry-run
//
// Idempotent (students with an existing review doc are skipped), so an
// hourly/daily task can re-run safely. Automate from Windows Task Scheduler;
// runs are recorded in cron_jobs.
//
// Requires scripts/service-account/key.json. Server-only collections
// (pass_out_reviews, cron_jobs) are written with admin privileges.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { config as loadEnv } from "dotenv";
import { initializeApp, cert } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { runPassOutJob } from "../functions/pass-out-job.js";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
loadEnv({ path: path.join(ROOT, ".env") });

const KEY = path.join(ROOT, "scripts", "service-account", "key.json");
if (!fs.existsSync(KEY)) throw new Error(`Service account key missing: ${KEY}`);

const app = initializeApp({
  credential: cert(KEY),
  projectId: process.env.FIREBASE_PROJECT_ID || "late-attendance-5bf6d",
});
const db = getFirestore(app, "default"); // this project's Firestore database id is "default"
db.settings({ ignoreUndefinedProperties: true });

async function main() {
  const dryRun = process.argv.includes("--dry-run");
  const result = await runPassOutJob({
    db,
    config: {
      requestedBy: process.env.FIREBASE_MAIL_REQUESTED_BY || "scripts/process-pass-out-job.js",
      dryRun,
    },
  });

  console.log(`\n[${dryRun ? "DRY-RUN" : "PASS-OUT JOB"}]`);
  console.log(`  open reviews: ${result.summary.pending}`);
  console.log(`  already notified: ${result.summary.alreadyNotified}`);
  if (dryRun) {
    for (const p of result.planned) {
      console.log(`    → ${p.studentId} — ${p.name} — ${p.department || "?"} — batch ${p.batchStartYear || "?"}–${p.batchEndYear || "?"}`);
    }
    console.log("\nDry-run complete — nothing written.");
    return;
  }
  for (const id of result.created) console.log(`  ✓ pass_out_reviews/${id}`);
  console.log(`\nCreated ${result.created.length} notification(s). The students are NOT deleted — review them in Admin › Pass-out Review.`);
}

main().catch((err) => {
  console.error(`\n[process-pass-out-job failed] ${err.message}`);
  process.exit(1);
});