// Phase 3 SPARK FALLBACK — HOD escalation mail without a Cloud Function.
//
// On the Blaze plan, functions/index.js handles the mail:
//   - `sendEscalationMail` HttpsCallable endpoint, and
//   - `processMailQueue` onCreate trigger on mail_queue.
// Spark has NO Cloud Functions, so this Admin SDK script is the equivalent
// server-side consumer of the SAME `mail_queue` collection, using the SAME core
// logic (functions/mail-core.js + functions/mail-sender.js processQueuedMail).
//
//   node scripts/process-mail.js                     # process pending mail_queue entries
//   node scripts/process-mail.js --dry-run           # build the full payload but send nothing
//   node scripts/process-mail.js --list              # show mail_queue + recent mail_logs
//   node scripts/process-mail.js enqueue <deptId> [studentId ...] [--period YYYY-MM]
//   node scripts/process-mail.js enqueue <deptId> --report [--from YYYY-MM-DD --to YYYY-MM-DD] [--year 1|2|3] [--split]
//   node scripts/process-mail.js enqueue <deptId> --weekly [--from YYYY-MM-DD (Monday)]
//
// The Resend API key lives ONLY in .env (RESEND_API_KEY), never in the app
// (docs/SECURITY.md §6). Requires scripts/service-account/key.json.
// Server reads escalation_queue/late_logs/students and writes mail_logs itself —
// the client is fully blocked from those collections (SECURITY.md §8).

import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { config as loadEnv } from "dotenv";
import { periodKey } from "../functions/escalation-core.js";
import { runDueMailQueue } from "../functions/mail-queue-runner.js";

// Load firebase-admin through functions/' node_modules — the SAME copy the
// queue runner and senders require("firebase-admin/firestore") with. Importing
// the separate copy under scripts/node_modules gives Firestore two different
// FieldValue classes, and the claim transaction then dies with
// "Couldn't serialize object of type NumericIncrementTransform" (Firestore
// rejects transforms whose prototype it doesn't recognize).
const functionsRequire = createRequire(
  new URL("../functions/package.json", import.meta.url),
);
const { initializeApp, cert } = functionsRequire("firebase-admin/app");
const { getFirestore, FieldValue } = functionsRequire(
  "firebase-admin/firestore",
);

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

/**
 * Shared mail_config for the queue runner: the Resend key + college name read
 * from .env (SECURITY.md §6); `from` is derived by the senders' defaultFrom().
 * The SAME runner (functions/mail-queue-runner.js) is used by the Blaze
 * trigger + retry schedule, so Spark retry/status behaviour cannot diverge.
 */
const mailConfig = (extra = {}) => ({
  apiKey: process.env.RESEND_API_KEY,
  collegeName: process.env.COLLEGE_NAME,
  requestedBy: process.env.FIREBASE_MAIL_REQUESTED_BY || "scripts/process-mail.js",
  ...extra,
});

function formatRetryDelay(ms) {
  if (ms == null) return null;
  if (ms < 1000) return `${Math.round(ms)} ms`;
  return `${(ms / 60000).toFixed(1)} min`;
}

/** Pretty-print the sender's dry-run payload (matches runDueMailQueue's shape). */
function printDryRun(out) {
  const r = out.result;
  if (r?.status === "dry-run") {
    console.log(`✓ ${out.id} (${out.type || "escalation"})`);
    console.log(`    → to: ${r.to}`);
    console.log(`    → subject: ${r.subject}`);
    if (out.type === "report") {
      console.log(`    → range: ${r.range} (${r.mode}) — ${r.stats.totalLateEntries} entries / ${r.stats.distinctStudents} students`);
      for (const g of r.tierGroups || []) console.log(`    → ${g.label}: ${g.count}`);
    } else if (out.type === "weekly_audit") {
      console.log(`    → week: ${r.weekLabel} — ${r.stats.totalLateEntries} late entries / ${r.stats.distinctStudents} students / ${r.stats.repeatedStudents} repeated`);
      console.log(`    → repeated students: ${(r.studentsIncluded || []).join(", ")}`);
    } else {
      console.log(`    → students: ${r.studentsIncluded.join(", ")}`);
    }
    for (const a of r.attachmentsPreview || []) {
      console.log(`    → attachment: ${a.filename} (${a.sizeBytes} bytes${a.content_id ? ", inline cid:" + a.content_id : ""})`);
    }
  } else {
    console.log(`✗ ${out.id} — ${r?.code}: ${r?.detail}`);
  }
}

