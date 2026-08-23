-- ═══════════════════════════════════════════════════════════════════
-- ISS · 10 — iss_my_sites()
--
-- The Cloud tab calls this after signing in, to tell the operator
-- "this PC is registered for commvar" before anything silently fails.
-- It lives in 05_bootstrap.sql, which was never run on this project —
-- same gap that produced the iss_may_use_site error earlier.
--
-- This creates ONLY that function. It does not touch policies, the
-- transactions table, or anything migration 06 and 08 put in place.
--
-- Safe to run. Safe to re-run.
-- ═══════════════════════════════════════════════════════════════════

create or replace function public.iss_my_sites()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_sites jsonb;
  v_admin boolean := false;
begin
  if auth.uid() is null then
    return jsonb_build_object('signed_in', false);
  end if;

  -- Lower-cased on the way out. The app forces its Site Code to lower
  -- case, and user_sites still holds "Hillside" with a capital H, so
  -- returning the raw value would make the app report a mismatch that
  -- migration 08 already dealt with everywhere else.
  select coalesce(jsonb_agg(distinct lower(btrim(us.site))), '[]'::jsonb)
    into v_sites
    from public.user_sites us
   where us.user_id = auth.uid()
     and us.site is not null;

  begin
    v_admin := public.iss_is_admin();
  exception when others then
    v_admin := false;                    -- helper missing: not fatal here
  end;

  return jsonb_build_object(
    'signed_in', true,
    'sites',     coalesce(v_sites, '[]'::jsonb),
    'admin',     v_admin
  );
end $$;

grant execute on function public.iss_my_sites() to authenticated;

-- ═══════════════════════════════════════════════════════════════════
-- DO NOT PRESS "Set up / repair backend" IN THE CLOUD TAB
--
-- That button calls iss_provision(), which rewrites iss_may_use_site()
-- with a version that compares site codes EXACTLY. That would undo
-- migration 08 and break Hillside again, because user_sites still says
-- "Hillside" while the app asks for "hillside".
--
-- It also rewrites the transactions policies. This project already has
-- working ones. Leave that button alone on scalelink.
-- ═══════════════════════════════════════════════════════════════════

-- Check it works (returns signed_in:false here — the SQL editor has no
-- logged-in user; that is expected. The real test is the app):
--   select public.iss_my_sites();
