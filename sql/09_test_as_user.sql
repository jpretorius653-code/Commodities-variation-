-- ═══════════════════════════════════════════════════════════════════
-- ISS · 09 — TEST SITE ACCESS AS A REAL USER
--
-- WHY THIS FILE EXISTS
--
-- Running   select public.iss_may_use_site('hillside');
-- straight into the SQL editor returns FALSE — always, even when
-- everything is set up perfectly.
--
-- The editor runs as the postgres role. There is no logged-in user, so
-- auth.uid() is null, so the "which sites is THIS user allowed" lookup
-- matches nothing. That false tells you nothing about whether Hillside
-- works. It only tells you that the SQL editor is not Hillside.
--
-- To get a real answer you have to pretend to be that user. Supabase
-- reads the current user from a request claim, and you can set that
-- claim by hand for one transaction.
-- ═══════════════════════════════════════════════════════════════════

-- ── Step 1. Find the user's id ─────────────────────────────────────
select id, email from auth.users where email = 'hillside@iss.local';


-- ── Step 2. Become that user for one transaction ───────────────────
-- Paste the id from step 1 into BOTH places marked <UUID>.
-- Everything is inside begin/rollback, so nothing is changed.

begin;
  select set_config('role','authenticated',true);
  select set_config('request.jwt.claims',
    json_build_object('sub','<UUID>','role','authenticated')::text, true);

  select public.iss_may_use_site('hillside') as lower_case_works,
         public.iss_may_use_site('Hillside') as capital_h_works,
         public.iss_is_admin()               as is_admin;

  -- and the call the weighbridge app actually makes
  select count(*) as fleet_rows_visible
    from public.iss_fleet_since('hillside', null);
rollback;

-- BOTH of the first two columns must come back true. That is the whole
-- point of 08: the app asks in lower case, user_sites still says
-- "Hillside", and matching is now blind to the difference.
--
-- If lower_case_works is false but capital_h_works is true, 08 did not
-- take — re-run it and check for errors.


-- ── Step 3. Confirm the function really was replaced ───────────────
-- Belt and braces: the new body compares lower(btrim(...)). If this
-- returns false, an old definition is still in place.
select position('lower(btrim' in pg_get_functiondef(p.oid)) > 0 as is_case_blind
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'iss_may_use_site';


-- ═══════════════════════════════════════════════════════════════════
-- THE EASIER TEST
--
-- All of the above is one way of asking a question the app answers by
-- itself. If you would rather not fiddle with claims:
--
--   Dashboard: sign in as hillside@iss.local, open the Fleet tab. If it
--   loads without the amber "may read but not change it" warning, and a
--   truck saves, matching is working.
--
--   Weighbridge app: Cloud tab -> Test connection. It should say the PC
--   is registered for its site. Then Sync now.
-- ═══════════════════════════════════════════════════════════════════
