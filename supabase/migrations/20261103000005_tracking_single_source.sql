-- ============================================================================
-- SINGLE SOURCE OF TRUTH FOR EMPLOYEE TRACKING
-- Run in Supabase SQL Editor AFTER 20261103000004_realtime_branch_geofences.sql.
-- Idempotent, additive, transaction-wrapped. NOTHING IS DELETED OR RENAMED.
--
-- WHAT THIS DOES
--   1. employee_location_events becomes the ONLY ingest table. Every writer
--      (Dart heartbeat, native foreground service, sync_offline_location_batch,
--      batch_sync_employee_locations, record_employee_location) lands here.
--   2. A BEFORE INSERT trigger on the employee_location_history TABLE copies
--      any row written there straight into events (ON CONFLICT DO NOTHING) and
--      returns NULL, so the old table can never accumulate rows again. The
--      table itself is KEPT (older apps reference it) but locked down.
--   3. classify_geofence(lat,lng,accuracy) - the single read-time resolver.
--      Reuses resolve_employee_location's candidate set, active filters and
--      geo_distance(); never invents a second formula.
--   4. BEFORE INSERT trigger on employee_location_events fills ONLY the NULL
--      classification columns from classify_geofence, so offline-batch,
--      heartbeat and native writers are consistent without a backfill UPDATE.
--   5. employee_live_positions_v2() - one row per in-scope employee, with
--      freshness, geofence status and confidence computed at READ time.
--   6. employee_location_history() is CREATE OR REPLACEd with the SAME
--      signature and SAME return columns, now reading events.
--   7. sync_offline_location_batch(jsonb) is REPOINTED to write events with
--      sync_status='backfilled_offline', is_offline_record=true.
--   8. batch_sync_employee_locations(jsonb) is REPOINTED to call the same path.
--   9. An AFTER INSERT trigger on events broadcasts {employee_id, recorded_at}
--      on a private realtime channel so the web can subscribe without opening
--      table access.
--   10. tracking_health_check() - read-only admin diagnostic.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. ADDITIVE COLUMNS ON THE EVENTS TABLE
-- IF NOT EXISTS so older app versions that already ran earlier migrations are
-- unaffected; existing rows keep their values.
-- ---------------------------------------------------------------------------
alter table public.employee_location_events
  add column if not exists altitude          numeric(10, 2),
  add column if not exists speed             numeric(10, 2),
  add column if not exists heading           numeric(10, 2),
  add column if not exists is_offline_record boolean not null default false,
  add column if not exists sync_status      text default 'synced',
  add column if not exists battery_level    numeric(5, 2),
  add column if not exists network_status    text;

-- geom (generated, additive) ONLY if the geofence math or the map needs it.
-- It does not: resolve_employee_location / classify_geofence use geo_distance
-- on the stored coordinates, and the web map reads lat/lng directly. Adding it
-- would duplicate the point for no reader benefit, so it is deliberately NOT
-- added here. The history TABLE keeps its own geom for older consumers.

-- ---------------------------------------------------------------------------
-- 2. THE SINGLE READ-TIME CLASSIFIER
-- Reuses EXACTLY the candidate set, active filters and distance formula that
-- resolve_employee_location() uses (branches with geofence_active + active
-- attendance_geofences, geo_distance haversine, greatest(1, radius, 150)).
-- No second formula, no postgis dependency, no new table.
-- ---------------------------------------------------------------------------
create or replace function public.classify_geofence(
  p_lat float,
  p_lng float,
  p_accuracy float default null
) returns table (
  geofence_id uuid,
  branch_id uuid,
  registered_name text,
  inside boolean,
  distance_to_center_m float,
  radius_m numeric,
  nearest_registered_name text,
  nearest_distance float,
  nearest_radius numeric,
  confidence text
)
language plpgsql
stable
set search_path = public
as $$
declare
  v_settings record;
  v_branch_id uuid;
  v_geofence_id uuid;
  v_name text;
  v_lat float;
  v_lng float;
  v_radius numeric;
  v_distance float;
  v_best_distance float;
  v_best_branch_id uuid;
  v_best_geofence_id uuid;
  v_best_name text;
  v_best_radius numeric;
  v_nearest_name text;
  v_nearest_distance float;
  v_nearest_radius numeric;
  v_has_location boolean := false;
  v_conf text;
