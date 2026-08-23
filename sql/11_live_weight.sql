-- ═══════════════════════════════════════════════════════════════════
-- ISS · 11 — LIVE WEIGHT
--
-- ONE ROW PER BRIDGE, UPDATED IN PLACE.
--
-- The live weight is throwaway. The ticket is the permanent record —
-- the same split the belt scales already use, where `hourly` is kept
-- forever and raw `readings` age out. So this table never grows: a
-- bridge posting every 2 seconds for a year is still one row, and
-- there is no retention job to write, schedule or forget.
--
-- Written by the weighbridge app itself on a new bridge. Hillside and
-- anything else on Cloud Sync writes nothing here and is unaffected.
--
-- Safe to run. Safe to re-run.
-- ═══════════════════════════════════════════════════════════════════

begin;

create table if not exists public.live_weight (
  device     text primary key,          -- one row per bridge, keyed by PC + bridge
  site       text not null,
  name       text,                      -- "Weighbridge 1", shown on the dashboard
  weight     numeric,
  unit       text default 'kg',
  stable     boolean not null default false,
  updated_at timestamptz not null default now()
);

create index if not exists live_weight_site_ix on public.live_weight (site);

-- The database keeps the clock. A PC with a wrong time would otherwise
-- make its reading look stale, or worse, permanently fresh.
create or replace function public.iss_live_touch()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  new.site := lower(btrim(new.site));
  return new;
end $$;

drop trigger if exists live_weight_touch on public.live_weight;
create trigger live_weight_touch before insert or update on public.live_weight
  for each row execute function public.iss_live_touch();

-- ── access ─────────────────────────────────────────────────────────
-- A site may read and write its own bridge. Delete is allowed here —
-- unlike tickets — because the app clears its row on shutdown so a
-- closed weighbridge does not leave a number on screen that looks live.
alter table public.live_weight enable row level security;

drop policy if exists live_site_select on public.live_weight;
drop policy if exists live_site_insert on public.live_weight;
drop policy if exists live_site_update on public.live_weight;
drop policy if exists live_site_delete on public.live_weight;

create policy live_site_select on public.live_weight
  for select to authenticated
  using (public.iss_may_use_site(site) or public.iss_is_admin());
create policy live_site_insert on public.live_weight
  for insert to authenticated
  with check (public.iss_may_use_site(site) or public.iss_is_admin());
create policy live_site_update on public.live_weight
  for update to authenticated
  using (public.iss_may_use_site(site) or public.iss_is_admin())
  with check (public.iss_may_use_site(site) or public.iss_is_admin());
create policy live_site_delete on public.live_weight
  for delete to authenticated
  using (public.iss_may_use_site(site) or public.iss_is_admin());

commit;

-- ═══════════════════════════════════════════════════════════════════
-- A bridge that stops posting leaves its last reading behind. The
-- dashboard shows anything older than 90 seconds as STALE with its age,
-- rather than a frozen number that looks current — on a weighbridge
-- screen an honest gap beats a confident lie.
--
-- Optional tidy-up, if a PC is retired without clearing its row:
--   delete from public.live_weight where updated_at < now() - interval '7 days';
--
-- Check what is posting:
--   select site, name, weight, stable, updated_at from public.live_weight
--    order by site, name;
-- ═══════════════════════════════════════════════════════════════════
