-- ---------------------------------------------------------------------------
-- Phase 05 — (1) allow attendance on devices WITHOUT usable biometrics,
--              (2) fix Manage summary 42804 type mismatches,
--              (3) fix Bound-app-devices function typing,
--              (4) mobile supervisor read RPC for Profile.
--
-- Mirrored as sara: 20260924000001_attendance_no_biometric_devices.sql
-- ---------------------------------------------------------------------------

-- mobile_session_guard keeps employee self-linking + device-binding checks.
-- Biometric gates (biometric_enabled + 5-minute freshness) now apply ONLY to
-- devices that report a biometric capability; sensors with capability 'none'
-- (no sensor / spoilt firmware) skip the local-assertion gates entirely while
-- still getting all of the device-binding / employee protections.
create or replace function public.mobile_session_guard(
  p_employee_id uuid,
  p_device_id text,
  p_fingerprint text,
  p_event_type text
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_employee_id uuid;
  v_session record;
  v_binding jsonb;
  v_window interval := '5 minutes';
begin
  if auth.uid() is null then raise exception 'Not authenticated.'; end if;

  select * into v_session
    from public.mobile_device_sessions
   where user_id = auth.uid()
     and is_active = true
     and device_id = p_device_id
   limit 1;

  if not found then
    raise exception 'MOBILE_SESSION:Cannot verify this device. Re-authenticate to continue.';
  end if;

  if coalesce(nullif(v_session.biometric_capability, ''), 'none') <> 'none' then
    if v_session.biometric_enabled is not true then
      raise exception 'BIOMETRIC_REQUIRED:Biometric attendance is not enabled on this device. Go to Profile → Biometric to set it up.';
    end if;
    if v_session.last_authenticated_at is null
       or v_session.last_authenticated_at < (clock_timestamp() - v_window) then
      raise exception 'BIOMETRIC_REQUIRED:Please verify with your device biometric before recording attendance.';
    end if;
  end if;

  if p_employee_id is not null then
    select id into v_employee_id
      from public.employees
     where id = p_employee_id and user_id = auth.uid()
       and coalesce(is_archived, false) = false;
    if v_employee_id is null then
      raise exception 'MOBILE_SESSION:You can only record attendance for yourself.';
    end if;
  else
    select id into v_employee_id
      from public.employees
     where user_id = auth.uid()
       and coalesce(is_archived, false) = false
     order by created_at desc
     limit 1;
    if v_employee_id is null then
      raise exception 'PROFILE:No employee record linked to this account yet.';
    end if;
  end if;

  v_binding := public.attendance_device_binding_check(p_fingerprint, v_employee_id, p_event_type);
  if (v_binding ->> 'allowed')::boolean is distinct from true then
    raise exception 'DEVICE_BINDING:This device could not be linked to an employee for today.';
  end if;

  return v_employee_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. mobile_clock_in / mobile_clock_out — biometric assertion is still
--    REQUIRED for devices that report biometric capability; devices whose
--    session capability is 'none' (no sensor, or failed/spoilt firmware)
--    record attendance through the normal location/branch/employee path.
--    Geofence, device binding, one-record-per-day and duplicate protections
--    stay fully enforced — this only relaxes the local identity-assertion
--    step for devices physically incapable of it.
-- ---------------------------------------------------------------------------

-- DROP old signatures to avoid overload ambiguity for named-arg RPC calls.
drop function if exists public.mobile_clock_in(double precision, double precision, double precision, text, uuid, text, text, boolean, text, uuid, text);
drop function if exists public.mobile_clock_out(uuid, double precision, double precision, double precision, text, uuid, text, text, boolean, text, uuid, text);

create or replace function public.mobile_clock_in(
  p_lat float,
  p_lng float,
  p_accuracy float default 0,
  p_device_fingerprint text default '',
  p_employee_id uuid default null,
  p_device_id text default 'app',
  p_app_version text default null,
  p_biometric_used boolean default false,
  p_app_build text default null,
  p_terminal_id uuid default null,
  p_entry_point text default 'mobile'
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_employee_id uuid;
  v_result jsonb;
  v_session_id uuid;
  v_session record;
  v_entry_point text := 'MOBILE';
  v_verification text := 'BIOMETRIC+GPS';
  v_terminal_device_id uuid;
begin
  v_employee_id := public.mobile_session_guard(
    p_employee_id, p_device_id, p_device_fingerprint, 'CLOCK_IN'
  );

  select * into v_session
    from public.mobile_device_sessions
   where user_id = auth.uid()
     and is_active = true
     and device_id = p_device_id
   limit 1;

  if not found then
    raise exception 'MOBILE_SESSION:Cannot verify this device. Re-authenticate to continue.';
  end if;
  v_session_id := v_session.id;

  if p_biometric_used is not true then
    if coalesce(nullif(v_session.biometric_capability, ''), 'none') <> 'none' then
      raise exception 'BIOMETRIC_REQUIRED:Attendance requires a successful biometric assertion on this device.';
    end if;
    v_verification := 'GPS';
  end if;

  if p_terminal_id is not null then
    select id into v_terminal_device_id
      from public.attendance_devices
     where id = p_terminal_id
       and device_type = 'attendance_terminal'
       and active = true
       and status = 'active';
    if not found then
      raise exception 'TERMINAL_INACTIVE:This attendance terminal is not active. Contact HR.';
    end if;
    v_entry_point := coalesce(nullif(lower(p_entry_point), ''), 'mobile_qr_terminal');
    if v_entry_point <> 'mobile_qr_terminal' then
      v_entry_point := 'MOBILE_QR_TERMINAL';
    end if;
    v_entry_point := upper(v_entry_point);
    if p_biometric_used is true then
      v_verification := 'BIOMETRIC+GPS+QR';
    else
      v_verification := 'GPS+QR';
    end if;
  end if;

  v_result := public.attendance_clock_in_for_employee(
    v_employee_id, p_lat, p_lng, p_accuracy,
    'mobile', v_terminal_device_id, v_verification, v_entry_point, null, false
  );

  update public.attendance_records
     set mobile_session_id = v_session_id,
         mobile_device_id = p_device_id,
         mobile_platform = coalesce(nullif(v_session.platform, ''), 'mobile'),
         mobile_app_version = coalesce(p_app_version, v_session.app_version),
         mobile_biometric_verified = p_biometric_used
   where id = (v_result ->> 'attendance_id')::uuid;

  update public.mobile_device_sessions
     set last_attendance_at = clock_timestamp()
   where id = v_session_id;

  perform public.attendance_device_bind(p_device_fingerprint, v_employee_id, null);

  perform public.mobile_audit_log(
    'MOBILE_ATTENDANCE_AUTHORIZED',
    'AttendanceRecord',
    (v_result ->> 'attendance_id')::text,
    format('Clock-in authorized for employee %s on device %s %s', v_employee_id, p_device_id,
           case when p_terminal_id is not null then format('via terminal %s', p_terminal_id) else '' end),
    'info'
  );

  return v_result || jsonb_build_object(
    'server_time', v_result ->> 'clock_in_at',
    'verification_method', v_verification,
    'source_detail', v_entry_point,
    'session_id', v_session_id,
    'terminal_id', case when p_terminal_id is not null then p_terminal_id else null end
  );
end;
$$;

create or replace function public.mobile_clock_out(
  p_attendance_id uuid,
  p_lat float,
  p_lng float,
  p_accuracy float default 0,
  p_device_fingerprint text default '',
  p_employee_id uuid default null,
  p_device_id text default 'app',
  p_app_version text default null,
  p_biometric_used boolean default false,
  p_app_build text default null,
  p_terminal_id uuid default null,
  p_entry_point text default 'mobile'
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_employee_id uuid;
  v_result jsonb;
  v_session_id uuid;
  v_session record;
  v_entry_point text := 'MOBILE';
  v_verification text := 'BIOMETRIC+GPS';
  v_terminal_device_id uuid;
begin
  v_employee_id := public.mobile_session_guard(
    p_employee_id, p_device_id, p_device_fingerprint, 'CLOCK_OUT'
  );

  select * into v_session
    from public.mobile_device_sessions
   where user_id = auth.uid()
     and is_active = true
     and device_id = p_device_id
   limit 1;

  if not found then
    raise exception 'MOBILE_SESSION:Cannot verify this device. Re-authenticate to continue.';
  end if;
  v_session_id := v_session.id;

  if p_biometric_used is not true then
    if coalesce(nullif(v_session.biometric_capability, ''), 'none') <> 'none' then
      raise exception 'BIOMETRIC_REQUIRED:Attendance requires a successful biometric assertion on this device.';
    end if;
    v_verification := 'GPS';
  end if;

  if p_terminal_id is not null then
    select id into v_terminal_device_id
      from public.attendance_devices
     where id = p_terminal_id
       and device_type = 'attendance_terminal'
       and active = true
       and status = 'active';
    if not found then
      raise exception 'TERMINAL_INACTIVE:This attendance terminal is not active. Contact HR.';
    end if;
    v_entry_point := coalesce(nullif(lower(p_entry_point), ''), 'mobile_qr_terminal');
    if v_entry_point <> 'mobile_qr_terminal' then
      v_entry_point := 'MOBILE_QR_TERMINAL';
    end if;
    v_entry_point := upper(v_entry_point);
    if p_biometric_used is true then
      v_verification := 'BIOMETRIC+GPS+QR';
    else
      v_verification := 'GPS+QR';
    end if;
  end if;

  v_result := public.attendance_clock_out_for_employee(
    v_employee_id, p_attendance_id, p_lat, p_lng, p_accuracy,
    'mobile', v_terminal_device_id, v_verification, v_entry_point, null, false
  );

  update public.attendance_records
     set mobile_session_id = v_session_id,
         mobile_device_id = p_device_id,
         mobile_platform = coalesce(nullif(v_session.platform, ''), 'mobile'),
         mobile_app_version = coalesce(p_app_version, v_session.app_version),
         mobile_biometric_verified = p_biometric_used
   where id = p_attendance_id;

  update public.mobile_device_sessions
     set last_attendance_at = clock_timestamp()
   where id = v_session_id;

  perform public.attendance_device_bind(p_device_fingerprint, v_employee_id, null);

  perform public.mobile_audit_log(
    'MOBILE_ATTENDANCE_AUTHORIZED',
    'AttendanceRecord',
    p_attendance_id::text,
    format('Clock-out authorized for employee %s on device %s %s', v_employee_id, p_device_id,
           case when p_terminal_id is not null then format('via terminal %s', p_terminal_id) else '' end),
    'info'
  );

  return v_result || jsonb_build_object(
    'server_time', v_result ->> 'clock_out_at',
    'verification_method', v_verification,
    'source_detail', v_entry_point,
    'session_id', v_session_id,
    'terminal_id', case when p_terminal_id is not null then p_terminal_id else null end
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Manage summary — declared double precision columns vs numeric(10,6)
--    source columns (Postgrest 42804, column 18 = clock_in_lat).
-- ---------------------------------------------------------------------------
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
    ar.id,
    ar.employee_id,
    e.full_name,
    coalesce(e.employee_number, e.staff_id, e.employee_code),
    e.department,
    ar.branch_id,
    b.branch_name,
    ar.attendance_date,
    ar.clock_in,
    ar.clock_out,
    ar.status,
    ar.work_hours,
    ar.total_minutes,
    case when ar.late_status then 'late' else 'on_time' end,
    ar.late_minutes,
    ar.location_status,
    ar.geofence_status,
    ar.clock_in_lat::double precision,
    ar.clock_in_lng::double precision,
    ar.clock_in_accuracy::double precision,
    (select (ae.metadata ->> 'actual_location_name')
       from public.attendance_events ae
      where ae.attendance_record_id = ar.id and ae.event_type = 'CLOCK_IN'
      order by ae.event_time asc limit 1)
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

-- ---------------------------------------------------------------------------
-- 3. Bound-app-devices list — explicit casts so every declared return column
--    exactly matches the produced value (no latent 42804).
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- 4. mobile_get_my_supervisor — Profile supervisor read. Returns the current
--    user's own supervisor chain from the HR org table
--    (employee_supervisors -> employees). HR roles may pass p_employee_id.
-- ---------------------------------------------------------------------------
create or replace function public.mobile_get_my_supervisor(
  p_employee_id uuid default null
)
returns table (
  employee_id uuid,
  supervisor_employee_id uuid,
  supervisor_name text,
  supervisor_position text,
  supervisor_department text,
  supervisor_title text,
  level integer
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_employee_id uuid;
begin
  v_employee_id := (
    select e.id from public.employees e
     where (p_employee_id is null and e.user_id = auth.uid())
        or (p_employee_id is not null and e.id = p_employee_id)
     order by (e.user_id = auth.uid()) desc
     limit 1
  );

  if v_employee_id is null then
    return;
  end if;

  if p_employee_id is not null and v_employee_id <> p_employee_id then
    return;
  end if;

  return query
  select es.employee_id,
         es.supervisor_employee_id,
         sup.full_name,
         sup.position,
         sup.department,
         es.supervisor_title,
         es.level
    from public.employee_supervisors es
    left join public.employees sup on sup.id = es.supervisor_employee_id
   where es.employee_id = v_employee_id
     and (es.effective_from is null or es.effective_from <= current_date)
   order by es.level asc
   limit 3;
end;
$$;

grant execute on function public.mobile_clock_in(float, float, float, text, uuid, text, text, boolean, text, uuid, text) to authenticated;
grant execute on function public.mobile_clock_out(uuid, float, float, float, text, uuid, text, text, boolean, text, uuid, text) to authenticated;
grant execute on function public.mobile_attendance_summary(date, date, uuid, text) to authenticated;
grant execute on function public.mobile_list_authorized_devices(text, uuid, text, text, text, text) to authenticated;
grant execute on function public.mobile_get_my_supervisor(uuid) to authenticated;