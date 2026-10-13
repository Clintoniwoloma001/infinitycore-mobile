-- ============================================================================
-- 20261113120000_lateness_reasons_profiles_fk.sql
--
-- Root cause of PGRST200 "Could not find a relationship between
-- 'lateness_reasons' and 'profiles' in the schema cache":
--   lib/features/attendance/lateness_service.dart:258
--     .select('*, employee:profiles!inner(full_name)')
-- The client embeds `profiles` (aliased `employee`) from `lateness_reasons`,
-- but no FK existed from lateness_reasons -> public.profiles, so PostgREST
-- could not resolve the relationship.
--
-- Fix (SERVER-SIDE, idempotent, non-destructive):
--   * report orphan count (lateness_reasons.user_id with no matching
--     profiles.id) — never delete anything
--   * add FK lateness_reasons(user_id) -> public.profiles(id)
--     ON DELETE CASCADE (matches the existing user_id -> auth.users FK)
--   * if orphans block a valid FK, add it NOT VALID and report pending
--   * reload the PostgREST schema cache
--
-- The existing FK lateness_reasons(user_id) -> auth.users(id) is left in
-- place. Indexes idx_lateness_reasons_user (user_id) and
-- idx_lateness_reasons_work_date (work_date desc) already exist, so no new
-- indexes are required.
-- ============================================================================

begin;

-- 1. Report orphans. Never delete.
do $$
declare
  v_orphans bigint;
begin
  select count(*)
    into v_orphans
    from public.lateness_reasons l
   where not exists (select 1 from public.profiles p where p.id = l.user_id);
  raise notice 'lateness_reasons->profiles orphans: %', v_orphans;
end;
$$;

-- 2. Add the FK (guarded, idempotent). Valid if clean; NOT VALID if orphans
--    block validation. Nothing is deleted in either case.
--
-- Guard note: the existing lateness_reasons(user_id) -> auth.users(id) FK is
-- also named lateness_reasons_user_id_fkey, so the guard must key off the
-- referenced table, not the constraint name alone.
do $$
declare
  v_exists boolean;
begin
  select exists (
    select 1
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    join pg_class ref on ref.oid = c.confrelid
    join pg_namespace refn on refn.oid = ref.relnamespace
    where n.nspname = 'public'
      and t.relname = 'lateness_reasons'
      and refn.nspname = 'public'
      and ref.relname = 'profiles'
      and c.contype = 'f'
      and c.conkey @> array(
        select attnum from pg_attribute
        where attrelid = t.oid and attname = 'user_id'
      )
  ) into v_exists;

  if v_exists then
    raise notice 'lateness_reasons(user_id) -> public.profiles(id) FK already exists; skipping';
    return;
  end if;

  begin
    alter table public.lateness_reasons
      add constraint lateness_reasons_user_id_profiles_fkey
      foreign key (user_id) references public.profiles(id) on delete cascade;
    raise notice 'lateness_reasons_user_id_profiles_fkey added (valid)';
  exception when others then
    -- Orphan rows (or another transient error) block validation. Add NOT
    -- VALID so the migration still succeeds; validation is pending.
    alter table public.lateness_reasons
      add constraint lateness_reasons_user_id_profiles_fkey
      foreign key (user_id) references public.profiles(id) on delete cascade
      not valid;
    raise notice 'lateness_reasons_user_id_profiles_fkey added NOT VALID; validation pending';
  end;
end;
$$;

-- 3. Reload the PostgREST schema cache so the new relationship is visible to
--    the REST API immediately (no restart required).
notify pgrst, 'reload schema';

commit;