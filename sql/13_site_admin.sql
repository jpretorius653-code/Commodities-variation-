-- ═══════════════════════════════════════════════════════════════════
-- ISS · 13 — SITE ADMIN FROM THE DASHBOARD
--
-- Creating a site and linking a login to it has meant hand-written SQL
-- so far. That is fine once; it is not fine every time a bridge is
-- commissioned, and it is where the Hillside / hillside capitalisation
-- mess came from in the first place.
--
-- These four calls do it from the Admin page. Every one is
-- SECURITY DEFINER — they read auth.users, which a browser session
-- cannot — and every one refuses outright unless the caller is an ISS
-- admin. That check is the only thing standing between a site login and
-- the whole user list, so it is the first line of each function.
--
-- Site codes are forced to lower case here, so the dashboard cannot
-- reintroduce the mismatch that migration 08 cleaned up.
--
-- Safe to run. Safe to re-run.
-- ═══════════════════════════════════════════════════════════════════

begin;

create table if not exists public.sites (
  code       text primary key,
  name       text,
  created_at timestamptz not null default now()
);
alter table public.sites enable row level security;

drop policy if exists sites_read on public.sites;
create policy sites_read on public.sites
  for select to authenticated
  using (public.iss_may_use_site(code) or public.iss_is_admin());

-- Backfill from every place a site code already appears, so the list is
-- complete on day one rather than starting empty next to live data.
insert into public.sites (code, name)
select DISTINCT lower(btrim(s)), initcap(btrim(s))
  from (
    select site as s from public.user_sites where site is not null
    union select site from public.transactions where site is not null
    union select site from public.scales where site is not null
  ) x
 where btrim(s) <> ''
on conflict (code) do nothing;

-- ── 1. the site list, with what is actually attached to each ───────
create or replace function public.iss_admin_sites()
returns jsonb language plpgsql stable security definer
set search_path = public as $$
begin
  if not public.iss_is_admin() then raise exception 'admin only'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'code', s.code,
             'name', s.name,
             'users',   (select count(*) from public.user_sites us
                          where lower(btrim(us.site)) = s.code),
             'scales',  (select count(*) from public.scales sc
                          where lower(btrim(sc.site)) = s.code),
             'tickets', (select count(*) from public.transactions t
                          where lower(btrim(t.site)) = s.code)
           ) order by s.code)
      from public.sites s), '[]'::jsonb);
end $$;

-- ── 2. create a site ───────────────────────────────────────────────
create or replace function public.iss_admin_create_site(p_code text, p_name text default null)
returns jsonb language plpgsql security definer
set search_path = public as $$
declare v_code text;
begin
  if not public.iss_is_admin() then raise exception 'admin only'; end if;
  v_code := lower(btrim(p_code));
  if v_code = '' or v_code is null then raise exception 'a site code is required'; end if;
  if v_code ~ '[^a-z0-9_-]' then
    raise exception 'site code % may only contain letters, digits, - and _ '
                    '(it has to match the Site Code typed into the weighbridge app)', v_code;
  end if;
  insert into public.sites (code, name)
  values (v_code, coalesce(nullif(btrim(p_name),''), initcap(v_code)))
  on conflict (code) do update set name = excluded.name;
  return jsonb_build_object('code', v_code);
end $$;

-- ── 3. who can reach what ──────────────────────────────────────────
create or replace function public.iss_admin_users()
returns jsonb language plpgsql stable security definer
set search_path = public as $$
begin
  if not public.iss_is_admin() then raise exception 'admin only'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'email',    u.email,
             'site',     us.site,
             'is_admin', coalesce(us.is_admin,false),
             'linked',   us.user_id is not null,
             'confirmed', u.email_confirmed_at is not null,
             'last_sign_in', u.last_sign_in_at
           ) order by u.email)
      from auth.users u
      left join public.user_sites us on us.user_id = u.id), '[]'::jsonb);
end $$;

-- ── 4. link / unlink a login ───────────────────────────────────────
-- Looked up by email rather than by a pasted UUID: an account deleted and
-- recreated gets a new id, and a stale UUID is exactly how commvar-wb1
-- ended up mapped to nothing.
create or replace function public.iss_admin_link_user(
  p_email text, p_site text, p_is_admin boolean default false)
returns jsonb language plpgsql security definer
set search_path = public as $$
declare v_uid uuid; v_code text;
begin
  if not public.iss_is_admin() then raise exception 'admin only'; end if;
  select id into v_uid from auth.users where lower(email) = lower(btrim(p_email));
  if v_uid is null then
    raise exception 'no login called % — create it under Authentication → Users first', p_email;
  end if;
  v_code := lower(btrim(p_site));
  if v_code = '' then v_code := null; end if;      -- null site = ISS admin, all sites
  if v_code is not null and not exists (select 1 from public.sites where code = v_code) then
    raise exception 'site % does not exist — create it first', v_code;
  end if;
  delete from public.user_sites where user_id = v_uid;
  insert into public.user_sites (user_id, site, is_admin)
  values (v_uid, v_code, coalesce(p_is_admin,false));
  return jsonb_build_object('email', p_email, 'site', v_code, 'is_admin', coalesce(p_is_admin,false));
end $$;

create or replace function public.iss_admin_unlink_user(p_email text)
returns jsonb language plpgsql security definer
set search_path = public as $$
declare v_uid uuid;
begin
  if not public.iss_is_admin() then raise exception 'admin only'; end if;
  select id into v_uid from auth.users where lower(email) = lower(btrim(p_email));
  if v_uid is null then raise exception 'no login called %', p_email; end if;
  -- Revoking your own admin rights would lock you out of this page with no
  -- way back except SQL. Refuse rather than let it happen.
  if v_uid = auth.uid() then raise exception 'you cannot unlink your own login'; end if;
  delete from public.user_sites where user_id = v_uid;
  return jsonb_build_object('email', p_email, 'unlinked', true);
end $$;

grant execute on function public.iss_admin_sites()                          to authenticated;
grant execute on function public.iss_admin_create_site(text, text)          to authenticated;
grant execute on function public.iss_admin_users()                          to authenticated;
grant execute on function public.iss_admin_link_user(text, text, boolean)   to authenticated;
grant execute on function public.iss_admin_unlink_user(text)                to authenticated;

commit;

-- A site is never deleted from here. Removing a site code that tickets or
-- readings still reference would orphan them silently. Retire it by
-- unlinking its logins instead — the data stays reachable to an admin.
