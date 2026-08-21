-- ═══════════════════════════════════════════════════════════════════
-- ISS · STEP 7 — SCOPED ACCESS ON transactions (ADMIN-AWARE)
--
-- Replaces the plain helper in 03_site_auth_rls.sql. The difference:
-- an admin login keeps seeing EVERY site. Without that, the dashboard's
-- admin tab goes empty the second RLS turns on.
--
-- SCOPE: this touches public.transactions and NOTHING ELSE.
-- Do not add readings / hourly / scales / sources / source_log here —
-- the ESP32 gateways post to those with the publishable key and no
-- login, and RLS without a device policy silences the belt scales.
--
-- BEFORE RUNNING: check block 1a/1b output from 00_inspect.sql and fix
-- the two marked lines below if your column names differ.
-- ═══════════════════════════════════════════════════════════════════

begin;

-- 7a. Is the caller an admin? Adjust the body to match what 1b showed.
--     If my_access() reads a different table (profiles, user_roles…),
--     point this at the same one so there is a single source of truth.
create or replace function public.iss_is_admin()
returns boolean language sql stable security definer
set search_path = public as $$
  select coalesce(
    (select us.is_admin
       from public.user_sites us
      where us.user_id = auth.uid()          -- ← column A
        and coalesce(us.is_admin,false)
      limit 1),
    false);
$$;

-- 7b. May the caller use this site? Admins: always. Everyone else: only
--     sites they are explicitly linked to.
create or replace function public.iss_may_use_site(p_site text)
returns boolean language sql stable security definer
set search_path = public as $$
  select public.iss_is_admin() or exists (
    select 1 from public.user_sites us
    where us.user_id = auth.uid()            -- ← column A
      and us.site    = p_site                -- ← column B
  );
$$;

grant execute on function public.iss_is_admin()          to authenticated;
grant execute on function public.iss_may_use_site(text)  to authenticated;

-- 7c. Turn RLS on and replace any previous ISS policies.
alter table public.transactions enable row level security;

drop policy if exists tx_site_select on public.transactions;
drop policy if exists tx_site_insert on public.transactions;
drop policy if exists tx_site_update on public.transactions;

-- Read: your own site (admins: all).
create policy tx_site_select on public.transactions
  for select to authenticated
  using (public.iss_may_use_site(site));

-- Write: only tagged with a site you are allowed to write.
create policy tx_site_insert on public.transactions
  for insert to authenticated
  with check (public.iss_may_use_site(site));

-- Update: same on both sides, so a row cannot be moved to another site.
create policy tx_site_update on public.transactions
  for update to authenticated
  using (public.iss_may_use_site(site))
  with check (public.iss_may_use_site(site));

commit;

-- ── VERIFY (run as a site login, not as the SQL editor's own role) ──
-- Should list that site only:
--   select site, count(*) from public.transactions group by site;
-- Must FAIL with a row-level security violation:
--   insert into public.transactions (row_id, site, ticket)
--   values (gen_random_uuid(), 'primecoal', 'WB999');

-- ── ROLLBACK, if the dashboard misbehaves ──────────────────────────
-- This puts it straight back to how it was. Nothing is lost.
--   alter table public.transactions disable row level security;
