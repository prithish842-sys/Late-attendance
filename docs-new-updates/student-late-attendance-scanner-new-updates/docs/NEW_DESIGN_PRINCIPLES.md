# UI/UX Design Principles for This App

These are the specific laws/rules to apply while building every screen in
`NEW_DESIGN.md`. They are not decoration — each one maps to a real problem PT Sir
or Admin will hit while using this app in a hurry.

## 60-30-10 Color Rule
Every screen uses three color roles only, in this ratio:
- **60% Neutral (base):** background, containers, large surfaces — off-white/light
  or dark surface, following the college's maroon/navy/cream palette from
  `DESIGN.md`, not generic gray.
- **30% Secondary (support):** cards, dividers, secondary text, inactive icons.
- **10% Accent (highlight):** ONE strong color reserved only for primary actions
  and status — the `Scan Student` button, `Submit`, escalation badges (2nd
  warning / 3rd escalated), `Send Report` / `Send Mail` buttons.
Do not spread the accent color across the whole screen — if everything is
highlighted, nothing is. Escalation severity colors (logged / warning /
escalated) count as accent usage and should be visually distinct from each other
but still within the 10% budget per screen.

## Hick's Law — Reduce Choices
More options on a screen = slower decisions. Apply this to:
- PT Sir Dashboard: only **one** primary action visible at a time — `Scan
  Student`. Everything else (today's list, audit suggestion) is secondary and
  visually smaller.
- Verification page: only two actions — `Submit` and `Scan Next Student`. No
  extra buttons competing for attention.
- Settings replacement area: keep it to the minimum toggles PT Sir actually
  needs (see `NEW_UPDATES_PRD.md` → Settings), not a full options menu.

## Fitts's Law — Make Actions Easier
Bigger target + closer to where the thumb already is = faster, fewer mis-taps.
- `Scan Student` on the dashboard must be the largest, most reachable tappable
  element on the screen (bottom half, thumb zone), not a small icon in a
  corner.
- `Submit` on the verification page should be a full-width button, not a small
  link-style action — PT Sir is scanning quickly, back-to-back, at the gate.
- Destructive actions in Admin (permanent delete) should be intentionally
  **smaller and further from the thumb's natural rest position**, with a second
  confirmation — the opposite treatment of Fitts's Law, used deliberately to
  prevent accidental taps.

## Jacob's Law — Use Familiar Patterns
Users spend most of their time on other apps, so this app should behave the way
they already expect:
- Camera scan screen = standard scanner UI (viewfinder box, torch toggle,
  manual-entry link/box below) like any QR/barcode scanner app.
- Filters on the Reports page = standard chip/dropdown filter pattern (like
  shopping or file-manager filter bars), not a custom novel control.
- Login = standard email + password (or PIN) form, nothing unusual.

## Miller's Law — Chunk Information
People hold ~5-9 items in working memory at once. Group, don't list flat:
- Verification page groups student info as **Name → Register No → Department →
  Year** as one visual block, then late-status as a separate block below —
  not eight loose fields in a row.
- Weekly Audit groups by **department first**, then shows students inside each
  department group — not one long flat student list.
- Register numbers/phone-style numbers in any confirmation screen should be
  visually chunked (e.g. `24BCS 001` spacing) rather than one long digit string.

## Peak-End Rule — Create Memorable Moments
People judge a flow by its peak moment and how it ends, not every step.
- The **peak** of the scan flow is the verification page — make the
  student-found confirmation clear and satisfying (photo + green check state),
  since this is the moment PT Sir is actually verifying against.
- The **end** of the scan flow (after Submit) should clearly confirm success
  before returning to dashboard — a brief, calm confirmation state, not an
  abrupt jump back.
- The end of the HOD mail flow (after Send) should clearly confirm "Mail sent
  to [HOD name]" rather than silently returning to the report page.

## Proximity — Group Related Things
Related controls sit close together, unrelated controls have visible space
between them:
- Filter controls (Department, Year, Date range) sit together as one filter
  bar, visually separated from the results table below.
- On the Recently Deleted page, `Restore` and `Permanent Delete` for the same
  student sit together on that student's row, clearly separated from the next
  student's row.

## Von Restorff Effect — Highlight What Matters
The one thing that must stand out, should actually look different from
everything else on the screen:
- A student on their **3rd+ late (escalated)** should look visually distinct
  from a normal "1st late (logged)" row — not just a small badge color change
  buried in the row, but a clearly different row treatment (e.g. accent-colored
  left border or background tint).
- The `Weekly Audit` suggestion at week-end should visually stand out from the
  regular dashboard content so PT Sir doesn't miss it, without turning into a
  disruptive popup.

## What to avoid (carried over from `DESIGN.md`)
Do not undo the "avoid generic AI-SaaS look" direction already set in
`DESIGN.md` while adding these laws — apply the laws using the existing maroon/
navy/cream palette and typography, not a new generic style. No identical
rounded-shadow cards for every block, no "01/02/03" step markers, no arrow (→)
buttons, no cream+terracotta combo.
