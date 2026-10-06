// Minimal Google/Firebase REST client helpers.
//
// Auth strategy (no service account required):
//   * Reuses the `firebase login` refresh token stored by firebase-tools
//     (configstore), or honours FIREBASE_REFRESH_TOKEN from .env, and mints a
//     short-lived access token from the Firebase CLI's public OAuth client.
//   * Later, when the project has a dedicated service account, set
//     GOOGLE_APPLICATION_CREDENTIALS and this module will prefer it.
//
// Firestore writes go through the Firestore v1 REST API (documented names use
// the "default" database id in the request path for this project).

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const FIREBASE_CLI_CLIENT_ID =
  "563584335869-fgrhgmd47bqnekij5i8b5pr03ho849e6.apps.googleusercontent.com";

// C2: the matching client secret lives ONLY in .env (loaded by the calling
// script's dotenv) — never in source. (It is Google's public Firebase CLI
// OAuth client, but this repo keeps the no-secrets-in-code rule absolute.)
// Read lazily inside getAccessToken so module-import order never snapshots a
// not-yet-loaded .env.

function findRefreshToken() {
  if (process.env.FIREBASE_REFRESH_TOKEN) return process.env.FIREBASE_REFRESH_TOKEN;
  const candidates = [
    path.join(os.homedir(), ".config", "configstore", "firebase-tools.json"),
    process.env.APPDATA ? path.join(process.env.APPDATA, "firebase", "tokens.json") : null,
    path.join(os.homedir(), ".config", "firebase-tools.json"),
  ].filter(Boolean);
  for (const file of candidates) {
    try {
      const raw = JSON.parse(fs.readFileSync(file, "utf8"));
      if (raw.tokens?.refresh_token) return raw.tokens.refresh_token;
    } catch {
      /* keep searching */
    }
  }
  throw new Error(
    "No Firebase refresh token found. Run `firebase login` or set FIREBASE_REFRESH_TOKEN in .env."
  );
}

let cachedToken = null;

export async function getAccessToken() {
  if (cachedToken?.expiresAt > Date.now() + 60_000) return cachedToken.value;
  const clientSecret = process.env.FIREBASE_CLI_CLIENT_SECRET;
  if (!clientSecret) {
    throw new Error(
      "FIREBASE_CLI_CLIENT_SECRET is missing from .env — copy .env.example and fill it in."
    );
  }
  const form = new URLSearchParams({
    grant_type: "refresh_token",
    client_id: FIREBASE_CLI_CLIENT_ID,
    client_secret: clientSecret,
    refresh_token: findRefreshToken(),
  });
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: form.toString(),
  });
  if (!res.ok) {
    throw new Error(`Failed to mint access token: ${res.status} ${await res.text()}`);
  }
  const data = await res.json();
  cachedToken = {
    value: data.access_token,
    expiresAt: Date.now() + data.expires_in * 1000,
  };
  return cachedToken.value;
}

const FIRESTORE_ROOT = (projectId) =>
  `https://firestore.googleapis.com/v1/projects/${projectId}/databases/default`;

export function fieldValue(value) {
  if (value === undefined || value === null) return null;
  if (typeof value === "boolean") return { booleanValue: value };
  if (typeof value === "number") {
    return Number.isInteger(value) ? { integerValue: String(value) } : { doubleValue: value };
  }
  if (value instanceof Date) return { timestampValue: value.toISOString() };
  if (Array.isArray(value)) return { arrayValue: { values: value.map(fieldValue).filter(Boolean) } };
  if (typeof value === "object") {
    return { mapValue: { fields: encodeFields(value) } };
  }
  return { stringValue: String(value) };
}

export function encodeFields(input) {
  const out = {};
  for (const [key, value] of Object.entries(input)) {
    const encoded = fieldValue(value);
    if (encoded) out[key] = encoded;
  }
  return out;
}

export async function getDocument(projectId, collection, docId) {
  const token = await getAccessToken();
  const url = `${FIRESTORE_ROOT(projectId)}/documents/${encodeURIComponent(collection)}/${encodeURIComponent(docId)}`;
  const res = await fetch(url, {
    headers: { authorization: `Bearer ${token}` },
  });
  if (res.status === 404) return null;
  if (!res.ok) throw new Error(`get ${collection}/${docId}: ${res.status} ${await res.text()}`);
  return res.json();
}

export async function createDocument(projectId, collection, docId, input) {
  const token = await getAccessToken();
  const url =
    `${FIRESTORE_ROOT(projectId)}/documents/${encodeURIComponent(collection)}` +
    `?documentId=${encodeURIComponent(docId)}`;
  const res = await fetch(url, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ fields: encodeFields(input) }),
  });
  if (res.status === 409) return { alreadyExists: true };
  if (!res.ok) {
    if (res.status === 404) {
      throw new Error(
        `create ${collection}/${docId}: database not ready (delete/recreate cooldown). ${await res.text()}`
      );
    }
    throw new Error(`create ${collection}/${docId}: ${res.status} ${await res.text()}`);
  }
  return res.json();
}

export async function writeDocument(projectId, collection, docId, input) {
  // Idempotent: create, falling back to a full replace when the doc exists.
  const created = await createDocument(projectId, collection, docId, input);
  if (!created?.alreadyExists) return created;

  const token = await getAccessToken();
  const url =
    `${FIRESTORE_ROOT(projectId)}/documents/${encodeURIComponent(collection)}/${encodeURIComponent(docId)}` +
    `?updateMask.fieldPaths=${encodeURIComponent("*")}`;
  const res = await fetch(url, {
    method: "PATCH",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ fields: encodeFields(input) }),
  });
  if (!res.ok) throw new Error(`write ${collection}/${docId}: ${res.status} ${await res.text()}`);
  return res.json();
}

export async function batchWrite(projectId, writes) {
  // Firestore v1 commit endpoint — fails atomically if any write conflicts.
  const token = await getAccessToken();
  const url = `${FIRESTORE_ROOT(projectId)}/documents:commit`;
  const documentWrites = writes
    .map((w) => ({
      update: {
        name: `${FIRESTORE_ROOT(projectId).replace("/databases/default", "")}/databases/default/documents/${encodeURIComponent(w.collection)}/${encodeURIComponent(w.docId)}`,
        fields: encodeFields(w.fields),
      },
      updateMask: { fieldPaths: Object.keys(w.fields) },
    }));
  const res = await fetch(url, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ writes: documentWrites }),
  });
  if (!res.ok) throw new Error(`batchWrite: ${res.status} ${await res.text()}`);
  return res.json();
}

const AUTH_SIGNUP = (apiKey) =>
  `https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${encodeURIComponent(apiKey)}`;

export async function createAuthUser(apiKey, email, password, displayName) {
  const res = await fetch(AUTH_SIGNUP(apiKey), {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email, password, displayName, returnSecureToken: true }),
  });
  const data = await res.json();
  if (!res.ok) {
    throw new Error(`createAuthUser(${email}): ${res.status} ${JSON.stringify(data)}`);
  }
  return data;
}