# DESIGN — Student Late Attendance Scanner

This document defines the visual identity for both the Flutter app (PT sir) and the React admin web app. It exists to stop the build from defaulting to a generic AI-generated look — a rounded-card SaaS kit, a cream-and-terracotta palette, or a near-black dashboard with a neon accent. Follow this instead of reaching for defaults.

## Why this direction
The subject isn't a generic SaaS tool — it's a physical, at-the-gate, security/discipline tool for **Sankara College of Science & Commerce**. The college already has a visual identity (seen on the student ID cards): a navy-blue shield crest, deep maroon/red used boldly (not as a timid accent), a clean white ground, and an NAAC A+ badge that signals institutional seriousness. The app should look like it belongs to this specific college, not like a template that could be reskinned for any college. Ground every screen in that identity rather than a default tech palette.

## 1. Color

| Token | Hex | Role |
|---|---|---|
| `--maroon-900` | `#8B1E1E` | Primary — headers, primary buttons, active states (drawn from the ID card's red) |
| `--maroon-700` | `#A82B2B` | Secondary emphasis, pressed/hover states |
| `--navy-900` | `#1B2A4A` | Secondary structural color — nav bars, headings on white, crest-adjacent elements |
| `--cream-50` | `#FAF8F5` | App background (not stark white — matches the card stock warmth) |
| `--ink-900` | `#232323` | Body text (soft black, not pure `#000` or a tinted `#0B0B0B`) |
| `--sand-200` | `#E8E2D8` | Dividers, card borders, subtle section separation |

**Status colors (functional, not decorative — used only for late-count severity):**
| Token | Hex | Meaning |
|---|---|---|
| `--status-ok` | `#2E7D4F` | 1st late (informational) |
| `--status-warn` | `#C77A1F` | 2nd late (warning) |
| `--status-escalate` | `#8B1E1E` | 3rd+ late (escalation — reuses primary maroon, reinforcing severity) |

Do not introduce a generic blue/purple gradient, a cream+terracotta combo, or a near-black-with-neon-accent scheme — those are the current AI-generated defaults and have nothing to do with this college's actual identity.

## 2. Typography

- **Headings / identity moments (app name, screen titles):** A grotesk with some institutional weight — e.g. **Fraunces** (for the rare display moment, like a splash/login screen) paired with a clean sans for everything else. Don't use a display serif everywhere; reserve it for one or two identity moments.
- **Body, data, UI labels:** **IBM Plex Sans** or **Inter** — chosen for numeral legibility, since PT sir is scanning ID numbers and counts under time pressure at the gate. Tabular figures matter more here than personality.
- No ALL-CAPS labels. No tracked-out eyebrow text above headings. No single word in a headline italicized or recolored for "emphasis" — if something needs emphasis, make it a separate, real UI element (a badge, a count), not a typographic trick.
- Numbers (late count, student ID, dates) should always use a tabular/monospaced-figure variant so columns in reports align.

## 3. Layout Concepts

### 3.1 Mobile — Scan Screen (PT sir)
This is the highest-stakes screen: used outdoors, under time pressure, likely one-handed. Design for speed and unambiguous confirmation, not for visual flourish.

```
┌─────────────────────────┐
│ [Sankara crest, small]  │  ← small, top-left; not centered/hero
│                          │
│   ┌─────────────────┐   │
│   │                 │   │
│   │  CAMERA VIEWFINDER │  ← full-width, dominant
│   │                 │   │
│   └─────────────────┘   │
│                          │
│   [Enter ID manually]    │  ← secondary, text link style, not a button
└─────────────────────────┘
```
After a successful scan, replace the viewfinder with a **full-bleed confirmation card** — student photo, name, ID, department, and a large color-coded late-count badge (`--status-ok/warn/escalate`). One clear "Confirm" action. No nested modals, no multi-step forms.

### 3.2 Web — Admin Dashboard
```
┌──────┬──────────────────────────────┐
│ Nav  │  Today's late count (large)  │
│      │  ─────────────────────────   │
│ Sank-│  Department bar chart        │
│ ara  │  ─────────────────────────   │
│ crest│  Recent scans (table, dense, │
│      │  not card-per-row)           │
└──────┴──────────────────────────────┘
```
- Left-aligned nav with the crest at top, not a centered logo lockup.
- Data tables stay as **tables** (dense rows, tabular numerals) — do not chop tabular report data into a grid of identical rounded cards with soft shadows. That pattern hides the thing admins actually need (fast row-to-row comparison).
- One deliberate accent per page — e.g., the department bar chart uses `--maroon-900` bars against `--cream-50`; don't add gradient washes or drop-shadows to every panel.

## 4. Motion
- One page-load moment maximum: the scan-to-confirmation transition (viewfinder → confirmation card) is the one moment worth animating, since it's the point where the user needs to register that something changed.
- No fade-and-slide-up entrances on dashboard sections, no hover-lift on every table row/card. Keep the admin dashboard static and information-dense; motion there should only respond to direct interaction (expanding a row, opening a filter).

## 5. Writing / Copy
- PT sir's UI: plain imperative verbs — "Scan ID", "Confirm", "Send mail" — never "Submit" or "Proceed."
- Errors describe what happened and what to do, in plain language: "Barcode not readable — enter the ID number instead," not "Scan failed. Please retry."
- No middle-dot-joined meta strings (`Dept · Year · ID`) — use real labels or a simple layout instead.
- No arrow (`→`) appended to buttons/links as a stylistic tic.

## 6. Accessibility / Quality Floor
- All interactive targets in the mobile app ≥ 44×44px (gate use, possibly gloved/rushed hands).
- Color is never the only signal for late-count severity — always pair the status color with the explicit count text ("2nd time this month"), since color-blind users and low-light gate conditions both reduce color reliability.
- Admin web: visible keyboard focus states, respects `prefers-reduced-motion`.

## 7. What to avoid (explicit anti-patterns for this build)
- The cream-background + terracotta-accent + high-contrast serif combo (common AI-generated default) — this college's own maroon/navy identity replaces it.
- Every dashboard panel as an identical rounded card with the same soft grey shadow.
- Numbered `01 / 02 / 03` markers unless the content is genuinely a sequence (e.g., onboarding steps) — a list of departments or students is not a sequence.
- A tracked-out ALL-CAPS eyebrow label above every section heading.
