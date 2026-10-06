# New Architecture

Keep the existing Flutter/Dart mobile + Firebase + React/TypeScript/Vite admin architecture.

## Mobile modules
- auth
- dashboard
- scanner
- manual lookup
- verification
- reports
- audit
- mail
- cache
- offline sync

## Admin modules
- student management
- batch import
- lifecycle
- recently deleted
- department/HOD master
- system configuration
- audit

## Backend services
- student lookup
- late-log creation
- idempotent duplicate protection
- monthly aggregation
- weekly aggregation
- month-end job
- pass-out notification
- PDF/Excel generation
- mail sending
- mail audit logging

## Collections
### students
studentId, registerNumber, name, departmentId, departmentName, currentYear, batchStartYear, batchEndYear, photoUrl, active, archivedAt, deletedAt, createdAt, updatedAt

### late_logs
logId, studentId, registerNumber, departmentId, departmentName, year, localDate, scannedAt, scannedBy, scanMethod, status, syncStatus, idempotencyKey

### monthly_student_status
studentId, monthKey, lateCount, status, updatedAt

### departments
departmentId, name, hodName, hodEmail

### mail_logs
mailId, type, departmentId, recipient, dateRange, filters, attachmentNames, sentBy, sentAt, providerStatus

### audit_logs
actorId, action, targetType, targetId, timestamp, metadata

### deletion_records
studentId, deletedAt, deletedBy, reason, originalStudentData, retentionUntil

## Duplicate key
`studentId + localDate`

Enforce this on the backend as well as the UI.

## Daily/monthly reset
Daily = query/view reset. Monthly = active counter/status rollover. Neither means deleting historical late logs.
