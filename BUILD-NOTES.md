# Build notes

## What changed in 9.6.9 — the fleet list becomes a haulier register
The fleet record already carried a Transporter, and the template already had
the column. What was missing was the view: the yard thinks in hauliers, not in
a flat list of plates.

* **Fleet tab now has two views** — *All trucks* (the old table) and
  *By transporter*. The second groups the same records by haulier, no data
  duplicated: the fleet record stays the single source of truth.
* Each haulier card shows truck count, driver count, average tare, and
  **loads + tonnes moved in the last 30 days** (matched on registration, or on
  the ticket's own transporter field). Collapsible, sorted by fleet size.
* Trucks with no transporter are collected under a flagged
  "no transporter recorded" card, so the gaps are visible instead of hidden.
* **Transporter filter** on both views.
* **Export by Transporter** — one workbook, one sheet per haulier. Per-haulier
  **Export** on each card produces that haulier's own list plus the
  Instructions sheet, ready to mail out for them to check and send back.
* **Import preview** now shows a truck that has changed haulier as
  `Old Transporter → New Transporter`, counts the transporters in the file,
  and warns about rows with no transporter before anything is written.
* **Orders:** the fleet restriction gains "+ Add a transporter's whole fleet…",
  which drops every registration on that haulier's list into the restriction.
  Locking an order to one transporter no longer means typing 40 plates.

## What changed in 9.6.8 — the branding, done properly
One logo file cannot do three jobs, so there are now three renditions built
from the supplied artwork:

| Where | Rendition | Why |
|---|---|---|
| App header | Gold monogram on **transparency** | Sits straight on the dark gradient. The old build boxed the logo in a white chip, which fought the branding. |
| Login / activation | Full gold lockup on transparency, 132 px | Room to show the wordmark, so it gets shown. |
| Ticket | **Solid black on white** | A thermal head fires or it does not. Gold prints as grey mush; the ticket gets a true 1-colour rendition with the hairlines thickened so nothing drops out at small sizes. |

* Header grown from 64 px to 78 px with a 62 px mark; company name up to
  16 px and the tagline given more letter-spacing. Big and readable.
* `build/icon.png` (512×512) and `build/icon.ico` regenerated from the mark on
  black. The .ico carries 16 / 24 / 32 / 48 / 64 / 128 / 256, so it stays sharp
  in the taskbar, Alt-Tab, the Start menu and Explorer.
* **Migration:** an installed copy already has the old logo saved inside
  `cfg.ticket.logo`, so a new default alone would never reach it. `cvLogoMigrate()`
  runs once per PC (guarded by `cfg.logoRev`) and swaps in the black & white
  ticket rendition. A site that deliberately uploaded its own logo is left alone
  — uploading now sets `ticket.logoCustom`.
* Settings → Ticket gains a **Reset logo** button.

## What changed in 9.6.7 — templates the customer can actually read
**Bug fixed first:** the 9.6.5 Fleet buttons shipped with literal `\u2b07` /
`\ud83d\udcc2` text instead of the icons. Corrected.

* **The template is now a real .xlsx**, not a CSV. Built in-app with no
  library — a ZIP of XML using STORED entries, so no compression is needed.
  It opens with a bold navy header row, frozen at row 1, sensible column
  widths, and a second **Instructions** sheet explaining every column. That is
  the answer to "no header, how does the client know what goes where".
  A CSV fallback still downloads if the workbook cannot be built.
* **Fleet → Export List** writes the live fleet in the identical layout, so
  the customer pulls it, edits it and sends it straight back.
* **Orders → Template / Export / Import Orders.** Bulk order creation from a
  spreadsheet: Order No, Customer, Product, Supplier, Destination,
  Transporter, Target (tonnes), Vehicle Regs (semicolon separated). Existing
  order numbers are updated, never duplicated, and loaded tonnage is left
  alone. New customers, products, suppliers, destinations and transporters
  are added to the Database lists automatically.
* Both importers share one reader and both show a NEW / UPDATE preview before
  writing.
* **Phone-friendly:** the file inputs now name their MIME types as well as the
  extensions, because Android's picker greys out files when it only sees bare
  extensions. Header button rows wrap. Both templates and both imports work
  in the APK, so the customer can fill the sheet on a laptop, mail it to
  themselves and import it from the phone.

## What changed in 9.6.6 — real shift boundaries for auto-reporting
The reporting engine (schedules → outbox → e-mail / WhatsApp) was already in
9.6.4. The one thing that did not match a colliery was the "shift" frequency:
it counted blocks of N hours from the Unix epoch, which in SAST lands on
02:00 / 10:00 / 18:00 and never matches the shift board on the wall.

"Every shift" now works off **actual shift end times**:
* Set the end times per schedule — presets for 2-shift (06:00 / 18:00) and
  3-shift (06:00 / 14:00 / 22:00), or type your own; each can be named.
* The report covers the shift that has just ended, labelled with its name —
  e.g. *Night shift · 21 Aug 18:00 → 22 Aug 06:00*.
* Shifts that cross midnight are handled.
* One slot key per shift end, so a tick every 60 s cannot double-send.
* If a shift was missed (PC off, LTE down), the next report reaches back to
  the last successful send so those loads are still reported rather than
  falling down the crack.
* Older schedules with no end times keep working — their `everyHours` is
  spread from 06:00.

## What changed in 9.6.5
1. **Dispatch / Receive wording.** "Loading" and "Off Loading" are gone from the
   whole app — weigh screen buttons, manual weigh, tickets, CSV export and the
   Records "Type" column now read **Dispatch** and **Receive**. Only the labels
   changed; the stored values were already `dispatch` / `receive`, so every
   existing ticket reprints under the new wording with no migration.
   The Batch Number / Dispatch Ticket Nr field swap is untouched.
2. **Axle weights on dispatch tickets only.** `ticketDeckSnapshot()` is the one
   gate — a receive ticket never prints axle rows, however the load was weighed.
   Applies to the 80 mm ticket, the ESC/POS roll and any reprint.
3. **Axle rows are weights only.** No axle-group name, no legal limit, no
   tolerance and no "OVER by" wording on the printout. The overload check is
   unchanged on screen for the operator — it just isn't a statement the ticket
   makes to the driver. Decks with no reading are skipped rather than printing a
   dash.
4. **Fleet template + bulk import.** Fleet tab now has **⬇ Template** and
   **📂 Import List**. The template is a CSV (opens straight in Excel) with
   Registration, Trailer 1, Trailer 2, Driver, Transporter, Tare (kg). Import
   accepts .csv or .xlsx, matches columns by header name (order may change,
   extra columns ignored), falls back to template order if there is no header,
   skips any line starting with `#`, and shows a NEW / UPDATE preview before it
   writes anything. Blank cells never wipe a detail already on record. New
   drivers and transporters are added to the Database lists too, so the weigh
   screen dropdowns fill themselves. Imported trucks feed the existing
   reg-lookup, so typing a registration auto-populates trailers, driver and
   transporter.

## The installer activation gate is OFF by default
An earlier build failed on `electron/installer.nsh` (the "Invalid command: ${If}"
error). To guarantee the build succeeds, the installer code-prompt is disabled.

**You lose nothing:** the app still asks for the activation code **ISS2025** the
first time it runs.

### To turn the installer code-prompt back ON later (optional)
1. Confirm the app builds cleanly first (green tick in Actions).
2. In `package.json`, inside `"build" > "nsis"`, add this line back:
       "include": "electron/installer.nsh",
3. Push. If that build goes green, the installer now asks for ISS2025 before
   installing. If it goes red again, remove the line — the app-level gate is enough.

## Toolchain (updated with this release)
| Package         | Was      | Now       | Why |
|-----------------|----------|-----------|-----|
| electron        | ^31.0.0  | ^41.10.4  | 31 is past end-of-life (no Chromium security fixes). 41 is the most settled of the currently supported lines. |
| electron-builder| ^24.13.3 | ^26.15.3  | Needed for modern Electron; better NSIS handling. |
| serialport      | ^12.0.0  | ^13.0.0   | Current major; prebuilds for current Node/Electron ABIs. |
| CI Node         | 20       | 22        | serialport 13 requires Node >= 20; 22 is LTS. |

`postinstall: electron-builder install-app-deps` was added so the serialport
native binary is always rebuilt against the Electron ABI in use. This is the
usual cause of "native serial: NOT loaded — using Web Serial fallback".

### If the native rebuild fails on the runner
Fall back one step at a time, rebuilding after each:
1. `electron` → `^38.8.6`
2. `electron` → `^37.10.3`
3. Last resort: back to `^31.0.0` + `electron-builder ^24.13.3` + `serialport ^12.0.0`
   (the exact combination that was known-green before this update).

Verify with: app menu → **Help → Serial Diagnostics…** → must read
"Native serial: ACTIVE".

## Data migration across the rebrand
Electron derives its data folder from `productName`, so renaming the app to
"ISS Weighbridge" moves it. `electron/storage.js` now adopts, on first launch,
both the config **and** the state file from any previous product name
(Hillside Complex Weighbridge, Hillside Weighbridge, NovaSpire Weighbridge,
A AND N KADIR Weighbridge) and from the old filenames
(`novaspire-config.json`, `hillside-state.json`).

Without this, every deployed site would have launched looking like a fresh
install — no activation, no users, no database, no paired COM ports. It copies
rather than moves, only when the destination is missing, and skips unparseable
files, so it cannot destroy live data.

Backups are now written as `ISS-Backup-<date>.json`; rotation still recognises
the older `Hillside-Backup-*` / `NovaSpire-Backup-*` files so the 30-day cap
keeps working on existing PCs.

## Version stamping (RENDERER_BUILD)
`renderer/index.html` carries a build stamp that CI checks against
`package.json`:

    const RENDERER_BUILD='9.0.0';

It sits at the top of the main `<script>` block (immediately before the debug
console). The format matters — no spaces around `=`, single quotes, one line —
because the workflow greps for it. **Bump both numbers together** or the build
fails with "Version mismatch".

To bump, one command:

    npm version 9.0.1 --no-git-tag-version && \
    sed -i "s/const RENDERER_BUILD='[^']*'/const RENDERER_BUILD='9.0.1'/" renderer/index.html

Better long-term: have CI *inject* the version instead of asserting it — replace
the guard step with a step that writes package.json's version into the constant
before `npm run dist`. Then there is only one number to bump, and the two can
never drift.

The build number is logged to the in-app debug console (Settings → Diagnostics,
or Ctrl+Alt+D) on every launch, so a site can be identified over the phone.

## Why there is no package-lock.json
`actions/setup-node` with `cache: npm` refuses to run without a committed
lockfile ("Dependencies lock file is not found"), so the cache line is left out
of the workflow and CI runs a plain `npm install`. That is how this repo has
always built.

If you want the ~30 s of cache back, add a lockfile — but generate it **on the
Windows machine you build from**, not on Linux, so platform-specific optional
dependencies are recorded:

    npm install --package-lock-only
    git add package-lock.json

then in `.github/workflows/build.yml`:
- put `cache: npm` back under `Setup Node`
- change `npm install` to `npm ci`

Re-run the lockfile command any time you change a dependency, or `npm ci` will
fail with "lock file out of sync".

## Multi-deck (9.1.0)
Per-bridge `deckMode` / `deckCount` / `deckMap` / `deckTol` in config. One
tokeniser (`numTokens`) now feeds both the field mapper and the parser, so the
field number shown in Settings is always the field the parser reads.

`parseRaw` was rewired onto that tokeniser and was checked against the original
implementation across 26 strings — identical output on every one, including
Toledo frames, thousands separators, negatives, space-padded readings and
manual position mode. Single-deck bridges are unaffected.

Known, pre-existing, left alone: the token regex allows spaces inside a number
(`1 2345` -> 12345) because some indicators pad that way. A side effect is that
`02 14280` reads as 214280. Changing it would break the space-padded indicators
it was written for, so it stands — but if a bridge ever reads a wildly inflated
weight, this is the first thing to check.

The gross cannot be told apart from a deck when only one deck is loaded — both
carry the same number. Suggest and Learn both refuse rather than guess, and say
what to do instead.

## Everything else is unchanged and verified
- All JS syntax-checks (`node --check` on every file in electron/, both renderer
  script blocks parsed)
- All internal paths resolve
- serialport native module builds on the GitHub Windows runner