async function processQueue({ dryRun }) {
  const { results, rollup } = await runDueMailQueue({ db, config: mailConfig({ dryRun: dryRun || undefined }) });

  if (results.length === 0) {
    if (dryRun) {
      console.log("No pending mail_queue entries to dry-run.");
    } else {
      console.log("No pending or due-retry mail_queue entries to process.");
    }
    return;
  }

  const label = dryRun ? "DRY-RUN (nothing sent)" : "PROCESS";
  console.log(`\n[${label}] ${results.length} mail request(s)\n`);

  for (const out of results) {
    if (dryRun) {
      printDryRun(out);
      continue;
    }
    if (out.skipped) {
      console.log(`- ${out.id} — skipped: ${out.reason}`);
    } else if (out.status === "sent") {
      console.log(`✓ ${out.id} — sent to ${out.to} (resend ${out.resendId})`);
    } else if (out.suppressedDuplicate) {
      console.log(
        `✗ ${out.id} — suppressed duplicate of ${out.duplicateOf} (identical intent already sent inside the 10 min window)`,
      );
    } else if (out.status === "retry") {
      console.log(`↻ ${out.id} — transient failure, will retry in ${formatRetryDelay(out.retryDelayMs)}: ${out.error}`);
    } else {
      console.log(`✗ ${out.id} — ${out.status}: ${out.error || `${out.code}: ${out.detail}`}`);
    }
  }

  if (dryRun) {
    console.log("\nDry-run complete — no mail sent, queue untouched.");
  } else {
    console.log(`\nDone: ${rollup.sent} sent, ${rollup.retry} scheduled for retry, ${rollup.failed} permanent failure(s), ${rollup.skipped} skipped.`);
  }
}

async function enqueue({ departmentId, studentIds, period, requestedBy, report, weekly, year, from, to, split }) {
  // C4: department ids are slugs (BSC-CS, BSC-COM-PAA, ...) — reject anything
  // else before it becomes a document id or query token, and keep the
  // per-request student list bounded like the firestore.rules cap.
  if (typeof departmentId !== "string" || !/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(departmentId)) {
    throw new Error(`Invalid department id "${departmentId}" — expected a slug like BSC-CS (letters, digits, - or _ only).`);
  }
  if ((studentIds || []).length > 500) {
    throw new Error(`Too many student ids (${studentIds.length}) — enqueue in batches of at most 500.`);
  }
  const tail = String(departmentId).replace(/[^a-z0-9]/gi, "_").slice(0, 24);

  const deptSnap = await db.collection("departments").doc(departmentId).get();
  const departmentInfo = deptSnap.exists
    ? { departmentId, department: deptSnap.data().name || departmentId }
    : { departmentId, department: departmentId };

  if (report) {
    const p = period || periodKey(new Date(), "monthly");
    const start = from || p || new Date().toISOString().slice(0, 10);
    const end = to || (from ? start : start);
    const id = `${tail}_report_${Date.now().toString(36)}`;
    await db.collection("mail_queue").doc(id).set({
      ...departmentInfo,
      type: "report",
      periodType: from && to ? "custom" : "daily",
      startDate: start,
      endDate: end,
      year: year || null,
      attachmentMode: split ? "split" : "combined",
      requestedBy: requestedBy || "scripts/process-mail.js",
      status: "pending",
      attemptCount: 0,
      requestedAt: FieldValue.serverTimestamp(),
    });
    console.log(`Enqueued report mail mail_queue/${id}`);
    console.log(`  → department: ${departmentInfo.department} (${departmentId}), ${start} to ${end}${year ? `, year tier ${year}` : ""} (${split ? "split" : "combined"})`);
    console.log("  → process it with:  node scripts/process-mail.js            (dry run: --dry-run)");
    return id;
  }

  if (weekly) {
    const start = from || new Date().toISOString().slice(0, 10);
    const id = `${tail}_weekly_${Date.now().toString(36)}`;
    await db.collection("mail_queue").doc(id).set({
      ...departmentInfo,
      type: "weekly_audit",
      startDate: start,
      requestedBy: requestedBy || "scripts/process-mail.js",
      status: "pending",
      attemptCount: 0,
      requestedAt: FieldValue.serverTimestamp(),
    });
    console.log(`Enqueued weekly audit mail_queue/${id}`);
    console.log(`  → department: ${departmentInfo.department} (${departmentId}), week starting ${start} (Monday)`);
    console.log("  → process it with:  node scripts/process-mail.js            (dry run: --dry-run)");
    return id;
  }

  const p = period || periodKey(new Date(), "monthly");
  const id = `${tail}_${p}_${Date.now().toString(36)}`;

  await db.collection("mail_queue").doc(id).set({
    ...departmentInfo,
    period: p,
    studentIds,
    requestedBy: requestedBy || "scripts/process-mail.js",
    status: "pending",
    attemptCount: 0,
    requestedAt: FieldValue.serverTimestamp(),
  });
  console.log(`Enqueued mail_queue/${id}`);
  console.log(`  → department: ${departmentInfo.department} (${departmentId}), period ${p}`);
  console.log(`  → students:   ${studentIds.length ? studentIds.join(", ") : "(all escalated in this department)"}`);
  console.log("  → process it with:  node scripts/process-mail.js            (dry run: --dry-run)");
  return id;
}

