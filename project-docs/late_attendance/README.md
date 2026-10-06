# Student Late Attendance Scanner

A gate-side scanning system for tracking student late arrivals, auto-escalating repeat late-comers to their department HOD, and generating attendance reports.

## Project Docs
- [`docs/PRD.md`](docs/PRD.md) — what the app does, features, users
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — tech stack, DB schema, automation flow, screens
- [`docs/SECURITY.md`](docs/SECURITY.md) — security fixes applied and hard constraints for development
- [`docs/DECISIONS.md`](docs/DECISIONS.md) — open questions to resolve before/during development
- [`docs/TASKS.md`](docs/TASKS.md) — phase-wise build plan

## Structure
```
late_attendance/
├── docs/            # all project documentation (read before coding)
├── src/             # Flutter app + Cloud Functions + Admin web source
├── tests/           # test files
├── .env.example     # placeholder env vars — copy to .env and fill in locally, never commit .env
└── .gitignore
```

## Tech Stack (short version)
Flutter + Dart (mobile) · Firebase (Firestore, Auth, Storage, Cloud Functions) · Hive/Isar (offline) · React + TypeScript + Vite + Tailwind (admin web) · Resend (mail) · ExcelJS/PDFKit (reports) · Gemini API (optional, Phase 7)

Full detail: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)

## Getting Started
1. Read `docs/PRD.md` and `docs/ARCHITECTURE.md` first.
2. Resolve the open items in `docs/DECISIONS.md`.
3. Copy `.env.example` to `.env` and fill in your own Firebase/Resend keys (never commit `.env`).
4. Follow `docs/TASKS.md` phase by phase — do not skip ahead.
5. Every Cloud Function / security rule change must match what's described in `docs/SECURITY.md`.

## Status
Project planning complete. Development not yet started — see `docs/TASKS.md` for Phase 1.
