-- ═══════════════════════════════════════════════════════════════════
-- ISS · STEP 10 — LET A CLIENT ADD TRUCKS AND ORDERS REMOTELY
--
-- 05_orders_fleet.sql created the tables with ONE rule: the office
-- (ISS admin) writes, the site reads. That is the wrong rule if the
-- customer is meant to maintain their own fleet list from a phone.
--
-- This migration changes that rule and adds the two things a two-way
-- sync needs: a maintained updated_at (so the app can ask "what has
-- changed since I last looked") and a soft delete (so a removal
-- travels — a row that simply disappears cannot be replicated).
--
-- Safe to run now. Safe to re-run. Never deletes a row.
-- ═══════════════════════════════════════════════════════════════════

begin;

-- ── the two helpers this migration leans on ────────────────────────
-- 03_site_auth_rls.sql and 03b create iss_may_use_site() and
-- iss_is_admin(). If those were never run on THIS project, every policy
-- below fails with 42883. Created here only when absent, so a project
-- that already has them keeps its own working versions untouched.
do $mig$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public' and p.proname='iss_is_admin'
  ) then
    execute $fn$
      create function public.iss_is_admin()
      returns boolean language sql stable security definer
      set search_path = public as $body$
        select coalesce((select us.is_admin from public.user_sites us
                          where us.user_id = auth.uid()
                            and coalesce(us.is_admin,false) limit 1), false);
      $body$;
    $fn$;
    execute 'grant execute on function public.iss_is_admin() to authenticated';
    raise notice 'created public.iss_is_admin()';
  end if;

  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public' and p.proname='iss_may_use_site'
  ) then
    execute $fn$
      create function public.iss_may_use_site(p_site text)
      returns boolean language sql stable security definer
      set search_path = public as $body$
        select public.iss_is_admin() or exists (
          select 1 from public.user_sites us
           where us.user_id = auth.uid() and us.site = p_site);
      $body$;
    $fn$;
    execute 'grant execute on function public.iss_may_use_site(text) to authenticated';
    raise notice 'created public.iss_may_use_site(text)';
  end if;
end
$mig$;

-- Both helpers read public.user_sites (user_id / site / is_admin). If that
-- table does not exist either, stop here and run 03_site_auth_rls.sql and
-- 03b_site_auth_rls_admin.sql first — this migration cannot invent your
-- access model for you.
do $chk$
begin
  if not exists (select 1 from information_schema.tables
                  where table_schema='public' and table_name='user_sites') then
    raise exception 'public.user_sites is missing — run 03_site_auth_rls.sql and 03b first';
  end if;
end
$chk$;