begin
  if p_lat is null or p_lng is null
     or p_lat <> p_lat or p_lng <> p_lng
     or p_lat < -90 or p_lat > 90 or p_lng < -180 or p_lng > 180 then
    return query select null::uuid, null::uuid, null::text, false,
      null::float, null::numeric, null::text, null::float, null::numeric, 'low';
    return;
  end if;

  select * into v_settings from public.hr_platform_settings where id = 1 limit 1;

  for v_branch_id, v_geofence_id, v_name, v_lat, v_lng, v_radius in
    select b.id as branch_id,
           null::uuid as geofence_id,
           b.branch_name as location_name,
           b.latitude::float as latitude,
           b.longitude::float as longitude,
           greatest(1, coalesce(b.geofence_radius, v_settings.default_geofence_radius, 150))::numeric as radius
      from public.branches b
     where coalesce(b.geofence_active, false)
       and b.latitude is not null
       and b.longitude is not null
    union all
    select gb.id as branch_id,
           g.id as geofence_id,
           coalesce(gb.branch_name, nullif(g.location_name, ''), g.name) as location_name,
           g.latitude::float as latitude,
           g.longitude::float as longitude,
           greatest(1, coalesce(g.radius_meters, v_settings.default_geofence_radius, 150))::numeric as radius
      from public.attendance_geofences g
      left join public.branches gb on gb.id::text = g.branch_id
     where coalesce(g.active, false)
       and g.latitude is not null
       and g.longitude is not null
  loop
    v_has_location := true;
    v_distance := public.geo_distance(p_lat, p_lng, v_lat, v_lng);

    if v_nearest_distance is null or v_distance < v_nearest_distance then
      v_nearest_distance := v_distance;
      v_nearest_name := v_name;
      v_nearest_radius := v_radius;
    end if;
    if v_distance <= v_radius
       and (v_best_distance is null or v_distance < v_best_distance) then
      v_best_distance := v_distance;
      v_best_branch_id := v_branch_id;
      v_best_geofence_id := v_geofence_id;
      v_best_name := v_name;
      v_best_radius := v_radius;
    end if;
  end loop;

  v_conf := case
             when p_accuracy is null then 'high'
             when v_best_radius is not null and p_accuracy <= v_best_radius then 'high'
             when v_nearest_radius is not null and p_accuracy <= v_nearest_radius then 'medium'
             else 'low'
           end;

  return query
  select v_best_geofence_id, v_best_branch_id, v_best_name,
         v_best_distance is not null,
         v_best_distance, v_best_radius,
         v_nearest_name, v_nearest_distance, v_nearest_radius, v_conf;
end;
$$;

revoke all on function public.classify_geofence(float, float, float) from public;
grant execute on function public.classify_geofence(float, float, float) to authenticated;
comment on function public.classify_geofence(float, float, float) is
  'Single read-time geofence classifier. Same candidate set, active filters and geo_distance() haversine as resolve_employee_location(). Returns the best-matching registered location (inside=true when distance <= radius), the nearest registered location regardless, and confidence (high/medium/low) based on the reported accuracy against the fence radius. Never raises.';

revoke all on function public.classify_geofence(float, float, float) from public;
grant execute on function public.classify_geofence(float, float, float) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. BEFORE INSERT TRIGGER ON employee_location_events
-- Fills ONLY the NULL classification columns from classify_geofence. Never
-- overwrites a non-null value, never raises an error that blocks the insert.
-- This makes offline-batch, heartbeat and native writers consistent.
-- ---------------------------------------------------------------------------
create or replace function public.trg_employee_location_events_classify()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_cls record;
begin
  -- Only classify when at least one of the derived columns is still NULL.
  if new.inside_geofence is null
     or new.detected_geofence_id is null
     or new.detected_branch_id is null
     or new.location_label is null
     or new.distance_meters is null
     or new.nearest_location_name is null then
    begin
      select * into v_cls
        from public.classify_geofence(new.latitude::float, new.longitude::float, new.accuracy::float)
        limit 1;

      if found then
        -- Never overwrite a value the caller already supplied.
        new.detected_geofence_id := coalesce(new.detected_geofence_id, v_cls.geofence_id);
        new.detected_branch_id   := coalesce(new.detected_branch_id,   v_cls.branch_id);
        new.distance_meters      := coalesce(new.distance_meters,      v_cls.distance_to_center_m);
        new.nearest_location_name := coalesce(new.nearest_location_name, v_cls.nearest_registered_name);
        new.inside_geofence      := coalesce(new.inside_geofence, v_cls.inside);
        -- Registered name exactly as stored. Inside: the fence name. Outside:
        -- the honest "Outside <nearest> (<distance> m away)" wording, so the
        -- legacy "HEAD OFFICE" casing is never re-introduced by this trigger.
        if new.location_label is null then
          new.location_label := case
            when v_cls.inside then coalesce(v_cls.registered_name, 'Registered location')
            when v_cls.nearest_registered_name is null then 'Outside registered locations'
            when v_cls.nearest_distance >= 1000
              then 'Outside ' || v_cls.nearest_registered_name || ' ('
                   || trim(trailing '.' from trim(trailing '0' from round(v_cls.nearest_distance / 1000.0)::text)) || ' km away)'
            else 'Outside ' || v_cls.nearest_registered_name || ' ('
                 || round(v_cls.nearest_distance)::text || ' m away)'
          end;
        end if;
      end if;
    exception when others then
      -- A classification failure must NEVER block the insert. The row lands
      -- unclassified and is reported by tracking_health_check().
      null;
    end;
  end if;

  -- Defensive: inside_geofence is NOT NULL, so guarantee it is set.
  new.inside_geofence := coalesce(new.inside_geofence, false);

  return new;
end;
$$;

drop trigger if exists trg_employee_location_events_classify on public.employee_location_events;
create trigger trg_employee_location_events_classify
  before insert on public.employee_location_events
  for each row execute function public.trg_employee_location_events_classify();

