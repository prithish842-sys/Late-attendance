// Pure unit tests for functions/offline-sync-core.js — device-vs-server time
// comparison for synced-offline scans (SECURITY.md §2). Run with `npm test` in
// functions/.
const test = require("node:test");
const assert = require("node:assert/strict");
const {
  OFFLINE_SYNC_TOLERANCE_MINUTES,
  scanDateFromLogId,
  discrepancyMinutes,
  assessOfflineScan,
  offlineSyncFlagDoc,
  flagRecentOfflineSyncs,
} = require("../offline-sync-core.js");

const at = (iso) => new Date(iso);

test("default tolerance is 10 minutes", () => {
  assert.equal(OFFLINE_SYNC_TOLERANCE_MINUTES, 10);
});

test("scanDateFromLogId extracts the deterministic date", () => {
  assert.equal(scanDateFromLogId("26BSC008_2026-09-24"), "2026-09-24");
  assert.equal(scanDateFromLogId("no-suffix"), null);
  assert.equal(scanDateFromLogId(""), null);
});

test("discrepancy is whole signed minutes server minus device", () => {
  assert.equal(discrepancyMinutes(at("2026-09-24T09:00:00Z"), at("2026-09-24T09:07:22Z")), 7);
  assert.equal(discrepancyMinutes(at("2026-09-24T09:05:40Z"), at("2026-09-24T09:00:00Z")), -6);
  assert.equal(discrepancyMinutes(at("2026-09-24T09:00:00Z"), at("2026-09-24T09:30:00Z")), 30);
});

test("accepts ISO strings and Firestore Timestamp-like inputs", () => {
  assert.equal(discrepancyMinutes("2026-09-24T09:00:00Z", { toDate: () => at("2026-09-24T09:01:00Z") }), 1);
});

test("unparseable timestamps return null discrepancy", () => {
  assert.equal(discrepancyMinutes(null, at("2026-09-24T09:00:00Z")), null);
  assert.equal(discrepancyMinutes(at("2026-09-24T09:00:00Z"), "garbage"), null);
  assert.equal(discrepancyMinutes("nope", "also-nope"), null);
});

test("within-tolerance scan is not flagged", () => {
  const r = assessOfflineScan("26BSC008_2026-09-24", {
    studentId: "26BSC008",
    deviceTimestamp: at("2026-09-24T09:00:00Z"),
    scanTimestamp: at("2026-09-24T09:02:00Z"),
  });
  assert.equal(r.flagged, false);
  assert.equal(r.reason, "within-tolerance");
  assert.equal(r.discrepancyMinutes, 2);
  assert.equal(r.date, "2026-09-24");
  assert.equal(r.studentId, "26BSC008");
});

test("device clock far behind server receipt is flagged for review", () => {
  const r = assessOfflineScan("26BSC008_2026-09-24", {
    studentId: "26BSC008",
    deviceTimestamp: at("2026-09-01T09:00:00Z"), // device says almost a month ago
    scanTimestamp: at("2026-09-24T09:00:00Z"),
  });
  assert.equal(r.flagged, true);
  assert.equal(r.reason, "device-behind-server");
  assert.ok(r.discrepancyMinutes > OFFLINE_SYNC_TOLERANCE_MINUTES);
});

test("device clock running ahead of the server is flagged too", () => {
  const r = assessOfflineScan("26BSC008_2026-09-24", {
    studentId: "26BSC008",
    deviceTimestamp: at("2026-09-24T09:20:00Z"),
    scanTimestamp: at("2026-09-24T09:00:00Z"),
  });
  assert.equal(r.flagged, true);
  assert.equal(r.reason, "device-ahead-of-server");
});

test("missing deviceTimestamp is itself a review reason", () => {
  const r = assessOfflineScan("26BSC008_2026-09-24", {
    studentId: "26BSC008",
    scanTimestamp: at("2026-09-24T09:00:00Z"),
  });
  assert.equal(r.flagged, true);
  assert.equal(r.reason, "missing-deviceTimestamp");
});

test("missing scanTimestamp is flagged as unverifiable", () => {
  const r = assessOfflineScan("26BSC008_2026-09-24", {
    studentId: "26BSC008",
    deviceTimestamp: at("2026-09-24T09:00:00Z"),
  });
  assert.equal(r.flagged, true);
  assert.equal(r.reason, "missing-scanTimestamp");
});

