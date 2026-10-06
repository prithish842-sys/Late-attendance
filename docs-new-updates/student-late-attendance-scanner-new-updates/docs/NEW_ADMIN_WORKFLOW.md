# Admin Student and Batch Lifecycle

## Excel import
Recommended columns:
Register Number | Student Name | Department | Current Year | Batch Start Year | Batch End Year | Photo URL(optional)

Example:
`24BCS001 | Student Name | B.Sc Computer Science | 1 | 2024 | 2027`

Validate required columns, duplicate register numbers, department, year and batch range before commit.

## Lifecycle
Active -> Pass-out Review -> Archived -> Soft Deleted -> Permanently Deleted

A pass-out notification asks Admin to review; it must not auto-delete students.

## Delete page
Filters: batch, department, year, search.
Action: soft delete/archive.

## Recently Deleted
Show student, register number, department, batch, deleted date, deleted by, Restore and Permanent Delete.

Permanent delete requires a second confirmation.

## Retention
Historical late logs/audit evidence may need retention or anonymization even after a student leaves. Do not blindly delete all historical logs.

Keep developer-only seed/import utilities separate from PT Sir.
