# SECURITY — Student Late Attendance Scanner

This document lists the security issues found in the original design and the fixes applied. Any AI coding agent or developer working on this project should treat these as hard constraints, not suggestions.

## 1. Escalation decision must be server-side, not client-side
**Risk:** If the Flutter app calculates "this is the 3rd late" and writes that decision directly to Firestore, a modified/rooted device could tamper with escalation results.
**Fix:** The app only ever creates a `late_logs` entry. A **Cloud Function** (`onCreate` trigger on `late_logs`) does the actual counting and writes `warning` / `escalation_queue` flags. The client only reads and displays the result — it never decides it.

## 2. Use server time, not device time
**Risk:** PT sir's phone clock could be wrong (accidentally or deliberately), corrupting the late/on-time decision.
**Fix:**
- Online scans: use Firestore `serverTimestamp()` as the authoritative time.
- Offline scans: store `deviceTimestamp` alongside, tag `syncedOffline: true`. On sync, a Cloud Function compares device time vs. server receipt time; large mismatches are flagged for admin review instead of trusted silently.

## 3. Duplicate-scan race condition
**Risk:** "Check if already scanned today, then insert" as two separate steps can race under bad network conditions (e.g., retry causing two writes).
**Fix:** Use a deterministic Firestore document ID: `studentId_YYYY-MM-DD`. This makes duplicate inserts structurally impossible — no separate duplicate-check query needed.

## 4. PIN/credentials must not live in Firestore
**Risk:** Storing a PIN hash as a plain Firestore field is exposed if security rules are ever loosened.
**Fix:** Use Firebase Authentication properly. Assign roles via **custom claims** (`role: pt_sir | admin` — exactly two roles, no third; NEW_SECURITY.md), settable only via a privileged Cloud Function (e.g., during staff onboarding by an admin) — never settable by the client.

## 5. Security Rules must be role-specific
**Risk:** Vague rules like "PT sir can scan and view" don't translate into safe Firestore rules and can leave unintended write access open.
**Fix (conceptual):**
```
match /late_logs/{logId} {
  allow create: if request.auth.token.role == 'pt_sir';
  allow read: if request.auth.token.role in ['pt_sir','admin'];
  allow update, delete: if false; // logs are immutable — corrections go through admin tools only
}
match /settings/{doc} {
  allow read: if request.auth.token.role == 'admin';
  allow write: if request.auth.token.role == 'admin';
}
match /staff/{doc} {
  allow write: if request.auth.token.role == 'admin';
}
```
Escalation counts and mail-trigger status must be write-protected from the client entirely — only Cloud Functions (admin privileges) write them.

## 6. Resend API key must never sit in the mobile app
**Risk:** Any secret bundled into the Flutter app can be extracted by decompiling the APK.
**Fix:** The app only calls a Cloud Function endpoint ("send escalation mail for department X"). The Cloud Function holds the Resend API key as an environment variable — never exposed to any client. See `.env.example`.

## 7. Storage rules for student photos
**Risk:** Public/unrestricted access to student photo URLs.
**Fix:** Only `pt_sir`, `admin` roles (via custom claims) can read `students/{id}/photo`. No public access.

## 8. General Rules for Development
- Never commit `.env` — only `.env.example` (placeholders) goes into git. See `.gitignore`.
- All writes to `late_logs`, `escalation_queue`, `mail_logs` that represent a *decision* (not a raw scan event) must originate from Cloud Functions, never from client SDKs directly.
- Audit every scan: `scannedBy`, `scanTimestamp`, `scanMethod` are mandatory fields, never optional.
