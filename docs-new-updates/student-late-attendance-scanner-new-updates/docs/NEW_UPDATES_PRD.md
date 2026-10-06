# Student Late Attendance Scanner — New Updates PRD

## PT Sir
- Dashboard shows live date/time, prominent `Scan Student` CTA, today's scanned students and count.
- Scanner opens camera for barcode/QR.
- Manual Register Number input is available below scanner as fallback.
- Successful lookup opens a verification page with photo, name, register number, department, year and current-month late status.
- `Submit` commits the scan; `Scan Next Student` returns to scanner flow.
- Today's dashboard list updates immediately after submit.
- Dashboard resets its *view/count* at the next local calendar day; historical late logs are never deleted.
- Student photos use device/browser caching with bounded cache size/eviction.
- Existing offline queue/sync remains.

## Escalation
Within the same calendar month:
1. first late = logged
2. second = warning
3. third+ = escalated
- Same student + same local date cannot be scanned twice.
- Historical logs remain available.

## Reports
Keep existing daily/weekly/monthly/custom reports.
Add:
- Department filter
- Year filter: 1st/2nd/3rd
- Date range
- Combined filters
- Filtered Excel/PDF download
- HOD search/selection
- `Send / Forward Report` preview
- Formal email body
- Year-wise student list in 3rd, 2nd, 1st order
- PDF attachment
- Optional separate PDFs by year; combined PDF remains default.

## Settings
Remove the separate PT Sir Settings page for now. Keep only a compact account/operational-preferences area if required. PT Sir must not change system time, escalation threshold, Firebase configuration or HOD master data.

## Weekly Audit
Show:
- departments sorted by late-student count
- unique late students
- total late events
- repeated-late students
- search/filter
- HOD mail status/history
- week-end `Weekly Audit` suggestion

Do not hard-code a subjective “high” threshold; use actual counts or a configurable threshold.

## Admin
- Excel batch import with batch range, department and student details
- validation/preview before commit
- batch filters
- pass-out review notification
- soft delete/archive
- Recently Deleted
- restore
- second-confirmation permanent delete
- storage cleanup when permanently deleting photos
- developer-only seed/import utility remains separate

## Batch logic
Store `batchStartYear` and `batchEndYear` explicitly. A register number such as `24BCS001` can assist validation, but should not be the only source of batch information.

## Monthly rollover
At month end:
- create audit snapshot
- reset active monthly counters/status
- start next month at zero
- keep historical late logs

## Firebase setup interpretation
Remove unnecessary manual setup/password friction, but do NOT make production Firestore/Storage publicly writable. Keep authentication, role authorization, server validation and audit logging.
