-- ---------------------------------------------------------------------------
-- Fix: verification_method_check rejects the biometric mobile clock-in /
-- clock-out value.
--
-- Root cause (verified against production):
--   public.mobile_clock_in / public.mobile_clock_out build the verification
--   string server-side and pass one of:
--       'BIOMETRIC+GPS'      (biometric mobile clock-in/out)
--       'BIOMETRIC+GPS+QR'   (biometric + scanned QR terminal)
--       'GPS+QR'             (GPS + scanned QR terminal)
--   into attendance_clock_in_for_employee / attendance_clock_out_for_employee.
--   Those engine functions write that same value into BOTH tables:
--       public.attendance_records.verification_method
--       public.attendance_events.verification_method
--   BOTH tables carry a CHECK constraint named "verification_method_check"
--   that originally allowed only: GPS, FINGERPRINT, DEVICE_AUTHENTICATION,
--   WEBAUTHN, ADMIN_OVERRIDE, NONE.
--   A successful biometric clock-in therefore failed with:
--       new row for relation "attendance_records"
--       violates check constraint "verification_method_check"
--   and, because the event row is written in the same transaction, fixing only
--   one table still rolled the whole clock-in back. BOTH constraints must be
--   expanded.
--
-- Fix strategy (smallest, additive, non-destructive):
--   * EXTEND the existing CHECK on BOTH tables to ALSO accept the three
--     legitimate values the mobile attendance functions already produce.
--   * PRESERVE every currently-accepted value unchanged.
--   * Do NOT drop the constraints' security role, and do NOT remap biometric
--     verification onto a weaker value — biometric attendance stays recorded
--     as biometric (mobile_biometric_verified + audit logs are untouched).
--   * No existing rows are modified; no attendance history is rewritten; no
--     table is recreated. The constraints stay validated (not NOT VALID).
--   * Idempotent per table: a table whose constraint already permits
--     'BIOMETRIC+GPS' is skipped.
--
-- GPS evidence is unaffected: latitude/longitude/accuracy, geofence_status and
-- location_status are stored in their own columns and are not part of these
-- constraints. This change only makes the biometric verification label
-- storable.
-- ---------------------------------------------------------------------------

-- Apply as two explicit, idempotent statements (no PL/pgSQL) so this runs
-- cleanly both in the Supabase SQL editor and via the Management API.
--
-- 1) attendance_records (idempotent via DO guard, already expanded in prod)
do $guard1$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.attendance_records'::regclass
      and conname='verification_method_check'
      and pg_get_constraintdef(oid) ilike '%BIOMETRIC+GPS%'
  ) then
    alter table public.attendance_records drop constraint verification_method_check;
    alter table public.attendance_records
      add constraint verification_method_check
      check (verification_method = any (array[
        'GPS','FINGERPRINT','DEVICE_AUTHENTICATION','WEBAUTHN','ADMIN_OVERRIDE','NONE',
        'BIOMETRIC+GPS','BIOMETRIC+GPS+QR','GPS+QR'
      ]::text[]));
  end if;
end
$guard1$;

-- 2) attendance_events (the constraint that was actually still blocking)
do $guard2$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.attendance_events'::regclass
      and conname='verification_method_check'
      and pg_get_constraintdef(oid) ilike '%BIOMETRIC+GPS%'
  ) then
    alter table public.attendance_events drop constraint verification_method_check;
    alter table public.attendance_events
      add constraint verification_method_check
      check (verification_method = any (array[
        'GPS','FINGERPRINT','DEVICE_AUTHENTICATION','WEBAUTHN','ADMIN_OVERRIDE','NONE',
        'BIOMETRIC+GPS','BIOMETRIC+GPS+QR','GPS+QR'
      ]::text[]));
  end if;
end
$guard2$;
