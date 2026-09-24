-- ---------------------------------------------------------------------------
-- Phase 07 — Persistent device binding
--
-- Security requirement: a device is bound to ONE account and stays bound even
-- after that account signs out. Nobody can sign a different account in on the
-- same phone just because the owner signed out. The only release path is an
-- explicit HR/Super Admin unbind (mobile_admin_revoke_device, role-checked).
--
-- Changes:
--   1. mobile_device_register() additionally refuses registration when this
--      physical device already has an ACTIVE session bound to a DIFFERENT
--      account (previously only the user→other-device direction was checked).
--   2. mobile_device_revoke() no longer releases the binding on client
--      sign-out. It records an audit event and refreshes last_seen_at only;
--      the session row stays active so the device remains bound.
--
-- Backwards compatibility: old builds still call mobile_device_revoke on
-- sign-out — with this function that call is harmless (binding retained).
-- New builds skip the call entirely and only clear local state.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. REGISTER — same phase-03 signature, plus the device→account check.
-- ---------------------------------------------------------------------------
drop function if exists public.mobile_device_register(text,text,text,text,text,text);

create or replace function public.mobile_device_register(
  p_device_id text,
  p_device_model text default null,
  p_os_version text default null,
  p_app_version text default null,
  p_biometric_capability text default 'none',
  p_platform text default 'mobile'
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_session_id uuid;
  v_employee_id uuid;
  v_existing record;
  v_device_owner record;
begin
  if auth.uid() is null then raise exception 'Not authenticated.'; end if;
  if coalesce(p_device_id, '') = '' then
    raise exception 'MOBILE_SESSION:Missing device identity.';
  end if;

  select id into v_employee_id
    from public.employees
   where user_id = auth.uid()
     and coalesce(is_archived, false) = false
   order by created_at desc
   limit 1;

  -- Enforce one active mobile device per user. Do not silently replace.
  select * into v_existing
    from public.mobile_device_sessions
   where user_id = auth.uid()
     and is_active = true
     and device_id is distinct from p_device_id
   limit 1;

  if found then
    perform public.mobile_audit_log(
      'MOBILE_UNAUTHORIZED_DEVICE',
      'MobileDeviceSession',
      v_existing.id::text,
      format('Attempt to register device %s while %s is already active for user %s',
             p_device_id, v_existing.device_id, auth.uid()),
      'warning'
    );
    raise exception 'MOBILE_UNAUTHORIZED_DEVICE:This account is already linked to another mobile device. Please contact HR or Super Admin to authorize this device.';
  end if;

  -- Phase 07: the binding survives sign-out, so an ACTIVE session on this
  -- device for a DIFFERENT account means the device is taken. Refuse.
  select * into v_device_owner
    from public.mobile_device_sessions
   where device_id = p_device_id
     and is_active = true
     and user_id is distinct from auth.uid()
   limit 1;

  if found then
    perform public.mobile_audit_log(
      'MOBILE_UNAUTHORIZED_DEVICE',
      'MobileDeviceSession',
      v_device_owner.id::text,
      format('Device %s is bound to user %s; registration refused for user %s',
             p_device_id, v_device_owner.user_id, auth.uid()),
      'warning'
    );
    raise exception 'MOBILE_UNAUTHORIZED_DEVICE:This device is already linked to another account. Please contact HR or Super Admin to unbind it before signing in here.';
  end if;

  insert into public.mobile_device_sessions (
    user_id, employee_id, device_id, device_model, os_version,
    app_version, platform, biometric_capability, status, is_active
  )
  values (
    auth.uid(), v_employee_id, p_device_id, p_device_model, p_os_version,
    p_app_version, coalesce(nullif(p_platform, ''), 'mobile'),
    p_biometric_capability, 'active', true
  )
  on conflict (user_id) where is_active is true
  do update set
    employee_id = excluded.employee_id,
    device_model = coalesce(excluded.device_model, public.mobile_device_sessions.device_model),
    os_version = coalesce(excluded.os_version, public.mobile_device_sessions.os_version),
    app_version = coalesce(excluded.app_version, public.mobile_device_sessions.app_version),
    platform = coalesce(excluded.platform, public.mobile_device_sessions.platform),
    biometric_capability = coalesce(excluded.biometric_capability, public.mobile_device_sessions.biometric_capability),
    last_seen_at = clock_timestamp(),
    status = 'active'
  returning id into v_session_id;

  perform public.mobile_audit_log(
    'MOBILE_DEVICE_LINKED',
    'MobileDeviceSession',
    v_session_id::text,
    format('Device %s registered for user %s (platform %s)', p_device_id, auth.uid(), coalesce(p_platform, 'mobile')),
    'info'
  );

  return jsonb_build_object(
    'ok', true,
    'session_id', v_session_id,
    'employee_id', v_employee_id,
    'device_id', p_device_id,
    'reason', 'registered'
  );
end;
$$;


-- ---------------------------------------------------------------------------
-- 2. REVOKE — client sign-out no longer releases the binding.
--
-- The device stays bound to the account across sign-outs. This function now
-- only refreshes last_seen_at and writes an audit event. The binding is
-- released exclusively through mobile_admin_revoke_device() (Super Admin /
-- Head of HR), so a phone cannot be recycled into another account by
-- signing out.
-- ---------------------------------------------------------------------------
drop function if exists public.mobile_device_revoke(text);
drop function if exists public.mobile_device_revoke(text,text);

create or replace function public.mobile_device_revoke(
  p_device_id text,
  p_reason text default 'client_sign_out'
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_session record;
begin
  if auth.uid() is null then raise exception 'Not authenticated.'; end if;

  select * into v_session
    from public.mobile_device_sessions
   where user_id = auth.uid()
     and is_active = true
     and (p_device_id is null or p_device_id = '' or device_id = p_device_id)
   limit 1;

  if found then
    -- Binding intentionally retained: only touch the heartbeat.
    update public.mobile_device_sessions
       set last_seen_at = clock_timestamp()
     where id = v_session.id;

    perform public.mobile_audit_log(
      'MOBILE_DEVICE_SIGN_OUT',
      'MobileDeviceSession',
      v_session.id::text,
      format('User %s signed out of device %s; binding retained (release requires HR/Super Admin unbind). Reason: %s',
             auth.uid(), v_session.device_id, p_reason),
      'info'
    );
  end if;

  -- 'revoked' is always false here: the client cannot unbind itself.
  return jsonb_build_object('ok', true, 'revoked', false, 'binding_retained', found);
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. PERMISSIONS — unchanged surface.
-- ---------------------------------------------------------------------------
grant execute on function public.mobile_device_register(text,text,text,text,text,text) to authenticated;
grant execute on function public.mobile_device_revoke(text,text) to authenticated;

revoke execute on function public.mobile_device_register(text,text,text,text,text,text) from anon, public;
revoke execute on function public.mobile_device_revoke(text,text) from anon, public;


-- ---------------------------------------------------------------------------
-- 4. BOUND-DEVICES LIST — 42804 repair.
--
-- The live database still carries an older mobile_list_authorized_devices
-- whose 6th produced column is character varying(255) (auth.users.email
-- without a cast), which PostgREST rejects:
--   "Returned type character varying(255) does not match expected type text
--    in column 6" (error 42804) — this is what blanked the Bound app devices
-- screen. Recreate it with explicit ::text casts on every text column.
-- (DROP first: CREATE OR REPLACE cannot change an existing return type, and
-- dropping clears grants — re-granted below.)
-- ---------------------------------------------------------------------------
drop function if exists public.mobile_list_authorized_devices(text, uuid, text, text, text, text);

create or replace function public.mobile_list_authorized_devices(
  p_search text default null,
  p_branch_id uuid default null,
  p_department text default null,
  p_platform text default null,
  p_status text default null,
  p_biometric_status text default null
)
returns table (
  session_id uuid,
  user_id uuid,
  employee_id uuid,
  employee_name text,
  employee_number text,
  email text,
  department text,
  branch_id uuid,
  branch_name text,
  device_id text,
  device_model text,
  platform text,
  os_version text,
  app_version text,
  biometric_capability text,
  biometric_enabled boolean,
  linked_at timestamptz,
  last_authenticated_at timestamptz,
  last_seen_at timestamptz,
  last_attendance_at timestamptz,
  created_at timestamptz,
  status text,
  revoked_at timestamptz,
  revoked_by uuid,
  revoked_reason text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if public.current_role() not in ('super_admin', 'head_of_human_resources') then
    raise exception 'Not authorized to manage mobile device bindings.';
  end if;

  return query
  select
    s.id::uuid,
    s.user_id::uuid,
    s.employee_id::uuid,
    e.full_name::text,
    coalesce(e.employee_number, e.staff_id, e.employee_code)::text,
    u.email::text,
    e.department::text,
    e.branch_id::uuid,
    b.branch_name::text,
    s.device_id::text,
    s.device_model::text,
    s.platform::text,
    s.os_version::text,
    s.app_version::text,
    s.biometric_capability::text,
    s.biometric_enabled::boolean,
    s.linked_at,
    s.last_authenticated_at,
    s.last_seen_at,
    s.last_attendance_at,
    s.created_at,
    s.status::text,
    s.revoked_at,
    s.revoked_by::uuid,
    s.revoked_reason::text
  from public.mobile_device_sessions s
  left join public.employees e on e.id = s.employee_id
  left join auth.users u on u.id = s.user_id
  left join public.branches b on b.id = e.branch_id
  where (p_search is null or p_search = ''
         or e.full_name ilike '%' || p_search || '%'
         or u.email ilike '%' || p_search || '%'
         or coalesce(e.employee_number, e.staff_id, e.employee_code) ilike '%' || p_search || '%'
         or s.device_id ilike '%' || p_search || '%')
    and (p_branch_id is null or e.branch_id = p_branch_id)
    and (p_department is null or p_department = '' or e.department ilike p_department)
    and (p_platform is null or p_platform = ''
         or (lower(p_platform) = 'other' and s.platform is not distinct from 'mobile')
         or s.platform = lower(p_platform))
    and (p_status is null or p_status = '' or s.status = lower(p_status))
    and (p_biometric_status is null or p_biometric_status = ''
         or (lower(p_biometric_status) = 'enabled' and s.biometric_enabled is true)
         or (lower(p_biometric_status) = 'disabled' and s.biometric_enabled is false))
  order by s.created_at desc
  limit 1000;
end;
$$;

grant execute on function public.mobile_list_authorized_devices(text, uuid, text, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. MANAGE SUMMARY — 42804 repair.
--
-- The live mobile_attendance_summary still returns uncast numeric(10,6)
-- columns where the declared type is double precision (PostgREST 42804,
-- column 18), blanking the Manage tab. Recreate with explicit casts on
-- every produced column. (DROP first: return-type changes need it, and
-- grants are re-applied below.)
-- ---------------------------------------------------------------------------
drop function if exists public.mobile_attendance_summary(date, date, uuid, text);

create or replace function public.mobile_attendance_summary(
  p_from date default null,
  p_to date default null,
  p_branch_id uuid default null,
  p_status text default null
)
returns table (
  attendance_id uuid,
  employee_id uuid,
  employee_name text,
  employee_number text,
  department text,
  branch_id uuid,
  branch_name text,
  attendance_date date,
  clock_in timestamptz,
  clock_out timestamptz,
  status text,
  work_hours numeric,
  total_minutes integer,
  late_status text,
  late_minutes integer,
  location_status text,
  geofence_status text,
  clock_in_lat double precision,
  clock_in_lng double precision,
  clock_in_accuracy double precision,
  actual_location_name text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if public.current_role() not in ('super_admin', 'admin', 'head_of_human_resources', 'hr_officer', 'branch_manager') then
    raise exception 'Not authorized to view attendance management.';
  end if;
  return query
  select
    ar.id::uuid,
    ar.employee_id::uuid,
    e.full_name::text,
    coalesce(e.employee_number, e.staff_id, e.employee_code)::text,
    e.department::text,
    ar.branch_id::uuid,
    b.branch_name::text,
    ar.attendance_date::date,
    ar.clock_in::timestamptz,
    ar.clock_out::timestamptz,
    ar.status::text,
    ar.work_hours::numeric,
    ar.total_minutes::integer,
    (case when ar.late_status then 'late' else 'on_time' end)::text,
    ar.late_minutes::integer,
    ar.location_status::text,
    ar.geofence_status::text,
    ar.clock_in_lat::double precision,
    ar.clock_in_lng::double precision,
    ar.clock_in_accuracy::double precision,
    (select (ae.metadata ->> 'actual_location_name')::text
       from public.attendance_events ae
      where ae.attendance_record_id = ar.id and ae.event_type = 'CLOCK_IN'
      order by ae.event_time asc limit 1)::text
  from public.attendance_records ar
  join public.employees e on e.id = ar.employee_id
  left join public.branches b on b.id = ar.branch_id
  where (p_from is null or ar.attendance_date >= p_from)
    and (p_to is null or ar.attendance_date <= p_to)
    and (p_branch_id is null or ar.branch_id = p_branch_id)
    and (p_status is null or ar.status = p_status)
  order by ar.attendance_date desc, ar.clock_in desc
  limit 500;
end;
$$;

grant execute on function public.mobile_attendance_summary(date, date, uuid, text) to authenticated;
revoke execute on function public.mobile_attendance_summary(date, date, uuid, text) from anon, public;

revoke execute on function public.mobile_list_authorized_devices(text, uuid, text, text, text, text) from anon, public;
