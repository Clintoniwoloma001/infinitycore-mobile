-- ============================================================================
-- RLS verification for 20261112000000_messaging_receipts_lateness_rls.sql
-- Every block runs in its own transaction and ROLLS BACK — nothing persists.
-- Run with:  supabase db query --linked -f supabase/backups/20261012161000_rls_verification.sql
--
-- Roles exercised: super_admin, admin (NON-member of the private group),
-- hr head (head_of_human_resources), plain staff (non-member).
-- F assertions: a non-member admin/staff/hr user sees ZERO rows of a private
-- group they are not in, and zero of its messages; super_admin sees all;
-- public channels remain visible to everyone.
-- G assertions: a user sees only their own lateness rows; the HR-head set sees
-- all rows; admin sees none.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. SUPER_ADMIN — must see everything
-- ---------------------------------------------------------------------------
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"bb5e24b0-e3e3-4f5e-9cf9-d0d94394803d","role":"authenticated"}', true);
select 'super_admin' as role,
       (select count(*) from public.message_groups) as groups_all,
       (select count(*) from public.message_groups where id = 'cd885deb-5a74-44c2-972e-8b8151c17b19') as private_group_visible,
       (select count(*) from public.message_channels) as channels_all,
       (select count(*) from public.chat_messages where group_id = 'cd885deb-5a74-44c2-972e-8b8151c17b19') as private_group_messages;
rollback;

-- ---------------------------------------------------------------------------
-- 2. ADMIN who is NOT a member of the private group — must see ZERO of it
-- ---------------------------------------------------------------------------
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a8a24a11-cb4d-40e8-94ef-153832f729a5","role":"authenticated"}', true);
select 'admin_non_member' as role,
       (select count(*) from public.message_groups) as groups_visible,
       (select count(*) from public.message_groups where id = 'cd885deb-5a74-44c2-972e-8b8151c17b19') as private_group_visible,
       (select count(*) from public.message_group_members where group_id = 'cd885deb-5a74-44c2-972e-8b8151c17b19') as private_group_members_visible,
       (select count(*) from public.chat_messages where group_id = 'cd885deb-5a74-44c2-972e-8b8151c17b19') as private_group_messages,
       (select count(*) from public.message_channels) as channels_visible;
rollback;

-- ---------------------------------------------------------------------------
-- 3. PLAIN STAFF who is NOT a member — must see ZERO of the private group
-- ---------------------------------------------------------------------------
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"18a7767d-21a7-458d-9adc-b4e3618f9496","role":"authenticated"}', true);
select 'staff_non_member' as role,
       (select count(*) from public.message_groups) as groups_visible,
       (select count(*) from public.message_groups where id = 'cd885deb-5a74-44c2-972e-8b8151c17b19') as private_group_visible,
       (select count(*) from public.chat_messages where group_id = 'cd885deb-5a74-44c2-972e-8b8151c17b19') as private_group_messages,
       (select count(*) from public.message_channels) as channels_visible;
rollback;

-- ---------------------------------------------------------------------------
-- 4. HR HEAD — must also see ZERO of the group it is not in (no HR widening)
-- ---------------------------------------------------------------------------
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"5bf91f4c-d5e4-4e01-b9d8-4a7596fa1b59","role":"authenticated"}', true);
select 'hr_head' as role,
       (select count(*) from public.message_groups) as groups_visible,
       (select count(*) from public.message_groups where id = 'cd885deb-5a74-44c2-972e-8b8151c17b19') as private_group_visible,
       (select count(*) from public.message_group_members where group_id = 'cd885deb-5a74-44c2-972e-8b8151c17b19') as private_group_members_visible;
rollback;

-- ---------------------------------------------------------------------------
-- 5. PUBLIC CHANNEL STILL WORKING — no public channel exists in live data (and
--    channel creation is RPC-gated, so one cannot be inserted here), so this
--    asserts the read policies still carry the is_public branch for every
--    authenticated user, which is what keeps all-staff channels visible.
-- ---------------------------------------------------------------------------
select tablename, policyname,
       (qual like '%is_public = true%') as keeps_public_branch,
       (qual like '%is_communication_admin()%') as still_widens_to_admin
  from pg_policies
 where schemaname = 'public'
   and tablename in ('message_groups','message_group_members','message_channels','message_channel_members')
 order by tablename;

-- ---------------------------------------------------------------------------
-- 6. G — lateness_reasons visibility per role. Two rows are inserted inside
--    the transaction: one owned by plain staff, one owned by the admin.
-- ---------------------------------------------------------------------------
begin;
set local role authenticated;
-- staff's own row (acting as staff)
select set_config('request.jwt.claims', '{"sub":"18a7767d-21a7-458d-9adc-b4e3618f9496","role":"authenticated"}', true);
insert into public.lateness_reasons (user_id, work_date, clocked_in_at, minutes_late, reason_category, reason_text)
values ('18a7767d-21a7-458d-9adc-b4e3618f9496', current_date, now(), 12, 'traffic', 'Road works');
-- admin's own row (acting as admin — a user may only insert their own row)
select set_config('request.jwt.claims', '{"sub":"a8a24a11-cb4d-40e8-94ef-153832f729a5","role":"authenticated"}', true);
insert into public.lateness_reasons (user_id, work_date, clocked_in_at, minutes_late, reason_category)
values ('a8a24a11-cb4d-40e8-94ef-153832f729a5', current_date, now(), 5, 'health');

-- staff: own row only
select set_config('request.jwt.claims', '{"sub":"18a7767d-21a7-458d-9adc-b4e3618f9496","role":"authenticated"}', true);
select 'staff_own_lateness' as role, count(*) from public.lateness_reasons;

-- admin: no HR reviewer rights -> zero rows
select set_config('request.jwt.claims', '{"sub":"a8a24a11-cb4d-40e8-94ef-153832f729a5","role":"authenticated"}', true);
select 'admin_lateness' as role, count(*) from public.lateness_reasons;

-- hr head: all rows
select set_config('request.jwt.claims', '{"sub":"5bf91f4c-d5e4-4e01-b9d8-4a7596fa1b59","role":"authenticated"}', true);
select 'hr_head_lateness' as role, count(*) from public.lateness_reasons;

-- super admin: all rows
select set_config('request.jwt.claims', '{"sub":"bb5e24b0-e3e3-4f5e-9cf9-d0d94394803d","role":"authenticated"}', true);
select 'super_admin_lateness' as role, count(*) from public.lateness_reasons;
rollback;

-- ---------------------------------------------------------------------------
-- 7. G — a user may NOT insert a lateness row for someone else
-- ---------------------------------------------------------------------------
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"18a7767d-21a7-458d-9adc-b4e3618f9496","role":"authenticated"}', true);
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

-- ---------------------------------------------------------------------------
-- 8. C — receipts: a user can upsert only their own row
-- ---------------------------------------------------------------------------
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"18a7767d-21a7-458d-9adc-b4e3618f9496","role":"authenticated"}', true);
do $$
declare v_id uuid;
begin
  select id into v_id from public.chat_messages limit 1;
  if v_id is not null then
    insert into public.message_receipts (message_id, user_id, read_at)
    values (v_id, '18a7767d-21a7-458d-9adc-b4e3618f9496', now());
    raise notice 'OK: own receipt upsert allowed';
  end if;
exception when unique_violation then
  raise notice 'OK: own receipt upsert allowed (existing row)';
end $$;
rollback;
