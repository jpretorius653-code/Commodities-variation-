# ISS Cloud Sync — every step, in order

Project: **cslrbpptdcehxbljgvvm** (the existing one — do not create a new project).

Read this once before starting. Steps 1–5 change nothing anyone can see.
Only **step 7** can break a working screen, and it has a one-line undo.

---

## Before you touch anything

### Back up the database

**Supabase Dashboard → Database → Backups**

Supabase takes daily backups automatically on paid plans. On the free plan
there is no automatic backup, so take a manual one:

**Dashboard → Database → Backups → "Download backup"** if the button is there.
If it is not, export the two tables that matter by hand:

**Dashboard → Table Editor → `transactions` → ⋯ (top right) → Export as CSV**

Do the same for `user_sites`. Keep both files somewhere off the PC.

Nothing in steps 1–8 deletes a row. The backup is for the case where a
migration is interrupted halfway, not because data is at risk.

### Know your undo

Every step below has a rollback line. The only one you are likely to need:

```sql
alter table public.transactions disable row level security;
```

That instantly restores the previous behaviour. Data is untouched.

---

## Step 1 — Inspect (read only)

**Dashboard → SQL Editor → New query** → paste `00_inspect.sql` → Run.

Run it block by block, not all at once. Keep the output. Four answers matter:

| Block | What you are looking for |
|---|---|
| 1a | The real column names in `user_sites`, and whether it has `is_admin` |
| 1b | What `my_access()` reads — the admin flag must come from the same place |
| 1e | Duplicate ticket numbers. **Any rows here block step 3** |
| 1f | Which site the existing rows belong to — you need this in step 3 |

If 1e returns rows, stop and resolve those first. If 1a shows different column
names from `user_id` / `site`, edit the two lines marked `← column A` /
`← column B` in `03b_site_auth_rls_admin.sql` before step 7.

**Changes nothing. No rollback needed.**

---

## Step 2 — Create the orders and fleet tables (optional, safe now)

**SQL Editor → New query** → paste `05_orders_fleet.sql` → Run.

New empty tables. Nothing reads them yet, so nothing can break. Doing it now
means the plumbing is ready when the UI is built.

Skip this if you would rather do one thing at a time.

**Rollback:** `drop table public.orders, public.fleet;`

---

## Step 3 — Add `row_id` and `site` to transactions

**SQL Editor** → paste **`02_keys_editor.sql`** → Run.

Use the `_editor` version. The original `02_keys.sql` starts with `\set`,
which is a **psql** meta-command — the Supabase SQL Editor only speaks plain
SQL and will fail with `syntax error at or near "\"`. The editor version has
the site code written directly into block 3b instead; check that it says the
right site before running.

Paste the whole file and Run once — don't run it line by line, or the
`begin`/`commit` won't wrap the changes and a failure part-way through will
leave the table half-migrated.

What it does: adds `row_id` and `site` columns, backfills every existing row,
makes both required, and changes ticket uniqueness from "unique everywhere" to
"unique per site" — so Hillside WB001 and Primecoal WB001 stop colliding.

**Verify:**

```sql
select site, count(*) from public.transactions group by site;
```

Every row should now carry a site.

**Rollback:** the columns are additive; leaving them costs nothing. If you must:
`alter table public.transactions drop column site, drop column row_id;`

---

## Step 4 — Set the Site Code on each weighbridge PC

**In ISS Weighbridge → Settings → Site Code**

Type the short form: `hillside`, `primecoal`. Not `Hillside Complex`.

The app normalises what you type (lower case, non-alphanumerics become
hyphens, trimmed), so `Hillside ` and `hillside` both send `hillside`. Short
codes survive a client renaming their site; long ones do not.

Do this on **every** PC before step 7, or that PC's uploads start failing the
moment RLS goes on.

**Verify** — after the next ticket uploads:

```sql
select distinct site from public.transactions order by site;
```

---

## Step 5 — One login per weighbridge PC

**Dashboard → Authentication → Users → Add user**

- Email: `hillside-wb1@iss.local` (the dashboard appends `@iss.local` to a
  bare username, so keep the same domain)
- Strong password
- Tick **Auto Confirm User**

