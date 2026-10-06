// Phase 4 SPARK FALLBACK — attendance reports without a Cloud Function.
//
// On the Blaze plan, functions/index.js handles reports:
//   - `generateReport` HttpsCallable endpoint.
// Spark has NO Cloud Functions, so this Admin SDK script is the equivalent
// server-side consumer of the SAME `report_requests` collection, using the SAME
// core logic (functions/report-core.js + functions/report-generator.js
// generateReport). The app enqueues a report_requests intent; this script
// turns it into the Excel + PDF files on the office machine.
//
//   node scripts/generate-report.js                        # process pending report_requests → reports/
//   node scripts/generate-report.js --dry-run              # build everything but write nothing
//   node scripts/generate-report.js --list                 # report_requests + recent report_logs
//   node scripts/generate-report.js enqueue monthly [--month YYYY-MM] [--department DEPT] [--year YEAR]
//   node scripts/generate-report.js enqueue weekly   [--start YYYY-MM-DD] [--department DEPT] [--year YEAR]
//   node scripts/generate-report.js enqueue daily    [--date  YYYY-MM-DD] [--department DEPT] [--year YEAR]
//   node scripts/generate-report.js enqueue custom   [--start YYYY-MM-DD] [--end YYYY-MM-DD] [--department DEPT] [--year YEAR]
//
// Generated files land in <repo>/reports/ (gitignored). The generation window
// is server-authoritative (docs/SECURITY.md §1, §8): report-core resolves it,
// and the client can never mark a request generated/failed — only the runner
// (or Cloud Function, on Blaze) does, via report_logs.
//
// Requires scripts/service-account/key.json. Defaults come from .env
// (FIREBASE_PROJECT_ID / FIREBASE_REPORT_REQUESTED_BY).

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { config as loadEnv } from "dotenv";
import { initializeApp, cert } from "firebase-admin/app";
import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { generateReport, reportLogDoc } from "../functions/report-generator.js";
import { reportWindow } from "../functions/report-core.js";

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

const REPORTS_DIR = path.join(ROOT, "reports");

function requestFromDoc(doc) {
  return {
    periodType: doc.periodType,
    startDate: doc.startDate || null,
    endDate: doc.endDate || null,
    department: doc.department || null,
    year: doc.year || null,
    requestedBy: doc.requestedBy || null,
  };
}

/** Atomically claim a pending request doc so two runs never double-generate. */
async function claim(docRef, id) {
  let result = null;
  await db.runTransaction(async (txn) => {
    const snap = await txn.get(docRef);
    if (!snap.exists || snap.data().status !== "pending") return;
    txn.update(docRef, {
      status: "processing",
      attemptCount: FieldValue.increment(1),
      processingAt: FieldValue.serverTimestamp(),
    });
    result = id;
  });
  return result === id;
}

function writeReportFiles(result) {
  fs.mkdirSync(REPORTS_DIR, { recursive: true });
  const paths = {};
  const buffers = { xlsx: result.xlsxBase64, pdf: result.pdfBase64 };
  for (const f of result.files) {
    const kind = f.name.endsWith(".xlsx") ? "xlsx" : "pdf";
    const target = path.join(REPORTS_DIR, f.name);
    fs.writeFileSync(target, buffers[kind], "base64");
    paths[f.name] = target;
  }
  return paths;
}

async function processOne(doc, { dryRun }) {
  const id = doc.id;
  const data = doc.data() || {};

  if (dryRun) {
    const request = requestFromDoc(data);
    const result = await generateReport({ db, request, config: { dryRun: true } });
    return { id, dryRun: true, result };
  }

  const ref = db.collection("report_requests").doc(id);
  if (!(await claim(ref, id))) {
    return { id, skipped: true, reason: `status is not 'pending' (currently ${data.status || "?"})` };
  }

  try {
    const request = requestFromDoc(data);
    const result = await generateReport({ db, request });

    if (result.status !== "generated") {
      await ref.update({
        status: "failed",
        error: `${result.code}: ${result.detail}`,
        processedAt: FieldValue.serverTimestamp(),
      });
      return { id, status: "failed", code: result.code, detail: result.detail };
    }

    const localFiles = writeReportFiles(result);
    await db.collection("report_logs").doc(id).set({
      ...reportLogDoc({ request, result, reportId: id }),
      generatedAt: FieldValue.serverTimestamp(),
    });
    await ref.update({
      status: "generated",
      stats: result.stats,
      files: result.files,
      localFiles,
      processedAt: FieldValue.serverTimestamp(),
    });
    return { id, status: "generated", label: result.label, localFiles };
  } catch (err) {
    await ref.update({
      status: "failed",
      error: err.message,
      processedAt: FieldValue.serverTimestamp(),
    });
    return { id, status: "failed", error: err.message };
  }
}

