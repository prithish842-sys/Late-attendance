# NOTES — Spark fallback mode & the Blaze switch

This file records what runs on the **Spark (free) plan** right now, what is
reasonably different from the full design in `docs/ARCHITECTURE.md` /
`docs/SECURITY.md`, and exactly what changes when the project upgrades to
Blaze. **Treat this as the source of truth for current runtime behavior.**

## What the project is running on

- Firebase **Spark plan**: `billingEnabled: false`, no billing account attached.
- **Cloud Functions: API disabled** and cannot run on Spark.
- **Cloud Storage for Firebase: API disabled** and unavailable on Spark.
- Firestore, Firebase Auth, and the Firebaserules service are all **free and active**.
- Project id: `late-attendance-5bf6d` (num `585065428392`). Firestore database id
  is literally `default` (not `(default)`) — Admin SDK scripts must pass
  `getFirestore(app, "default")`.

## What's running in "fallback mode" (Spark)

| Feature | Full design (Blaze) | Current Spark behavior | Where |
|---|---|---|---|
| Escalation decision | Cloud Function `onCreate` on `late_logs` counts + writes `escalation_queue` (SECURITY.md §1) | **`scripts/process-escalation.js`** — an Admin-SDK runner that reproduces the exact same count + verdict using the *same* core logic (`functions/escalation-core.js`). Run it after scans, or on a schedule. | `functions/` (deployable), `scripts/process-escalation.js` |
| Student photos | Firebase Storage, role-gated (SECURITY.md §7) | **`photoBase64` stored in the Firestore `students` doc** (set by `seed_project.js`). | `storage.rules` ships ready; API still disabled |
| HOD escalation mail (Phase 3) | Resend API in a Cloud Function (SECURITY.md §6) | **Queues `mail_queue` requests (client writable for `pt_sir`/`admin` only); `scripts/process-mail.js` — an Admin-SDK runner using the *same* core (`functions/mail-core.js` + `mail-sender.js`) — sends via Resend and writes `mail_logs`** | `functions/` (deployable), `scripts/process-mail.js` |
| Attendance reports (Phase 4) | Cloud Function `generateReport` callable — builds Excel/PDF, stores under Cloud Storage `reports/{reportId}/`, returns signed URLs, writes `report_logs` | **Enqueues `report_requests` (client writable for `pt_sir`/`admin` only); `scripts/generate-report.js` — an Admin-SDK runner using the *same* core (`functions/report-core.js` + `report-generator.js`) — resolves the window, joins `late_logs` with students, applies department/year filters, writes the `.xlsx` + `.pdf` into `reports/` and records `report_logs`** | `functions/` (deployable), `scripts/generate-report.js` |
| Offline sync validation (Phase 5) | Validation of `deviceTimestamp`-vs-server-time on every `late_logs.create` that carries `syncedOffline`, writing `offline_sync_flags` (SECURITY.md §2) | **Flag write happens server-side only. Spark: `scripts/process-offline-sync.js` — an Admin-SDK runner using the *same* core (`functions/offline-sync-core.js`) — scans recent `syncedOffline: true` logs, computes the skew, and writes `offline_sync_flags/{logId}` (client writes blocked by rules). Blaze: the same assessment runs inline in the `escalateLateLog` onCreate trigger** | `functions/` (deployable), `scripts/process-offline-sync.js` |
| Role on login | Custom claims from a privileged Cloud Function | **`scripts/set_claims.js`** (Admin SDK + service account) assigns `role: pt_sir \| admin` — exactly two roles, no third (NEW_SECURITY.md). | `scripts/set_claims.js` |

**Important caveat:** because Cloud Functions are off, the escalation verdict is
not instantaneous — it appears after the runner next runs. The client never
decides it (SECURITY.md §1 is preserved); it just reads whatever
`escalation_queue` currently holds and falls back to a count-based badge until
then.

**Phase-3 mail follows the same pattern.** The app only ever **enqueues** a
`mail_queue` request — a raw intent, like a scan. Everything that matters
happens server-side only: department resolution, HOD email lookup, bundling the
escalated students into ONE mail per department, photo + xlsx + pdf attachment,
the Resend call, and the `mail_logs` audit write (`SECURITY.md` §1, §5, §8).
That server work is either the `processMailQueue` Cloud Function (Blaze) or
`scripts/process-mail.js` (Spark). The Resend key lives only in `.env`/function
env vars, never in the app (§6). Without a key, a send is refused — verified by
`functions/test/mail-core.test.js`.

