// QA Phase 8 — duplicate-mail suppression in the shared queue runner
// (functions/mail-queue-runner.js intentKey / findRecentlySentDuplicate /
// runMailQueueDoc). A double-tapped "Send to HOD" enqueues two identical
// docs; the runner must send one and terminal-fail the other instead of
// mailing the HOD twice. Run with `npm test`.
import test from "node:test";
import assert from "node:assert/strict";
import {
  intentKey,
  findRecentlySentDuplicate,
  runMailQueueDoc,
} from "../mail-queue-runner.js";

const ts = (ms) => ({ toMillis: () => ms });

const escalationRequest = (over = {}) => ({
  type: "escalation",
  departmentId: "BSC-CS",
  department: "B.Sc Computer Science",
  period: "2026-09",
  studentIds: ["26BSC001", "26BSC008"],
  requestedBy: "pt1",
  ...over,
});

test("intentKey: identical intents match, changed payload does not", () => {
  const a = intentKey(escalationRequest());
  assert.equal(a, intentKey(escalationRequest({ studentIds: ["26BSC008", "26BSC001"] })));
  assert.notEqual(a, intentKey(escalationRequest({ period: "2026-08" })));
  assert.notEqual(a, intentKey(escalationRequest({ departmentId: "BSC-IT" })));
  assert.notEqual(
    a,
    intentKey(escalationRequest({ studentIds: ["26BSC001"] })),
  );
  assert.notEqual(
    a,
    intentKey({
      type: "report",
      departmentId: "BSC-CS",
      startDate: "2026-09-01",
      endDate: "2026-09-07",
    }),
  );
});

test("findRecentlySentDuplicate: same intent sent inside the window is found", async () => {
  const nowMs = Date.UTC(2026, 8, 27, 8, 0, 0);
  const db = stubDb({
    sentDocs: [
      {
        id: "orig",
        data: {
          status: "sent",
          processedAt: ts(nowMs - 60_000),
          ...escalationRequest(),
        },
      },
    ],
  });
  const hit = await findRecentlySentDuplicate({
    db,
    request: escalationRequest(),
    nowMs,
  });
  assert.equal(hit?.id, "orig");
});

test("findRecentlySentDuplicate: window and payload differences are not duplicates", async () => {
  const nowMs = Date.UTC(2026, 8, 27, 8, 0, 0);
  const tooOld = stubDb({
    sentDocs: [
      {
        id: "old",
        data: {
          status: "sent",
          processedAt: ts(nowMs - 11 * 60_000),
          ...escalationRequest(),
        },
      },
    ],
  });
  assert.equal(
    await findRecentlySentDuplicate({ db: tooOld, request: escalationRequest(), nowMs }),
    null,
  );

  const different = stubDb({
    sentDocs: [
      {
        id: "other-period",
        data: {
          status: "sent",
          processedAt: ts(nowMs - 60_000),
          ...escalationRequest({ period: "2026-08" }),
        },
      },
    ],
  });
  assert.equal(
    await findRecentlySentDuplicate({ db: different, request: escalationRequest(), nowMs }),
    null,
  );
});

test("runMailQueueDoc: a duplicate intent is suppressed, not sent twice", async () => {
  const nowMs = Date.UTC(2026, 8, 27, 8, 0, 0);
  const docs = {
    dup: { status: "pending", attemptCount: 0, ...escalationRequest() },
  };
  const updates = [];
  const db = stubDb({
    queueDocs: docs,
    updates,
    sentDocs: [
      {
        id: "orig",
        data: {
          status: "sent",
          processedAt: ts(nowMs - 30_000),
          ...escalationRequest(),
        },
      },
    ],
  });

  const out = await runMailQueueDoc({
    db,
    id: "dup",
    data: docs.dup,
    config: { now: nowMs },
  });

  assert.equal(out.status, "failed");
  assert.equal(out.suppressedDuplicate, true);
  assert.equal(out.duplicateOf, "orig");
  assert.equal(docs.dup.status, "failed");
  assert.match(docs.dup.error, /duplicate request/i);
  assert.equal(docs.dup.duplicateOf, "orig");
  // The sender was never reached (no Resend call, no throw).
  assert.ok(!updates.some((u) => u.data.status === "sent"));
});

/** Minimal Firestore stub for the two shapes the runner touches. */
function stubDb({ queueDocs = {}, sentDocs = [], updates = [] }) {
  return {
    collection(name) {
      if (name !== "mail_queue") throw new Error(`unexpected collection ${name}`);
      return {
        doc(id) {
          return {
            id,
            firestore: {
              runTransaction: async (fn) => {
                await fn({
                  get: async () => ({
                    exists: Boolean(queueDocs[id]),
                    data: () => queueDocs[id],
                  }),
                  update: (_ref, data) => {
                    queueDocs[id] = { ...queueDocs[id], ...data };
                    updates.push({ id, data });
                  },
                  set: (_ref, data) => {
                    queueDocs[id] = { ...data };
                    updates.push({ id, data });
                  },
                });
              },
            },
            update: async (data) => {
              queueDocs[id] = { ...queueDocs[id], ...data };
              updates.push({ id, data });
            },
            set: async (data) => {
              queueDocs[id] = { ...data };
              updates.push({ id, data });
            },
          };
        },
        where(field, _op, value) {
          return {
            limit: () => ({
              get: async () => ({
                docs: sentDocs
                  .filter((d) => d.data[field] === value)
                  .map((d) => ({ id: d.id, data: () => d.data })),
              }),
            }),
          };
        },
      };
    },
  };
}
