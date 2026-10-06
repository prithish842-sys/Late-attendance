# PRD — Student Late Attendance Scanner

## 1. Problem Statement
Students who arrive late to college are not currently tracked in a structured way. Repeat late-comers go unnoticed, daily attendance gets disturbed, and there is no easy way for gate-duty staff (PT sir) to identify repeat offenders and escalate the matter to the concerned HOD.

## 2. Goal
Build a simple gate-side scanning app that:
- Lets PT sir scan/verify late students in 2–3 taps.
- Tracks how many times each student has been late in the current reset period.
- Automatically escalates repeat late-comers (3+ times) to the department HOD via email.
- Generates daily/weekly/monthly reports (Excel/PDF).

## 3. Users
| Role | Description |
|---|---|
| PT Sir / Gate Duty Staff | Primary user. Scans barcodes/IDs at the gate. Needs an extremely simple interface. |
| Admin | Manages settings (cutoff time, threshold, HOD emails), views all reports. |
| HOD | Receives escalation emails, no app login required (email only). |

## 4. Core Features

### 4.1 Scan & Verify
- PT sir scans the barcode on the student ID card, or manually types the student ID (backup if barcode is damaged/unreadable).
- App checks current time against a configurable late cutoff (e.g., 9:15 AM), set in Admin Settings — not hardcoded.
- If late, records the entry with timestamp and shows:
  - Name, Student ID, Year, Department
  - Number of times late in the current reset period (1st / 2nd / 3rd+)
- Same student cannot be recorded as late twice on the same day (duplicate protection).

### 4.2 Escalation Logic
| Late Count | Action |
|---|---|
| 1st time | Logged only |
| 2nd time | Warning flag shown to PT sir |
| 3rd time (configurable threshold) | Added to Escalation Queue |

- Reset period: monthly or semester-wise (finalize in `DECISIONS.md`).
- Escalation Page: lists all students who crossed the threshold, grouped by department.
- PT sir/Admin selects student(s) → clicks "Send Mail to HOD".
- Auto-generated professional email includes: student photo, name, ID, department, year, table of late dates, total count.
- Multiple students from the same department in one period → bundled into a single mail with an Excel/PDF attachment table.

### 4.3 Reporting
- Daily / Weekly / Monthly reports.
- Filters: department, year, date range.
- Export: Excel (.xlsx) and PDF.
- Trend view (once enough data exists): department-wise comparison, most common late-arrival weekday.

### 4.4 Access & Security
- PT sir and Admin log in via Firebase Authentication (role-based, see `SECURITY.md`).
- Every scan logs who scanned + when (audit trail).

### 4.5 Offline Mode
- Treated as a core requirement (gate area network is often weak).
- Scans save locally when offline, auto-sync when connection returns.
- Duplicate-safe sync (see `ARCHITECTURE.md` §5.3 for the fix applied).

## 5. Out of Scope (for now)
- Parent SMS/notifications (future).
- Multi-gate / multi-scanner support (future, single gate assumed for v1).
- Gemini AI features — planned for Phase 7, not required for core functionality (see `TASKS.md`).

## 6. Success Criteria
- PT sir can complete a scan-to-verify cycle in under 5 seconds.
- Zero duplicate late entries per student per day.
- Escalation mail sent automatically and correctly once threshold is crossed, without manual counting.
- Reports exportable in Excel/PDF for any date range.