**Phase-4 reports follow the same pattern.** The app previews the window
locally (mirroring the server's *exact* window + fuzzy department rules) but
only ever **enqueues** a `report_requests` raw intent. The server recomputes
the authoritative window, joins `late_logs` with students, applies the
department/year filters, builds the Excel + PDF, and writes `report_logs`
(`SECURITY.md` §1, §5, §8). That work is either the `generateReport` callable
(Blaze) or `scripts/generate-report.js` (Spark). The department filter uses the
same fuzzy resolution as mail — `"B.SC CS"` students match the `BSC-CS`
reference doc — so the preview always matches the downloaded file.

## Service account (used by all Admin-SDK scripts)

- `late-attendance-admin@late-attendance-5bf6d.iam.gserviceaccount.com`
- Roles granted: `roles/firebaseauth.admin`, `roles/datastore.user`
- Key JSON: `scripts/service-account/key.json` — **gitignored**, never commit.
- Admin SDK scripts bypass Firestore security rules by design (SECURITY.md §8).

## Verified end-to-end (2026-09-23)

- 2 demo Auth accounts exist with custom claims (exactly two roles, no third —
  NEW_SECURITY.md). Emails live only in `.env` (`FIREBASE_DEMO_*` — see
  `.env.example`); scripts read them from there:
  PT Sir placeholder `prithishrajmbsccs2024@sankara.ac.in` → `pt_sir`,
  `admin@sankara.ac.in` → `admin`. Re-apply with `node scripts/set_claims.js sync`.
- `escalation-core` logic: **13/13 unit tests pass** (`functions/`).
- `scripts/process-escalation.js` run over seeded data produced:
  - `26BSC004_2026-09` → `warning` (count 2)
  - `26BSC008_2026-09` → `escalated` (count 3)
  - `26BSC010_2026-09` → `escalated` (count 4)
  - 1st-late students correctly produced **no** queue entry (tracking).
- **Firestore rules live-verified** against the deployed ruleset with real
  demo ID tokens (`scripts/verify_rules.js`):
  - pt_sir creates `late_logs` → ALLOWED
  - admin (any non-pt_sir claim) creates `late_logs` → DENIED
  - any client writes `escalation_queue` → DENIED
  - admin writes `settings` → ALLOWED, pt_sir writes `settings` → DENIED
  - anonymous read of `students` → DENIED

## Verified end-to-end (2026-09-24 — Phase 3 mail + rules)

- Mail core + send orchestration: **28/28 node tests pass** (`functions/`,
  `npm test` — 13 escalation-core + 15 mail-core).
- App side: `flutter analyze` clean, **19/19 Flutter tests pass**, incl. the
  Phase-3 department-match and `QueuedMailService` (Spark enqueue) tests.
- Firestore rules extended for Phase 3 (`mail_queue`) and **published to the
  live project** via `scripts/publish_rules.mjs` (REST — the CLI deploy hangs on
  this box). `scripts/verify_rules.js` is now **10/10** and self-cleaning (docs
  it is allowed to create are removed via the Admin SDK afterwards, because the
  rules block client deletes by design).
- `scripts/process-mail.js` **dry-run over live data** (period `2026-09`,
  request `BSC_CS_2026-09_*` for 26BSC008 + 26BSC010): resolved the department
  to `B.Sc Computer Science` / `Kanishkak@sankara.ac.in` and built the full
  payload — 2 inline student photos (`cid:photo_*`), `late-attendance-2026-09.xlsx`
  + `.pdf`. Nothing was sent: `RESEND_API_KEY` is intentionally blank.
- One real `mail_queue` doc is **pending** right now; it will send once
  `RESEND_API_KEY` (and optionally `RESEND_FROM_EMAIL` / `RESEND_FROM_NAME`) are
  in `.env` and `node scripts/process-mail.js` is run.

## Verified end-to-end (2026-09-24 — Phase 4 reports + rules)

- Report core + orchestration: **45/45 node tests pass** (`functions/`,
  `npm test` — 13 escalation-core + 15 mail-core + 17 report-core).
- Firestore rules extended for Phase 4 (`report_requests` + `report_logs`) and
  **published to the live project** via `scripts/publish_rules.mjs`.
  `scripts/verify_rules.js` is now **14/14** and self-cleaning.
- `scripts/generate-report.js` end-to-end over live data:
  - enqueued `report_muf50jiu` for monthly `2026-09` (tests the raw
    daily/weekly/monthly/custom window math at parse time);
  - `--dry-run` reported **7 late entries / 2 students** — exactly matching
    the live `late_logs` for 2026-09 (26BSC008 ×3, 26BSC010 ×4);
  - real `process` wrote `reports/late-attendance-september-2026.xlsx`
    (7752 bytes, valid `PK` archive) + `.pdf` (2055 bytes, `%PDF-`), verified
    `report_logs/report_muf50jiu` (stats + file names + status) and the request
    doc flipped to `generated` / `attemptCount: 1`;
  - test artifacts cleaned up afterwards (`reports/` is gitignored).
- App side: `flutter analyze` clean, **30/30 Flutter tests pass**, incl. the
  Phase-4 `reportWindowFor` math, `summarizeReport`, and `QueuedReportService`
  (Spark enqueue → `report_requests`) tests. `ReportsScreen` is wired from the
  scan screen header; preview + generate button is gated to `pt_sir`/`admin`.
- Note: `escalation_queue` holds a `26BSC004_2026-09` warning (count 2) with no
  September `late_logs` — a Phase-2 runner artifact, not a report bug. The 7
  live September entries are the report source of truth.

## Verified end-to-end (2026-09-24 — Phase 5 offline mode)

- Offline core + server assessment: **59/59 node tests pass** (`functions/`,
  `npm test` — 13 escalation-core + 15 mail-core + 17 report-core +
  14 offline-sync-core). Covers tolerance/boundaries, `scanDateFromLogId`,
  skew verdicts max/rate/device-behind-server/within-tolerance, flag shaping.
- App side: `flutter analyze` clean, **47/47 Flutter tests pass** — offline
  queueing (online vs offline record), `PendingScan` JSON round-trip,
  `MemoryOfflineStore`, `looksLikeOffline` mapping, `ScanService` cached-roster
  lookup, `SyncService` drain/idempotency/transient-failure, real Hive
  box round-trips. The app never writes `offline_sync_flags` (rules deny).
- Live rules: `offline_sync_flags` (read isStaff; write false) added and
  **published** via `scripts/publish_rules.mjs`; `scripts/verify_rules.js` is
  now **18/18** and self-cleaning.
- `scripts/process-offline-sync.js` verified live end-to-end:
  - seeded 2 `late_logs` with `syncedOffline: true` — one 1-minute device skew
    (`ok`, not flagged) and one ~23-day-behind device clock (`FLAGGED`,
    `device-behind-server`, Δ 33120 min);
  - real `process` wrote both `offline_sync_flags` docs; re-run was idempotent
    (`already: 2`, 0 new flags); `--list` showed scan + flag detail;
  - both test docs and their flags cleaned up afterwards.
- Everything shown in the app during offline (stale roster, cached
  counts, "Saved — will sync when back online") comes from Hive boxes seeded
  from the same reads the online path uses.

## The Blaze switch (checklist)

When you upgrade to Blaze and want the real implementations:

1. **Functions:** wire `functions/` into `firebase.json`
   (`"functions": {"source": "functions"}`), then
   `firebase deploy --only functions`.
2. **App config:** rebuild the Flutter app with
   `--dart-define=BLAZE_ENABLED=true` (see `lib/src/config/app_config.dart`).
   The escalation read path is identical either way; the *mail* path flips from
   `QueuedMailService` (writes `mail_queue`) to `CloudMailService` (calls the
   `sendEscalationMail` callable) — no call-site changes, same unit contract.
3. **Storage (optional, §7):** enable Cloud Storage for Firebase and
   `firebase deploy --only storage` to publish `storage.rules`; then migrate
   `photoBase64` → Storage URLs.
4. **Rules:** nothing to change — `firestore.rules` is already exactly what the
   Cloud-Function deployment expects (client writes to `escalation_queue`,
   `mail_logs`, and decisions are blocked unconditionally).
5. **Mail (Phase 3):** deploy `functions/` (ships both the `sendEscalationMail`
   callable and the `processMailQueue` trigger) and rebuild the app with
   `BLAZE_ENABLED=true`. The app then calls the callable, and the trigger would
   also consume any `mail_queue` docs the Spark fallback left behind.
6. **Storage (Phase 4):** with Storage enabled, `storage.rules` (already
   uploaded, release pending) gates `reports/{reportId}/{file}` and the
   `generateReport` callable returns 30-day signed URLs instead of object refs.
   Run `scripts/generate-report.js` first so `reports/` on the office machine
   and Cloud Storage both have files; map the local copy to the Storage paths
   for continuity.
7. **Offline sync (Phase 5):** deploy `functions/` (the `escalateLateLog` trigger
   now runs the offline-skew assessment inline and writes `offline_sync_flags`
   whenever a `late_logs.create` carries `syncedOffline: true`). The Spark
   runner `scripts/process-offline-sync.js` can keep running as a safety net —
   both write the same flags; repeated writes are idempotent (`already`). No
   client or rules change is needed for the Blaze flip.
8. **Web admin (Phase 6):** set `VITE_BLAZE_ENABLED=true` in the Vercel project
   env (and/or `admin-web/.env`) and redeploy. `admin-web/src/lib/reportService.ts`
   detects the flag at build time and calls the `generateReport` callable instead
   of writing `report_requests`; no page or rules change. The request payload is
   identical (`periodType`/`start/end`/`department`/`year`), so `report_requests`
   docs left behind by the Spark fallback remain consumable by the same
   `generateReport` logic once fired.

## Verified end-to-end (2026-09-24 — Phase 6 admin web)

- Toolchain fixed first: the interrupted first `npm install` had left the
  `firebase` umbrella package stubbed (missing `firestore/dist/firestore/*.d.ts`,
  etc.), which surfaced as `TS2305: Module '"firebase/firestore"' has no exported
  member 'doc'/'setDoc'/...` plus `TS7006 implicit-any` cascades. A full wipe and
  reinstall (`--no-audit --no-fund`) completed in ~5 min and restored every
  package. A second type-conflict — npm had hoisted `recharts` + `@types/react`
  into `C:\Users\HP\node_modules` (`@types/react@19`, from the unrelated
  `college-election-frontend` project at the workspace root) — was contained via
  `tsconfig` `paths` + `typeRoots` pinning `react`/`react-dom` to the project's
  `@types/react@18`.
- `npm run typecheck` clean; **20/20 Vitest** pass (`report.test.ts` 16 +
  `describeAuthError.test.ts` 4 — window bounds, fuzzy dept match, summary order,
  threshold levels, auth-error text); `npm run build` ok (1,030 kB JS / 275 kB
  gzip — firebase SDK bulk, chunk-size warning only; fine for an admin app);
  `vite preview` served dist (index + bundled JS 200).
- Vercel (prithish account, project `admin-web`):
  https://admin-kgoy8p7cz-prithish.vercel.app —
  first deployment was auto-assigned to production. 8 `VITE_*` env vars added
  (production/preview/development; the API key required `--type config` since it
  is deliberately public web-SDK config). Live bundle verified to contain
  `late-attendance-5bf6d` + the api key. Default **Deployment Protection** is on,
  so visitors must sign in with Vercel; turn it off in project Settings → Security
  for open access.
- The deployed admin app talks to the same production Firestore database as the
  Flutter app. With `VITE_BLAZE_ENABLED=false` (default) it uses only the
  client-legal surface in `firestore.rules` (reads isStaff / `late_logs` write
  create / `report_requests.create`); report requests wait in the queue for the
  office `scripts/generate-report.js` runner or the Blaze trigger.

## Security-rules notes

- `firestore.rules`: every read/write is role-gated via
  `request.auth.token.role in ['pt_sir','admin']` (exactly two roles — no HOD
  role, no public access; NEW_SECURITY.md). Writes are narrowly
  scoped: `late_logs.create` (pt_sir), `settings` / `students` / `departments` /
  `staff` (admin), and `mail_queue.create` / `report_requests.create`
  (pt_sir / admin — raw request events, Phase 3 / Phase 4). `escalation_queue`,
  `mail_logs`, `report_logs`, `offline_sync_flags`, `mail_queue` /
  `report_requests` status+edits,
  and all deletes are client-forbidden.
- Deploying rules/indexes on this box: the Firebase CLI intermittently hangs,
  so use the Firebaserules + Firestore REST APIs — `scripts/publish_rules.mjs`
  (reproducible in `scripts/lib/firebase-rest.js` conventions).