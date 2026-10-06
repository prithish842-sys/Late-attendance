# New Implementation Tasks

### Phase 1 — PT Sir
Status: ✅ Complete
- [x] Dashboard redesign
- [x] prominent scan icon
- [x] live date/time
- [x] barcode/QR
- [x] manual register fallback
- [x] verification page
- [x] submit/
scan-next
- [x] image cache
- [x] today's list/count

### Phase 2 — Reports/Mail
Status: ✅ Complete
- [x] department filter
- [x] 1st/2nd/3rd filter
- [x] date range
- [x] PDF/Excel
- [x] HOD search
- [x] mail preview
- [x] combined PDF
- [x] optional separate year PDFs
- [x] mail logs

### Phase 3 — Escalation/Audit
Status: ✅ Complete
- [x] monthly counter
- [x] 1/2/3+ status
- [x] department grouping
- [x] weekly aggregation
- [x] repeated student view
- [x] weekly HOD notification

### Phase 4 — Admin
Status: ✅ Complete
- [x] Excel import
- [x] validation preview
- [x] batch metadata
- [x] pass-out notification
- [x] soft delete
- [x] Recently Deleted
- [x] restore
- [x] permanent delete
- [x] storage cleanup

### Phase 5 — Automation/Hardening
Status: ✅ Complete
- [x] daily date query
- [x] monthly rollover
- [x] weekly audit job
- [x] pass-out job
- [x] mail retry/status
- [x] security rules
- [x] role checks
- [x] offline sync tests
- [x] performance tests

### Phase 6 — Design System Pass
Status: ✅ Complete (11/11 done)
- [x] apply 60-30-10 color rule across every screen (dashboard, scanner,
      verification, reports, audit, admin)