async function processQueue({ dryRun }) {
  const pending = await db.collection("report_requests").get();
  const docs = pending.docs.filter((d) => (d.data().status || "pending") === "pending");

  if (docs.length === 0) {
    console.log("No pending report_requests entries to process.");
    return;
  }

  const label = dryRun ? "DRY-RUN (nothing written)" : "PROCESS";
  console.log(`\n[${label}] ${docs.length} pending report request(s)\n`);

  let generated = 0;
  for (const doc of docs) {
    const out = await processOne(doc, { dryRun });

    if (out.dryRun) {
      const r = out.result;
      if (r?.status === "dry-run") {
        console.log(`✓ ${out.id}`);
        console.log(`    → period: ${r.label}`);
        console.log(`    → rows:   ${r.rowCount} late entries · ${r.stats.distinctStudents} students`);
        for (const d of r.stats.byDepartment) console.log(`        ${d.department}: ${d.count}`);
        for (const f of r.files) console.log(`    → would write: ${f.name} (${f.sizeBytes} bytes)`);
      } else {
        console.log(`✗ ${out.id} — ${r?.code}: ${r?.detail}`);
      }
      continue;
    }

    if (out.skipped) {
      console.log(`- ${out.id} — skipped: ${out.reason}`);
      continue;
    }
    if (out.status === "generated") {
      generated++;
      console.log(`✓ ${out.id} — ${out.label}`);
      for (const [, target] of Object.entries(out.localFiles)) console.log(`    → ${target}`);
    } else {
      console.log(`✗ ${out.id} — ${out.status}: ${out.error || `${out.code}: ${out.detail}`}`);
    }
  }
  console.log(generated ? `\n${generated} report(s) written to ${REPORTS_DIR}.` : dryRun ? "\nDry-run complete — no files written, queue untouched." : "\nNo reports could be generated. Check the failures above.");
}

async function enqueue({ periodType, flags, requestedBy }) {
  // C4: --department is an optional slug filter (BSC-CS, ...) — validate the
  // shape before it reaches the report_requests document.
  if (flags.department === true) {
    throw new Error("--department needs a value, e.g. --department BSC-CS.");
  }
  if (flags.department != null && !/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(String(flags.department))) {
    throw new Error(`Invalid department "${flags.department}" — expected a slug like BSC-CS (letters, digits, - or _ only).`);
  }
  const request = {
    periodType,
    startDate: flags.start || null,
    endDate: flags.end || null,
    date: flags.date || null,
    month: flags.month || null,
    department: flags.department || null,
    year: flags.year || null,
  };
  const window = reportWindow(request);
  if (!window) {
    throw new Error(`Invalid ${periodType} report window. For custom provide --start and --end; check the range.`);
  }

  // Store the resolved inclusive day range (never the raw --date/--month), so
  // functions/report-generator.js recomputes the exact same window on process.
  const startDate = window.start.toISOString().slice(0, 10);
  const endDate = new Date(window.end.getTime() - 86400000).toISOString().slice(0, 10);

  const id = `report_${Date.now().toString(36)}`;
  await db.collection("report_requests").doc(id).set({
    periodType,
    startDate,
    endDate,
    department: request.department || null,
    year: request.year || null,
    requestedBy: requestedBy || "scripts/generate-report.js",
    status: "pending",
    attemptCount: 0,
    requestedAt: FieldValue.serverTimestamp(),
  });
  console.log(`Enqueued report_requests/${id}`);
  console.log(`  → period: ${window.label} (${startDate} → ${endDate})`);
  if (request.department) console.log(`  → department: ${request.department}`);
  if (request.year) console.log(`  → year: ${request.year}`);
  console.log("  → process it with:  node scripts/generate-report.js            (dry run: --dry-run)");
  return id;
}

async function list() {
  const q = await db.collection("report_requests").orderBy("requestedAt", "desc").limit(20).get();
  console.log(`\nreport_requests (recent ${q.size}):`);
  if (q.size === 0) console.log("  (empty)");
  for (const d of q.docs) {
    const x = d.data();
    console.log(`  ${d.id} — ${x.status} — ${x.periodType} — dept ${x.department || "all"} — year ${x.year || "all"} — by ${x.requestedBy || "?"}`);
    if (x.error) console.log(`       ${x.error}`);
  }

  const logs = await db.collection("report_logs").orderBy("generatedAt", "desc").limit(10).get();
  console.log(`\nreport_logs (recent ${logs.size}):`);
  if (logs.size === 0) console.log("  (empty)");
  for (const d of logs.docs) {
    const x = d.data();
    const files = (x.files || []).map((f) => f.name).join(", ");
    console.log(`  ${d.id} — ${x.label} — ${x.stats?.totalLateEntries ?? 0} entries — ${files}`);
  }
  console.log("");
}

function parseArgs(argv) {
  const flags = {};
  const positional = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith("--")) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next && !next.startsWith("--") && !(key === "dry-run" || key === "list")) {
        flags[key] = next;
        i++;
      } else {
        flags[key] = true;
      }
    } else {
      positional.push(a);
    }
  }
  return {
    command: positional[0] || "process",
    args: positional.slice(1),
    flags,
    dryRun: flags["dry-run"] === true,
    list: flags["list"] === true || positional[0] === "list",
  };
}

async function main() {
  const { command, args, flags, dryRun, list: wantList } = parseArgs(process.argv.slice(2));

  if (wantList) return list();

  if (command === "enqueue") {
    const types = new Set(["daily", "weekly", "monthly", "custom"]);
    const pt = flags.periodType || args[0] || null;
    if (!pt || !types.has(pt)) {
      throw new Error("Usage: node scripts/generate-report.js enqueue <daily|weekly|monthly|custom> [--date YYYY-MM-DD | --start YYYY-MM-DD] [--end YYYY-MM-DD] [--month YYYY-MM] [--department DEPT] [--year YEAR]");
    }
    await enqueue({ periodType: pt, flags, requestedBy: process.env.FIREBASE_REPORT_REQUESTED_BY });
    return;
  }

  if (command !== "process") {
    throw new Error("Unknown command. Use: process | enqueue <daily|weekly|monthly|custom> [...] | list");
  }
  await processQueue({ dryRun });
}

main().catch((err) => {
  console.error(`\n[generate-report failed] ${err.message}`);
  process.exit(1);
});