Then link it. **Do not copy UUIDs by hand** — look them up from the email, so
there is no placeholder left to paste wrong:

```sql
insert into public.user_sites (user_id, site, is_admin)
select u.id, 'hillside', false
from auth.users u
where u.email = 'hillside-wb1@iss.local'
  and not exists (
    select 1 from public.user_sites us where us.user_id = u.id
  );
```

Change the email and the site string for each PC. The `not exists` guard makes
it safe to run twice.

Repeat for each PC. Two PCs at one site get two accounts, both linked to
`hillside` — never share one login, or you cannot revoke one of them.

**Your own admin account gets ONE row, with a null site:**

```sql
insert into public.user_sites (user_id, site, is_admin)
select u.id, null, true
from auth.users u
where u.email = 'your.email@here.co.za'
  and not exists (
    select 1 from public.user_sites us where us.user_id = u.id
  );
```

If that inserts 0 rows you already have a row — promote it instead:

```sql
update public.user_sites us
set site = null, is_admin = true
from auth.users u
where u.id = us.user_id and u.email = 'your.email@here.co.za';
```

A null site means "all sites" — `iss_is_admin()` returns true before the site
is ever compared, so RLS gives you everything.

**Do not give any user more than one row.** `my_access()` returns one row per
`user_sites` row with no `ORDER BY`, and the dashboard reads only `data[0]`.
Two rows for the same user means the dashboard picks one arbitrarily, and your
admin tab appears or disappears between page loads. One row per user, every
time:

- site PC → `(user_id, 'hillside', false)`
- admin   → `(user_id, null, true)`

Check before you move on — this must return no rows:

```sql
select user_id, count(*) from public.user_sites
group by user_id having count(*) > 1;
```

And read back what you actually created:

```sql
select u.email, us.site, us.is_admin
from public.user_sites us
join auth.users u on u.id = us.user_id
order by us.is_admin desc, us.site;
```

**Rollback:** `delete from public.user_sites where user_id = '<uuid>';`

---

## Step 6 — Check the site strings line up

**SQL Editor** → paste `04_match_check.sql` → Run.

This finds the near-misses that look identical on screen — a trailing space, a
capital letter. Fix anything it reports **before** step 7. This is the single
most common reason a PC locks itself out.

---

## Step 7 — Turn on scoped access ⚠️

This is the only step that can break a working screen.

**SQL Editor** → paste `03b_site_auth_rls_admin.sql` → Run.

Use `03b`, not `03`. The difference is that `03b` keeps admin logins seeing
every site — without it your dashboard's admin tab goes empty.

It touches `transactions` only. **Do not add `readings`, `hourly`, `scales`,
`sources` or `source_log`** — the ESP32 gateways post to those with the
publishable key and no login, and RLS without a device policy silences the
belt scales.

**Verify immediately, in this order:**

1. Open the dashboard, sign in as your admin account. Trucks and reports must
   still show every site.
2. Sign in as `hillside-wb1`. Must show Hillside only.
3. Run this as the Hillside login — it **must fail** with a row-level security
   violation:

```sql
insert into public.transactions (row_id, site, ticket)
values (gen_random_uuid(), 'primecoal', 'WB999');
```

4. Do a real weigh on each site PC and confirm the ticket appears.

**If anything is wrong, undo it in one line and nothing is lost:**

```sql
alter table public.transactions disable row level security;
```

Then re-check step 6 before trying again.

---

## Step 8 — Rotate the exposed secret key

Only once everything above works and nothing depends on the old key.

**Dashboard → Settings → API Keys** → revoke the old `service_role` / secret
key that GitHub flagged.

Confirm first that no Cloud Sync install still has it in Settings. The site
PCs should be using the publishable key plus their login, never a secret key —
a secret key bypasses RLS entirely, and anyone can read it out of the app.

---

## Updating the site software after this

You do **not** need to reinstall the EXE to change the UI.

**Help → Update UI — open override folder…**

Drop the new `index.html` in the folder that opens, then restart ISS
Weighbridge. The window title shows **UI OVERRIDE** while one is active.

Before installing a genuinely new EXE, use **Help → Update UI — remove
override** first, or the old override will shadow the upgrade.

Changes to `serial.js`, `main.js` or anything else outside the UI still need a
rebuild.
