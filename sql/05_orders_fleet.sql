-- ═══════════════════════════════════════════════════════════════════
-- ISS · STEP 9 (LATER) — ORDERS + FLEET, PUSHED DOWN TO SITE
--
-- These flow the OPPOSITE way to tickets: the office writes, the site
-- reads. Creating the tables changes nothing on its own — no existing
-- query touches them. Run it whenever you like; the UI to use them is
-- separate work in both the dashboard and the weighbridge app.
--
-- Safe to run now. Safe to run later. Safe to re-run.
-- ═══════════════════════════════════════════════════════════════════

begin;

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
create unique index if not exists orders_site_no_uk
  on public.orders (site, order_no);
create index if not exists orders_site_active_ix
  on public.orders (site, active);

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
create unique index if not exists fleet_site_reg_uk
  on public.fleet (site, reg);
create index if not exists fleet_site_active_ix
  on public.fleet (site, active);

-- Same site rule as transactions, same helper. Sites READ only; the
-- office (admin) is the only role that may write.
alter table public.orders enable row level security;
alter table public.fleet  enable row level security;

drop policy if exists orders_site_select on public.orders;
drop policy if exists orders_admin_write on public.orders;
drop policy if exists fleet_site_select  on public.fleet;
drop policy if exists fleet_admin_write  on public.fleet;

create policy orders_site_select on public.orders
  for select to authenticated using (public.iss_may_use_site(site));
create policy orders_admin_write on public.orders
  for all to authenticated
  using (public.iss_is_admin()) with check (public.iss_is_admin());

create policy fleet_site_select on public.fleet
  for select to authenticated using (public.iss_may_use_site(site));
create policy fleet_admin_write on public.fleet
  for all to authenticated
  using (public.iss_is_admin()) with check (public.iss_is_admin());

commit;

-- Seed one row to prove the read works from a site login:
--   insert into public.orders (site, order_no, customer, product)
--   values ('hillside','TEST-001','Test Customer','Coal ROM');
