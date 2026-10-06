# Seed Data

This folder holds sample/initial data used for the one-time import into Firebase (see `docs/TASKS.md` Phase 1).

## Files
- `students.json` — 2 sample rows given as template. Copy the shape for all 11 of your students. `photoFile` must match the exact filename in `student-photos/`.
- `staff.json` — 2 staff entries (pt_sir, admin roles — exactly two, no third). `email` is used for Firebase Auth account creation.
- `departments.json` — one row per department, with the HOD's email (used by the escalation-mail Cloud Function).
- `student-photos/` — put each student's ID photo here, filename exactly matching `photoFile` in `students.json` (e.g. `25BSA001.jpg`).

## How this gets used
1. The Phase 1 import script reads `students.json` + `departments.json` + `staff.json`.
2. Student/staff/department records are written into Firestore (`students`, `staff`, `departments` collections — see `docs/ARCHITECTURE.md` §2).
3. Each photo in `student-photos/` is uploaded to Firebase Storage; the resulting URL is written into that student's `photoUrl` field. The raw image is never stored inside Firestore or the JSON itself.
4. Staff accounts are created in Firebase Authentication, and custom claims (`role: pt_sir | admin`) are set — see `docs/SECURITY.md` §4.

## Important
- This is real student data (even if only 11 sample records) — do not commit `student-photos/` to a public GitHub repo. Keep the repo private, or add `seed/student-photos/` to `.gitignore` if you want to be extra safe.
- Replace every `REPLACE_...` placeholder before running the import script.
