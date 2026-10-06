# Data Lifecycle

## Active students
Available to scanner and normal reports.

## Soft-deleted/archived
Unavailable for new scans; retained for recovery during retention period; Admin-only visibility.

## Permanently deleted
Remove active student record and associated photo storage object where policy permits. Keep required deletion/audit evidence.

## Late logs
Never clear all late logs for a daily or monthly reset.

## Monthly counter
Rotate/reset `monthly_student_status` only.

## Images
Use stable photo identifiers and client caching. Avoid duplicate downloads/uploads. Clean obsolete storage objects during permanent deletion when allowed.

## Yearly maintenance
Review pass-out batches -> archive -> review Recently Deleted -> permanent delete only after retention approval -> review storage/audit usage.
