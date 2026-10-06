# New Security Interpretation

## Roles — confirmed
This app has exactly **two** roles: **PT Sir** and **Admin**. There is no HOD
login, HOD account, or HOD-facing screen anywhere in the app. HOD only ever
appears as an **email recipient** (name + email stored in the `departments`
collection) that PT Sir sends reports/audit mail to. Do not add a third role,
a HOD dashboard, or HOD authentication anywhere in the codebase or docs.

## Firebase permission/password removal
The request to remove Firebase permission/password setup means: remove the
manual setup friction the developer currently deals with — e.g. a hardcoded
Firestore/Storage security-rule password prompt, an extra manual
permission-approval step, or an interim rule set added only to unblock local
development — not opening the production database to the public internet.
In practice this means simplifying `firestore.rules`/`storage.rules` down to
role-based checks (PT Sir / Admin, both authenticated via Firebase Auth) so
there is no separate manual password step beyond normal login, while never
setting rules to `allow read, write: if true;` in production. If a temporary
fully-open rule set is being used only for local dev/testing, it must be
clearly labeled as dev-only and never deployed to the production project.

Keep:
- Firebase Authentication
- Firestore/Storage rules
- role checks
- backend validation
- server-side duplicate protection
- audit logs
- secrets outside client source

PT Sir can scan, search, view allowed reports, preview/send HOD reports and view audit information.

PT Sir cannot delete master student data, permanently delete, change Firebase configuration, change monthly threshold, change system time or edit HOD master data.

Admin can manage imports, batch lifecycle, restore/permanent deletion, department/HOD data and system configuration.

Never hard-code database/service-account passwords in the app.
