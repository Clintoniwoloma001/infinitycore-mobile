-- ============================================================================
-- RLS verification for the lateness_reasons -> public.profiles FK added by
-- 20261113120000_lateness_reasons_profiles_fk.sql.
--
-- Every block runs in its own transaction and ROLLS BACK — nothing persists.
-- Run with:
--   psql "$PGHOST" -f supabase/backups/20261113120000_lateness_rls_verification.sql
--
-- The point of this file: the client query
--     .select('*, employee:profiles!inner(full_name)')
-- now embeds profiles through the new FK. This file confirms the embed is
-- usable under RLS for every role that needs it, and that the embed does not
-- leak rows to users who should not see them.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Schema snapshot (informational)
-- ---------------------------------------------------------------------------
select tablename,
       (select count(*) from pg_policies p
         where p.schemaname = 'public' and p.tablename = t.tablename) as rls_policies
  from pg_tables t
 where schemaname = 'public'
   and tablename in ('lateness_reasons','profiles')
 order by tablename;

-- ---------------------------------------------------------------------------
-- A. profiles has NO RLS — every authenticated user reads every profile.
--    This is how HR reads other staff names through the embed. Confirm it is
--    intentional and that lateness_reasons still gates the row set.
-- ---------------------------------------------------------------------------
select tablename, rowsecurity
  from pg_tables
 where schemaname = 'public'
   and tablename in ('lateness_reasons','profiles');

-- ---------------------------------------------------------------------------
-- B. lateness_reasons RLS per role. Two rows are inserted inside the
--    transaction: one owned by plain staff, one owned by the admin.
--    Assertions:
--      staff  -> sees only own row (1)
--      admin  -> sees zero (no HR reviewer rights)
--      hr_officer -> sees all (2)
--      super_admin -> sees all (2)
-- ---------------------------------------------------------------------------
begin;
set local role authenticated;

-- staff's own row
select set_config('request.jwt.claims',
  '{"sub":"18a7767d-21a7-458d-9adc-b4e3618f9496","role":"authenticated"}', true);
insert into public.lateness_reasons (user_id, work_date, clocked_in_at, minutes_late, reason_category, reason_text)
values ('18a7767d-21a7-458d-9adc-b4e3618f9496', current_date, now(), 12, 'traffic', 'Road works');

-- admin's own row
select set_config('request.jwt.claims',
  '{"sub":"a8a24a11-cb4d-40e8-94ef-153832f729a5","role":"authenticated"}', true);
insert into public.lateness_reasons (user_id, work_date, clocked_in_at, minutes_late, reason_category)
values ('a8a24a11-cb4d-40e8-94ef-153832f729a5', current_date, now(), 5, 'health');

-- staff: own row only, with the embedded profile name
select set_config('request.jwt.claims',
  '{"sub":"18a7767d-21a7-458d-9adc-b4e3618f9496","role":"authenticated"}', true);
select 'staff_embed' as check_name,
       count(*) as rows,
       count(e.full_name) as embedded_names
  from public.lateness_reasons l
  join public.profiles e on e.id = l.user_id;

-- admin: no HR reviewer rights -> zero rows
select set_config('request.jwt.claims',
  '{"sub":"a8a24a11-cb4d-40e8-94ef-153832f729a5","role":"authenticated"}', true);
select 'admin_embed' as check_name,
       count(*) as rows,
       count(e.full_name) as embedded_names
  from public.lateness_reasons l
  join public.profiles e on e.id = l.user_id;

-- hr_officer: all rows, all names
select set_config('request.jwt.claims',
  '{"sub":"5bf91f4c-d5e4-4e01-b9d8-4a7596fa1b59","role":"authenticated"}', true);
select 'hr_officer_embed' as check_name,
       count(*) as rows,
       count(e.full_name) as embedded_names
  from public.lateness_reasons l
  join public.profiles e on e.id = l.user_id;

-- super_admin: all rows, all names
select set_config('request.jwt.claims',
  '{"sub":"bb5e24b0-e3e3-4f5e-9cf9-d0d94394803d","role":"authenticated"}', true);
select 'super_admin_embed' as check_name,
       count(*) as rows,
       count(e.full_name) as embedded_names
  from public.lateness_reasons l
  join public.profiles e on e.id = l.user_id;

rollback;

-- ---------------------------------------------------------------------------
-- C. A user may NOT insert a lateness row for someone else (WITH CHECK).
-- ---------------------------------------------------------------------------
begin;
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"18a7767d-21a7-458d-9adc-b4e3618f9496","role":"authenticated"}', true);
do $$
begin
  begin
    insert into public.lateness_reasons (user_id, work_date, clocked_in_at, minutes_late, reason_category)
    values ('a8a24a11-cb4d-40e8-94ef-153832f729a5', current_date, now(), 9, 'others');
    raise exception 'EXPECTED_FAILURE: insert for another user was allowed';
  exception when insufficient_privilege then
    raise notice 'OK: insert for another user rejected (%)', sqlerrm;
  end;
end $$;
rollback;