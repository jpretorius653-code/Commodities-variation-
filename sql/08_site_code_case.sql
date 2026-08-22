-- ═══════════════════════════════════════════════════════════════════
-- ISS · 08 — SITE CODE CASE
--
-- user_sites currently holds:
--     commvar    (lower)
--     primecoal  (lower)
--     Hillside   (CAPITAL H)
--
-- Two conventions grew side by side. The dashboard and the scales/
-- readings tables use "Hillside"; the weighbridge app forces its Site
-- Code to lower case in Settings, so it will always ask for "hillside".
-- To Postgres those are different sites, so Hillside's app would be
-- refused by every policy and its fleet list would silently never
-- arrive — no error, just an empty list.
--
-- This does NOT rename anything in transactions, readings or scales.
-- Renaming a live site key is how you lose a month of tickets. Instead:
--
--   1. site MATCHING becomes case-insensitive, so both spellings work
--      everywhere and nothing existing changes behaviour.
--   2. fleet and orders — new, near-empty tables — are normalised to
--      lower case and kept that way by a trigger, so the app and the
--      dashboard cannot end up with two separate lists for one site.
--
-- Safe to run. Safe to re-run.
-- ═══════════════════════════════════════════════════════════════════

begin;

-- ── 1. matching, case-insensitively ────────────────────────────────
create or replace function public.iss_may_use_site(p_site text)
returns boolean language sql stable security definer
set search_path = public as $$
  select public.iss_is_admin() or exists (
    select 1 from public.user_sites us
     where us.user_id = auth.uid()
       and lower(btrim(us.site)) = lower(btrim(p_site))
  );
$$;
grant execute on function public.iss_may_use_site(text) to authenticated;

-- ── 2. fleet + orders always store a lower-case site ───────────────
create or replace function public.iss_lower_site()
returns trigger language plpgsql as $$
begin
  new.site := lower(btrim(new.site));
  return new;
end $$;

drop trigger if exists fleet_lower_site  on public.fleet;
drop trigger if exists orders_lower_site on public.orders;
-- BEFORE the updated_at trigger alphabetically, which is what we want:
-- normalise first, then stamp.
create trigger fleet_lower_site  before insert or update on public.fleet
  for each row execute function public.iss_lower_site();
create trigger orders_lower_site before insert or update on public.orders
  for each row execute function public.iss_lower_site();

-- ── 3. normalise what is already there ─────────────────────────────
-- Lower-casing could collide with the (site, reg) unique index if the
-- same truck was entered under both spellings. Drop the older of any
-- such pair first, so the update cannot fail half way.
delete from public.fleet f
 where exists (
   select 1 from public.fleet g
    where lower(btrim(g.site)) = lower(btrim(f.site))
      and upper(btrim(g.reg))  = upper(btrim(f.reg))
      and (g.updated_at, g.id) > (f.updated_at, f.id)
 );
update public.fleet
   set site = lower(btrim(site))
 where site <> lower(btrim(site));

delete from public.orders o
 where exists (
   select 1 from public.orders p
    where lower(btrim(p.site))     = lower(btrim(o.site))
      and upper(btrim(p.order_no)) = upper(btrim(o.order_no))
      and (p.updated_at, p.id) > (o.updated_at, o.id)
 );
update public.orders
   set site = lower(btrim(site))
 where site <> lower(btrim(site));

-- ── 4. the pull RPCs match case-insensitively too ──────────────────
-- Belt and braces: even if something writes a capitalised site before
-- the trigger is in place, the app still finds its rows.
create or replace function public.iss_fleet_since(p_site text, p_since timestamptz default null)
returns setof public.fleet
language sql stable security invoker as $$
  select * from public.fleet
   where lower(btrim(site)) = lower(btrim(p_site))
     and (p_since is null or updated_at > p_since)
   order by updated_at asc
   limit 5000;
$$;
grant execute on function public.iss_fleet_since(text, timestamptz) to authenticated;

create or replace function public.iss_orders_since(p_site text, p_since timestamptz default null)
returns setof public.orders
language sql stable security invoker as $$
  select * from public.orders
   where lower(btrim(site)) = lower(btrim(p_site))
     and (p_since is null or updated_at > p_since)
   order by updated_at asc
   limit 5000;
$$;
grant execute on function public.iss_orders_since(text, timestamptz) to authenticated;

commit;

-- ═══════════════════════════════════════════════════════════════════
-- WHAT THIS DELIBERATELY LEAVES ALONE
--
-- transactions.site, readings.site, scales.site and user_sites.site keep
-- their current values, capitals and all. Matching is now case-blind, so
-- Hillside's dashboard and its ticket upload carry on exactly as before.
--
-- Optional tidy-up, once you have a quiet moment and a backup — makes
-- every table agree on lower case. NOT required, and not to be run in
-- the middle of a shift:
--
--   update public.user_sites set site = lower(btrim(site)) where site is not null;
--   update public.transactions set site = lower(btrim(site));
--   update public.readings     set site = lower(btrim(site));
--   update public.scales       set site = lower(btrim(site));
--
-- If you do that, the dashboard's ALL_SITES list and any hard-coded
-- "Hillside" in its queries must be lower-cased in the same sitting.
-- ═══════════════════════════════════════════════════════════════════

-- Check it worked:
--   select site, count(*) from public.fleet group by site;
--   select public.iss_may_use_site('hillside');   -- as hillside@iss.local: true
--   select public.iss_may_use_site('Hillside');   -- as hillside@iss.local: true
