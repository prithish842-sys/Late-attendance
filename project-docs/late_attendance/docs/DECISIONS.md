# DECISIONS — Student Late Attendance Scanner

Finalized decisions are marked ✅. Anything still open is marked _TBD_ — an AI coding agent should treat _TBD_ rows as blockers and ask before assuming a default.

| # | Question | Decision | Notes |
|---|---|---|---|
| 1 | Escalation reset period | ✅ **Monthly** | Cloud Function counts `late_logs` for the current calendar month only. Count resets on the 1st of every month. |
| 2 | Escalation threshold | ✅ **3 times per month** | On the 3rd late scan in the same month, the student is added to `escalation_queue` and an HOD mail is triggered. Stored in `settings.escalationThreshold` (configurable, default 3 — don't hardcode). |
| 3 | Late cutoff time | ✅ **Removed as a separate configurable setting — college start time is 9:45 AM.** | The app no longer does a "current time > cutoff" check. PT sir only scans students who are *already* arriving after 9:45 AM at the gate — the act of scanning itself is what creates a `late_logs` entry. This simplifies the flow: **scan = late**, no time-comparison logic needed in Phase 1. (If a configurable cutoff is wanted again later, `settings.lateCutoffTime` can be reintroduced — see `ARCHITECTURE.md`.) |
| 4 | Mail sending provider | ✅ **Resend API** | Free tier (3,000 mails/month, 100/day) comfortably covers this scale (3 staff, small student batches). Zero IT-department setup needed, better deliverability than typical college SMTP. Revisit only if mail volume grows far beyond free-tier limits after a full college rollout. |
| 5 | Barcode data | ✅ **Separate field from `studentId`, filled during seeding** | ID card's physical barcode number may differ from the internal `studentId` format. `students.json` has a dedicated `barcode` field — scan each of the 11 sample ID cards and enter the *exact* barcode value there. Firestore lookup on scan happens by `barcode`, which resolves to the matching student record. |
| 6 | Student master data source | _TBD_ | College ERP export / Manual CSV entry — decide before Phase 1 bulk import beyond the 11 sample students. |
| 7 | Play Store distribution | _TBD_ | APK sideload to PT sir's phone only (recommended for v1, single-device internal tool) / Full Play Store release. |

## Impact of removing the cutoff-time check (#3)
This simplifies `docs/ARCHITECTURE.md` §3 (automation flow) slightly — the "Check Late Cutoff" step is no longer part of the Cloud Function logic. Every `late_logs` write is treated as a late entry by definition. If this project doc set needs updating to reflect that in `ARCHITECTURE.md` and `PRD.md` too, say so and it'll be rewritten there as well.

## How to update this file
When a _TBD_ row is finalized, replace it with ✅ and the chosen option, and add reasoning to Notes. Do not delete resolved rows — they document why the system behaves the way it does.