-- ---------------------------------------------------------------------------
-- 4. REPOINT record_employee_location() TO WRITE events
-- Same signature, same access rules, same dedupe key. Now also fills the
-- additive telemetry columns and tags offline uploads.
-- ---------------------------------------------------------------------------
create or replace function public.record_employee_location(
  p_lat float,
  p_lng float,
  p_accuracy float default null,
  p_recorded_at timestamptz default null,
  p_source text default 'mobile',
  p_source_detail text default null,
  p_device_id text default null,
  p_device_fingerprint text default null,
  p_attendance_record_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_employee record;
  v_resolved jsonb;
  v_id uuid;
  v_recorded timestamptz := coalesce(p_recorded_at, now());
  v_inserted boolean := false;
  v_inside boolean;
  v_offline boolean := p_recorded_at is not null
                       and p_recorded_at < now() - interval '2 minutes';
begin
  select e.* into v_employee
    from public.employees e
    join public.profiles p on p.id = e.user_id
   where p.id = auth.uid()
   limit 1;

  if not found then
    raise exception 'NO_EMPLOYEE_PROFILE:No employee record is linked to this account.';
  end if;

  if v_recorded > now() + interval '5 minutes' then
    v_recorded := now();
  end if;

  v_resolved := public.resolve_employee_location(p_lat, p_lng, 'track', null);
  v_inside := coalesce((v_resolved ->> 'inside')::boolean, false);

  insert into public.employee_location_events (
    employee_id, latitude, longitude, accuracy, recorded_at, uploaded_at,
    source, source_detail, device_id, device_fingerprint,
    attendance_record_id, detected_geofence_id, detected_branch_id,
    location_label, inside_geofence, distance_meters,
    nearest_location_name, nearest_distance, nearest_radius,
    altitude, speed, heading, is_offline_record, sync_status,
    battery_level, network_status
  ) values (
    v_employee.id, p_lat, p_lng, p_accuracy, v_recorded, now(),
    lower(coalesce(nullif(p_source, ''), 'mobile')),
    p_source_detail,
    p_device_id,
    p_device_fingerprint,
    p_attendance_record_id,
    nullif(v_resolved ->> 'geofence_id', '')::uuid,
    nullif(v_resolved ->> 'branch_id', '')::uuid,
    case when v_inside
         then v_resolved ->> 'human_label'
         else coalesce(nullif(v_resolved ->> 'outside_label', ''), v_resolved ->> 'human_label')
    end,
    v_inside,
    nullif(v_resolved ->> 'distance_meters', '')::numeric,
    nullif(v_resolved ->> 'nearest_location_name', ''),
    nullif(v_resolved ->> 'nearest_distance', '')::numeric,
    nullif(v_resolved ->> 'nearest_radius', '')::numeric,
    null, null, null, v_offline,
    case when v_offline then 'backfilled_offline' else 'synced' end,
    null, null
  )
  on conflict (employee_id, recorded_at, latitude, longitude) do nothing;

  v_inserted := found;
  if v_inserted then
    select id into v_id
      from public.employee_location_events
     where employee_id = v_employee.id
       and recorded_at = v_recorded
       and latitude = p_lat
       and longitude = p_lng
     limit 1;
  end if;

  return jsonb_build_object(
    'ok', true,
    'stored', v_inserted,
    'id', v_id,
    'recorded_at', v_recorded,
    'uploaded_at', now(),
    'offline_sync', v_offline,
    'location', v_resolved);
end;
$$;

revoke all on function public.record_employee_location(float, float, float, timestamptz, text, text, text, text, uuid) from public;
grant execute on function public.record_employee_location(float, float, float, timestamptz, text, text, text, text, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. REPOINT sync_offline_location_batch(jsonb) -> employee_location_events
-- SECURITY DEFINER, SET search_path=public, identity from auth.uid()
-- (ignores any employee_id in the payload). Max 500 rows. Validates lat/lng
-- and recorded_at (not more than 5 min in the future). INSERT ... ON CONFLICT
-- on the 4-column key DO NOTHING. sync_status='backfilled_offline',
-- is_offline_record=true, source='mobile_offline_queue',
-- source_detail='background_sync', uploaded_at=now().
-- ---------------------------------------------------------------------------
create or replace function public.sync_offline_location_batch(
  p_locations jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_employee record;
  v_location jsonb;
  v_total     int := 0;
  v_inserted  int := 0;
  v_skipped   int := 0;
  v_invalid   int := 0;
  v_count     int := 0;
  v_lat numeric; v_lng numeric; v_rec timestamptz;
begin
  select e.* into v_employee
    from public.employees e
    join public.profiles p on p.id = e.user_id
   where p.id = auth.uid()
   limit 1;

  if not found then
    return jsonb_build_object('status', 'rejected', 'message', 'NO_EMPLOYEE_PROFILE');
  end if;

  if p_locations is null or jsonb_typeof(p_locations) <> 'array' or jsonb_array_length(p_locations) = 0 then
    return jsonb_build_object('status', 'error', 'message', 'Payload must be a non-empty array');
  end if;

  v_total := jsonb_array_length(p_locations);
  if v_total > 500 then
    return jsonb_build_object('status', 'error', 'message', 'Batch exceeds 500 items (got ' || v_total || ')');
  end if;

  for v_location in select * from jsonb_array_elements(p_locations) loop
    v_count := v_count + 1;

    if jsonb_typeof(v_location) <> 'object' then
      v_invalid := v_invalid + 1;
      continue;
    end if;

    v_lat := (v_location ->> 'latitude')::numeric;
    v_lng := (v_location ->> 'longitude')::numeric;

    if v_lat is null or v_lng is null
       or v_lat < -90 or v_lat > 90
       or v_lng < -180 or v_lng > 180 then
      v_invalid := v_invalid + 1;
      continue;
    end if;

    v_rec := coalesce(
      (v_location ->> 'recorded_at')::timestamptz,
      (v_location ->> 'timestamp')::timestamptz,
      null
    );
    if v_rec is null or v_rec > now() + interval '5 minutes' then
      v_invalid := v_invalid + 1;
      continue;
    end if;

    -- The BEFORE INSERT trigger classifies the row; we only supply the
    -- telemetry and the offline flags here.
    insert into public.employee_location_events (
      employee_id, latitude, longitude, accuracy, recorded_at, uploaded_at,
      source, source_detail, device_id, device_fingerprint,
      is_offline_record, sync_status, battery_level, network_status
    ) values (
      v_employee.id, v_lat, v_lng,
      coalesce((v_location ->> 'accuracy')::numeric, 0::numeric),
      v_rec, now(),
      coalesce(v_location ->> 'source', 'mobile_offline_queue'),
      coalesce(v_location ->> 'source_detail', 'background_sync'),
      null, null,
      true, 'backfilled_offline',
      nullif(v_location ->> 'battery_level', '')::numeric,
      nullif(v_location ->> 'network_status', '')
    )
    on conflict (employee_id, recorded_at, latitude, longitude) do nothing;

    if found then
      v_inserted := v_inserted + 1;
    else
      v_skipped := v_skipped + 1;
    end if;
  end loop;

  return jsonb_build_object(
    'status',         'synced',
    'records_synced', v_inserted,
    'records_skipped', v_skipped,
    'records_invalid', v_invalid
  );
end;
$$;

revoke all on function public.sync_offline_location_batch(jsonb) from public, anon;
grant execute on function public.sync_offline_location_batch(jsonb) to service_role, authenticated;

comment on function public.sync_offline_location_batch(jsonb) is
  'Batch sync for the offline queue. Derives employee from auth.uid(); ignores any payload employee_id. Writes employee_location_events (the single source of truth), dedupes on (employee_id, recorded_at, latitude, longitude), tags backfilled_offline. Returns {status, records_synced, records_skipped, records_invalid}.';

-- ---------------------------------------------------------------------------
-- 6. REPOINT batch_sync_employee_locations(jsonb) -> events
-- Same signature. Older apps that call this still land in the single table.
-- ---------------------------------------------------------------------------
create or replace function public.batch_sync_employee_locations(
  p_locations jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_employee_id uuid;
  v_item jsonb;
  v_result jsonb := '[]'::jsonb;
  v_id uuid;
  v_offline boolean := true;
begin
  select id into v_employee_id
    from public.employees
   where user_id = auth.uid()
     and coalesce(is_archived, false) = false
   order by created_at desc
   limit 1;

  if v_employee_id is null then
    raise exception 'NO_EMPLOYEE_PROFILE:No active employee profile found for authenticated user';
  end if;

  for v_item in select * from jsonb_array_elements(p_locations) loop
    insert into public.employee_location_events (
      employee_id, latitude, longitude, accuracy, recorded_at, uploaded_at,
      source, source_detail, is_offline_record, sync_status,
      battery_level, network_status
    )
    values (
      v_employee_id,
      (v_item->>'latitude')::numeric,
      (v_item->>'longitude')::numeric,
      (v_item->>'accuracy')::numeric,
      coalesce((v_item->>'recorded_at')::timestamptz, (v_item->>'timestamp')::timestamptz, now()),
      now(),
      coalesce(v_item->>'source', 'mobile'),
      coalesce(v_item->>'source_detail', 'batch_sync'),
      v_offline, 'backfilled_offline',
      (v_item->>'battery_level')::integer,
      v_item->>'network_status'
    )
    on conflict (employee_id, recorded_at, latitude, longitude) do nothing
    returning id into v_id;

    if v_id is not null then
      v_result := v_result || jsonb_build_object('id', v_id);
      v_id := null;
    else
      select id into v_id
        from public.employee_location_events
       where employee_id = v_employee_id
         and recorded_at = coalesce((v_item->>'recorded_at')::timestamptz, (v_item->>'timestamp')::timestamptz, now())
         and latitude::numeric(10,6) = (v_item->>'latitude')::numeric(10,6)
         and longitude::numeric(10,6) = (v_item->>'longitude')::numeric(10,6)
       limit 1;
      if v_id is not null then
        v_result := v_result || jsonb_build_object('id', v_id);
        v_id := null;
      end if;
    end if;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'synced_count', jsonb_array_length(v_result),
    'synced_ids', v_result
  );
end;
$$;

revoke all on function public.batch_sync_employee_locations(jsonb) from public, anon;
grant execute on function public.batch_sync_employee_locations(jsonb) to authenticated;

comment on function public.batch_sync_employee_locations(jsonb) is
  'Batch sync (older app path). Writes employee_location_events, dedupes on (employee_id, recorded_at, latitude, longitude). Returns {ok, synced_count, synced_ids}.';

-- ---------------------------------------------------------------------------
-- 7. SAFETY NET: BEFORE INSERT TRIGGER ON employee_location_history (TABLE)
-- Any row written to the old table is copied into employee_location_events
-- (same columns, ON CONFLICT on the 4-column key DO NOTHING) and the insert
-- into the old table is suppressed (RETURN NULL). Never raises. After this,
-- the old table can never accumulate rows again, but it still EXISTS and is
-- still readable by older apps through the SECURITY DEFINER functions.
-- ---------------------------------------------------------------------------
create or replace function public.trg_history_to_events()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_id uuid;
begin
  begin
    insert into public.employee_location_events (
      employee_id, latitude, longitude, accuracy, recorded_at, uploaded_at,
      source, source_detail, is_offline_record, sync_status,
      battery_level, network_status, altitude, speed, heading
    ) values (
      new.employee_id, new.latitude, new.longitude, new.accuracy,
      coalesce(new.recorded_at, now()), now(),
      coalesce(new.source, 'mobile'), new.source_detail,
      coalesce(new.is_offline_record, false), coalesce(new.sync_status, 'SYNCED'),
      new.battery_level, new.network_status,
      new.altitude, new.speed, new.heading
    )
    on conflict (employee_id, recorded_at, latitude, longitude) do nothing
    returning id into v_id;
  exception when others then
    -- Never let a misclassification or a constraint problem block a writer
    -- that still thinks it is writing the old table.
    null;
  end;

  -- Suppress the row in the old table. The old table stays empty; the row lives
  -- in events (or was already there and is deduped).
  return null;
end;
$$;

drop trigger if exists trg_history_to_events on public.employee_location_history;
create trigger trg_history_to_events
  before insert on public.employee_location_history
  for each row execute function public.trg_history_to_events();

-- ---------------------------------------------------------------------------
-- 8. employee_live_positions_v2()
-- NEW function (v2 name, because a changed return type cannot use
-- CREATE OR REPLACE). One row per employee in the caller's scope, using the
-- SAME Full/Shared tracking access model (employee_tracking_access()) and the
-- SAME security mode as list_tracked_employees().
--
-- Freshness thresholds live in ONE place here (LIVE 6 min, DELAYED 30 min,
-- STALE > 30 min). Geofence status is computed NOW via classify_geofence for
-- the latest fix. The exact emulator coordinate is excluded; no other
-- suspect-row rule is applied (per approval).
-- ---------------------------------------------------------------------------
drop function if exists public.employee_live_positions_v2(integer, text, uuid);
create or replace function public.employee_live_positions_v2(
  p_within_minutes integer default 60,
  p_department text default null,
  p_branch_id uuid default null
)
returns table (
  employee_id uuid,
  full_name text,
  employee_number text,
  "position" text,
  department text,
  branch_id uuid,
  branch_name text,
  latitude numeric,
  longitude numeric,
  accuracy numeric,
  recorded_at timestamptz,
  uploaded_at timestamptz,
  age_seconds integer,
  server_now timestamptz,
  freshness text,
  geofence_status text,
  geofence_name text,
  nearest_name text,
  distance_to_center_m float,
  meters_outside numeric,
  confidence text,
  location_label text,
  sync_status text,
  tracking_unavailable_reason text,
  has_fix boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_access jsonb;
  v_emulator_lat numeric := 37.4219983;
  v_emulator_lng numeric := -122.0840000;
begin
  v_access := public.employee_tracking_access();
  if not coalesce((v_access ->> 'can_view')::boolean, false) then
    raise exception 'TRACKING_FORBIDDEN:%', coalesce(v_access ->> 'reason', 'Not authorized.');
  end if;

  return query
  select
    e.id,
    e.full_name,
    e.employee_number,
    e.position,
    e.department,
    e.branch_id,
    b.branch_name,
    le.latitude,
    le.longitude,
    le.accuracy,
    le.recorded_at,
    le.uploaded_at,
    case when le.recorded_at is null then null
         else extract(epoch from (now() - le.recorded_at))::int end as age_seconds,
    now() as server_now,
    case
      when le.recorded_at is null then 'no_data'
      when le.recorded_at > now() - interval '6 minutes' then 'live'
      when le.recorded_at > now() - interval '30 minutes' then 'delayed'
      else 'stale'
    end as freshness,
    coalesce(cls.inside::text, 'outside') as geofence_status,
    cls.registered_name as geofence_name,
    cls.nearest_registered_name as nearest_name,
    cls.distance_to_center_m,
    case when cls.inside then null
         else round(cls.nearest_distance)::numeric end as meters_outside,
    cls.confidence,
    case
      when cls.inside then coalesce(cls.registered_name, 'Registered location')
      when cls.nearest_registered_name is null then 'Outside registered locations'
      when cls.nearest_distance >= 1000
        then 'Outside ' || cls.nearest_registered_name || ' ('
             || trim(trailing '.' from trim(trailing '0' from round(cls.nearest_distance / 1000.0)::text)) || ' km away)'
      else 'Outside ' || cls.nearest_registered_name || ' ('
           || round(cls.nearest_distance)::text || ' m away)'
    end as location_label,
    le.sync_status,
    (select tu.reason from public.employee_tracking_unavailable tu
     where tu.employee_id = e.id
       and (tu.occurred_at > le.recorded_at or le.recorded_at is null)
     order by tu.occurred_at desc limit 1) as tracking_unavailable_reason,
    le.recorded_at is not null as has_fix
  from public.employees e
  left join lateral (
    select l.id, l.employee_id, l.latitude, l.longitude, l.accuracy,
           l.recorded_at, l.uploaded_at, l.sync_status
      from public.employee_location_events l
     where l.employee_id = e.id
       and not (l.latitude = v_emulator_lat and l.longitude = v_emulator_lng)
     order by l.recorded_at desc nulls last, l.id desc
     limit 1
  ) le on true
  left join public.branches b on b.id = e.branch_id
  left join lateral (
    select * from public.classify_geofence(
      le.latitude::float, le.longitude::float, le.accuracy::float) cls
    limit 1
  ) cls on true
  where (p_department is null or lower(e.department) = lower(p_department))
    and (p_branch_id is null or e.branch_id = p_branch_id);
end;
$$;

revoke all on function public.employee_live_positions_v2(integer, text, uuid) from public;
grant execute on function public.employee_live_positions_v2(integer, text, uuid) to authenticated;

comment on function public.employee_live_positions_v2(integer, text, uuid) is
  'Live positions v2. One row per in-scope employee (employee_tracking_access gate), latest fix by MAX(recorded_at). Freshness (live<=6m, delayed<=30m, stale>30m, no_data) computed against the SERVER clock. Geofence status computed NOW via classify_geofence. Excludes the exact emulator coordinate only. Returns {employee_id, full_name, ..., has_fix}.';

-- ---------------------------------------------------------------------------
-- 9. SERVER-CONTROLLED TRACKING POLICY + UNAVAILABLE EVENTS
-- Cached locally so the policy applies offline; changeable server-side
-- without a release. Default mode all_day, interval 120 s.
-- ---------------------------------------------------------------------------
create table if not exists public.tracking_policy (
  id integer primary key default 1 check (id = 1),
  mode text not null default 'all_day'
    check (mode in ('all_day','working_hours','clocked_in')),
  window_start time,
  window_end time,
  days_of_week int[] default array[0,1,2,3,4,5,6],
  interval_seconds integer not null default 120 check (interval_seconds between 30 and 120),
  enabled boolean not null default true,
  policy_version integer not null default 1,
  updated_at timestamptz not null default now()
);

insert into public.tracking_policy (id, mode, interval_seconds, enabled, policy_version)
values (1, 'all_day', 120, true, 1)
on conflict (id) do nothing;

alter table public.tracking_policy enable row level security;

-- Readable by everyone authenticated (it is not secret); only service_role
-- writes it.
do $$
begin
  if not exists (select 1 from pg_policy where polname = 'tracking_policy_read') then
    execute 'create policy tracking_policy_read on public.tracking_policy for select to authenticated using (true)';
  end if;
end;
$$;

-- A tracking_unavailable event records WHY a device went silent (permission
-- revoked, location off, etc.) so the web can explain a silent employee.
create table if not exists public.employee_tracking_unavailable (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id) on delete cascade,
  reason text not null,
  occurred_at timestamptz not null default now(),
  detail text
);

create index if not exists idx_tracking_unavailable_emp on public.employee_tracking_unavailable(employee_id, occurred_at desc);

alter table public.employee_tracking_unavailable enable row level security;

-- Employees may record their own unavailable events; readers reach rows only
-- through the v2 function (which is SECURITY DEFINER).
do $$
begin
  if not exists (select 1 from pg_policy where polname = 'tracking_unavailable_self_insert') then
    execute 'create policy tracking_unavailable_self_insert on public.employee_tracking_unavailable for insert to authenticated with check (employee_id = (select e.id from public.employees e join public.profiles p on p.id = e.user_id where p.id = auth.uid() limit 1))';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. employee_location_history(uuid,date,time,time,text) - CREATE OR REPLACE
-- SAME signature, SAME return columns. Now reads employee_location_events
-- ordered strictly by recorded_at ASC, including backfilled rows. The Leaflet
-- map and the movement drawer consume this unchanged.
-- ---------------------------------------------------------------------------
create or replace function public.employee_location_history(
  p_employee_id uuid,
  p_date date,
  p_from_time time default null,
  p_to_time time default null,
  p_inside_only text default 'all'
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_access jsonb;
  v_tz text := public.att_app_timezone();
  v_points jsonb;
  v_emp record;
begin
  v_access := public.employee_tracking_access();
  if not coalesce((v_access ->> 'can_view')::boolean, false) then
    raise exception 'TRACKING_FORBIDDEN:%', coalesce(v_access ->> 'reason', 'Not authorized.');
  end if;

  select * into v_emp from public.employees where id = p_employee_id;
  if not found then
    raise exception 'Employee not found.';
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.recorded_at), '[]') into v_points
    from (
      select le.id, le.latitude, le.longitude, le.accuracy, le.recorded_at,
             le.uploaded_at, le.source, le.device_id, le.location_label,
             le.inside_geofence, le.distance_meters, le.detected_branch_id,
             le.nearest_location_name, le.nearest_distance, le.nearest_radius,
             le.altitude, le.speed, le.heading, le.is_offline_record,
             le.sync_status, le.battery_level, le.network_status,
             b.branch_name,
             -- Read-time classification, using the registered name exactly as
             -- stored. The stored legacy label text is NOT re-shown.
             cls.registered_name as classified_name,
             cls.inside as classified_inside,
             cls.nearest_registered_name as classified_nearest_name,
             cls.distance_to_center_m as classified_distance,
             cls.confidence as classified_confidence
        from public.employee_location_events le
        left join public.branches b on b.id = le.detected_branch_id
        left join lateral (
          select * from public.classify_geofence(
            le.latitude::float, le.longitude::float, le.accuracy::float) cls
          limit 1
        ) cls on true
       where le.employee_id = p_employee_id
         and (le.recorded_at at time zone v_tz)::date = p_date
         and (p_from_time is null or (le.recorded_at at time zone v_tz)::time >= p_from_time)
         and (p_to_time   is null or (le.recorded_at at time zone v_tz)::time <= p_to_time)
         and (p_inside_only = 'all'
              or (p_inside_only = 'inside' and le.inside_geofence)
              or (p_inside_only = 'outside' and not le.inside_geofence))
    ) x;

  insert into public.audit_logs (action, entity_type, entity_id, user_name, details, severity)
  values ('EMPLOYEE_LOCATION_HISTORY_QUERIED', 'Employee', p_employee_id::text,
          (select full_name from public.profiles where id = auth.uid()),
          jsonb_build_object('date', p_date, 'points',
                             coalesce(jsonb_array_length(v_points), 0), 'success', true)::text,
          'info');

  return jsonb_build_object(
    'ok', true,
    'employee', jsonb_build_object(
      'id', v_emp.id, 'full_name', v_emp.full_name,
      'employee_number', v_emp.employee_number, 'position', v_emp.position,
      'department', v_emp.department, 'branch_id', v_emp.branch_id),
    'date', p_date,
    'from_time', p_from_time,
    'to_time', p_to_time,
    'points', v_points,
    'point_count', coalesce(jsonb_array_length(v_points), 0),
    'timezone', v_tz);
end;
$$;

revoke all on function public.employee_location_history(uuid, date, time, time, text) from public;
grant execute on function public.employee_location_history(uuid, date, time, time, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 11. NEW employee_movement_trail_v2(uuid,date,time,time,text)
-- Same signature as employee_location_history but adds the fields the map and
-- the drawer need (accuracy, uploaded_at, sync_status, nearest name, distance,
-- confidence) and computes place names at READ time through classify_geofence.
-- ---------------------------------------------------------------------------
create or replace function public.employee_movement_trail_v2(
  p_employee_id uuid,
  p_date date,
  p_from_time time default null,
  p_to_time time default null,
  p_inside_only text default 'all'
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_access jsonb;
  v_tz text := public.att_app_timezone();
  v_points jsonb;
  v_emp record;
begin
  v_access := public.employee_tracking_access();
  if not coalesce((v_access ->> 'can_view')::boolean, false) then
    raise exception 'TRACKING_FORBIDDEN:%', coalesce(v_access ->> 'reason', 'Not authorized.');
  end if;

  select * into v_emp from public.employees where id = p_employee_id;
  if not found then
    raise exception 'Employee not found.';
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.recorded_at), '[]') into v_points
    from (
      select le.id, le.latitude, le.longitude, le.accuracy, le.recorded_at,
             le.uploaded_at, le.source, le.source_detail, le.location_label,
             le.inside_geofence, le.distance_meters, le.detected_branch_id,
             le.nearest_location_name, le.nearest_distance, le.nearest_radius,
             le.altitude, le.speed, le.heading, le.is_offline_record,
             le.sync_status, le.battery_level, le.network_status,
             b.branch_name,
             cls.registered_name as classified_name,
             cls.inside as classified_inside,
             cls.nearest_registered_name as classified_nearest_name,
             cls.distance_to_center_m as classified_distance,
             cls.nearest_distance as classified_nearest_distance,
             cls.confidence as classified_confidence
        from public.employee_location_events le
        left join public.branches b on b.id = le.detected_branch_id
        left join lateral (
          select * from public.classify_geofence(
            le.latitude::float, le.longitude::float, le.accuracy::float) cls
          limit 1
        ) cls on true
       where le.employee_id = p_employee_id
         and (le.recorded_at at time zone v_tz)::date = p_date
         and (p_from_time is null or (le.recorded_at at time zone v_tz)::time >= p_from_time)
         and (p_to_time   is null or (le.recorded_at at time zone v_tz)::time <= p_to_time)
         and (p_inside_only = 'all'
              or (p_inside_only = 'inside' and le.inside_geofence)
              or (p_inside_only = 'outside' and not le.inside_geofence))
    ) x;

  return jsonb_build_object(
    'ok', true,
    'employee', jsonb_build_object(
      'id', v_emp.id, 'full_name', v_emp.full_name,
      'employee_number', v_emp.employee_number, 'position', v_emp.position,
      'department', v_emp.department, 'branch_id', v_emp.branch_id),
    'date', p_date,
    'from_time', p_from_time,
    'to_time', p_to_time,
    'points', v_points,
    'point_count', coalesce(jsonb_array_length(v_points), 0),
    'timezone', v_tz);
end;
$$;

revoke all on function public.employee_movement_trail_v2(uuid, date, time, time, text) from public;
grant execute on function public.employee_movement_trail_v2(uuid, date, time, time, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 12. REALTIME: private broadcast on INSERT, coordinates NEVER included
-- The trigger wraps realtime.send in its own exception handler so it can never
-- fail or slow an insert. The payload carries ONLY {employee_id, recorded_at}.
-- The web authorizes the private channel with an RLS policy on
-- realtime.messages that allows only users who hold Full/Shared tracking
-- access (employee_tracking_access()).
-- ---------------------------------------------------------------------------
create or replace function public.trg_employee_location_events_realtime()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  begin
    perform realtime.send(
      jsonb_build_object(
        'employee_id', new.employee_id,
        'recorded_at', new.recorded_at
      ),
      'message', 'tracking:live', true);
  exception when others then
    -- Broadcast is best-effort: a realtime failure must never block ingest.
    null;
  end;
  return new;
end;
$$;

drop trigger if exists trg_employee_location_events_realtime on public.employee_location_events;
create trigger trg_employee_location_events_realtime
  after insert on public.employee_location_events
  for each row execute function public.trg_employee_location_events_realtime();

-- Authorize the private broadcast channel. Only callers who hold tracking
-- access may subscribe; this does NOT grant table SELECT.
do $$
declare
  v_sql text;
begin
  if not exists (select 1 from pg_policy where polname = 'tracking_live_subscribe') then
    v_sql := format(
      'create policy tracking_live_subscribe on realtime.messages for select to authenticated using (coalesce((public.employee_tracking_access() ->> %L)::boolean, false))',
      'can_view'
    );
    execute v_sql;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 13. READ-ONLY HEALTH CHECK (admin / Full-tracking access only)
-- ---------------------------------------------------------------------------
create or replace function public.tracking_health_check()
returns table (
  old_history_rows bigint,
  events_24h bigint,
  backfilled_offline_24h bigint,
  employees_with_events_24h bigint,
  unclassified_24h bigint,
  newest_recorded_at timestamptz,
  newest_uploaded_at timestamptz,
  per_employee jsonb
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_access jsonb;
begin
  v_access := public.employee_tracking_access();
  if not coalesce((v_access ->> 'can_view')::boolean, false) then
    raise exception 'TRACKING_FORBIDDEN:%', coalesce(v_access ->> 'reason', 'Not authorized.');
  end if;

  return query
  select
    (select count(*) from public.employee_location_history) as old_history_rows,
    (select count(*) from public.employee_location_events where recorded_at > now() - interval '24 hours') as events_24h,
    (select count(*) from public.employee_location_events
       where sync_status = 'backfilled_offline' and recorded_at > now() - interval '24 hours') as backfilled_offline_24h,
    (select count(distinct employee_id) from public.employee_location_events
       where recorded_at > now() - interval '24 hours') as employees_with_events_24h,
    (select count(*) from public.employee_location_events
       where recorded_at > now() - interval '24 hours'
         and inside_geofence is null) as unclassified_24h,
    (select max(recorded_at) from public.employee_location_events) as newest_recorded_at,
    (select max(uploaded_at) from public.employee_location_events) as newest_uploaded_at,
    (select jsonb_agg(jsonb_build_object(
        'employee_id', e.id, 'full_name', e.full_name,
        'fixes_24h', coalesce(t.fixes, 0),
        'newest_recorded_at', t.newest_recorded_at,
        'newest_uploaded_at', t.newest_uploaded_at,
        'unclassified_24h', coalesce(t.unclassified, 0)
      ) order by coalesce(t.fixes, 0) desc)
       from public.employees e
       left join lateral (
         select count(*) as fixes,
                max(le.recorded_at) as newest_recorded_at,
                max(le.uploaded_at) as newest_uploaded_at,
                count(*) filter (where le.inside_geofence is null) as unclassified
           from public.employee_location_events le
          where le.employee_id = e.id
            and le.recorded_at > now() - interval '24 hours'
       ) t on true) as per_employee;
end;
$$;

revoke all on function public.tracking_health_check() from public;
grant execute on function public.tracking_health_check() to authenticated;

comment on function public.tracking_health_check() is
  'Read-only tracking diagnostic. Requires Full/Shared tracking access. Returns old-table row count (must be 0), events in the last 24h, backfilled_offline count, per-employee newest recorded/uploaded_at and unclassified rows.';

-- ---------------------------------------------------------------------------
-- 14. LOCK DOWN employee_location_history (TABLE)
-- It has no RLS and anon/authenticated hold all privileges. Revoke, enable RLS
-- with no policies, so direct table access is impossible. SECURITY DEFINER
-- functions are unaffected. The table is NOT dropped or renamed.
-- ---------------------------------------------------------------------------
revoke all on table public.employee_location_history from anon, authenticated, public;

alter table public.employee_location_history enable row level security;

-- No policies: the table is reachable only through SECURITY DEFINER functions
-- (employee_location_history, employee_live_positions_v2, etc.) and through
-- the BEFORE INSERT safety-net trigger, which runs as the function owner.

-- ---------------------------------------------------------------------------
-- 15. COPY ANY EXISTING history TABLE ROWS INTO events (idempotent, no-op
-- today: the table is empty). ON CONFLICT DO NOTHING. The table is NOT
-- dropped, renamed or turned into a view.
-- ---------------------------------------------------------------------------
insert into public.employee_location_events (
  employee_id, latitude, longitude, accuracy, recorded_at, uploaded_at,
  source, source_detail, is_offline_record, sync_status,
  battery_level, network_status, altitude, speed, heading
)
select
  h.employee_id, h.latitude, h.longitude, h.accuracy,
  coalesce(h.recorded_at, h.created_at, now()), now(),
  coalesce(h.source, 'mobile'), h.source_detail,
  coalesce(h.is_offline_record, false), coalesce(h.sync_status, 'SYNCED'),
  h.battery_level, h.network_status,
  h.altitude, h.speed, h.heading
from public.employee_location_history h
on conflict (employee_id, recorded_at, latitude, longitude) do nothing;

commit;

-- ---------------------------------------------------------------------------
-- 16. TRACKING CONSENT (first-run disclosure acceptance)
-- Stored per user, with the policy_version that was accepted, so the web can
-- show when consent was given and under which policy.
-- ---------------------------------------------------------------------------
create table if not exists public.tracking_consent (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  accepted_at timestamptz not null default now(),
  policy_version integer not null,
  disclosure_text text not null
);

alter table public.tracking_consent enable row level security;

-- A user may read and insert their own consent row only.
do $$
begin
  if not exists (select 1 from pg_policy where polname = 'tracking_consent_self') then
    execute 'create policy tracking_consent_self on public.tracking_consent for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid())';
  end if;
end;
$$;

grant execute on function public.record_employee_location(float, float, float, timestamptz, text, text, text, text, uuid) to authenticated;
