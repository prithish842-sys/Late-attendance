// Shared mail orchestration — the stage between the escalation_queue data and
// the Resend call. Used by BOTH runtime paths so behaviour never diverges:
//
//   - Blaze:  functions/index.js processMailQueue Cloud Function (or the
//             sendEscalationMail callable) calls processQueuedMail().
//   - Spark:  scripts/process-mail.js Admin-SDK runner calls processQueuedMail().
//
// Server-authoritative only (docs/SECURITY.md §8): this runs with admin
// privileges, reads escalation_queue / late_logs / students, builds the mail,
// sends via Resend, and writes the mail_logs audit record. The client never
// touches any decision here — it only enqueues mail_queue requests.

const { FieldValue } = require("firebase-admin/firestore");
const {
  formatDate,
  formatTime,
  normalizeToken,
  resolveDepartment,
  buildMailHtml,
  buildXlsxAttachment,
  buildPdfAttachment,
  sendViaResend,
  mailLogDoc,
} = require("./mail-core.js");

const DEFAULT_FROM = "Sankara College of Science & Commerce <onboarding@resend.dev>";

function defaultFrom() {
  const name = process.env.RESEND_FROM_NAME;
  const email = process.env.RESEND_FROM_EMAIL;
  if (email) return name ? `${name} <${email}>` : email;
  return DEFAULT_FROM;
}

async function loadSettings(db) {
  const snap = await db.collection("settings").doc("default").get();
  const data = snap.exists ? snap.data() : {};
  const threshold = Number.isInteger(data.escalationThreshold) && data.escalationThreshold > 0
    ? data.escalationThreshold
    : 3;
  return { threshold, resetPeriod: data.resetPeriod || "monthly" };
}

async function loadDepartments(db) {
  const snap = await db.collection("departments").get();
  return snap.docs.map((d) => ({ id: d.id, ...d.data() }));
}

/**
 * Resolve the department an escalation mail targets. `request.departmentId` is
 * preferred; otherwise the request's display `department` string is fuzzy
 * matched against the departments collection (functions/mail-core.js
 * resolveDepartment). Returns {departmentId, name, hodEmail} or null.
 */
async function resolveRequestDepartment(db, request) {
  if (!db || !request) return null;
  const docs = await loadDepartments(db);
  const needle = request.departmentId || request.department || "";
  return resolveDepartment(needle, docs);
}

/**
 * Which escalated_queue docs belong to this request: period matches, optional
 * studentId allow-list, and (when resolvable) the department matches.
 */
async function loadEscalatedStudents(db, request, resolved) {
  const period = request.period;
  const wantIds = new Set((request.studentIds || []).filter(Boolean));
  const target = resolved
    ? normalizeToken(resolved.departmentId) || normalizeToken(resolved.name)
    : normalizeToken(request.departmentId || request.department);

  const snap = await db.collection("escalation_queue")
    .where("status", "==", "escalated")
    .get();

  const matches = [];
  for (const doc of snap.docs) {
    const d = doc.data();
    if (d.period && d.period !== period) continue;
    if (wantIds.size && !wantIds.has(d.studentId)) continue;
    if (target) {
      const n = normalizeToken(d.department);
      if (!n || n !== target) continue;
    }
    matches.push(d);
  }
  matches.sort((a, b) => String(a.name || "").localeCompare(String(b.name || "")));
  return matches;
}

function periodWindow(period) {
  const [y, m] = String(period || "").split("-").map(Number);
  if (!y || !m || m < 1 || m > 12) return null;
  return { start: new Date(Date.UTC(y, m - 1, 1)), end: new Date(Date.UTC(y, m, 1)) };
}

/** Attach student photo + the individual late-dates table for an escalated doc. */
async function enrichStudents(db, escalatedDocs, period) {
  const window = periodWindow(period);
  const out = [];
  for (const e of escalatedDocs) {
    const sSnap = await db.collection("students").doc(e.studentId).get();
    const sData = sSnap.exists ? sSnap.data() : {};
    const photo = sData.photoBase64 ? { base64: sData.photoBase64, mimeType: sData.photoMimeType || "image/jpeg" } : null;

    const dates = [];
    if (window) {
      const logs = await db.collection("late_logs")
        .where("studentId", "==", e.studentId)
        .where("scanTimestamp", ">=", window.start)
        .where("scanTimestamp", "<", window.end)
        .get();
      for (const d of logs.docs) {
        const ts = d.data().scanTimestamp?.toDate ? d.data().scanTimestamp.toDate() : new Date();
        dates.push({ date: formatDate(ts), time: formatTime(ts) });
      }
      dates.sort((a, b) => (a.date + a.time).localeCompare(b.date + b.time));
    }

    out.push({
      studentId: e.studentId,
      name: e.name || sData.name || "",
      department: sData.department || e.department || "",
      year: e.year || sData.year || "",
      count: e.count || 0,
      dates,
      photo,
    });
  }
  return out;
}

