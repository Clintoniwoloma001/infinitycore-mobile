-- ============================================================================
-- Widen Employee Tracking + Geofences to Head of E-Business, MD/CEO, Chairman
-- and Director on mobile (Dart gates were widened; this is the SERVER half).
-- ============================================================================
-- WHY THIS FILE EXISTS
-- The Dart gates in lib/core/security/role_guard.dart are a NAVIGATION gate only:
-- they decide whether a menu entry appears and whether a route redirects. The
-- REAL boundary is the server, and before this migration it refused these roles:
--
--   * employee_tracking_access() baseline list was
--       ('head_of_human_resources', 'hr_manager', 'md_ceo', 'chairman', 'director')
--     -> Head of E-Business was missing.
--   * is_geofence_admin() was
--       ('super_admin', 'head_of_human_resources', 'hr_manager')
--     -> Head of E-Business, MD/CEO, Chairman and Director were ALL missing.
--
-- Shipping the Dart change alone would show the menu entries and then have every
-- read refused, which is worse than not showing them.
--
-- SCOPE, DELIBERATELY NARROW
--   employee_tracking_access() : ADD 'head_of_e_business' only. MD/CEO,
--     Chairman and Director were already admitted there.
--   is_geofence_admin()        : ADD all four. It was Super Admin + Head of HR.
--   Staff Analytics            : NO SQL here. It reads
--     mobile_attendance_summary, whose gate is canManageAttendance
--     (super_admin, admin, head_of_human_resources, hr_officer,
--     branch_manager) — a list this change deliberately does NOT widen, because
--     doing so would also open Attendance Management for those roles, which was
--     never asked for. The mobile screen itself is gated separately in Dart.
--
-- SAFETY
-- The full previous text of BOTH functions is in the ROLLBACK section at the
-- bottom, so this is reversible without restoring a backup.
-- employee_tracking_access() is applied as the EXACT current definition with one
-- token added to the role list — its signature (p_user_id), its return shape
-- (can_view / allowed / can_manage / via / expires_at / reason), its grant
-- columns and its ordering are unchanged, so an existing caller cannot notice
-- the difference except that Head of E-Business now passes.
--
-- APPLY (single file, by hand — never `supabase db push`):
--   psql "$POSTGRES_URL" -f supabase/manual/20261110000007_widen_mobile_roles_staff_analytics_tracking_geofences.sql
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. employee_tracking_access(): add Head of E-Business to the baseline list.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.employee_tracking_access(p_user_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  -- The CALLER. Never p_user_id: reading auth.uid() here is what makes the
  -- decision impossible to spoof by passing another id.
  v_uid uuid := auth.uid();
  v_role text;
  v_grant record;
  v_is_super boolean := false;
begin
  if v_uid is null then
    return jsonb_build_object('can_view', false, 'allowed', false,
      'can_manage', false, 'via', 'none', 'expires_at', null,
      'reason', 'Not signed in.');
  end if;

  select p.role into v_role from public.profiles p where p.id = v_uid;
  v_is_super := coalesce(v_role, '') = 'super_admin';

  -- Super Admin: full access, no grant required. Checked FIRST and it
  -- short-circuits, so this branch is reached with a trustworthy id.
  if v_is_super then
    return jsonb_build_object('can_view', true, 'allowed', true,
      'can_manage', true, 'via', 'super_admin', 'expires_at', null,
      'reason', null);
  end if;

  -- BASELINE VIEWERS (added by 20261102000001; Head of E-Business added by
  -- 20261110000007). Head of HR, Head of E-Business, MD/CEO, Director and
  -- Chairman are tracking VIEWS in the product's role matrix; they should not
  -- need the Super Admin to issue a grant before their menu appears.
  -- can_manage stays false: sharing is never delegable.
  if v_role in ('head_of_human_resources', 'hr_manager', 'head_of_e_business', 'md_ceo', 'chairman', 'director') then
    return jsonb_build_object('can_view', true, 'allowed', true,
      'can_manage', false, 'via', 'baseline_role', 'expires_at', null,
      'reason', null);
  end if;

  -- Delegated access. The grant must name THIS caller, either directly or by the
  -- caller's role. The EARLIEST live expiry is reported, and a grant whose
  -- expiry has already passed is ignored here — auto-revocation, no cron needed.
  select g.* into v_grant
    from public.tracking_access_grants g
   where g.revoked_at is null
     and (g.expires_at is null or g.expires_at > now())
     and ( (g.target_type = 'user'   and g.target_user_id = v_uid)
        or (g.target_type = 'role'  and g.target_role    = v_role) )
   order by g.expires_at asc nulls last
   limit 1;

  if found then
    return jsonb_build_object(
      'can_view', true, 'allowed', true,
      'can_manage', false,
      'via', 'delegated:' || v_grant.target_type,
      'expires_at', v_grant.expires_at,
      'reason', null);
  end if;

  return jsonb_build_object('can_view', false, 'allowed', false,
    'can_manage', false, 'via', 'none', 'expires_at', null,
    'reason', 'Employee tracking requires an explicit grant from the Super Admin.');
end;
$function$;

-- ---------------------------------------------------------------------------
-- 2. is_geofence_admin(): same audience. This is the authority behind every
--    geofence RPC (save_branch_geofence, delete_branch_geofence,
--    set_branch_geofence_active) and behind the fence RLS policies.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_geofence_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce((
    select p.role in ('super_admin', 'head_of_human_resources', 'hr_manager', 'head_of_e_business', 'md_ceo', 'chairman', 'director')
      from public.profiles p
     where p.id = auth.uid()
  ), false);
$function$;

COMMIT;

-- ============================================================================
-- ROLLBACK — restores both functions to their exact previous text. Run the
-- whole block manually if you need to undo this migration.
-- ============================================================================
-- BEGIN;
-- CREATE OR REPLACE FUNCTION public.is_geofence_admin()
--  RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
-- AS $function$
--   select coalesce((
--     select p.role in ('super_admin', 'head_of_human_resources', 'hr_manager')
--       from public.profiles p
--      where p.id = auth.uid()
--   ), false);
-- $function$;
-- CREATE OR REPLACE FUNCTION public.employee_tracking_access(p_user_id uuid DEFAULT NULL::uuid)
--  RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
-- AS $function$
-- declare
--   v_uid uuid := auth.uid();
--   v_role text;
--   v_grant record;
--   v_is_super boolean := false;
-- begin
--   if v_uid is null then
--     return jsonb_build_object('can_view', false, 'allowed', false,
--       'can_manage', false, 'via', 'none', 'expires_at', null,
--       'reason', 'Not signed in.');
--   end if;
--   select p.role into v_role from public.profiles p where p.id = v_uid;
--   v_is_super := coalesce(v_role, '') = 'super_admin';
--   if v_is_super then
--     return jsonb_build_object('can_view', true, 'allowed', true,
--       'can_manage', true, 'via', 'super_admin', 'expires_at', null,
--       'reason', null);
--   end if;
--   if v_role in ('head_of_human_resources', 'hr_manager', 'md_ceo', 'chairman', 'director') then
--     return jsonb_build_object('can_view', true, 'allowed', true,
--       'can_manage', false, 'via', 'baseline_role', 'expires_at', null,
--       'reason', null);
--   end if;
--   select g.* into v_grant
--     from public.tracking_access_grants g
--    where g.revoked_at is null
--      and (g.expires_at is null or g.expires_at > now())
--      and ( (g.target_type = 'user'   and g.target_user_id = v_uid)
--         or (g.target_type = 'role'  and g.target_role    = v_role) )
--    order by g.expires_at asc nulls last
--    limit 1;
--   if found then
--     return jsonb_build_object(
--       'can_view', true, 'allowed', true,
--       'can_manage', false,
--       'via', 'delegated:' || v_grant.target_type,
--       'expires_at', v_grant.expires_at,
--       'reason', null);
--   end if;
--   return jsonb_build_object('can_view', false, 'allowed', false,
--     'can_manage', false, 'via', 'none', 'expires_at', null,
--     'reason', 'Employee tracking requires an explicit grant from the Super Admin.');
-- end;
-- $function$;
-- COMMIT;
