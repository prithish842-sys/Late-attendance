// Phase 4 SPARK FALLBACK — Admin operations without a Cloud Function.
//
// On the Blaze plan, functions/index.js handles admin ops:
//   - `commitImportBatch` / `adminSoftDelete` / `adminRestore` /
//     `adminPermanentDelete` HttpsCallable endpoints (admin role only).
// Spark has NO Cloud Functions, so this Admin SDK script is the equivalent
// server-side consumer of the SAME `admin_requests` collection, using the SAME
// logic (functions/admin-core.js validation/staging + functions/admin-scheduler.js
// execution). Append-only audit side effects (audit_logs, import_batches,
// deletion_records) are identical on both plans.
//
//   node scripts/process-admin.js                 # process pending admin_requests
//   node scripts/process-admin.js --list          # show pending admin_requests
//
// Requires scripts/service-account/key.json. Only the server writes
// audit_logs / import_batches / deletion_records; the client stays blocked
// (NEW_SECURITY.md §5, §8).

import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { config as loadEnv } from "dotenv";
import { runCommitImportBatch, runSoftDelete, runRestore, runPermanentDelete } from "../functions/admin-scheduler.js";

// Load firebase-admin through functions/' node_modules — the SAME copy
// admin-scheduler.js require("firebase-admin/firestore") with. Importing the
// separate copy under scripts/node_modules hands Firestore two different
// FieldValue classes, and every scheduler write dies with "Couldn't serialize
// object of type ServerTimestampTransform" (same fix as process-mail.js).
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
const db = getFirestore(app, "default");
db.settings({ ignoreUndefinedProperties: true });

/** Atomically claim a pending admin request so two runs never double-execute. */
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

async function processOne(doc) {
  const id = doc.id;
  const data = doc.data() || {};
  const type = data.type || "";
  const requestedBy = data.requestedBy || "scripts/process-admin.js";

  const ref = db.collection("admin_requests").doc(id);
  if (!(await claim(ref, id))) {
    return { id, skipped: true, reason: `status is not 'pending' (currently ${data.status || "?"})` };
  }

  try {
    let result;
    if (type === "import_batch") {
      result = await runCommitImportBatch({
        db,
        request: {
          importId: data.importId || id,
          filename: data.filename || null,
          departmentId: data.departmentId || null,
          department: data.department || null,
          rows: Array.isArray(data.rows) ? data.rows : [],
          requestedBy,
        },
      });
    } else if (type === "soft_delete") {
      result = await runSoftDelete({
        db,
        request: {
          studentIds: Array.isArray(data.studentIds) ? data.studentIds : [],
          reason: data.reason,
          deletedBy: requestedBy,
        },
      });
    } else if (type === "restore") {
      result = await runRestore({
        db,
        request: { studentIds: Array.isArray(data.studentIds) ? data.studentIds : [], restoredBy: requestedBy },
      });
    } else if (type === "permanent_delete") {
      result = await runPermanentDelete({
        db,
        request: { studentIds: Array.isArray(data.studentIds) ? data.studentIds : [], requestedBy },
      });
    } else {
      await ref.update({ status: "failed", error: "unknown admin_requests type: " + type, processedAt: FieldValue.serverTimestamp() });
      return { id, status: "failed", error: "unknown type " + type };
    }

    if (result.status === "abort") {
      await ref.update({
        status: "failed",
        error: `${result.code}: ${result.detail}`,
        processedAt: FieldValue.serverTimestamp(),
      });
      return { id, status: "failed", code: result.code, detail: result.detail };
    }

    await ref.update({
      status: "done",
      result,
      processedAt: FieldValue.serverTimestamp(),
    });
    return { id, type, status: "done", result };
  } catch (err) {
    await ref.update({
      status: "failed",
      error: err.message,
      processedAt: FieldValue.serverTimestamp(),
    });
    return { id, status: "failed", error: err.message };
  }
}

async function processQueue() {
  const pending = await db.collection("admin_requests").get();
  const docs = pending.docs.filter((d) => (d.data().status || "pending") === "pending");

  if (docs.length === 0) {
    console.log("No pending admin_requests entries to process.");
    return;
  }

  console.log(`\n[PROCESS] ${docs.length} pending admin request(s)\n`);
  for (const doc of docs) {
    const out = await processOne(doc);
    if (out.skipped) {
      console.log(`- ${out.id} — skipped: ${out.reason}`);
    } else if (out.status === "done") {
      const counts =
        out.type === "import_batch"
          ? `added ${out.result.added} / skipped ${out.result.skipped} (${out.result.counts?.warnings ?? 0} warnings)`
          : out.type === "soft_delete"
            ? `deleted ${out.result.deleted}${out.result.skipped?.length ? ` (skipped ${out.result.skipped.length})` : ""}`
            : out.type === "restore"
              ? `restored ${out.result.restored}${out.result.skipped?.length ? ` (skipped ${out.result.skipped.length})` : ""}`
              : out.type === "permanent_delete"
                ? `permanently deleted ${out.result.permanentlyDeleted}${out.result.skipped?.length ? ` (skipped ${out.result.skipped.length})` : ""}`
                : "done";
      console.log(`✓ ${out.id} — ${counts}`);
    } else {
      console.log(`✗ ${out.id} — ${out.status}: ${out.error || `${out.code}: ${out.detail}`}`);
    }
  }
}

async function list() {
  const pending = await db.collection("admin_requests").limit(20).get();
  console.log(`\nadmin_requests (recent ${pending.size}):`);
  if (pending.size === 0) console.log("  (empty)");
  for (const d of pending.docs) {
    const x = d.data();
    console.log(`  ${d.id} — ${x.status || "pending"} — ${x.type || "?"}${x.type === "soft_delete" || x.type === "restore" || x.type === "permanent_delete" ? ` — students ${(x.studentIds || []).length}` : ""}`);
    if (x.error) console.log(`       error: ${x.error}`);
  }
  console.log("");
}

async function main() {
  const args = process.argv.slice(2);
  if (args.includes("--list")) return list();
  await processQueue();
}

main().catch((err) => {
  console.error(`\n[process-admin failed] ${err.message}`);
  process.exit(1);
});