async function list() {
  const q = await db.collection("mail_queue").orderBy("requestedAt", "desc").limit(20).get();
  console.log(`\nmail_queue (recent ${q.size}):`);
  if (q.size === 0) console.log("  (empty)");
  for (const d of q.docs) {
    const x = d.data();
    console.log(`  ${d.id} — ${x.status} — dept ${x.departmentId || x.department} — period ${x.period} — students ${(x.studentIds || []).length}`);
    if (x.resendId) console.log(`       resend ${x.resendId}`);
  }

  const logs = await db.collection("mail_logs").orderBy("sentTimestamp", "desc").limit(10).get();
  console.log(`\nmail_logs (recent ${logs.size}):`);
  if (logs.size === 0) console.log("  (empty)");
  for (const d of logs.docs) {
    const x = d.data();
    console.log(`  ${d.id} — ${x.sentTimestamp?.toDate?.().toISOString?.() ?? "?"} — to ${x.to} — students ${(x.studentsIncluded || []).length} — resend ${x.resendId || "?"}`);
  }
  console.log("");
}

function parseArgs(argv) {
  const positional = [];
  let period;
  let year;
  let from;
  let to;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--period") {
      period = argv[i + 1];
      i++;
    } else if (a === "--year") {
      year = argv[i + 1];
      i++;
    } else if (a === "--from") {
      from = argv[i + 1];
      i++;
    } else if (a === "--to") {
      to = argv[i + 1];
      i++;
    } else if (a.startsWith("--")) {
      // flag only (--dry-run, --list, --report, --split, ...)
    } else {
      positional.push(a);
    }
  }
  const flags = new Set(argv.filter((a) => a.startsWith("--")));
  return {
    command: positional[0] || "process",
    args: positional.slice(1),
    dryRun: flags.has("--dry-run"),
    list: flags.has("--list"),
    report: flags.has("--report"),
    weekly: flags.has("--weekly"),
    split: flags.has("--split"),
    period,
    year,
    from,
    to,
  };
}

async function main() {
  const { command, args, dryRun, list: wantList, period, report, weekly, split, year, from, to } = parseArgs(process.argv.slice(2));

  if (wantList || command === "list") return list();
  if (command !== "process" && command !== "enqueue") {
    throw new Error("Unknown command. Use: process | enqueue <deptId> [studentId ...] | list");
  }
  if (command === "enqueue") {
    if (!args[0]) {
      throw new Error(
        report
          ? "Usage: node scripts/process-mail.js enqueue <departmentId> --report [--from YYYY-MM-DD --to YYYY-MM-DD] [--year 1|2|3] [--split]"
          : weekly
            ? "Usage: node scripts/process-mail.js enqueue <departmentId> --weekly [--from YYYY-MM-DD (Monday)]"
            : "Usage: node scripts/process-mail.js enqueue <departmentId> [studentId ...] [--period YYYY-MM]"
      );
    }
    await enqueue({
      departmentId: args[0],
      studentIds: args.slice(1),
      period,
      requestedBy: process.env.FIREBASE_MAIL_REQUESTED_BY,
      report,
      weekly,
      split,
      year,
      from,
      to,
    });
    return;
  }
  await processQueue({ dryRun });
}

main().catch((err) => {
  console.error(`\n[process-mail failed] ${err.message}`);
  process.exit(1);
});