-- ── the tables may not exist yet if 05 was never run ────────────────
create table if not exists public.fleet (
  id          uuid primary key default gen_random_uuid(),
  site        text not null,
  reg         text not null,
  transporter text,
  driver      text,
  trailer1    text,
  trailer2    text,
  tare        numeric,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index if not exists fleet_site_reg_uk on public.fleet (site, reg);

create table if not exists public.orders (
  id          uuid primary key default gen_random_uuid(),
  site        text not null,
  order_no    text not null,
  customer    text,
  product     text,
  destination text,
  supplier    text,
  transporter text,
  tons_target numeric,
  active      boolean not null default true,
  notes       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index if not exists orders_site_no_uk on public.orders (site, order_no);

-- ── columns the sync needs ──────────────────────────────────────────
-- local_id: the id the weighbridge app uses on the PC. Carrying it means
-- a row that went up from site and comes back down is recognised as the
-- same truck instead of arriving as a duplicate.
alter table public.fleet  add column if not exists local_id   text;
alter table public.fleet  add column if not exists deleted    boolean not null default false;
alter table public.fleet  add column if not exists updated_by text;
alter table public.orders add column if not exists local_id   text;
alter table public.orders add column if not exists deleted    boolean not null default false;
alter table public.orders add column if not exists updated_by text;
alter table public.orders add column if not exists fleet_regs text[];   -- order fleet restriction

-- Pull cursor. Without an index on (site, updated_at) the "what changed
-- since X" query table-scans once the list gets long.
create index if not exists fleet_site_updated_ix  on public.fleet  (site, updated_at desc);
create index if not exists orders_site_updated_ix on public.orders (site, updated_at desc);

-- ── updated_at must be maintained by the database ───────────────────
-- If the client sets it, two clocks disagree and the sync cursor skips
-- rows. The database is the only clock that matters here.
create or replace function public.iss_touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  if auth.uid() is not null then new.updated_by := auth.uid()::text; end if;
  return new;
end $$;

drop trigger if exists fleet_touch  on public.fleet;
drop trigger if exists orders_touch on public.orders;
create trigger fleet_touch  before insert or update on public.fleet
  for each row execute function public.iss_touch_updated_at();
create trigger orders_touch before insert or update on public.orders
  for each row execute function public.iss_touch_updated_at();

-- ── THE RULE CHANGE ────────────────────────────────────────────────
-- Before: site reads, office writes.
-- After:  anyone registered for a site may read AND write that site's
--         fleet and orders. The ISS admin still reaches everything.
--
-- Note what is NOT granted: no delete. A removal sets deleted = true,
-- so it can be replicated to every weighbridge PC. A hard delete would
-- silently reappear on the next push from a PC that never saw it go.
alter table public.fleet  enable row level security;
alter table public.orders enable row level security;

drop policy if exists fleet_site_select   on public.fleet;
drop policy if exists fleet_admin_write   on public.fleet;
drop policy if exists fleet_site_insert   on public.fleet;
drop policy if exists fleet_site_update   on public.fleet;
drop policy if exists orders_site_select  on public.orders;
drop policy if exists orders_admin_write  on public.orders;
drop policy if exists orders_site_insert  on public.orders;
drop policy if exists orders_site_update  on public.orders;

create policy fleet_site_select on public.fleet
  for select to authenticated
  using (public.iss_may_use_site(site) or public.iss_is_admin());
create policy fleet_site_insert on public.fleet
  for insert to authenticated
  with check (public.iss_may_use_site(site) or public.iss_is_admin());
create policy fleet_site_update on public.fleet
  for update to authenticated
  using (public.iss_may_use_site(site) or public.iss_is_admin())
  with check (public.iss_may_use_site(site) or public.iss_is_admin());

create policy orders_site_select on public.orders
  for select to authenticated
  using (public.iss_may_use_site(site) or public.iss_is_admin());
create policy orders_site_insert on public.orders
  for insert to authenticated
  with check (public.iss_may_use_site(site) or public.iss_is_admin());
create policy orders_site_update on public.orders
  for update to authenticated
  using (public.iss_may_use_site(site) or public.iss_is_admin())
  with check (public.iss_may_use_site(site) or public.iss_is_admin());

-- ── one call the app can make to pull a delta ──────────────────────
-- The app sends the newest updated_at it has already stored; it gets
-- back only what changed after that, deletions included.
create or replace function public.iss_fleet_since(p_site text, p_since timestamptz default null)
returns setof public.fleet
language sql stable security invoker as $$
  select * from public.fleet
   where site = p_site
     and (p_since is null or updated_at > p_since)
   order by updated_at asc
   limit 5000;
$$;
grant execute on function public.iss_fleet_since(text, timestamptz) to authenticated;

create or replace function public.iss_orders_since(p_site text, p_since timestamptz default null)
returns setof public.orders
language sql stable security invoker as $$
  select * from public.orders
   where site = p_site
     and (p_since is null or updated_at > p_since)
   order by updated_at asc
   limit 5000;
$$;
grant execute on function public.iss_orders_since(text, timestamptz) to authenticated;

commit;

-- ═══════════════════════════════════════════════════════════════════
-- AFTER RUNNING THIS
--
-- 1. Give the customer their OWN login, separate from the weighbridge
--    PC's login, and point it at the same site:
--
--      select public.iss_register_site('fleet@commoditiesvariation.co.za','commvar');
--
--    Two logins, one site. Revoking the customer later does not lock
--    the weighbridge out.
--
-- 2. Prove the read works from that login before building any UI:
--
--      select * from public.iss_fleet_since('commvar', null);
--
-- 3. A truck added from a phone lands here. It reaches the weighbridge
--    when the app's pull is built — that is the remaining app work.
-- ═══════════════════════════════════════════════════════════════════
