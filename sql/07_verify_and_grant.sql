-- ═══════════════════════════════════════════════════════════════════
-- ISS · 07 — DID IT LAND, AND WHO MAY USE IT
--
-- Read-only checks first. Nothing here changes anything until you
-- uncomment the grant at the bottom.
--
-- Run this AFTER 06_fleet_orders_remote_write.sql.
-- ═══════════════════════════════════════════════════════════════════

-- ── 1. The pieces the app and the dashboard both need ──────────────
select
  'tables'                                                as what,
  to_jsonb(array(
    select table_name from information_schema.tables
     where table_schema='public' and table_name in ('fleet','orders','user_sites','transactions')
     order by table_name))                                as found
union all
select
  'fleet columns the sync needs',
  to_jsonb(array(
    select column_name from information_schema.columns
     where table_schema='public' and table_name='fleet'
       and column_name in ('local_id','deleted','updated_at','updated_by')
     order by column_name))
union all
select
  'functions',
  to_jsonb(array(
    select p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public'
       and p.proname in ('iss_may_use_site','iss_is_admin','iss_fleet_since','iss_orders_since')
     order by p.proname))
union all
select
  'write policies on fleet',
  to_jsonb(array(
    select polname from pg_policy pol join pg_class c on c.oid=pol.polrelid
     where c.relname='fleet' order by polname))
union all
select
  'update triggers',
  to_jsonb(array(
    select tgname from pg_trigger
     where tgname in ('fleet_touch','orders_touch') and not tgisinternal
     order by tgname));

-- Expect, in order:
--   tables    ["fleet","orders","transactions","user_sites"]
--   columns   ["deleted","local_id","updated_at","updated_by"]
--   functions ["iss_fleet_since","iss_is_admin","iss_may_use_site","iss_orders_since"]
--   policies  ["fleet_site_insert","fleet_site_select","fleet_site_update"]
--   triggers  ["fleet_touch","orders_touch"]
-- Anything missing means 06 did not finish — re-run it and read the notices.


-- ── 2. Who can currently reach which site ──────────────────────────
select u.email, us.site, coalesce(us.is_admin,false) as is_admin
  from public.user_sites us
  join auth.users u on u.id = us.user_id
 order by us.site nulls first, u.email;

-- Site strings grew inconsistent: commvar and primecoal are lower case,
-- Hillside is capitalised. 08_site_code_case.sql makes matching case-blind
-- and normalises fleet/orders to lower case, so this no longer bites. Run 08
-- if you have not already.


-- ── 3. What is actually in the fleet table, per site ───────────────
select site,
       count(*)                                  as rows,
       count(*) filter (where not deleted)       as live,
       count(*) filter (where deleted)           as removed,
       max(updated_at)                           as last_change
  from public.fleet
 group by site
 order by site;


-- ═══════════════════════════════════════════════════════════════════
-- 4. GIVE THE CLIENT THEIR OWN LOGIN  (uncomment to run)
--
-- Create the user first in Supabase → Authentication → Users → Add user,
-- then map it to the site here. Give the CUSTOMER a separate login from
-- the weighbridge PC's own account: revoking the customer later must not
-- lock the bridge out of the cloud.
-- ═══════════════════════════════════════════════════════════════════

-- insert into public.user_sites (user_id, site, is_admin)
-- select id, 'commvar', false
--   from auth.users
--  where email = 'fleet@commoditiesvariation.co.za'
-- on conflict do nothing;

-- Then prove the read works AS THAT USER (from the dashboard, signed in as
-- them — not from here, where you are the postgres role and see everything):
--   select * from public.iss_fleet_since('commvar', null);

-- ── Undo a client's access, any time ───────────────────────────────
-- delete from public.user_sites
--  where site='commvar'
--    and user_id = (select id from auth.users where email='fleet@commoditiesvariation.co.za');
