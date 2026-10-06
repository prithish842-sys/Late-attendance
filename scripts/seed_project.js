// Phase 1 one-time import + demo-user helper.
//
// Usage (from the repo root):
//   node scripts/seed_project.js seed                          # students/departments/settings from seed/*.json
//   node scripts/seed_project.js csv <file.csv>                # bulk import: student_id,name,department,year,barcode
//   node scripts/seed_project.js adduser <email> [password]    # create a Firebase Auth login (demo/testing)
//
// Imports run via the Admin SDK (scripts/service-account/key.json) so they keep
// working under the hardened role-gated Firestore rules — the rules bypass the
// Admin SDK on purpose (docs/SECURITY.md §8). `adduser` uses the public Auth
// REST API (any signed-up user can exist; roles arrive via scripts/set_claims.js).
// No Firebase Storage is used in Phase 1 — student photos are stored as
// `photoBase64` directly in the Firestore document (demo-phase decision).

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { config as loadEnv } from "dotenv";
import { initializeApp, cert } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";

import { createAuthUser } from "./lib/firebase-rest.js";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
loadEnv({ path: path.join(ROOT, ".env") });

const PROJECT_ID = process.env.FIREBASE_PROJECT_ID || "late-attendance-5bf6d";
const PHOTOS_DIR = path.join(ROOT, "seed", "student-photos");
const README = "Seed data lives in seed/*.json — see docs/ARCHITECTURE.md §2 for the schema.";

const KEY = path.join(ROOT, "scripts", "service-account", "key.json");
if (!fs.existsSync(KEY)) throw new Error(`Service account key missing: ${KEY}`);

const app = initializeApp({
  credential: cert(KEY),
  projectId: PROJECT_ID,
});
const db = getFirestore(app, "default"); // this project's Firestore database id is "default"
db.settings({ ignoreUndefinedProperties: true });

function clean(value) {
  if (typeof value !== "string") return value;
  return value.replace(/\s*\(SAMPLE\)\s*$/i, "").trim();
}

function studentFields(record) {
  const fields = {
    name: record.name,
    department: record.department,
    phone: clean(record.phone || ""),
    barcode: clean(record.barcode || record.studentId || ""),
    photoUrl: "",
    active: true,
  };
  if (record.year !== undefined && record.year !== "") fields.year = String(record.year);
  // Real-data fields (studentSeedDoc shape): consumers read both — the
  // management-screen search uses registerNumber, filters fall back to names.
  if (record.studentId) fields.studentId = record.studentId;
  if (record.registerNumber) fields.registerNumber = record.registerNumber;
  if (record.departmentName) fields.departmentName = record.departmentName;
  // Mirrors the live roster: departmentId is only present on rows created via
  // the batch-import path (studentSeedDoc), not on the original seed rows —
  // consumers fall back to the `department` name when it is absent.
  if (record.departmentId) fields.departmentId = record.departmentId;

  let photoFile = record.photoFile;
  if (!photoFile && record.studentId) {
    const candidate = path.join(PHOTOS_DIR, `${record.studentId}.jpg`);
    if (fs.existsSync(candidate)) photoFile = `${record.studentId}.jpg`;
  }
  if (photoFile) {
    const photoPath = path.join(PHOTOS_DIR, photoFile);
    const raw = fs.readFileSync(photoPath);
    fields.photoBase64 = raw.toString("base64");
    fields.photoMimeType = "image/jpeg";
    fields.photoFile = photoFile;
  }
  return fields;
}

async function seedFromJson() {
  const students = JSON.parse(fs.readFileSync(path.join(ROOT, "seed", "students.json"), "utf8"));
  const departments = JSON.parse(fs.readFileSync(path.join(ROOT, "seed", "departments.json"), "utf8"));

  let count = 0;
  for (const dept of departments) {
    await db.collection("departments").doc(dept.id).set({
      id: dept.id,
      name: dept.name,
      hodEmail: dept.hodEmail,
    }, { merge: true });
    count++;
    console.log(`departments/${dept.id}`);
  }

  for (const student of students) {
    const existing = await db.collection("students").doc(student.studentId).get();
    if (existing.exists) {
      console.log(`students/${student.studentId} — skipped (already present)`);
      continue;
    }
    await db.collection("students").doc(student.studentId).set(studentFields(student));
    count++;
    console.log(`students/${student.studentId}`);
  }

  await db.collection("settings").doc("default").set({
    escalationThreshold: Number(process.env.DEFAULT_ESCALATION_THRESHOLD || 3),
    resetPeriod: process.env.DEFAULT_RESET_PERIOD || "monthly",
    notes: README,
  }, { merge: true });
  console.log("settings/default");

  console.log(`\nSeeded ${count} documents across students, departments, settings.`);
  console.log("late_logs and mail_logs are intentionally left empty — Firestore materializes them on first write.");
}

