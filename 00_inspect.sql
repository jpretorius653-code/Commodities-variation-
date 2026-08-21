-- ═══════════════════════════════════════════════════════════════════
-- ISS · STEP 1 — INSPECT (READ ONLY)
-- Changes nothing. Run each block, keep the output, paste it back if
-- you want the later scripts adjusted to what you actually have.
-- Where: Supabase Dashboard → SQL Editor → New query.
-- ═══════════════════════════════════════════════════════════════════

-- 1a. What does user_sites look like? The RLS helper must use these names.
select column_name, data_type, is_nullable
from information_schema.columns
where table_schema = 'public' and table_name = 'user_sites'
order by ordinal_position;

-- 1b. What does the dashboard's my_access() actually read?
--     The admin flag has to come from the same place, or admins get
--     locked out of other sites the moment RLS goes on.
select p.proname, pg_get_functiondef(p.oid) as definition
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in ('my_access','iss_may_use_site','iss_is_admin');

-- 1c. Which tables already have RLS on, and what policies exist?
--     Anything already protected must not be disturbed.
select c.relname as table_name, c.relrowsecurity as rls_enabled
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r'
order by c.relname;

select tablename, policyname, cmd, roles
from pg_policies where schemaname = 'public' order by tablename, policyname;

-- 1d. Does transactions already have row_id / site?
select column_name, data_type
from information_schema.columns
where table_schema='public' and table_name='transactions'
order by ordinal_position;

-- 1e. Duplicate ticket numbers? Any rows here BLOCK the per-site unique
--     index in step 2 — they must be resolved first.
select ticket, count(*) as copies
from public.transactions
group by ticket having count(*) > 1
order by copies desc limit 50;

-- 1f. How many rows are there, and are any already tagged with a site?
select count(*) as total_rows from public.transactions;
select site, count(*) from public.transactions group by site order by 2 desc;

-- 1g. Existing logins, so you know which UUIDs to link in step 5.
select id, email, created_at from auth.users order by created_at;
select * from public.user_sites;
