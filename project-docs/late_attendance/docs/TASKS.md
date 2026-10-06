# TASKS — Student Late Attendance Scanner

Work through phases in order. Do not start a phase until the related rows in `DECISIONS.md` are resolved. Each phase should be a separate set of prompts/commits, not one giant build.

## Phase 1 — Foundation
- [ ] Set up Firebase project (Firestore, Auth, Storage, Functions)
- [ ] Define Firestore collections per `ARCHITECTURE.md` §2
- [ ] Build one-time CSV/Excel student import script (2500+ students)
- [ ] Flutter project scaffold + `mobile_scanner` integration
- [ ] Basic online-only scan + verify screen (no escalation logic yet)

## Phase 2 — Server-Side Escalation Logic
- [ ] Cloud Function: `onCreate` trigger on `late_logs`
- [ ] Implement count-per-reset-period logic (per `DECISIONS.md` #1)
- [ ] Write `warning` flag at 2nd late
- [ ] Write to `escalation_queue` at threshold (per `DECISIONS.md` #5)
- [ ] Firebase Auth custom claims for `pt_sir` / `admin` roles (exactly two, no third — NEW_SECURITY.md)
- [ ] Firestore + Storage security rules per `SECURITY.md` §5, §7

## Phase 3 — HOD Mail Automation
- [ ] Cloud Function endpoint: "send escalation mail for department X"
- [ ] Resend API integration (key in Cloud Function env vars only — `SECURITY.md` §6)
- [ ] Professional mail template (student photo, ID, dept, late-dates table)
- [ ] Multi-student bundling into single mail with Excel/PDF attachment
- [ ] `mail_logs` write-back for audit trail

## Phase 4 — Reports
- [ ] Server-side Excel generation (ExcelJS)
- [ ] Server-side PDF generation (PDFKit)
- [ ] Daily/Weekly/Monthly report filters (department, year, date range)

## Phase 5 — Offline Mode
- [ ] Hive/Isar local storage integration in Flutter app
- [ ] Connectivity Plus — detect online/offline state
- [ ] Local scan queue when offline
- [ ] Sync logic on reconnect, using deterministic doc ID (`SECURITY.md` §3)
- [ ] `deviceTimestamp` vs. server-time validation on sync (`SECURITY.md` §2)

## Phase 6 — Admin Web Dashboard
- [ ] React + Vite + TypeScript + Tailwind scaffold
- [ ] Login (Firebase Auth)
- [ ] Dashboard: today's count, department-wise chart (Recharts)
- [ ] Reports page (filters + export)
- [ ] Settings page (cutoff time, threshold, HOD emails, reset period)
- [ ] Audit log page (who scanned what, when)
- [ ] Deploy to Vercel

## Phase 7 — AI Features (Optional)
- [ ] Gemini-powered report summary generation
- [ ] Gemini-assisted professional mail drafting (still triggered by deterministic logic, not by Gemini's judgment)
- [ ] Admin natural-language query interface ("this month CSE la 3 times late vantha students yaaru?")

## Definition of Done (per phase)
- All checklist items complete
- Related `DECISIONS.md` rows resolved
- Related `SECURITY.md` rules implemented and verified (not just planned)
- Manually tested on PT sir's actual device/network conditions before moving to next phase
