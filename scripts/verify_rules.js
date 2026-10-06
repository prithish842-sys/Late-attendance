// Live verification of the deployed role-gated Firestore rules (SECURITY.md §5).
// Signs in with the real demo accounts and tries operations via the v1 REST API.
// Idempotent: docs a check is allowed to create are removed afterwards via the
// Admin SDK, because the RULES THEMSELVES forbid client-side deletes.
//   node scripts/verify_rules.js
import { config as loadEnv } from "dotenv";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { initializeApp, cert } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
loadEnv({ path: path.join(path.dirname(fileURLToPath(import.meta.url)), "..", ".env") });

const API_KEY = process.env.FIREBASE_API_KEY;
const PROJECT = process.env.FIREBASE_PROJECT_ID || "late-attendance-5bf6d";
const ROOT = `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/default/documents`;

const adminApp = initializeApp({ credential: cert(path.join(path.dirname(fileURLToPath(import.meta.url)), "service-account/key.json")) });
const adminDb = getFirestore(adminApp, "default");
const created = []; // {collection, id} allowed to be created by a client, deleted via Admin SDK after

async function cleanupCreated() {
  for (const { collection, id } of created) {
    await adminDb.collection(collection).doc(id).delete();
  }
  if (created.length) console.log(`\ncleaned up ${created.length} verification doc(s) via Admin SDK (client deletes are blocked by design).`);
}