/**
 * Execute one escalation mail. Returns a stable status object for the queue
 * processor / Cloud Function to record:
 *   { status: "sent", resendId, to, mailLogId, studentsIncluded }
 *   { status: "abort", code, detail }          — not sent, no audit row
 *   { status: "dry-run", to, subject, ... }    — everything built, nothing sent
 */
async function processQueuedMail({ db, request, mailRequestId, config = {} }) {
  const { threshold } = await loadSettings(db);

  const resolved = await resolveRequestDepartment(db, request);
  if (!resolved || !resolved.hodEmail) {
    return {
      status: "abort",
      code: "NO_HOD_EMAIL",
      detail: `No HOD email resolvable for '${request.departmentId || request.department || "?"}' (check the departments collection).`,
    };
  }

  const escalated = await loadEscalatedStudents(db, request, resolved);
  if (escalated.length === 0) {
    return {
      status: "abort",
      code: "NO_ESCALATED",
      detail: "No escalated students match this mail request (status=escalated in escalation_queue for this department/period).",
    };
  }

  const students = await enrichStudents(db, escalated, request.period);
  const subject = `[Escalated] Late Attendance — ${resolved.name} — ${request.period}`;
  const html = buildMailHtml({
    collegeName: config.collegeName,
    departmentName: resolved.name,
    period: request.period,
    threshold,
    students,
  });

  const attachments = [];
  for (const s of students) {
    if (s.photo?.base64) {
      const ext = s.photo.mimeType === "image/png" ? "png" : "jpg";
      attachments.push({
        filename: `${s.studentId}.${ext}`,
        content: s.photo.base64,
        content_type: s.photo.mimeType || "image/jpeg",
        content_id: `photo_${s.studentId}`,
        disposition: "inline",
      });
    }
  }
  if (students.length > 1) {
    const xlsx = await buildXlsxAttachment(students, { period: request.period, departmentName: resolved.name });
    attachments.push({
      filename: `late-attendance-${request.period}.xlsx`,
      content: xlsx.toString("base64"),
      content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    });
    const pdf = await buildPdfAttachment(students, { period: request.period, departmentName: resolved.name });
    attachments.push({
      filename: `late-attendance-${request.period}.pdf`,
      content: pdf.toString("base64"),
      content_type: "application/pdf",
    });
  }

  const to = config.toOverride || resolved.hodEmail;
  const from = config.from || defaultFrom();

  if (config.dryRun) {
    return {
      status: "dry-run",
      to,
      subject,
      departmentName: resolved.name,
      studentsIncluded: students.map((s) => s.studentId),
      attachmentsPreview: attachments.map((a) => ({
        filename: a.filename,
        content_type: a.content_type,
        content_id: a.content_id || null,
        sizeBytes: Buffer.from(a.content, "base64").byteLength,
      })),
    };
  }

  const sent = await sendViaResend({ apiKey: config.apiKey, from, to, subject, html, attachments });

  const logDoc = mailLogDoc({
    departmentId: resolved.departmentId,
    department: resolved.name,
    period: request.period,
    to,
    subject,
    studentsIncluded: students.map((s) => s.studentId),
    triggeredBy: request.requestedBy || null,
    mailRequestId,
    resendId: sent.id,
  });
  await db.collection("mail_logs").doc(mailRequestId).set({
    ...logDoc,
    sentTimestamp: FieldValue.serverTimestamp(),
  });

  return { status: "sent", resendId: sent.id, to, mailLogId: mailRequestId, studentsIncluded: logDoc.studentsIncluded };
}

module.exports = {
  loadSettings,
  loadDepartments,
  resolveRequestDepartment,
  loadEscalatedStudents,
  enrichStudents,
  processQueuedMail,
  defaultFrom,
};