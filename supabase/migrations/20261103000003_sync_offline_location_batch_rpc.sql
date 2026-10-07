-- ============================================================================
-- P1-A / OFFLINE BATCH SYNC — sync_offline_location_batch(p_locations jsonb)
-- ============================================================================
-- This is the batch-upload endpoint used by the offline queue flush.
-- It ignores any employee_id embedded in the payload (security: the server
-- resolves the caller from auth.uid() via the same employee mapping
-- `record_employee_location` uses). It relies on the existing 4-column
-- unique index `uq_location_events_dedupe` (employee_id, recorded_at,
-- latitude, longitude) for deduplication — matching decision 1.
-- ============================================================================

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
begin
  -- Resolve employee exactly as record_employee_location does.
  select e.* into v_employee
    from public.employees e
    join public.profiles p on p.id = e.user_id
   where p.id = auth.uid()
   limit 1;

  if not found then
    return jsonb_build_object('status', 'rejected', 'message', 'NO_EMPLOYEE_PROFILE');
  end if;

  -- Must be a non-null array.
  if p_locations is null or not (p_locations ? '#') or (p_locations ? '#[]') is false then
    return jsonb_build_object('status', 'error', 'message', 'Payload must be a non-empty array');
  end if;

  -- Cap batch size (500 max, per requirement).
  v_total := jsonb_array_length(p_locations);
  if v_total > 500 then
    return jsonb_build_object('status', 'error', 'message', 'Batch exceeds 500 items (got ' || v_total || ')');
  end if;

  -- Process each item.
  for v_location in select * from jsonb_array_elements(p_locations) loop
    v_count := v_count + 1;

    -- Skip rows that aren't objects.
    if v_location ? '#[]' is false then
      v_invalid := v_invalid + 1;
      continue;
    end if;

    -- Validate lat / lng.
    declare
      v_lat numeric; v_lng numeric; v_rec timestamptz;
    begin
      v_lat := (v_location ->> 'latitude')::numeric;
      v_lng := (v_location ->> 'longitude')::numeric;

      -- Skip if lat or lng missing / out of range.
      if v_lat is null or v_lng is null
         or v_lat < -90 or v_lat > 90
         or v_lng < -180 or v_lng > 180 then
        v_invalid := v_invalid + 1;
        continue;
      end if;

      -- Validate recorded_at (must exist, must not be > 5 min in future).
      v_rec := coalesce(
        (v_location ->> 'recorded_at')::timestamptz,
        (v_location ->> 'timestamp')::timestamptz,
        null
      );
      if v_rec is null or v_rec > now() + interval '5 minutes' then
        v_invalid := v_invalid + 1;
        continue;
      end if;

      -- Insert using the 4-column conflict key (decision 1 — no narrower key).
      -- sync_status, source, source_detail set per requirement.
      insert into public.employee_location_events (
        employee_id, latitude, longitude, accuracy,
        recorded_at, uploaded_at,
        source, source_detail,
        sync_status
      ) values (
        v_employee.id,
        v_lat,
        v_lng,
        coalesce((v_location ->> 'accuracy')::numeric, 0::numeric),
        v_rec,
        now(),
        coalesce(v_location ->> 'source', 'mobile_offline_queue'),
        coalesce(v_location ->> 'source_detail', 'background_sync'),
        'backfilled_offline'
      )
      on conflict (employee_id, recorded_at, latitude, longitude) do nothing;

      if found then
        v_inserted := v_inserted + 1;
      else
        -- Conflicts (duplicate) don't count as new inserts.
        v_skipped := v_skipped + 1;
      end if;
    end;
  end loop;

  return jsonb_build_object(
    'status',         'synced',
    'records_synced', v_inserted,
    'records_skipped', v_skipped,
    'records_invalid', v_invalid
  );
end;
$$;

-- Security: only the service role and authenticated users can call this.
-- (The existing RLS policies on employee_location_events still apply to inserts.)
revoke all on function public.sync_offline_location_batch(jsonb) from public, anon;
grant execute on function public.sync_offline_location_batch(jsonb) to service_role, authenticated;

comment on function public.sync_offline_location_batch(jsonb) is
  'Batch sync for offline location queue. Derives employee from auth.uid(); ignores any payload employee_id. Uses 4-column conflict (employee_id, recorded_at, latitude, longitude) per decision 1. Returns {status, records_synced, records_skipped, records_invalid}.';
