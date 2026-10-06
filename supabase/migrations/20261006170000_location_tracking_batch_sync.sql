-- Location tracking and batch sync migration
-- Supports offline-first location tracking with batch uploads and geofencing

-- Enable PostGIS extension if not already enabled
CREATE EXTENSION IF NOT EXISTS postgis;

-- Branch geofences table
CREATE TABLE IF NOT EXISTS public.branch_geofences (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id uuid REFERENCES public.branches(id) ON DELETE CASCADE,
  radius_meters numeric(10, 2) NOT NULL DEFAULT 100,
  center_lat numeric(10, 6) NOT NULL,
  center_lng numeric(10, 6) NOT NULL,
  geom geography(Point, 4326) GENERATED ALWAYS AS (
    ST_SetSRID(ST_MakePoint(center_lng, center_lat), 4326)
  ) STORED,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Index for geofences
CREATE INDEX IF NOT EXISTS idx_branch_geofences_branch_id ON public.branch_geofences(branch_id);
CREATE INDEX IF NOT EXISTS idx_branch_geofences_active ON public.branch_geofences(active);
CREATE INDEX IF NOT EXISTS idx_branch_geofences_geom ON public.branch_geofences USING GIST(geom);

-- Employee location history table
CREATE TABLE IF NOT EXISTS public.employee_location_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id uuid REFERENCES public.employees(id) ON DELETE CASCADE NOT NULL,
  latitude numeric(10, 6) NOT NULL,
  longitude numeric(10, 6) NOT NULL,
  accuracy numeric(8, 2),
  altitude numeric(8, 2),
  speed numeric(6, 2),
  heading numeric(6, 2),
  recorded_at timestamptz NOT NULL,
  is_offline_record boolean NOT NULL DEFAULT false,
  sync_status text CHECK (sync_status IN ('PENDING', 'SYNCING', 'SYNCED', 'FAILED')) DEFAULT 'SYNCED',
  battery_level integer CHECK (battery_level BETWEEN 0 AND 100),
  network_status text,
  source text DEFAULT 'mobile',
  source_detail text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  geom geography(Point, 4326) GENERATED ALWAYS AS (
    ST_SetSRID(ST_MakePoint(longitude, latitude), 4326)
  ) STORED
);

-- Indexes for efficient querying
CREATE INDEX IF NOT EXISTS idx_employee_location_history_employee_id ON public.employee_location_history(employee_id);
CREATE INDEX IF NOT EXISTS idx_employee_location_history_recorded_at ON public.employee_location_history(recorded_at);
CREATE INDEX IF NOT EXISTS idx_employee_location_history_employee_recorded ON public.employee_location_history(employee_id, recorded_at);
CREATE INDEX IF NOT EXISTS idx_employee_location_history_geom ON public.employee_location_history USING GIST(geom);
CREATE INDEX IF NOT EXISTS idx_employee_location_history_sync_status ON public.employee_location_history(sync_status);

-- Geofence check function
CREATE OR REPLACE FUNCTION public.check_within_geofence(
  p_lat numeric,
  p_lng numeric,
  p_branch_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_within boolean := false;
  v_geofence record;
BEGIN
  FOR v_geofence IN
    SELECT radius_meters, geom
    FROM public.branch_geofences
    WHERE branch_id = p_branch_id
      AND active = true
  LOOP
    IF ST_DWithin(
      v_geofence.geom,
      ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326),
      v_geofence.radius_meters
    ) THEN
      RETURN true;
    END IF;
  END LOOP;
  RETURN false;
END;
$$;

COMMENT ON FUNCTION public.check_within_geofence(numeric, numeric, uuid) IS
  'Checks if coordinates (lat, lng) fall within any active geofence for the given branch_id';

GRANT EXECUTE ON FUNCTION public.check_within_geofence(numeric, numeric, uuid) TO authenticated;

-- Batch sync RPC for offline location points
CREATE OR REPLACE FUNCTION public.batch_sync_employee_locations(
  p_locations jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result jsonb := '[]'::jsonb;
  v_item jsonb;
  v_id uuid;
  v_employee_id uuid;
  v_rec record;
BEGIN
  -- Get employee_id for authenticated user
  SELECT id INTO v_employee_id
  FROM public.employees
  WHERE user_id = auth.uid()
    AND coalesce(is_archived, false) = false
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_employee_id IS NULL THEN
    RAISE EXCEPTION 'NO_EMPLOYEE_PROFILE: No active employee profile found for authenticated user';
  END IF;

  -- Process each location in the batch
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_locations)
  LOOP
    -- Insert location if not duplicate (same employee, recorded_at, lat, lng)
    INSERT INTO public.employee_location_history (
      employee_id,
      latitude,
      longitude,
      accuracy,
      altitude,
      speed,
      heading,
      recorded_at,
      is_offline_record,
      sync_status,
      battery_level,
      network_status,
      source,
      source_detail
    )
    SELECT
      v_employee_id,
      (v_item->>'latitude')::numeric,
      (v_item->>'longitude')::numeric,
      (v_item->>'accuracy')::numeric,
      (v_item->>'altitude')::numeric,
      (v_item->>'speed')::numeric,
      (v_item->>'heading')::numeric,
      COALESCE(
        (v_item->>'recorded_at')::timestamptz,
        (v_item->>'timestamp')::timestamptz,
        now()
      ),
      COALESCE((v_item->>'is_offline_record')::boolean, true),
      'SYNCED',
      (v_item->>'battery_level')::integer,
      v_item->>'network_status',
      COALESCE(v_item->>'source', 'mobile'),
      COALESCE(v_item->>'source_detail', 'batch_sync')
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.employee_location_history
      WHERE employee_id = v_employee_id
        AND recorded_at = COALESCE(
          (v_item->>'recorded_at')::timestamptz,
          (v_item->>'timestamp')::timestamptz,
          now()
        )
        AND latitude::numeric(10,6) = (v_item->>'latitude')::numeric(10,6)
        AND longitude::numeric(10,6) = (v_item->>'longitude')::numeric(10,6)
    )
    RETURNING id INTO v_id;

    -- If inserted successfully, add to result
    IF v_id IS NOT NULL THEN
      v_result := v_result || jsonb_build_object('id', v_id);
      v_id := NULL;
    ELSE
      -- Try to find existing record to return its ID (for dedup case)
      SELECT id INTO v_id
      FROM public.employee_location_history
      WHERE employee_id = v_employee_id
        AND recorded_at = COALESCE(
          (v_item->>'recorded_at')::timestamptz,
          (v_item->>'timestamp')::timestamptz,
          now()
        )
        AND latitude::numeric(10,6) = (v_item->>'latitude')::numeric(10,6)
        AND longitude::numeric(10,6) = (v_item->>'longitude')::numeric(10,6)
      LIMIT 1;
      
      IF v_id IS NOT NULL THEN
        v_result := v_result || jsonb_build_object('id', v_id);
        v_id := NULL;
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'synced_count', jsonb_array_length(v_result),
    'synced_ids', v_result
  );
END;
$$;

COMMENT ON FUNCTION public.batch_sync_employee_locations(jsonb) IS
  'Batch sync offline location records. Accepts array of location objects, deduplicates by employee+recorded_at+lat+lng, inserts in bulk, returns synced record IDs.';

GRANT EXECUTE ON FUNCTION public.batch_sync_employee_locations(jsonb) TO authenticated;
