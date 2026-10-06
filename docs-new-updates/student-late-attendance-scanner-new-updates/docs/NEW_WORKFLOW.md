# New End-to-End Workflow

## 1. Daily PT Sir flow
Login -> Dashboard -> live date/time -> Scan Student -> camera scan OR manual register number -> student lookup -> verification page -> Submit -> duplicate check -> save/sync -> Dashboard today's list -> Reports/Audit update.

## 2. Daily rollover
At the next local date, today's dashboard query naturally returns zero records. No database wipe occurs.

## 3. Monthly rollover
Month-end job -> close active month -> audit snapshot -> reset monthly counters/status -> next month starts at zero. Historical late logs remain.

## 4. Repeated-late flow
Every valid scan calculates the student's current-month count. 1 = logged, 2 = warning, 3+ = escalation. Escalations can be grouped by department and reported to the relevant HOD.

## 5. Weekly audit
Aggregate late logs by department -> count unique students/events -> identify repeated students -> show departments sorted by count -> PT Sir selects department -> preview formal HOD mail -> generate PDF -> confirm send -> record mail status.

## 6. Admin flow
Admin imports new batch -> validates -> commits -> students become active -> pass-out review notification near batch end -> admin reviews -> soft delete/archive -> Recently Deleted -> restore or permanent delete after confirmation.

## 7. HOD report mail
Filter report -> choose HOD -> preview recipient/subject/body/student list -> generate combined PDF (default) or separate year PDFs -> explicit Send -> provider -> mail log.