test("tolerance is configurable", () => {
  const log = {
    studentId: "26BSC008",
    deviceTimestamp: at("2026-09-24T09:00:00Z"),
    scanTimestamp: at("2026-09-24T09:12:00Z"),
  };
  assert.equal(assessOfflineScan("26BSC008_2026-09-24", log).flagged, true); // 12 min > default 10

  const relaxed = assessOfflineScan("26BSC008_2026-09-24", log, { toleranceMinutes: 15 });
  assert.equal(relaxed.flagged, false);

  const strict = assessOfflineScan("26BSC008_2026-09-24", log, { toleranceMinutes: 5 });
  assert.equal(strict.flagged, true);
});

test("flag doc carries the assessment + assessment time", () => {
  const a = assessOfflineScan("26BSC008_2026-09-24", {
    studentId: "26BSC008",
    deviceTimestamp: at("2026-09-24T09:00:00Z"),
    scanTimestamp: at("2026-09-24T09:01:00Z"),
  });
  const doc = offlineSyncFlagDoc(a, { assessedAt: at("2026-09-24T10:00:00Z") });
  assert.equal(doc.logId, "26BSC008_2026-09-24");
  assert.equal(doc.flagged, false);
  assert.equal(doc.discrepancyMinutes, 1);
  assert.equal(doc.assessedAt.toISOString(), at("2026-09-24T10:00:00Z").toISOString());
});

test("flagRecentOfflineSyncs dry-run assesses without writing", async () => {
  const written = {};
  const db = stubDb({
    "26BSC008_2026-09-24": { studentId: "26BSC008", syncedOffline: true, deviceTimestamp: at("2026-09-24T09:00:00Z"), scanTimestamp: at("2026-09-24T09:00:30Z") },
    "26BSC010_2026-09-24": { studentId: "26BSC010", syncedOffline: true, deviceTimestamp: at("2026-09-01T09:00:00Z"), scanTimestamp: at("2026-09-24T09:00:00Z") },
  }, written);

  const r = await flagRecentOfflineSyncs({ db, dryRun: true, now: at("2026-09-24T12:00:00Z") });
  assert.equal(r.assessed, 2);
  assert.equal(r.flagged, 1);
  assert.deepEqual(Object.keys(written), []);
  assert.equal(r.assessments.length, 2);
  assert.equal(r.assessments[0].logId, "26BSC008_2026-09-24");
});

test("flagRecentOfflineSyncs writes only for logs without an existing flag", async () => {
  const written = {};
  const db = stubDb({
    "26BSC008_2026-09-24": { studentId: "26BSC008", syncedOffline: true, deviceTimestamp: at("2026-09-24T09:00:00Z"), scanTimestamp: at("2026-09-24T09:00:30Z") },
    "26BSC010_2026-09-24": { studentId: "26BSC010", syncedOffline: true, deviceTimestamp: at("2026-09-01T09:00:00Z"), scanTimestamp: at("2026-09-24T09:00:00Z") },
  }, written, { existingFlags: new Set(["26BSC008_2026-09-24"]) });

  const r = await flagRecentOfflineSyncs({ db, now: at("2026-09-24T12:00:00Z") });
  assert.equal(r.already, 1);
  assert.equal(r.assessed, 1);
  assert.equal(r.flagged, 1);
  assert.deepEqual(Object.keys(written), ["26BSC010_2026-09-24"]);
  assert.equal(written["26BSC010_2026-09-24"].flagged, true);
});

const ISO = (d) => d.toISOString();
/** Minimal in-memory stand-in for the Firestore surface the core uses. */
function stubDb(logs, written, { existingFlags = new Set() } = {}) {
  const docs = Object.entries(logs).map(([id, data]) => ({ id, data: () => data }));
  return {
    collection() {
      return {
        where() {
          return { get: async () => ({ docs }) };
        },
        doc(id) {
          return {
            get: async () => ({ exists: existingFlags.has(id) }),
            set: async (v) => {
              written[id] = { ...v, assessedAt: v.assessedAt instanceof Date ? ISO(v.assessedAt) : v.assessedAt };
            },
          };
        },
      };
    },
  };
}