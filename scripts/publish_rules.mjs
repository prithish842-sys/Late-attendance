// Publish firestore.rules (and storage.rules when present) to the live project
// using the Firebaserules REST API. The CLI deploy intermittently hangs on this
// box (docs/NOTES.md), so this mirrors the phase-2 in-session convention:
//   GET  none
//   POST projects/{project}/rulesets          (uploads the rules source)
//   PATCH projects/{project}/releases/{release}  (points the release at it)
//
// Usage: node scripts/publish_rules.mjs [--firestore|--storage]

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { config as loadEnv } from "dotenv";
import { getAccessToken } from "./lib/firebase-rest.js";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
loadEnv({ path: path.join(ROOT, ".env") });

const PROJECT = process.env.FIREBASE_PROJECT_ID || "late-attendance-5bf6d";
const RULES_ROOT = `https://firebaserules.googleapis.com/v1/projects/${PROJECT}`;

async function publish(releaseId, fileName, filePath) {
  if (!fs.existsSync(filePath)) {
    console.log(`skip ${fileName} — ${filePath} not present`);
    return;
  }
  const token = await getAccessToken();
  const content = fs.readFileSync(filePath, "utf8");

  const rs = await fetch(`${RULES_ROOT}/rulesets`, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ source: { files: [{ name: fileName, content }] } }),
  });
  const rsData = await rs.json();
  if (!rs.ok) throw new Error(`rulesets upload: ${rs.status} ${JSON.stringify(rsData)}`);
  console.log(`ruleset uploaded: ${rsData.name}`);

  const resourceName = `projects/${PROJECT}/releases/${releaseId}`;
  const rel = await fetch(`${RULES_ROOT}/releases/${releaseId}`, {
    method: "PATCH",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ release: { name: resourceName, rulesetName: rsData.name } }),
  });
  const relData = await rel.json();
  if (!rel.ok) throw new Error(`release ${releaseId}: ${rel.status} ${JSON.stringify(relData)}`);
  console.log(`released ${releaseId} → ${relData.rulesetName}`);
}

const RELEASE_IDS = { firestore: ["firestore.rules", "cloud.firestore/default"], storage: ["storage.rules", "firebase.storage"] };

const target = process.argv.includes("--storage") ? "storage" : "firestore";
const [fileName, releaseId] = RELEASE_IDS[target];
await publish(releaseId, fileName, path.join(ROOT, fileName));
console.log("\nRules published.");