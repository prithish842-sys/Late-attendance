// Dependency tests for the pure HOD mail building blocks (functions/mail-core.js).
// Run from the functions/ dir: node --test test/mail-core.test.js
import test from "node:test";
import assert from "node:assert/strict";
import {
  esc,
  formatDate,
  formatTime,
  normalizeToken,
  resolveDepartment,
  buildMailHtml,
  buildXlsxAttachment,
  buildPdfAttachment,
  sendViaResend,
  mailLogDoc,
} from "../mail-core.js";

const depts = [
  { id: "BSC-CS", name: "B.Sc Computer Science", hodEmail: "hod@bsc.example" },
  { id: "BCA", name: "BCA", hodEmail: "hod@bca.example" },
];

const student = {
  studentId: "26BSC008",
  name: "BHAGYADHARSHINI V",
  department: "B.SC CS",
  year: "",
  count: 3,
  dates: [
    { date: "2026-09-03", time: "08:41" },
    { date: "2026-09-07", time: "08:55" },
    { date: "2026-09-10", time: "09:02" },
  ],
  photo: { base64: "aGVsbG8=", mimeType: "image/jpeg" },
};

test("normalizeToken strips everything non-alphanumeric", () => {
  assert.equal(normalizeToken("B.SC CS"), "bsccs");
  assert.equal(normalizeToken(" B.Sc Computer Science "), "bsccomputerscience");
  assert.equal(normalizeToken(""), "");
});

test("resolveDepartment matches a student display string to a dept id by normalization", () => {
  const r = resolveDepartment("B.SC CS", depts);
  assert.deepEqual(r, { departmentId: "BSC-CS", name: "B.Sc Computer Science", hodEmail: "hod@bsc.example" });
});

test("resolveDepartment matches on exact name too", () => {
  assert.equal(resolveDepartment("BCA", depts).departmentId, "BCA");
});

test("resolveDepartment returns null on no match or ambiguity", () => {
  assert.equal(resolveDepartment("Not a dept", depts), null);
  assert.equal(resolveDepartment("", depts), null);
  assert.equal(resolveDepartment("B.SC CS", null), null);
  assert.equal(resolveDepartment("dup", [{ id: "A1", name: "dup" }, { id: "A2", name: "dup" }]), null);
});

test("formatDate/formatTime produce tabular YYYY-MM-DD and HH:MM", () => {
  const d = new Date(Date.UTC(2026, 8, 3, 8, 41, 20));
  assert.equal(formatDate(d), "2026-09-03");
  assert.equal(formatTime(d), "08:41");
});

test("buildMailHtml embeds a single student with photo cid and late-dates table", () => {
  const html = buildMailHtml({
    collegeName: "Sankara College of Science & Commerce",
    departmentName: "B.Sc Computer Science",
    period: "2026-09",
    threshold: 3,
    students: [student],
  });
  assert.match(html, /BHAGYADHARSHINI V/);
  assert.match(html, /26BSC008/);
  assert.match(html, /cid:photo_26BSC008/);
  assert.match(html, /2026-09-03/);
  assert.match(html, /08:41/);
  assert.match(html, /3 late arrivals this period/);
  // Threshold from settings (not the count field)
  assert.match(html, /threshold: 3/);
});

test("buildMailHtml escapes student-controlled HTML and bundles multiple students", () => {
  const evil = { ...student, studentId: '26BSC001", "bad": "x', name: "<script>alert(1)</script>" };
  const html = buildMailHtml({ departmentName: "B.Sc Computer Science", period: "2026-09", threshold: 3, students: [student, evil] });
  assert.ok(!html.includes("<script>"), "student name is escaped");
  assert.ok(html.includes("&lt;script&gt;"), "escaped name present");
  assert.match(html, /have each been late <strong>/);
});

test("buildMailHtml: dates come from late_logs, never the queue doc id", () => {
  const s = { ...student, dates: [] };
  const html = buildMailHtml({ departmentName: "B.Sc Computer Science", period: "2026-09", threshold: 3, students: [s] });
  assert.match(html, /No individual dates recorded/);
  assert.ok(!html.includes("2026-09-03"));
});

test("buildXlsxAttachment returns a real xlsx zip buffer", async () => {
  const buf = await buildXlsxAttachment([student], { period: "2026-09", departmentName: "B.Sc Computer Science" });
  assert.ok(Buffer.isBuffer(buf));
  assert.ok(buf.byteLength > 500);
  assert.equal(buf.subarray(0, 2).toString(), "PK", "xlsx is a zip container");
});

test("buildPdfAttachment returns a real PDF buffer", async () => {
  const buf = await buildPdfAttachment([student], { period: "2026-09", departmentName: "B.Sc Computer Science" });
  assert.ok(Buffer.isBuffer(buf));
  assert.ok(buf.byteLength > 500);
  assert.equal(buf.subarray(0, 5).toString(), "%PDF-");
});

test("sendViaResend: succeeds with an id and posts base64 attachments", async () => {
  const calls = [];
  globalThis.fetch = async (url, opts) => {
    calls.push({ url, opts });
    return { ok: true, json: async () => ({ id: "resend_123" }) };
  };
  const data = await sendViaResend({
    apiKey: "re_test",
    from: "a@b.c",
    to: "hod@bsc.example",
    subject: "s",
    html: "<p>hi</p>",
    attachments: [{ filename: "a.xlsx", content: Buffer.from("X").toString("base64") }],
  });
  assert.equal(data.id, "resend_123");
  assert.equal(calls[0].url, "https://api.resend.com/emails");
  assert.equal(calls[0].opts.headers.authorization, "Bearer re_test");
  const body = JSON.parse(calls[0].opts.body);
  assert.equal(body.from, "a@b.c");
  assert.equal(body.to, "hod@bsc.example");
  assert.equal(body.attachments[0].content, Buffer.from("X").toString("base64"));
  delete globalThis.fetch;
});

test("sendViaResend: refuses to run without a key (SECURITY.md §6)", async () => {
  await assert.rejects(
    () => sendViaResend({ from: "a", to: "b", subject: "s", html: "x" }),
    (err) => err.code === "RESEND_KEY_MISSING"
  );
});

test("sendViaResend: surfaces a Resend error with status", async () => {
  globalThis.fetch = async () => ({ ok: false, json: async () => ({ message: "rate limit" }) });
  await assert.rejects(
    () => sendViaResend({ apiKey: "k", from: "a", to: "b", subject: "s", html: "x" }),
    (err) => err.code === "RESEND_API_ERROR" && err.status === undefined
  );
  delete globalThis.fetch;
});

test("mailLogDoc carries the audit trail schema", () => {
  const doc = mailLogDoc({
    departmentId: "BSC-CS",
    department: "B.Sc Computer Science",
    period: "2026-09",
    to: "hod@bsc.example",
    subject: "s",
    studentsIncluded: ["26BSC008"],
    triggeredBy: "uid-1",
    mailRequestId: "q-1",
    resendId: "r-1",
  });
  assert.deepEqual(doc, {
    departmentId: "BSC-CS",
    department: "B.Sc Computer Science",
    period: "2026-09",
    to: "hod@bsc.example",
    subject: "s",
    studentsIncluded: ["26BSC008"],
    triggeredBy: "uid-1",
    mailRequestId: "q-1",
    resendId: "r-1",
  });
});

test("esc protects mail-obfuscating characters", () => {
  assert.equal(esc('<a href="x">&'), "&lt;a href=&quot;x&quot;&gt;&amp;");
});