const pwd = (email, pw) =>
  fetch(`https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${API_KEY}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email, password: pw, returnSecureToken: true }),
  }).then((r) => r.json());

// Type-aware encoder: rules now demand real shapes (int attemptCount, list
// studentIds, timestamp requestedAt), so probes must send real types too.
const encodeValue = (v) => {
  if (v === null) return { nullValue: null };
  if (Array.isArray(v)) {
    // REST Value uses arrayValue.values (listValue is the SDK/protobuf name).
    return { arrayValue: { values: v.map((x) => ({ stringValue: String(x) })) } };
  }
  if (typeof v === "number") {
    return Number.isInteger(v) ? { integerValue: String(v) } : { doubleValue: String(v) };
  }
  if (typeof v === "boolean") return { booleanValue: v };
  if (v && typeof v === "object") return v; // already-encoded {timestampValue: ...}
  return { stringValue: String(v) };
};

async function tryWrite(idToken, collection, docId, fields, expected) {
  const url = `${ROOT}/${collection}?documentId=${encodeURIComponent(docId)}`;
  const body = { fields: Object.fromEntries(Object.entries(fields).map(([k, v]) => [k, encodeValue(v)])) };
  const res = await fetch(url, {
    method: "POST",
    headers: { authorization: `Bearer ${idToken}`, "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  const ok = res.ok;
  if (ok && expected === "allow") created.push({ collection, id: docId });
  const status = ok ? "ALLOWED" : `DENIED(${res.status})`;
  const pass = ok === (expected === "allow");
  console.log(`${pass ? "✓" : "✗"} ${collection}/${docId} → ${status} (expected ${expected})`);
  return pass;
}

async function tryUpdate(idToken, collection, docId, fields, expected) {
  const url = `${ROOT}/${collection}/${encodeURIComponent(docId)}?updateMask.fieldPaths=${encodeURIComponent("*")}`;
  const body = { fields: Object.fromEntries(Object.entries(fields).map(([k, v]) => [k, { stringValue: String(v) }])) };
  const res = await fetch(url, {
    method: "PATCH",
    headers: { authorization: `Bearer ${idToken}`, "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  const status = res.ok ? "ALLOWED" : `DENIED(${res.status})`;
  const pass = res.ok === (expected === "allow");
  console.log(`${pass ? "✓" : "✗"} UPDATE ${collection}/${docId} → ${status} (expected ${expected})`);
  return pass;
}

const suffix = `${Date.now().toString(36)}`;

// Test credentials come from .env only (FIREBASE_DEMO_* — see .env.example).
const PT_EMAIL = process.env.FIREBASE_DEMO_PT_SIR_EMAIL;
const PT_PASSWORD = process.env.FIREBASE_DEMO_PT_SIR_PASSWORD;
const ADMIN_EMAIL = process.env.FIREBASE_DEMO_ADMIN_EMAIL;
const ADMIN_PASSWORD = process.env.FIREBASE_DEMO_ADMIN_PASSWORD;
if (!PT_EMAIL || !PT_PASSWORD || !ADMIN_EMAIL || !ADMIN_PASSWORD) {
  console.error("missing FIREBASE_DEMO_PT_SIR_EMAIL/PASSWORD or FIREBASE_DEMO_ADMIN_EMAIL/PASSWORD in .env — see .env.example");
  process.exit(1);
}
const pt = await pwd(PT_EMAIL, PT_PASSWORD);
const admin = await pwd(ADMIN_EMAIL, ADMIN_PASSWORD);
for (const [name, tok] of [["pt_sir", pt], ["admin", admin]]) {
  if (tok.error) { console.log(`signin ${name} failed: ${JSON.stringify(tok.error)}`); process.exit(1); }
  console.log(`signed in: ${name} (${tok.idToken ? "has idToken" : "NO idToken"})`);
}

let all = true;
all &= await tryWrite(pt.idToken, "late_logs", `26BSC001_${suffix}`, { studentId: "26BSC001", scannedBy: pt.localId, scanMethod: "barcode", syncedOffline: "false" }, "allow");
// late_logs.create is pt_sir-only — even admin (or any other claim) is denied.
all &= await tryWrite(admin.idToken, "late_logs", `26BSC004_${suffix}`, { studentId: "26BSC004" }, "deny");
all &= await tryWrite(pt.idToken, "escalation_queue", `26BSC001_${suffix}`, { studentId: "26BSC001", count: 3, threshold: 3, status: "escalated", period: `${new Date().toISOString().slice(0, 7)}` }, "deny");
all &= await tryWrite(admin.idToken, "settings", `verify_${suffix}`, { escalationThreshold: "3" }, "allow");
all &= await tryWrite(pt.idToken, "settings", `verify_${suffix}`, { escalationThreshold: "1" }, "deny");

// ── Phase 3 mail_queue: staff enqueue requests, the server alone finalizes them ──
const mqId = `verify_${suffix}`;
const nowTs = () => ({ timestampValue: new Date().toISOString() });
const escalationShape = {
  departmentId: "BSC-CS",
  department: "B.SC CS",
  period: "2026-09",
  studentIds: ["26BSC008"],
  requestedBy: "verify_rules",
  status: "pending",
  attemptCount: 0,
  requestedAt: nowTs(),
};
all &= await tryWrite(pt.idToken, "mail_queue", mqId, escalationShape, "allow");
// C4 caps: a non-slug departmentId and an unknown key are both rejected.
all &= await tryWrite(pt.idToken, "mail_queue", `verify_long_${suffix}`, {
  ...escalationShape,
  departmentId: "D".repeat(65),
  requestedAt: nowTs(),
}, "deny");
all &= await tryWrite(pt.idToken, "mail_queue", `verify_extra_${suffix}`, {
  ...escalationShape,
  bloat: "not part of the contract",
  requestedAt: nowTs(),
}, "deny");
// The status/update path is server-only — even the requesting staff may not edit a queue doc.
all &= await tryUpdate(pt.idToken, "mail_queue", mqId, { status: "sent" }, "deny");
all &= await tryUpdate(admin.idToken, "mail_logs", `verify_${suffix}`, { studentsIncluded: ["26BSC008"] }, "deny");
all &= await tryUpdate(admin.idToken, "escalation_queue", `verify_${suffix}`, { status: "escalated" }, "deny");

// ── Phase 4 report_requests: staff enqueue intent, the server alone finalizes them ──
all &= await tryWrite(pt.idToken, "report_requests", `verify_${suffix}`, {
  periodType: "monthly",
  startDate: "2026-09-01",
  endDate: "2026-09-30",
  department: null,
  year: null,
  requestedBy: "verify_rules",
  status: "pending",
  attemptCount: 0,
  requestedAt: nowTs(),
}, "allow");
// C4 cap: periodType is an enum — anything else is rejected.
all &= await tryWrite(pt.idToken, "report_requests", `verify_enum_${suffix}`, {
  periodType: "hourly",
  startDate: "2026-09-01",
  endDate: "2026-09-01",
  department: null,
  year: null,
  requestedBy: "verify_rules",
  status: "pending",
  attemptCount: 0,
  requestedAt: nowTs(),
}, "deny");
// The status/update path is server-only — even the requesting staff may not edit a request doc.
all &= await tryUpdate(pt.idToken, "report_requests", `verify_${suffix}`, { status: "generated" }, "deny");
all &= await tryUpdate(admin.idToken, "report_logs", `verify_${suffix}`, { stats: "{}" }, "deny");

// ── Phase 5 offline_sync_flags: server-authoritative time validation ─────────
// The server (Blaze trigger / Spark runner) assesses synced-offline scans;
// clients may read the flags but can never write or edit them (SECURITY.md §2).
all &= await tryWrite(pt.idToken, "offline_sync_flags", `verify_${suffix}`, { reason: "within-tolerance", flagged: "false" }, "deny");
all &= await tryWrite(admin.idToken, "offline_sync_flags", `verify_a_${suffix}`, { reason: "within-tolerance", flagged: "false" }, "deny");
all &= await tryUpdate(pt.idToken, "offline_sync_flags", `verify_${suffix}`, { flagged: "true" }, "deny");
all &= await tryUpdate(admin.idToken, "offline_sync_flags", `verify_a_${suffix}`, { reason: "device-behind-server" }, "deny");

console.log(all ? "\nAll rules behave as designed." : "\nSOME RULE CHECKS FAILED.");
await cleanupCreated();
process.exit(all ? 0 : 1);