- [x] reduce dashboard to one primary action (Hick's Law)
- [x] resize/reposition `Scan Student` and `Submit` into thumb-reachable,
      full-width targets (Fitts's Law)
- [x] make destructive Admin actions deliberately smaller/harder to hit + add
      second confirmation
- [x] standardize scanner UI to familiar camera-scanner pattern (Jacob's Law)
- [x] standardize report filters to a chip/dropdown filter bar
- [x] chunk verification-page fields and register numbers (Miller's Law)
- [x] group weekly audit by department first, students nested inside
- [x] add clear success/confirmation states at end of scan flow and end of
      mail-send flow (Peak-End Rule)
- [x] give escalated (3rd+ late) rows a visually distinct treatment, not just
      a badge (Von Restorff Effect)
- [x] visual QA pass against `NEW_DESIGN_PRINCIPLES.md` and `DESIGN.md`
      "what to avoid" list

### Phase 7 — Firebase Cleanup
Status: ✅ Complete (4/4 done)
- [x] remove manual/interim Firestore & Storage rule password step from dev
      setup (never present — rules are role-based; no password gate existed;
      `scripts/set_claims.js` no longer carries a demo-HOD fallback account)
- [x] replace with role-based rules keyed to Firebase Auth (PT Sir / Admin) —
      `firestore.rules` + `storage.rules` `isStaff()`/read/write now key off
      `request.auth.token.role in ['pt_sir','admin']`; server functions and UI
      gates verified already two-role
- [x] confirm no dev-only open rule (`allow read, write: if true;`) is present
      in the production project (none found anywhere except docs mentioning the
      concept)
- [x] re-verify only PT Sir and Admin roles exist anywhere in auth/rules/UI —
      no HOD login or HOD role (`hod` removed from rules, set_claims.js,
      verify_rules.js, auth_service comment, Admin web Layout labels,
      seed/staff.json, and all legacy docs; HOD remains only as a mail
      recipient via `departments.hodEmail`)

---

## Phase status verdict (full-codebase audit, 2026-09-26)

- **Original `docs/TASKS.md` Phases 1–6: implemented in code.**
- **Original `docs/TASKS.md` Phase 7 (Gemini AI): NOT STARTED** — no consumer of
  `GEMINI_API_KEY` exists anywhere (only the `.env.example` placeholder).
- **New-update Phases 1–7 above: implemented in code**, with the doc-vs-code
  gaps listed under "Pending work" below (the checklists alone overstate
  completeness — these were found by reading the code, not the checklists).
- **Runtime reality:** everything runs on the **Spark fallback path** — the app
  only *enqueues* `mail_queue` / `report_requests` / `admin_requests`; the real
  work happens in `scripts/process-*.js` runners. Cloud Functions are written
  but never deployed (Spark plan).

### Pending work (found during QA — build decisions needed)

- [ ] **G1 — No report download path.** `ReportRequestResult.xlsxUrl/pdfUrl`
      are parsed (`report_service.dart:77`) but never rendered; on Spark files
      land only in the office machine's `reports/`. Only delivery today is the
      mail attachment. Needs a decision: download UI + where files live
      (Blaze/Storage vs. local share).
- [ ] **G2 — No month-end audit snapshot job.** `NEW_UPDATES_PRD.md` §"month
      end" and this file's Phase 5 "monthly rollover" refer to a job that does
      not exist; counters only roll because they are month-keyed.
- [ ] **G3 — No Department/HOD admin CRUD.** Admin can only edit an existing
      `departments.hodEmail` (admin-web Settings); no create/delete department,
      no HOD name field.
- [ ] **G4 — Mail status/retry invisible in the app.** Server lifecycle
      (`mail_queue.status`, `attemptCount`, retry) exists; no UI reads it
      (`MailLogEntry` has no status field; admin-web Audit mail tab has no
      status column).
- [ ] **G5 — Weekly audit screen shows no send history** (only Mail Logs screen does).
- [ ] **G6 — Repeated-late alerts on dashboard** (`NEW_DESIGN.md`) not built.
- [ ] **G7 — Leftover `hod` login in live Auth.** `hod@sankara.ac.in`
      (claims `role: "hod"`) and a second `ptsir@sankara.ac.in` still exist as
      Firebase Auth users, and `staff` holds matching docs — contradicting
      decision #16 / Phase 7 "exactly two roles". Rules already deny the `hod`
      claim everything; needs an explicit delete/disable decision.
- [ ] **G8 — `monthly_student_status`** is written server-side but has no
      `firestore.rules` block (denied) and no reader.
- [ ] **G9 — Windows desktop unsupported** (no `firebase_options` Windows
      entry, no `mobile_scanner` Windows plugin) — document or configure.
- [ ] **G10 — Real HOD mail delivery blocked by the Resend testing tier.**
      The API key only permits sending TO `prithish842@gmail.com`; every other
      recipient fails `Resend 403 validation_error` ("verify a domain at
      resend.com/domains"). `departments.hodEmail` is correctly back on
      `kanishkak@sankara.ac.in`, so real sends now fail by design until a
      domain is verified and the `from` address moved onto it. Verified live
      2026-09-28 (queue `status: failed` + the 403 in `error`).

### Phase 8 — QA & hardening pass
Status: 🔄 in progress (10/15 done)
- [x] Baseline gates: `flutter analyze` clean · 123/123 Flutter tests ·
      125/125 node tests · admin-web typecheck clean + 20/20 vitest
      (re-verified 2026-09-28: **flutter analyze clean + 127/127** ·
      **functions `node --test` 129/129** · **admin-web vitest 20/20 +
      `tsc -b` clean** · `verify_rules.js` all pass after the rules redeploy;
      re-verified again 2026-10-01: **flutter analyze clean + 131/131** ·
      **functions 129/129** · **admin-web vitest 20/20 + `tsc -b` clean** ·
      **`verify_rules.js` all pass** after the live-data cleanup)
- [x] Test credentials verified live: PT Sir placeholder → `role: pt_sir`,
      Admin → `role: admin`, `verify_rules.js` **18/18** (fixed `.env`
      `FIREBASE_API_KEY` to the *web* key — the Android key is rejected by the
      Identity Toolkit REST API the scripts use)
- [x] HOD recipient confirmed to exist only in `seed/departments.json` →
      Firestore `departments.hodEmail` (normalized to `kanishkak@sankara.ac.in`);
      placeholder warnings added to `NEW_DECISIONS.md` #19 + `.env(.example)`
- [x] Login blocker resolved on the Android emulator via **uiautomator
      bounds** (no guessed coordinates): `uiautomator dump` exposes Flutter's
      accessibility nodes (email `[63,1240][1017,1377]`, password
      `[63,1414][1017,1550]`, Sign in `[63,1613][1017,1750]` at default
      layout — always re-dump, the keyboard shifts the form). Typed the
      PT-Sir credentials in verified chunks (emulator drops chars in bulk
      `input text`), tapped the button's reported center → dashboard rendered
      (attendance log + weekly audit tiles); two post-login screenshots differ
      (ticking clock → UI alive, not frozen)
- [x] Functional QA feature-by-feature against live data — **verified live on
      the Android emulator 2026-09-28** (every tap from `uiautomator dump`
      bounds, never guessed pixels): scan→verify→submit incl. manual fallback,
      verify-screen "Escalated — threshold reached" for a 5th-time student,
      duplicate re-scan → disabled "Recorded today", double-tap guard (lookup
      counter delta = 1); dashboard live log (1 student, BHAGYADHARSHINI V);
      reports **7 filter states** checked against ground truth (daily/monthly ×
      all/CS × all/1st → 1/1, 11/4/CS9/IT2, 9/2, 4/1, 5/2 — all exact);
      Excel/PDF export via `generate-report.js` (`late-attendance-2026-09-28`
      7600 B / 1882 B, request `generated` + stats); Send/Forward → HOD picker →
      preview → queue → `process-mail.js` sent (resend IDs + `mail_logs` rows)
      incl. the **10-min duplicate suppression** (`duplicateOf`) and the fixed
      duplicate printer line; admin flow: batch import (SAF picker → preview
      `1 valid` → commit → `students/26BCA999` + `import_batches` +
      `audit_logs`), archive (manual **and** pass_out reasons → `active:false`
      + `deletion_records`), restore (→ `active:true`, evidence row consumed by
      design), two-step permanent delete (→ student gone, evidence kept with
      `permanentlyDeletedAt`, UI "Closed evidence"). QR/barcode camera path not
      automatable — covered by widget tests instead.
- [ ] Escalation 1st/2nd/3rd tier tiles + weekly-audit screen still lack a
      live end-to-end pass (only the verify-screen escalated state was
      confirmed this round) — blocked: not reached before emulator ANR/memory
      pressure on this 8 GB host (status 2026-10-01, data level verified:
      `escalation_queue` has 4 docs all `period: 2026-09` with
      status/severity matching the Sept late_logs; the current period
      `2026-10` has none → the screen must render its empty state —
      tile rendering needs the final device pass plus a runner-shaped
      fixture doc `escalation_queue/{id}_2026-10` → verify → delete)
- [ ] Performance measurements (cold start, scan→verify, submit→dashboard,
      report generation, export) with recorded numbers — partial only:
      `[perf]` logcat gives cold-start→first frame 8.4–16.2 s, report preview
      3.1 s, first roster read 2.7–6.9 s; scan→verify and submit→dashboard
      spans not captured (instrumentation now complete: six spans in
      `perf_log.dart` incl. the newly wired `dumpDb` at reports/dashboard/scan
      dispose + the QA `analyzeImage` hook on the scan title — one clean
      capture run deferred to the final device pass)
- [ ] Firestore/API call audit verified dynamically (per-action call counts)
      — instrumentation ready: every `firestore_service` call passes through
      `_track` → `[perf] db-summary` table (static counts drafted in the
      Spark-quota entry below; device capture still pending)
- [x] Rate limits added (scan same-code cooldown, mail re-send guard, report
      preview debounce) — `ScanScreen._onCode` ignores a repeat of the last
      code for 3 s; `functions/mail-queue-runner.js` suppresses an identical
      intent already sent within 10 min (status `failed` + `duplicateOf`, new
      `test/mail-queue-runner.test.js`); `ReportsScreen` debounces preview
      queries by 300 ms. **Decision: `_submitManual` intentionally has NO 3 s
      cooldown** — that guard exists for the camera re-emitting the same code;
      the manual path is a human action already serialized by `_processing`
      and double-protected at the record layer (deterministic doc id
      `studentId_YYYY-MM-DD` + txn + the disabled "Recorded today" button).
- [x] Performance fixes from the instrumentation pass: verify-screen stream
      listeners now cancelled in `dispose`, `OfflineStrip` caches its streams
      (was re-subscribing a connectivity stream on every rebuild), dashboard
      clock moved into its own leaf widget (was rebuilding the whole screen
      1×/s), `todayLateLogs` roster read once per subscription (was one full
      `students` read per scan emission), escalation N+1 reads now concurrent
- [x] Offline queue/sync test + Spark quota math (script-level 2026-10-01):
      unit coverage green in both suites — `MemoryOfflineStore` queue
      ordering, `ConnectivityService.looksLikeOffline` (Firestore network /
      socket codes → offline, permission + validation errors NOT),
      `ScanService` offline path (queues instead of writing, a Firestore
      network failure while "connected" also queues, permission-denied
      rethrows, cached-roster lookup) and `SyncService` (oldest-first drain,
      idempotent `studentId_YYYY-MM-DD` doc id, transient failure keeps the
      queue) inside the **131/131** Flutter run; `functions/test/
      offline-sync-core.test.js` inside the **129/129** node run. Server
      runner verified live with a fixture late_log (device Δ45 min):
      `--dry-run` (assessed 1, nothing written) → `process` (flag written,
      `device-behind-server`) → rerun idempotent (`already: 1`) → `--list`
      → fixture + flag deleted; 2 orphan `offline_sync_flags` from the
      09-24 E2E run also removed (0 remain). **Spark quota math** (free
      tier = 50K reads / 20K writes / 1 GiB storage per day; every client
      op is `_track`-labelled so the device `db-summary` will confirm these
      static counts): scan→submit worst case ≈ **12–18 reads + 1 write**
      (doc/barcode get 1–2, settings 1, verify-screen streams
      settings + period-count + already-recorded + escalation-verdict
      ≈ 6–10 across emissions, txn 1 r/1 w); dashboard open through a
      **60-scan day ≈ 1.8–3.6K reads** (today-stream re-emits today's docs:
      Σt ≈ 60²/2; roster cached, ≤2 refreshes × 12); reports + weekly +
      admin ≈ **300–600 reads/day** (Sept preview = 15 rows, list queries
      capped ≤200/50/40). Total ≈ **6–8K reads/day → ~6–8× headroom under
      50K**; writes ≈ **100–400/day → ~50× headroom under 20K**; storage
      ≈ 12 photos × ~140 KB + logs ≈ **2 MB ≪ 1 GiB**. Admin-SDK script
      runs bill the same project budget (<1K ops per run). Safe for a
      60-student demo class; the read ceiling only gets tight above ~200
      concurrent dashboard listeners.
- [ ] Console error sweep (final device pass — collect `flutter run` /
      logcat errors across all screens in one clean session)
- [ ] Mobile-width responsive pass (Chrome DevTools + Android emulator)
- [x] Fixes applied, all four test suites green again, live test data cleaned
      up — suites: `flutter analyze` clean + **127/127** (was 123; +3 regression
      tests), functions `node --test` **129/129**, admin-web **vitest 20/20 +
      `tsc -b` clean**, `verify_rules.js` all pass; QA cleanup: `hodEmail`
      restored to `kanishkak@sankara.ac.in`, QA student `26BCA999` removed via
      the real permanent-delete flow (evidence row kept by design), probe/queue
      mail artifacts deleted (`mail_logs` back to the 2 real sends), all
      `scripts/_qa_*` / `_diag*` temp scripts + `_qa_import.xlsx` deleted.
      **Bugs found & fixed this pass** (all live-verified; fixes live in the
      touched files): (1) stuck "Recording…" — `_confirm()` had no failure path;
      (2) offline detection missed Firestore `unknown` state; (3) report
      preview one-change-behind — `setState(() => _future = _load())` returns
      a Future, debug assertion threw before `markNeedsBuild` (3 call sites);
      (4) mail preview header printed `Instance of 'ReportSummary'.…`;
      (5) `process-mail.js` dual `firebase-admin` copies →
      `NumericIncrementTransform` not serializable (fixed via
      `createRequire(functions/package.json)`); (6) duplicate-suppression
      CLI printed `undefined: undefined`; (7) **deployed** `firestore.rules`
      predated Phase 4 — every `admin_requests`/`import_batches`/
      `deletion_records`/`audit_logs` op was `PERMISSION_DENIED` for the real
      admin token despite local rules being correct (redeployed with
      `firebase deploy --only firestore:rules`); (8) `process-admin.js` had
      the same dual-copy bug (`ServerTimestampTransform`) + `admin-scheduler.js`
      `runSoftDelete` referenced an undefined `deletedBy` (crashed the whole
       "Passed out" archive path); plus `MailLogEntry` couldn't parse live
       `Timestamp` objects → every row showed "time unknown".
- [x] Backend script-level verification pass, device-free (2026-10-01) —
      everything below was proven against live Firestore with Admin-SDK
      scripts (no phone UI): ground truth via `scripts/_qa_state.mjs`
      (**12** active students — 10 CS + 2 IT · Sept `late_logs` **15** after
      deleting the `26BSC001_muid9hel` probe residue · escalation queue 4
      docs all `period 2026-09` → period `2026-10` empty-state expected ·
      weekly 09-28…10-04: 5 rows, B.SC CS 3 distinct, repeated(≥2) =
      `26BSC001`+`26BSC011` · report_requests 12); report pipeline re-run
      (`generate-report.js` enqueue monthly Sept + dailies → process →
      **12/12 generated, 0 pending**, stats match ground truth: Sept
      15 entries / 6 distinct / B.SC CS 13 + B.SC IT 2, Sept-30 daily 2/2,
      Oct-1 daily 0/0, PDF `%PDF-1.3` + XLSX `PK` magic); mail pipeline
      drained (4 pending → `failed` carrying the exact Resend 403
      domain-verification message — G10 by design, no crash → dual-admin
      `createRequire` fix holds, queue now **0 pending**);
      `process-admin.js` clean (0 pending); **seed↔live reconciliation:
      `seed == live`** — `students.json` rebuilt to 12 rows mirroring
      Firestore (the 2 IT students added; per-row raw `1/2/3` years restored
      — the uniform "1st Year" rewrite from 09-30 was wrong, `yearTier`
      accepts both formats; 004's phone typo fixed; `(SAMPLE)` suffixes
      kept, they are stripped by `seed_project`), `departments.json` +
      `BSC-IT`, `seed_project.js` now writes `active: true` and passes
      `departmentId` through, seed README counts 11→12 + year-format
      wording corrected; `node scripts/seed_project.js seed` re-run proven
      safe (all 12 skip as "already present", departments/settings merge
      idempotent). **Bugs found & fixed this pass:** `process-escalation.js`
      imported `getFirestore` without `FieldValue` → crashed every run;
      `_qa_state.mjs` defaulted `repeatThreshold` to 3 — settings has no
      such field and the app + server both default to **2** (fixed; weekly
      repeated now matches the audit mail).

## Real-data onboarding & clean-slate wipe (2026-10-01)

> Supersedes the earlier "final phone pass" plan above (that plan stands only
> if the user revives it). No mail was sent at any point — HOD addresses are
> now real mailboxes; passwords live only in Firebase Auth + the gitignored
> `.env`, never in this file.

- [x] **1. Real credentials everywhere** — `.env` + `.env.example` comment
      blocks rewritten to real accounts (PT `pdarts@sankara.ac.in`, Admin
      `admin@sankara.ac.in`); `seed/departments.json` and the archive copy
      `project-docs/late_attendance/seed/departments.json` now carry all 7
      real HOD emails; `seed/staff.json` = 2 real rows; `NEW_DECISIONS.md` #19
      flipped from ⚠️ placeholder to ✅ resolved. Firebase Auth: created
      `pdarts@sankara.ac.in` (uid `Q07s11or4Mdeeg7YNfGEWAGDuE32`),
      `set_claims.js` → `role=pt_sir` + `staff/PT Sir` doc; sign-in verified
      live (idToken claim `role=pt_sir`). User confirmed #7 spelling →
      `computersciencearts@sankara.ac.in` (corrected from `sankra`).
- [x] **2. Clean slate** — new `scripts/wipe_test_data.js` (`--dry-run`
      previewed 97 docs → executed): wiped **every root Firestore collection
      except `settings`** (students 12, late_logs 16, escalation_queue 4,
      mail_queue 9, mail_logs 2, report_requests 12, report_logs 12,
      admin_requests 7, audit_logs 7, departments 2, staff 5,
      monthly_student_status 6, deletion_records 1, import_batches 1,
      pass_out_reviews 1); deleted the 3 test Auth users
      (`prithishrajmbsccs2024@`, `ptsir@`, `hod@` — user-approved) leaving
      only `pdarts@` + `admin@`; removed 16 local `reports/` QA files and the
      `settings/verify_muid9hel` probe doc. `_qa_state.mjs` extended with a
      `collectionCounts` line → post-wipe: only `settings` (1) + `staff` (2
      real, re-synced via `set_claims.js sync`, PT name fixed to "PT Sir").
- [x] **3. Roster + departments seeded** — `seed/students.json` rebuilt from
      `bsc_cs_students.json` (136 rows, validated: unique register numbers,
      years 1/2/3, dept BSC-CS) into the existing document shape
      (doc id + `studentId`, `registerNumber`, `departmentId`/`department`/
      `departmentName`, `year` as **string** — `Student.fromFirestore` casts
      `as String?` — `barcode`, `active`); `studentFields` extended to pass
      `studentId`/`registerNumber`/`departmentName` through (+ `String(year)`,
      existing `active: true`/`departmentId`); 136 existing docs backfilled
      with `studentId`. `seed_project.js seed` → **students=136**
      (byYear 1:39 / 2:50 / 3:47 = roster), **departments=7** (all 7
      hodEmails verified against the seed file), every other collection 0;
      3 full-field spot-checks passed (24BSC001 y3, 25BSC033 y2, 26BSC003 y1)
      + 7/7 HOD email match — "ALL SPOT-CHECKS PASSED".
- [x] **4. APK built** — `flutter build apk --debug` →
      `build\app\outputs\flutter-apk\app-debug.apk` (210.2 MB,
      2026-10-01 15:36); single `adb devices` check (full path
      `%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe`, one check, no
      retries) → **no device attached**; exact install command handed to the
      user in the final report instead.

## Production Hardening (2026-10-01)

> Scope per user brief. `[x]` only when genuinely verified. Skip policy: any
> step that drags (slow install, flaky device) is skipped + noted here and in
> the final summary. No mail sent during this task.

### Part A — App changes
- [x] A1. Scan option removed from admin side (kept on PT dashboard) — hidden for `_isAdmin`, PT untouched, widget tests green
- [x] A2. Student Management year/batch filter fixed → year-of-study dropdown ('1'/'2'/'3'); verified 39/50/47 against `_qa_state.mjs` byYear ground truth
- [x] A3. Register-number scan fallback: 3rd lookup branch (`where('registerNumber')`) + offline cache match + auto-reveal manual entry on decode fail; both barcode and manual paths tested
- [x] A4. Doc/artifact cleanup: tool/AI attribution stripped (rg sweep clean outside gitignored dirs); `.claude/`, `.agents/`, `skills-lock.json` gitignored

### Part B — Performance & code quality
- [x] B5. General rate limiting: `functions/rate-limit.js` sliding-window Firestore helper wired into all 8 callables (mail_send/report/import/admin_write buckets) + client 30-scans/min cap in ScanService (+ tests, functions 136/136). Review fixes: mail_send raised 10→30/h (bulk escalation+weekly morning must fit); retryAfterSec now Math.min over the window; enforceRateLimit moved AFTER argument validation in all 8 callables (malformed retries no longer consume quota, admin wrappers pre-check mirror the cores' NO_STUDENTS/MISSING_IMPORT_ID aborts). RESIDUAL: Spark queue path has no callable-level rate limit (rules cannot rate-limit direct writes) — runner dedup + queue rules bound it; accepted.
- [x] B6. Caching: `TtlMemo` helper — departments 5-min + reportRows params-keyed 60-s memos in FirebaseFirestoreService; admin-web loadDepartments promise-memo (busted on HOD save); Reports.tsx double range-fetch merged into one + dept/year clicks refilter locally (replaces planned 300ms debounce). Semantic cache SKIPPED: deterministic structured queries with no NL surface — a param-keyed TTL memo already covers every repeat.
- [x] B7. Lint: oxlint over functions/admin-web/scripts — 19 dead-code findings fixed, 0 warnings remain (gate passes); Dart via `flutter analyze` clean + `dart fix --apply` (nothing to fix)
- [x] B8. Latency pass: slow paths identified from recorded `[perf]`/prior runs (cold start 8.4–16.2 s, report preview 3.1 s, roster 2.7–6.9 s); fixes applied: report preview double-fetch on admin-web collapsed to one + dept/year clicks now local (B6 memos cover repeats). SKIPPED: live device capture (no device attached) and photo-field projection (cloud_firestore 6.10 / firebase 12 expose no Query.select — documented follow-up: photo → Storage migration)

### Part C — Security hardening
- [x] C1. Login rate limit 5 attempts / 15 min — `LoginThrottle` (Flutter, injectable clock, auto-release) + `loginThrottle.ts` (admin-web, localStorage ledger); lock blocks before Firebase is called; tests: pure ledger ×4 + widget lock flow + vitest ×5. Review fixes: ledger owned by State (widget-rebuild can't reset it), busy guard in _signIn, and network/throttle failures (`network-request-failed`, `too-many-requests`) no longer count toward the ledger on either client (`SignInOutcome.countsAsFailure` / `signInFailure()`)
- [x] C2. Hardcoded secrets scan: zero real credentials in tracked files; firebase-tools client secret moved to .env
- [x] C3. Env hygiene: .env + service-account + admin-web .env ignored (verified via git check-ignore post-init)
- [x] C4. Input sanitization: manual-entry caps, xlsx 5 MB cap, register-number length, maxLength fields, hodEmail format, script argv validation, firestore.rules payload caps (deploy + verify_rules + probe cleanup)
- [x] C5. Full security audit — secrets scan PASSED (0 findings); `npm audit`: functions 3 moderate (transitive uuid via exceljs/gaxios), scripts 2 moderate (same uuid), admin-web 9 high (grpc-js+braces chains — force-fix would DOWNGRADE firebase to 9.14 / rewrite tailwind 4, not applied); `pub outdated`: 12 upgradable transitives + google_fonts 8→9 & cupertino_icons 1→2 majors held back
- [x] V1. Exposed API keys — sweep found only Firebase web API keys (google-services.json + firebase_options.dart = public-by-design, guarded by app-restrictions + rules); the one real secret (FIREBASE_CLI_CLIENT_SECRET) moved to gitignored .env in C2
- [x] V2. Broken authentication — login throttle (C1); `AdminGateMixin` self-guards on all 4 admin sub-screens + PT-denial widget test (149/149); admin-web `AdminOnly` router gate on /settings (admin-only per user decision) + Settings nav hidden for PT, `canOpenSettings` unit tests (27/27). Review fix: role check wrapped in try/catch → deny-by-default (no spinner hang on fetch failure)
- [x] V3. Missing input validation — all C4 caps live: manual-entry 24-char + control-char deny, xlsx 5 MB pre-read, register ≤24 (client + functions + rules), search maxLength 64, hodEmail regex pre-flight, script slug argv; rules reject bad shapes (verify_rules probes)
- [x] V4. Row/document-level security — verify_rules.js 19/19 (incl. new cap probes: long deptId/extra key/bad enum all 403), probe residue swept (0 docs); role matrix: late_logs pt-only create, admin-only admin writes, mail/report queues pending-only client creates, update/delete server-only
- [x] V5. Outdated packages — findings listed above: npm audits kept as-is (only breaking fixes available; non-force fix ran clean, lock files unchanged); pub: google_fonts/cupertino_icons majors + 12 transitives; hive ^2.2.3 still used in lib/main.dart (unmaintained — migration noted as residual risk)

### Part D — GitHub
- [x] D. Own repo init + hardened .gitignore (env/secrets/node_modules/build/.claude/.agents/roster-PII excluded) + clean initial commit + pushed to https://github.com/prithish842-sys/Late-attendance (main, 310 files)

### Part E — Final review
- [x] E. Full code review (code-reviewer on the session diff) → verdict FIX FIRST; ALL findings fixed: CRITICAL secret-in-history (orphan-branch rewrite at final push), HIGH-2 mail bulk-send (stop-on-first-failure, clear only sent selections, rate-limit-specific snackbar with retryAfter minutes + "Sent so far" note via `callable_errors.rateLimitOf` on all 5 send/commit catches), HIGH-3 login ledger counts only credential errors (both clients), MEDIUMs (AdminGate deny-on-exception, State-owned throttle, _reportRowsMemo.clear() on late-log writes), LOWs (retryAfter Math.min, limit-after-validation, Settings changed-only email check, TtlMemo overwrite guard, manual-entry submit-time 24-char check), NITs (StackTrace.empty, dead Settings subtitle branch). SKIPPED NIT: Layout "Audit log" nav shown to PT — premise wrong (Audit page reads only staff-readable collections, never `audit_logs`). Accepted residuals: npm audit vulns (no non-breaking fix), hive unmaintained, Spark rate-limit gap (B5), callable-path cross-request dedup absent (queue path has runner dedup), secret remains in GitHub history until final push
- [x] Z. Final baselines green: flutter analyze 0 issues + **149/149** tests, functions **136/136**, admin-web tsc 0 + **29/29** vitest + oxlint 0 (admin-web + scripts)

