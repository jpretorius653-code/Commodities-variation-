-- ═══════════════════════════════════════════════════════════════════
-- ISS · STEP 3 — SITE + ROW ID ON TRANSACTIONS
-- Supabase SQL Editor version of 02_keys.sql.
--
-- The original uses \set, which is a psql meta-command — the Supabase
-- editor only speaks plain SQL, so the site code is written directly
-- into 3b below. Everything else is identical.
--
-- Safe to re-run. Deletes nothing.
--
-- Paste the WHOLE file and Run once. Do not run it line by line — the
-- begin/commit has to wrap the lot so a failure rolls back cleanly.
-- ═══════════════════════════════════════════════════════════════════

begin;

-- 3a. Columns. row_id is the cloud identity of a transaction; the app
--     generates it on the weighbridge PC when the truck first drives on.
alter table public.transactions add column if not exists row_id uuid;
alter table public.transactions add column if not exists site   text;

-- 3b. Backfill history. Rows uploaded before 9.2.0 have neither.
--     'hillside' — the only site that has uploaded so far. Lower case,
--     matching what the app normalises Site Code to.
update public.transactions set row_id = gen_random_uuid() where row_id is null;
update public.transactions set site   = 'hillside'         where site is null or site = '';

-- 3c. Now they can be required.
alter table public.transactions alter column row_id set not null;
alter table public.transactions alter column site   set not null;
alter table public.transactions alter column row_id set default gen_random_uuid();

-- 3d. row_id is what upserts key on, so it must be unique on its own.
--     A re-send after a dropped connection then updates the same row
--     instead of creating a second ticket.
create unique index if not exists transactions_row_id_uk
  on public.transactions (row_id);

-- 3e. Drop the OLD global uniqueness rule on ticket alone.
--     The table was created with UNIQUE (ticket), which is exactly what
--     makes Hillside's WB001 block Primecoal's WB001. Adding the per-site
--     index below does NOT replace it — both would apply — so the old
--     constraint has to go or multi-site numbering silently stays broken.
--     It is a CONSTRAINT, not a plain index, so `drop index` will refuse.
alter table public.transactions drop constraint if exists transactions_ticket_key;

-- 3f. A ticket number must be unique WITHIN a site, not across all of
--     them. Every site keeps counting from 001; a genuine double-issue
--     at one site is still refused.
--     NULL tickets do not collide — trucks currently on site are fine.
create unique index if not exists transactions_site_ticket_uk
  on public.transactions (site, ticket);

-- 3g. Reporting nearly always filters by site and date.
create index if not exists transactions_site_time_ix
  on public.transactions (site, time_in desc);

commit;

-- ── VERIFY — run these after the commit ────────────────────────────
-- Both must say NO:
--   select column_name, is_nullable from information_schema.columns
--   where table_schema='public' and table_name='transactions'
--     and column_name in ('row_id','site');
--
-- No UNIQUE (ticket) may remain — only the per-site one:
--   select conname, pg_get_constraintdef(oid) from pg_constraint
--   where conrelid = 'public.transactions'::regclass and contype = 'u';
--
-- Must be 0:
--   select count(*) as missing_row_id from public.transactions where row_id is null;
--
-- One row: hillside, with its ticket range:
--   select site, count(*) as tickets, min(ticket) as first_ticket,
--          max(ticket) as last_ticket
--   from public.transactions group by site order by site;

-- ── ROLLBACK, if needed ────────────────────────────────────────────
-- The columns are additive and cost nothing to leave in place. Only if
-- you really must undo it:
--   drop index if exists public.transactions_site_ticket_uk;
--   drop index if exists public.transactions_row_id_uk;
--   drop index if exists public.transactions_site_time_ix;
--   alter table public.transactions alter column row_id drop not null;
--   alter table public.transactions alter column site   drop not null;
