-- ═══════════════════════════════════════════════════════════════════
-- ISS · 12 — TICKETS WRITTEN BY THE APP
--
-- Cloud Sync writes transactions with a SERVICE key, which ignores
-- row-level security entirely. A connected bridge signs in as its site
-- and does not, so the table needs the same site rules the fleet and
-- orders tables already have.
--
-- Nothing here deletes a ticket, and nothing renames a site. Hillside's
-- Cloud Sync keeps working throughout: a service key is unaffected by
-- every policy below.
--
-- Safe to run. Safe to re-run.
-- ═══════════════════════════════════════════════════════════════════

begin;

do $chk$
begin
  if to_regclass('public.transactions') is null then
    raise exception 'public.transactions does not exist — nothing to do here';
  end if;
end
$chk$;

-- ── columns the connected app writes ───────────────────────────────
alter table public.transactions add column if not exists site         text;
alter table public.transactions add column if not exists row_id       uuid default gen_random_uuid();
alter table public.transactions add column if not exists order_no     text;
alter table public.transactions add column if not exists transporter  text;
alter table public.transactions add column if not exists driver       text;
alter table public.transactions add column if not exists updated_at   timestamptz not null default now();

create or replace function public.iss_tx_touch()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  if new.site is not null then new.site := lower(btrim(new.site)); end if;
  return new;
end $$;

drop trigger if exists transactions_touch on public.transactions;
create trigger transactions_touch before insert or update on public.transactions
  for each row execute function public.iss_tx_touch();

-- ── the key the app upserts on ─────────────────────────────────────
-- (site, ticket): ticket numbers repeat across sites, so ticket alone
-- would collide the moment a second bridge came online. Created only if
-- the existing data allows it — a duplicate pair means something is
-- already wrong and silently dropping a row would be worse.
do $uk$
declare v_dupes int;
begin
  select count(*) into v_dupes from (
    select lower(btrim(site)) s, ticket from public.transactions
     where site is not null group by 1,2 having count(*) > 1) d;
  if v_dupes = 0 then
    execute 'create unique index if not exists transactions_site_ticket_uk
               on public.transactions (site, ticket)';
    raise notice 'unique index on (site, ticket) is in place';
  else
    raise warning 'SKIPPED the (site,ticket) unique index: % duplicate pairs already exist. '
                  'The app cannot upsert tickets until these are resolved.', v_dupes;
  end if;
end
$uk$;

-- ── access ─────────────────────────────────────────────────────────
-- A site may read, add and correct its own tickets. There is deliberately
-- NO delete policy: a weighbridge must never be able to make a ticket
-- disappear. Corrections happen by update, which leaves a trail.
alter table public.transactions enable row level security;

drop policy if exists tx_site_select on public.transactions;
drop policy if exists tx_site_insert on public.transactions;
drop policy if exists tx_site_update on public.transactions;

create policy tx_site_select on public.transactions
  for select to authenticated
  using (public.iss_may_use_site(site) or public.iss_is_admin());
create policy tx_site_insert on public.transactions
  for insert to authenticated
  with check (public.iss_may_use_site(site) or public.iss_is_admin());
create policy tx_site_update on public.transactions
  for update to authenticated
  using (public.iss_may_use_site(site) or public.iss_is_admin())
  with check (public.iss_may_use_site(site) or public.iss_is_admin());

-- Reading order progress needs the ticket's tonnage grouped by order.
create index if not exists transactions_site_order_ix
  on public.transactions (site, order_no) where order_no is not null;
create index if not exists transactions_site_status_ix
  on public.transactions (site, status);

commit;

-- ═══════════════════════════════════════════════════════════════════
-- CHECK BEFORE YOU TRUST IT
--
-- 1. Any ticket with no site is invisible to every site login once RLS
--    is on (an admin still sees it). This counts them:
--
--      select count(*) from public.transactions where site is null;
--
--    If that is not zero, tag them — they are almost certainly Hillside's:
--
--      update public.transactions set site='hillside' where site is null;
--
-- 2. Do not run the app's ticket publisher on a bridge where Cloud Sync
--    is also running, or the same ticket arrives twice by two routes.
-- ═══════════════════════════════════════════════════════════════════
