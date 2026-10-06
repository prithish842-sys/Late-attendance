// Unit tests for functions/rate-limit.js — the B5 sliding-window limiter
// behind all 8 callables. The Firestore surface is faked in-memory (the real
// one is a transaction over `rate_limits/{uid}_{bucket}`); time is injected.
// Run with `npm test` in functions/.
import test from "node:test";
import assert from "node:assert/strict";
import {
  LIMITS,
  slidingWindowCheck,
  enforceRateLimit,
} from "../rate-limit.js";

const HOUR = 60 * 60 * 1000;

/** Minimal in-memory stand-in for the Admin SDK Firestore surface used here. */
function fakeDb() {
  const docs = new Map(); // "coll/id" -> data
  const refFor = (path) => ({
    async get() {
      const data = docs.get(path);
      return { exists: data !== undefined, data: () => data };
    },
    set(data) {
      docs.set(path, data);
    },
  });
  return {
    docs,
    collection(name) {
      return { doc: (id) => refFor(`${name}/${id}`) };
    },
    async runTransaction(fn) {
      return fn({
        async get(ref) {
          return ref.get();
        },
        set(ref, data) {
          ref.set(data);
        },
      });
    },
  };
}

test("LIMITS covers every bucket the callables use", () => {
  assert.deepEqual(Object.keys(LIMITS).sort(), [
    "admin_write",
    "import",
    "mail_send",
    "report",
  ]);
  for (const { max, windowMs } of Object.values(LIMITS)) {
    assert.ok(max >= 1 && max <= 100, "sane per-hour cap");
    assert.equal(windowMs, HOUR, "fixed 1-hour window");
  }
});

test("slidingWindowCheck allows under the cap and prunes stale events", () => {
  const now = 10 * HOUR;
  const stale = now - HOUR - 1;
  const check = slidingWindowCheck([stale, stale, stale], 3, HOUR, now);
  assert.equal(check.allowed, true);
  assert.deepEqual(check.events, [], "events older than the window are pruned");
});

test("slidingWindowCheck denies at the cap with a positive retry hint", () => {
  const now = 1000;
  const events = [now - 500, now - 400, now - 300];
  const check = slidingWindowCheck(events, 3, HOUR, now);
  assert.equal(check.allowed, false);
  assert.ok(check.retryAfterSec >= 1);
  assert.equal(check.retryAfterSec, Math.ceil((HOUR - 500) / 1000));
});

test("enforceRateLimit records up to the cap, then throws resource-exhausted", async () => {
  const db = fakeDb();
  let now = 1000;
  for (let i = 0; i < 3; i++) {
    await enforceRateLimit(db, { uid: "uid-1", bucket: "mail_send", max: 3, windowMs: HOUR, now });
    now += 10;
  }
  const doc = db.docs.get("rate_limits/uid-1_mail_send");
  assert.equal(doc.events.length, 3);

  await assert.rejects(
    () => enforceRateLimit(db, { uid: "uid-1", bucket: "mail_send", max: 3, windowMs: HOUR, now }),
    (err) => {
      assert.equal(err.code, "resource-exhausted");
      assert.ok(err.details.retryAfterSec >= 1);
      return true;
    }
  );
  // The rejected attempt must NOT have been recorded.
  assert.equal(db.docs.get("rate_limits/uid-1_mail_send").events.length, 3);
});

test("enforceRateLimit is per-uid and per-bucket", async () => {
  const db = fakeDb();
  const args = { bucket: "mail_send", max: 1, windowMs: HOUR, now: 500 };
  await enforceRateLimit(db, { uid: "uid-a", ...args });
  // uid-b unaffected by uid-a's spend.
  await enforceRateLimit(db, { uid: "uid-b", ...args });
  // A different bucket for uid-a still has its own budget.
  await enforceRateLimit(db, { uid: "uid-a", bucket: "report", max: 1, windowMs: HOUR, now: 500 });
  assert.ok(db.docs.has("rate_limits/uid-a_mail_send"));
  assert.ok(db.docs.has("rate_limits/uid-b_mail_send"));
  assert.ok(db.docs.has("rate_limits/uid-a_report"));
});

test("enforceRateLimit allows again once the window has slid past old events", async () => {
  const db = fakeDb();
  const start = 1000;
  await enforceRateLimit(db, { uid: "uid-1", bucket: "import", max: 1, windowMs: HOUR, now: start });
  await assert.rejects(
    () => enforceRateLimit(db, { uid: "uid-1", bucket: "import", max: 1, windowMs: HOUR, now: start + 60_000 }),
    (err) => err.code === "resource-exhausted"
  );
  // Past the window: the stored event is stale and the bucket refills.
  await enforceRateLimit(db, {
    uid: "uid-1",
    bucket: "import",
    max: 1,
    windowMs: HOUR,
    now: start + HOUR + 1,
  });
  assert.equal(db.docs.get("rate_limits/uid-1_import").events.length, 1);
});

test("unknown bucket or missing uid fails fast as a programmer error", async () => {
  const db = fakeDb();
  await assert.rejects(
    () => enforceRateLimit(db, { uid: "uid-1", bucket: "nope" }),
    /unknown bucket/
  );
  await assert.rejects(
    () => enforceRateLimit(db, { uid: null, bucket: "report" }),
    /uid is required/
  );
});
