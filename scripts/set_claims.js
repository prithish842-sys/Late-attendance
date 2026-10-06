// Phase 2 — assign Firebase Auth custom claims (roles) using the Admin SDK.
//
// Roles (NEW_SECURITY.md): exactly two — pt_sir | admin (no third role).
// Claims live inside the user's ID token (`token.role`) and are the only thing
// Firestore rules trust (docs/SECURITY.md §5). The client app can never set them.
//
// Usage (from the repo root):
//   node scripts/set_claims.js <email> <role> [name]
//   node scripts/set_claims.js sync          # apply role + staff doc for .env demo accounts
//
// Requires the service account key at scripts/service-account/key.json
// (gitignored). Created once via the IAM admin API — see docs/NOTES.md.

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
if (!fs.existsSync(KEY)) {
  throw new Error(`Service account key missing: ${KEY}`);
}

const app = initializeApp({
  credential: cert(KEY),
  projectId: process.env.FIREBASE_PROJECT_ID || "late-attendance-5bf6d",
});
const auth = getAuth(app);
// This project's Firestore database id is literally "default" (not "(default)").
const db = getFirestore(app, "default");
db.settings({ ignoreUndefinedProperties: true });

const ROLE_NAMES = ["pt_sir", "admin"];

function titleCase(name) {
  return String(name || "Staff")
    .replace(/[._-]/g, " ")
    .replace(/\b\w/g, (c) => c.toUpperCase());
}

async function setClaims({ email, role }) {
  if (!ROLE_NAMES.includes(role)) {
    throw new Error(`Unknown role '${role}'. Use one of: ${ROLE_NAMES.join(", ")}`);
  }
  const user = await auth.getUserByEmail(email);
  await auth.setCustomUserClaims(user.uid, { role });
  // staff/{uid} mirrors the claim for display + rule-friendly lookups.
  await db.collection("staff").doc(user.uid).set(
    {
      uid: user.uid,
      name: titleCase(email.split("@")[0]),
      email,
      role,
      updatedAt: new Date(),
    },
    { merge: true }
  );
  console.log(`role=${role} → ${email} (uid ${user.uid})`);
  return user;
}

async function syncFromEnv() {
  // Demo accounts (see .env.example) — the env file is the only place they live;
  // skip any that are unset so this never falls back to a hardcoded address.
  const entries = ["FIREBASE_DEMO_PT_SIR_EMAIL", "FIREBASE_DEMO_ADMIN_EMAIL"];
  let synced = 0;
  for (const envKey of entries) {
    const email = process.env[envKey];
    if (!email) {
      console.warn(`skip: ${envKey} not set in .env`);
      continue;
    }
    const role = process.env[`${envKey.replace("EMAIL", "ROLE")}`];
    if (!ROLE_NAMES.includes(role)) {
      console.warn(`skip ${email}: ${envKey.replace("EMAIL", "ROLE")} must be one of ${ROLE_NAMES.join(", ")}`);
      continue;
    }
    try {
      await setClaims({ email, role });
      synced++;
    } catch (err) {
      console.warn(`skip ${email}: ${err.message}`);
    }
  }
  if (!synced) console.warn("sync: no demo accounts configured in .env — nothing applied.");
}

async function main() {
  const [command, arg1] = process.argv.slice(2);
  if (command === "sync") {
    await syncFromEnv();
    return;
  }
  if (!command || !arg1) {
    throw new Error("Usage: node scripts/set_claims.js <email> <pt_sir|admin>");
  }
  await setClaims({ email: command, role: arg1 });
}

main().catch((err) => {
  console.error(`\n[set_claims failed] ${err.message}`);
  process.exit(1);
});