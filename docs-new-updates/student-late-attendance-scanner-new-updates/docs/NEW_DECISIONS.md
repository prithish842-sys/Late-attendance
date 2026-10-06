# New Decisions

1. Preserve the existing Flutter/Firebase/React architecture.
2. PT Sir remains the mobile-first operational role.
3. Admin manages student master data and lifecycle.
4. Daily reset is a view/query reset, not database deletion.
5. Monthly reset affects active counters/status, not historical logs.
6. 3-late escalation is within the same calendar month.
7. Department/year filters are first-class report filters.
8. HOD mail requires preview and explicit send.
9. Combined PDF is default; separate year PDFs are optional.
10. Weekly audit sorts actual counts; any high-count threshold is configurable.
11. Explicit batch years are authoritative; register parsing is secondary.
12. Student deletion is two-stage: soft delete/recovery, then permanent delete.
13. Historical audit data is retained according to policy.
14. Firebase setup is simplified without removing production authorization.
15. Backend/provider mail is the reliable attachment path; Gmail compose handoff is optional.
16. Exactly two roles exist — PT Sir and Admin. HOD has no login/role; HOD is only a mail recipient.
17. Firebase "permission/password removal" means removing manual dev-setup friction only — production rules stay role-based, never fully open.
18. UI/UX must follow the 60-30-10 rule, Hick's, Fitts's, Jacob's, Miller's, Peak-End and Von Restorff principles as detailed in `NEW_DESIGN_PRINCIPLES.md`.
19. Real accounts (single source of truth in `.env` — `FIREBASE_DEMO_*`, never hardcoded in scripts): PT Sir login = `pdarts@sankara.ac.in` (`pt_sir` claim); Admin = `admin@sankara.ac.in` (`admin` claim). HOD has no login (per #16); HOD mail recipients are per-department real addresses configured only in seed/config data (`seed/departments.json` → Firestore `departments.hodEmail`): BSC-CS `computersciencearts@sankara.ac.in`, BSC-IT `itarts@sankara.ac.in`, BSC-MGMT `managementarts@sankara.ac.in`, BSC-COM `commercearts@sankara.ac.in`, BSC-COM-PAA `commercepaatrs@sankara.ac.in`, BSC-COM-CA `commercecaarts@sankara.ac.in`, BSC-CAT `cateringarts@sankara.ac.in`. Passwords live only in Firebase Auth and the local gitignored `.env` — never in committed files.

    > ✅ **RESOLVED (2026-10-01)** — the former placeholders (PT Sir `prithishrajmbsccs2024@sankara.ac.in`, HOD recipient `kanishkak@sankara.ac.in`) were replaced: PT/Admin logins in `.env` + Firebase Auth (old `prithishrajmbsccs2024@`, `ptsir@`, `hod@` Auth users removed), HOD recipients in `seed/departments.json` → Firestore `departments/{id}.hodEmail`. Swap points remain `.env` (`FIREBASE_DEMO_PT_SIR_EMAIL/PASSWORD`), `seed/departments.json` (`hodEmail`), and live Firestore `departments/{id}.hodEmail`.
