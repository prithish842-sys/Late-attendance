// Phase 5 SPARK FALLBACK — weekly audit job without a Cloud Function.
//
// On the Blaze plan, functions/index.js runWeeklyAuditJob runs on a Monday
// schedule and audits the week that just ended. Spark has NO Cloud Functions,
// so this Admin SDK script is the equivalent scheduled runner, using the SAME
// logic (functions/weekly-audit-job.js runWeeklyAuditJob) and the SAME sender
// under it (functions/weekly-audit-sender.js).
//
//   node scripts/process-weekly-audit-job.js                      # current week
//   node scripts/process-weekly-audit-job.js --from 2026-09-21    # a specific
//                                                                # Monday week
//   node scripts/process-weekly-audit-job.js --dry-run            # preview only
//
// Idempotent per department+week (departments with an existing weekly_audit
// mail_logs row are skipped), so scheduling it repeatedly is safe. Automate it
// from Windows Task Scheduler or cron; the run is recorded in cron_jobs.
//
// Requires scripts/service-account/key.json. The Resend key lives ONLY in .env
// (RESEND_API_KEY); server-only collections (mail_logs, cron_jobs) are written
// with admin privileges (NEW_SECURITY.md §5, §8).

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { config as loadEnv } from "dotenv";
import { initializeApp, cert } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { runWeeklyAuditJob } from "../functions/weekly-audit-job.js";

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

function parseArgs(argv) {
  const args = argv.slice();
  const flags = new Set(args.filter((a) => a.startsWith("--")));
  let from = null;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--from") {
      from = args[i + 1];
      break;
    }
  }
  // Sane default for a Monday-morning schedule: audit the week that just ended.
  if (!from) {
    const now = new Date();
    const day = now.getUTCDay(); // 0 = Sunday
    const backToMonday = day === 0 ? 6 : day - 1;
    const monday = new Date(now);
    monday.setUTCDate(monday.getUTCDate() - backToMonday - 7);
    from = monday.toISOString().slice(0, 10);
  }
  return { from, dryRun: flags.has("--dry-run") };
}

async function main() {
  const { from, dryRun } = parseArgs(process.argv.slice(2));
  const result = await runWeeklyAuditJob({
    db,
    config: {
      apiKey: process.env.RESEND_API_KEY,
      collegeName: process.env.COLLEGE_NAME,
      requestedBy: process.env.FIREBASE_MAIL_REQUESTED_BY || "scripts/process-weekly-audit-job.js",
      weekStartDate: from,
      dryRun: dryRun,
    },
  });

  console.log(result.status === "abort" ? `\n✗ ${result.code}: ${result.detail}` : "");
  if (result.status === "abort") return;

  const { planned, summary } = result;
  console.log(`\n[${dryRun ? "DRY-RUN" : "WEEKLY AUDIT JOB"}] ${result.range} (${result.weekLabel})`);
  console.log(`  due:          ${planned.due.length} department(s) still need their HOD mail`);
  console.log(`  already sent: ${planned.alreadySent.length} department(s)`);
  console.log(`  no HOD email: ${planned.noHod.length} department(s) (fix departments, re-run)`);
  for (const c of planned.due) {
    console.log(`    → ${c.departmentName}${c.departmentId ? ` (${c.departmentId})` : ""} — ${c.uniqueStudents} students / ${c.totalEvents} events / ${c.repeatedStudents} repeated`);
  }
  for (const c of planned.noHod) {
    console.log(`    ✗ ${c.departmentName} — no hodEmail on file`);
  }

  if (dryRun) {
    console.log("\nDry-run complete — no mail sent, no cron_jobs row written.");
    return;
  }
  console.log(`\nSummary: ${summary.sent} sent, ${summary.failed} failed, ${summary.alreadySent} already sent, ${summary.noHod} without an HOD email.`);
  for (const r of result.results || []) {
    if (r.status === "failed") {
      console.log(`  ✗ ${r.departmentName}: ${r.error || `${r.code}: ${r.detail}`}`);
    } else {
      console.log(`  ✓ ${r.departmentName}: ${r.status}`);
    }
  }
}

main().catch((err) => {
  console.error(`\n[process-weekly-audit-job failed] ${err.message}`);
  process.exit(1);
});