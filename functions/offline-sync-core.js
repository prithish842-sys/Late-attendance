// Pure offline-sync time-validation logic — CommonJS so functions/index.js
// (require) and the Spark runner (scripts/process-offline-sync.js) share it.
//
// SECURITY.md §2: an offline scan stores `deviceTimestamp` + `syncedOffline: true`
// and is written to late_logs when the phone reconnects; `scanTimestamp` then
// becomes the SERVER receipt time. The server compares the device clock against
// that receipt — a large mismatch is flagged for admin review instead of being
// trusted silently. Nothing here runs on the client (SECURITY.md §8: decision
// writes originate from the server only).

/** Default tolerance: device clock may differ from server by this many minutes. */
const OFFLINE_SYNC_TOLERANCE_MINUTES = 10;

/** Date part (`YYYY-MM-DD`) of a deterministic late_logs id, else null. */
function scanDateFromLogId(logId) {
  const m = /_(\d{4}-\d{2}-\d{2})$/.exec(String(logId || ""));
  return m ? m[1] : null;
}

/** Normalise a Date / ISO string / Firestore Timestamp-like value to a Date. */
function toDate(value) {
  if (!value) return null;
  if (value instanceof Date) return Number.isNaN(value.getTime()) ? null : value;
  if (typeof value.toDate === "function") {
    const d = value.toDate();
    return d instanceof Date && !Number.isNaN(d.getTime()) ? d : null;
  }
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? null : d;
}

/**
 * Whole minutes the server receipt came after the device clock (signed):
 * positive = device was behind server, negative = device clock ran ahead.
 * Returns null when either timestamp is unparseable.
 */
function discrepancyMinutes(deviceTimestamp, scanTimestamp) {
  const device = toDate(deviceTimestamp);
  const server = toDate(scanTimestamp);
  if (!device || !server) return null;
  return Math.round((server.getTime() - device.getTime()) / 60000);
}

/**
 * Compare one synced-offline late_log against server receipt time
 * (SECURITY.md §2). `log` is the late_logs doc data; `logId` supplies the
 * deterministic date the entry claims. Never throws — an unparseable or
 * missing timestamp is itself a reason to flag for review.
 */
function assessOfflineScan(logId, log, { toleranceMinutes = OFFLINE_SYNC_TOLERANCE_MINUTES } = {}) {
  const studentId = String(log.studentId || String(logId || "").split("_")[0] || "");
  const date = scanDateFromLogId(logId);
  const device = toDate(log.deviceTimestamp);
  const server = toDate(log.scanTimestamp);

  if (!device) {
    return {
      logId,
      studentId,
      date,
      deviceTimestamp: null,
      scanTimestamp: server,
      discrepancyMinutes: null,
      toleranceMinutes,
      flagged: true,
      reason: "missing-deviceTimestamp",
    };
  }
  if (!server) {
    return {
      logId,
      studentId,
      date,
      deviceTimestamp: device,
      scanTimestamp: null,
      discrepancyMinutes: null,
      toleranceMinutes,
      flagged: true,
      reason: "missing-scanTimestamp",
    };
  }

  const discrepancy = discrepancyMinutes(device, server);
  const flagged = Math.abs(discrepancy) > toleranceMinutes;
  return {
    logId,
    studentId,
    date,
    deviceTimestamp: device,
    scanTimestamp: server,
    discrepancyMinutes: discrepancy,
    toleranceMinutes,
    flagged,
    reason: !flagged
      ? "within-tolerance"
      : discrepancy > 0
        ? "device-behind-server"
        : "device-ahead-of-server",
  };
}

/** Fields for the offline_sync_flags doc `{logId}` (server-writes only). */
function offlineSyncFlagDoc(assessment, { assessedAt = new Date() } = {}) {
  return {
    logId: assessment.logId,
    studentId: assessment.studentId,
    date: assessment.date,
    deviceTimestamp: assessment.deviceTimestamp,
    scanTimestamp: assessment.scanTimestamp,
    discrepancyMinutes: assessment.discrepancyMinutes,
    toleranceMinutes: assessment.toleranceMinutes,
    flagged: assessment.flagged,
    reason: assessment.reason,
    assessedAt,
  };
}

/**
 * Assess every recent `syncedOffline` late_log that has not been flagged yet
 * and write its offline_sync_flags doc. The Spark path for this is the runner
 * scripts/process-offline-sync.js (Admin SDK bypasses rules, SECURITY.md §8);
 * the Blaze path writes the flag inline from the escalateLateLog trigger.
 * Recency-bounded so re-runs stay cheap; already-flagged docs are skipped.
 * Pass `dryRun: true` to assess without writing (returns the assessments).
 */
async function flagRecentOfflineSyncs({
  db,
  now = new Date(),
  toleranceMinutes = OFFLINE_SYNC_TOLERANCE_MINUTES,
  recentDays = 30,
  dryRun = false,
} = {}) {
  const cutoff = new Date(now.getTime() - recentDays * 86400000);
  const snap = await db.collection("late_logs").where("syncedOffline", "==", true).get();

  let assessed = 0;
  let flagged = 0;
  let already = 0;
  let skipped = 0;
  const assessments = [];

  for (const doc of snap.docs) {
    const data = doc.data() || {};
    const stamp = toDate(data.scanTimestamp);
    if (stamp && stamp < cutoff) {
      skipped++;
      continue;
    }
    const assessment = assessOfflineScan(doc.id, data, { toleranceMinutes });
    if (!dryRun) {
      const flagRef = db.collection("offline_sync_flags").doc(doc.id);
      const existing = await flagRef.get();
      if (existing.exists) {
        already++;
        continue;
      }
      await flagRef.set(offlineSyncFlagDoc(assessment, { assessedAt: now }));
    }
    assessments.push(assessment);
    assessed++;
    if (assessment.flagged) flagged++;
  }

  return { assessed, flagged, already, skipped, dryRun, assessments };
}

module.exports = {
  OFFLINE_SYNC_TOLERANCE_MINUTES,
  scanDateFromLogId,
  toDate,
  discrepancyMinutes,
  assessOfflineScan,
  offlineSyncFlagDoc,
  flagRecentOfflineSyncs,
};
