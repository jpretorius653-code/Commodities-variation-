# DEPLOY — Commodities Variation Weighbridge 9.8.1

Everything in this file assumes the **ISS scalelink** Supabase project
(`cslrbpptdcehxbljgvvm`). Check the project name in the header before you run
any SQL — running it against the wrong project is the single easiest mistake
to make here, and it fails in ways that look like a code problem.

---

## What is in this package

| | |
|---|---|
| `renderer/index.html` | the app — renderer build **9.8.1** |
| `electron/` | main process, serial, printing, SMTP mailer |
| `build/icon.ico`, `icon.png` | Commodities Variation mark, all sizes |
| `sql/` | migrations, in numbered order |

**Two different files are called `index.html`.** This one is the weighbridge
app. The Remote Monitor dashboard has its own, which goes in the Vercel repo.
Mixing them up costs an hour.

---

## 1. Supabase — run once per project

Already run on scalelink: `06`, `08`, `10`.

Still outstanding:

    11_live_weight.sql        live weight, one row per bridge
    12_tickets_from_app.sql   tickets written by the app
    13_site_admin.sql         sites + logins from the Admin page

**Before running 12**, check two things. It turns on row-level security for
`transactions`, and a ticket with no site becomes invisible to site logins the
moment it does:

```sql
select count(*) from public.transactions where site is null;
-- not zero? they are almost certainly Hillside's:
--   update public.transactions set site='hillside' where site is null;

select lower(btrim(site)) s, ticket, count(*)
  from public.transactions where site is not null
 group by 1,2 having count(*) > 1;
-- must return no rows, or 12 skips the ticket key and warns
```

**Never press "Set up / repair backend" in the Cloud tab on scalelink.** It
calls `iss_provision()`, which rewrites `iss_may_use_site()` with an
exact-match version — undoing migration 08 and breaking Hillside, whose site
is stored as `Hillside` while the app asks for `hillside`. That button is for
a fresh project only.

---

## 2. Dashboard

Deploy the Remote Monitor `index.html` to the Vercel repo. Confirm it landed:
the Fleet page status line ends with a build stamp.

Then **sign in as `hillside@iss.local`** and check its Trucks tab still shows
tickets. That is the regression test for migration 12. If it is blank, stop —
tickets with a null or mismatched site are the cause.

---

## 3. The weighbridge PC

**To test**, no rebuild needed: drop `renderer/index.html` into

    %APPDATA%\ISS Weighbridge\renderer\

and restart. The window title says an override is active. Delete the file to
go back.

**To deliver**, build the installer:

    npm install
    npm run dist

Before installing a rebuilt EXE, delete any override file first — the override
wins, so the new installer would silently run the old dropped-in copy.

---

## 4. Commissioning a bridge

1. Dashboard → **Admin → Sites** → create the site code, lower case, no spaces
2. Supabase → Authentication → Users → create the login for that PC
3. Dashboard → **Admin → Logins** → link it to the site
4. App → **Settings** → set the same Site Code, character for character
5. App → **Cloud** → URL, publishable key, login email, password → *Test connection*
   — it should say **registered for "&lt;site&gt;"**
6. App → **Cloud → Fleet & Orders sync**:
   - **This PC syncs fleet & orders** — one PC per site only
   - **Publish live weight**
   - **Publish tickets** — only where Cloud Sync is NOT running

**Two bridges at one site:** give each its own ticket prefix in Settings
(`WB1-`, `WB2-`). Tickets are keyed on (site, ticket), so two bridges both
counting from 1 would overwrite each other in the cloud while looking correct
on both PCs.

---

## 5. Licence codes

- Installation code — entered once per PC, masked
- Second authorisation — asked a day later. Weighing, manual weigh and ticket
  printing keep working; records, reports, settings and exports wait for it
- Maintenance code — ticket designer, company/site naming, branding reset

All stored as salted SHA-256. The check runs on the PC, so someone who can
edit the program files can defeat it. It stops a copied folder being useful;
it does not stop a determined engineer. Binding activation to Supabase is what
would make it real.

---

## Known state, August 2026

- **Hillside** — Cloud Sync pushes tickets, no live weight. Leave it alone.
  Its site is stored capitalised; matching is case-insensitive since 08
- **Primecoal** — registered, not yet uploading
- **Commodities Variation** (`commvar`) — the first connected bridge
- The exposed `sb_secret` key rotation is still outstanding. When you do it,
  Cloud Sync at every site needs the new key; the weighbridge app does not
  (it uses the publishable key, and now refuses a secret one outright)
