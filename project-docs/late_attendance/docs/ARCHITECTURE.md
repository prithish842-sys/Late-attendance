# ARCHITECTURE — Student Late Attendance Scanner

## 1. Full Tech Stack

### 1.1 Mobile App (PT Sir)
| Technology | Purpose |
|---|---|
| Flutter + Dart | Cross-platform mobile app |
| Material 3 | UI components |
| `mobile_scanner` | Barcode/QR scanning |
| Firebase SDK | Firebase integration |
| Hive / Isar | Local offline database |
| Connectivity Plus | Detect internet availability |
| Shared Preferences | Local session/settings |
| Firebase Auth (custom claims) | Role-based login |

### 1.2 Backend / Cloud (Firebase)
| Service | Purpose |
|---|---|
| Cloud Firestore | Students + attendance database |
| Firebase Authentication (custom claims) | PT sir / Admin / HOD roles |
| Firebase Storage | Student photos |
| Cloud Functions | All decision logic — escalation count, mail trigger, server-time validation |
| Firebase Security Rules | Role-based read/write access |
| Firebase Cloud Messaging | Optional push notifications (future) |

### 1.3 Admin Web App
| Technology | Purpose |
|---|---|
| React.js + TypeScript | Web UI |
| Vite | Build tool |
| Tailwind CSS | Styling |
| Recharts | Dashboard charts |
| React Router | Navigation |

### 1.4 Mail & Reports
| Technology | Purpose |
|---|---|
| Resend API (Cloud Function only, never client-side) | HOD escalation mail |
| ExcelJS | Excel report generation (server-side) |
| PDFKit | PDF report generation (server-side) |

### 1.5 AI (Phase 7, optional)
| Technology | Purpose |
|---|---|
| Gemini API | Report summaries, mail drafting assistance, admin natural-language queries. **Never decides escalation — that stays deterministic in Cloud Functions.** |

### 1.6 Dev Tools
VS Code, Android Studio, Flutter SDK, Firebase CLI, Git/GitHub, Postman, Chrome DevTools.

### 1.7 Hosting
- Mobile: APK direct install on PT sir's phone → AAB/Play Store later if needed.
- Admin web: Vercel.
- Backend: Firebase (no separate Node/Express server needed for v1).

## 2. Database Schema

**students**
```
studentId (doc ID)
name
department
year
phone
photoUrl
barcode
```

**late_logs** — doc ID = `studentId_YYYY-MM-DD`
```
studentId
scannedBy         // staff UID
scanTimestamp     // Firestore serverTimestamp
scanMethod        // "barcode" | "manual"
syncedOffline     // true if created offline then synced
deviceTimestamp   // stored for audit comparison against server time
```

**staff**
```
uid               // Firebase Auth UID
name
role              // custom claim: pt_sir | admin (exactly two roles)
```

**departments**
```
id
name
hodEmail
```

**settings**
```
lateCutoffTime
escalationThreshold   // default 3
resetPeriod           // "monthly" | "semester"
```

**mail_logs**
```
departmentId
sentTimestamp
studentsIncluded[]
triggeredBy       // staff UID
```

## 3. Corrected Automation Flow

```
PT Sir scans barcode
        |
Online?  --No--> Save to Hive/Isar (local) with deviceTimestamp
   |Yes                    |
   v                       v (when back online)
Write late_logs doc         Sync queue -> write late_logs doc
(ID = studentId_date,             (server validates deviceTimestamp
 serverTimestamp used)              vs. server receipt time)
        |
        v
Cloud Function (onCreate trigger)
        |
        +- Count late_logs for this student, current reset period
        +- 1st -> log only
        +- 2nd -> set warning flag
        +- 3rd+ -> add to escalation_queue
        |
        v
Admin/PT sir opens Escalation Page
        |
        v
Click "Send Mail to HOD"
        |
        v
Cloud Function (server-side only)
   +- Builds student table (name, ID, dept, late dates)
   +- Generates Excel/PDF attachment if multiple students
   +- Calls Resend API (key stored server-side, see SECURITY.md)
        |
        v
HOD receives professional escalation mail
```

## 4. Key Fixes Applied (summary — full detail in SECURITY.md)
1. Escalation decision computed server-side (Cloud Function), not on the client.
2. `serverTimestamp()` used for the late/on-time decision, not device clock.
3. Deterministic doc ID (`studentId_date`) eliminates duplicate-scan race conditions.
4. Firebase Auth + custom claims replace a client-writable PIN field.
5. Role-specific Firestore/Storage security rules.
6. Resend API key lives only in Cloud Function environment variables.

## 5. Screens

### Mobile App (PT Sir)
1. Login (Firebase Auth)
2. Scan screen (camera scanner + manual ID entry toggle)
3. Student verify screen (details + late count + confirm)
4. Escalation list screen (grouped by department, checkbox select, "Send Mail" button)
5. Reports screen (date range picker -> download Excel/PDF)

### Admin Web
1. Login
2. Dashboard (today's late count, department-wise chart)
3. Reports (filter + export)
4. Settings (cutoff time, threshold, HOD emails, reset period)
5. Audit log (who scanned what, when)

## 6. Student Data Import
- One-time bulk import from CSV/Excel (2500+ students) via an import script into Firestore.
- Example CSV: `student_id,name,department,year,barcode`