const CSV_COLUMNS = ["student_id", "name", "department", "year", "barcode"];

function parseCsv(text) {
  const rows = [];
  let row = [];
  let field = "";
  let inQuotes = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (inQuotes) {
      if (ch === '"') {
        if (text[i + 1] === '"') {
          field += '"';
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field += ch;
      }
    } else if (ch === '"') {
      inQuotes = true;
    } else if (ch === ",") {
      row.push(field);
      field = "";
    } else if (ch === "\n" || ch === "\r") {
      if (ch === "\r" && text[i + 1] === "\n") i++;
      row.push(field);
      field = "";
      if (row.some((cell) => cell.trim() !== "")) rows.push(row);
      row = [];
    } else {
      field += ch;
    }
  }
  row.push(field);
  if (row.some((cell) => cell.trim() !== "")) rows.push(row);
  return rows;
}

async function importCsv(csvPath) {
  const text = fs.readFileSync(csvPath, "utf8");
  const rows = parseCsv(text);
  if (rows.length < 2) throw new Error(`CSV is empty or missing a header row: ${csvPath}`);
  const header = rows[0].map((h) => h.trim().toLowerCase());
  for (const required of CSV_COLUMNS) {
    if (!header.includes(required)) {
      throw new Error(`CSV must contain columns: ${CSV_COLUMNS.join(", ")} (got: ${header.join(", ")})`);
    }
  }
  const idx = Object.fromEntries(CSV_COLUMNS.map((c) => [c, header.indexOf(c)]));
  let count = 0;
  for (const row of rows.slice(1)) {
    const record = {
      studentId: row[idx.student_id]?.trim(),
      name: row[idx.name]?.trim(),
      department: row[idx.department]?.trim(),
      year: row[idx.year]?.trim(),
      barcode: row[idx.barcode]?.trim(),
    };
    if (!record.studentId || !record.name) {
      console.warn("Skipping a CSV row with missing student_id/name:", JSON.stringify(record));
      continue;
    }
    const existing = await db.collection("students").doc(record.studentId).get();
    if (existing.exists) {
      console.log(`students/${record.studentId} — skipped (already present)`);
      continue;
    }
    await db.collection("students").doc(record.studentId).set(studentFields(record));
    count++;
    console.log(`students/${record.studentId}`);
  }
  console.log(`\nImported ${count} students from ${csvPath}.`);
  console.log("Note: bulk CSV rows carry no photo — add photoBase64 via the seed path or a later script.");
}

async function addUser(email, password) {
  const apiKey = process.env.FIREBASE_API_KEY;
  if (!apiKey) throw new Error("FIREBASE_API_KEY missing from .env");
  const generated = !password;
  if (generated) {
    password = Array.from({ length: 12 }, () =>
      "abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789".charAt(
        Math.floor(Math.random() * 58)
      )
    ).join("");
  }
  const data = await createAuthUser(apiKey, email, password, toTitle(email.split("@")[0], "pt-sir"));
  console.log(`Created Auth user: ${data.email} (uid ${data.localId})`);
  console.log("");
  if (generated) {
    console.log("  email:    " + email);
    console.log("  password: " + password);
    console.log("");
  }
  console.log("Sign-in method: Email/Password. Roles come from custom claims — set them with:");
  console.log(`  node scripts/set_claims.js ${email} pt_sir`);
  return { email, password, uid: data.localId };
}

function toTitle(part, append = "") {
  const base = String(part || "staff").replace(/[._-]/g, " ");
  const titled = base.replace(/\b\w/g, (c) => c.toUpperCase());
  return `${titled}${append ? ` (${append})` : ""}`;
}

async function main() {
  const [command, arg1, arg2] = process.argv.slice(2);
  switch (command) {
    case "seed":
      await seedFromJson();
      break;
    case "csv":
      if (!arg1) throw new Error("Usage: node scripts/seed_project.js csv <file.csv>");
      await importCsv(arg1);
      break;
    case "adduser":
      if (!arg1) throw new Error("Usage: node scripts/seed_project.js adduser <email> [password]");
      await addUser(arg1, arg2);
      break;
    default:
      throw new Error(
        "Unknown command. Use: seed | csv <file.csv> | adduser <email> [password]"
      );
  }
}

main().catch((err) => {
  console.error(`\n[import failed] ${err.message}`);
  process.exit(1);
});