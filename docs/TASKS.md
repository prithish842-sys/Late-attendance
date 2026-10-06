# TASKS — Student Late Attendance Scanner

Work through phases in order. Do not start a phase until the related rows in `DECISIONS.md` are resolved. Each phase should be a separate set of prompts/commits, not one giant build.

## Phase 1 — Foundation
- [x] Set up Firebase project (Firestore, Auth, Storage, Functions)
- [x] Define Firestore collections per `ARCHITECTURE.md` §2
- [x] Build one-time CSV/Excel student import script (2500+ students)
- [x] Flutter project scaffold + `mobile_scanner` integration
- [x] Basic online-only scan + verify screen (no escalation logic yet)

## Phase 2 — Server-Side Escalation Logic
- [x] Cloud Function: `onCreate` trigger on `late_logs` — **built but not deployed** (Spark plan; see `docs/NOTES.md`). Fallback on Spark: `scripts/process-escalation.js` (Admin-SDK runner using the same core logic)
- [x] Implement count-per-reset-period logic (per `DECISIONS.md` #1) — `functions/escalation-core.js`, 13/13 tests pass
- [x] Write `warning` flag at 2nd late — verified live in `escalation_queue`
- [x] Write to `escalation_queue` at threshold (per `DECISIONS.md` #5) — verified live
- [x] Firebase Auth custom claims for `pt_sir` / `admin` roles (exactly two, no third — NEW_SECURITY.md) — applied + verified (`scripts/set_claims.js`; demo accounts in `docs/NOTES.md`)
- [x] Firestore + Storage security rules per `SECURITY.md` §5, §7 — `firestore.rules` deployed + live-verified (5/5), `storage.rules` ready for Blaze
- [x] App integration: `EscalationService` abstraction (Spark/Blaze routing via `BLAZE_ENABLED`), verdict displayed in verify screen

## Phase 3 — HOD Mail Automation
- [x] Cloud Function endpoint: "send escalation mail for department X" — `sendEscalationMail` HttpsCallable + `processMailQueue` trigger — **built but not deployed** (Spark plan; see `docs/NOTES.md`). Fallback on Spark: `scripts/process-mail.js` (Admin-SDK runner using the same `functions/mail-core.js` + `mail-sender.js`)
- [x] Resend API integration (key in Cloud Function env vars only — `SECURITY.md` §6) — `RESEND_API_KEY` never in the app; missing key is refused server-side (28/28 tests)
- [x] Professional mail template (student photo, ID, dept, late-dates table) — `functions/mail-core.js buildMailHtml`
- [x] Multi-student bundling into single mail with Excel/PDF attachment — `buildXlsxAttachment` (ExcelJS) + `buildPdfAttachment` (PDFKit); one mail per department
- [x] `mail_logs` write-back for audit trail — server-only write (SECURITY.md §5, §8)
- [x] Firestore rules for `mail_queue` (staff read, `pt_sir`/`admin` create, server-only update/delete) — published + live-verified (10/10)
- [x] App integration: `MailService` abstraction (Spark queue / Blaze callable via `BLAZE_ENABLED`), `EscalationScreen` (grouped by dept, checkbox select, send) wired from the scan screen

## Phase 4 — Reports
- [x] Server-side Excel generation (ExcelJS) — `functions/report-core.js buildReportXlsx` + `scripts/generate-report.js` (Admin-SDK runner on Spark; `generateReport` callable on Blaze) — verified live (valid `.xlsx`, 7 late entries / 2 students Sept 2026)
- [x] Server-side PDF generation (PDFKit) — `buildReportPdf` — verified live (valid `%PDF-`)
- [x] Daily/Weekly/Monthly report filters (department, year, date range) — window + department-match + year-filter logic in `report-core.js`/`report-generator.js`; preview mirrors it client-side (`ReportsScreen`); `report_requests` enqueues intent (startDate/endDate resolved server-side); `report_requests` + `report_logs` rules published + live-verified (14/14)

## Phase 5 — Offline Mode
- [x] Hive local storage — `lib/src/services/offline_store.dart` (`HiveOfflineStore`: `offline_students` / `offline_settings` / `offline_counts` / `offline_pending_scans` boxes) + `MemoryOfflineStore` for tests; boxes opened via `defaultHiveDirectory()` in `main()`
- [x] Connectivity Plus — `lib/src/services/connectivity_service.dart` (`onConnectivityChanged` + `checkConnectivity`; test seams; `looksLikeOffline` maps Firebase offline codes)
- [x] Local scan queue when offline — `ScanService` short-circuits through `queue`/`_queueScan` (`PendingScan` with deterministic `studentId_YYYY-MM-DD` doc id from device-local time); UI shows navy "offline / X pending" banner
- [x] Sync logic on reconnect — `SyncService` flips on reconnect, `scan.syncPending()` oldest-first, removes on `RecordResult.recorded`/`alreadyRecorded`, writes `syncedOffline: true` + `serverTimestamp` while preserving `deviceTimestamp` (SECURITY.md §3)
- [x] `deviceTimestamp` vs. server-time validation on sync — `functions/offline-sync-core.js` (`scanDateFromLogId` / `discrepancyMinutes` / tolerance 10 min) → `offline_sync_flags/{logId}`; Spark runner `scripts/process-offline-sync.js` writes real flags; Blaze path inline in `escalateLateLog` — verified live (1-min Δ kept, 33120-min Δ flagged `device-behind-server`)

## Phase 6 — Admin Web Dashboard
- [x] React + Vite + TypeScript + Tailwind scaffold — `admin-web/` (Vite 5 + React 18 + TS strict + Tailwind 3 with the DESIGN tokens; `tsconfig`/`vite.config`/`tailwind`/`postcss`/`index.html`/`vercel.json`/`.env(.example)`); `src/lib/report.ts` + `describeAuthError.ts` are pure-logic seams unit-tested with Vitest (**20/20 tests pass**, `npm run typecheck` clean, `npm run build` ok, ~275 kB gzip)
- [x] Login (Firebase Auth) — `src/auth/AuthContext.tsx` + `pages/Login.tsx`; plain-language errors via `describeAuthError`, role from custom claims (`pt_sir`/`admin` — exactly two roles), crest + Fraunces/Inter per DESIGN
- [x] Dashboard: today's count, department-wise chart (Recharts) — `pages/Dashboard.tsx`; local-day window, Spark-safe `watchScansBetween`, maroon/navy/sand bar chart
- [x] Reports page (filters + export) — `pages/Reports.tsx`; preview uses the same `filterRows`/`summarizeReport` logic as the app; the request is **always** enqueued via `lib/reportService.ts` — Spark writes `report_requests` (only client-writable Phase-4 path), Blaze calls `generateReport` (guard rails server-side); custom range
- [x] Settings page (cutoff time, threshold, HOD emails, reset period) — `pages/Settings.tsx`; admin-only, writes `settings.escalationThreshold`/`lateCutoffTime` (stored, per DECISIONS #3 not applied) + `departments.hodEmail`
- [x] Audit log page (who scanned what, when) — `pages/Audit.tsx`; scans / mail logs / report requests + report logs tabs, status + late-count badges
- [x] Deploy to Vercel — live at `https://admin-kgoy8p7cz-prithish.vercel.app` (project `admin-web`, prithish account; first deploy auto-assigned to production; 8 `VITE_*` env vars set for prod/preview/dev; default Deployment Protection enabled — disable in project settings for open access)

## Phase 7 — AI Features (Optional)
- [ ] Gemini-powered report summary generation
- [ ] Gemini-assisted professional mail drafting (still triggered by deterministic logic, not by Gemini's judgment)
- [ ] Admin natural-language query interface ("this month CSE la 3 times late vantha students yaaru?")

## Definition of Done (per phase)
- All checklist items complete
- Related `DECISIONS.md` rows resolved
- Related `SECURITY.md` rules implemented and verified (not just planned)
- Manually tested on PT sir's actual device/network conditions before moving to next phase
