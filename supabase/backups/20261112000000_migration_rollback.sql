-- ============================================================================
-- 20261112000000_migration_rollback.sql
--
-- Reverses supabase/migrations/20261112000000_messaging_receipts_lateness_rls.sql
-- using the pre-change state captured in
-- supabase/backups/20261012160000_pre_migration_policies_triggers.sql.
--
-- Properties:
--   * Restores the four read policies VERBATIM (with is_communication_admin()).
--   * Restores send_chat_message to its original two-argument body.
--   * Drops only objects this migration created.
--   * Data note: chat_threads.last_message_at / last_message / last_sender_id
--     predate this migration and remain maintained by the send RPCs, so they
--     are left exactly as they are. The backfilled values are the TRUE latest
--     messages, so removing them would degrade correctness; only the new
--     last_message_id column is dropped.
--   * message_receipts rows are backfilled read/ack history that existed in
--     message_reads / chat_message_acks; dropping the table loses nothing that
--     is not still present in those tables.
--   * Idempotent: safe to run twice.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- G. Lateness reasons
-- ---------------------------------------------------------------------------
drop table if exists public.lateness_reasons cascade;
drop function if exists public.is_hr_reviewer();

-- ---------------------------------------------------------------------------
-- F. Restore the four read policies exactly as they were (with the
--    is_communication_admin() widening this migration removed).
-- ---------------------------------------------------------------------------
drop policy if exists "msg_groups read_member" on public.message_groups;
create policy "msg_groups read_member" on public.message_groups
  for select to public using (
    is_group_member(id)
    or creator_id = auth.uid()
    or is_communication_admin()
    or is_super_admin()
    or (is_public = true)
  );

drop policy if exists "msg_group_members read_member" on public.message_group_members;
create policy "msg_group_members read_member" on public.message_group_members
  for select to public using (
    is_group_member(group_id)
    or is_communication_admin()
    or is_super_admin()
    or (exists (
      select 1 from message_groups g
      where g.id = message_group_members.group_id and g.is_public = true
    ))
  );

drop policy if exists "msg_channels read_member" on public.message_channels;
create policy "msg_channels read_member" on public.message_channels
  for select to public using (
    is_channel_member(id)
    or creator_id = auth.uid()
    or is_communication_admin()
    or is_super_admin()
    or (is_public = true)
  );

drop policy if exists "msg_channel_members read_member" on public.message_channel_members;
create policy "msg_channel_members read_member" on public.message_channel_members
  for select to public using (
    is_channel_member(channel_id)
    or is_communication_admin()
    or is_super_admin()
    or (exists (
      select 1 from message_channels c
      where c.id = message_channel_members.channel_id and c.is_public = true
    ))
  );

-- ---------------------------------------------------------------------------
-- B/C. Drop receipts (policies, grants and indexes go with the table) and
--      restore send_chat_message to its original two-argument signature.
-- ---------------------------------------------------------------------------
do $$
begin
  begin
    alter publication supabase_realtime drop table public.message_receipts;
  exception when undefined_object then null;
  end;
end $$;

drop table if exists public.message_receipts cascade;
drop function if exists public.mark_messages_read(uuid[]);

create or replace function public.send_chat_message(p_thread_id uuid, p_body text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_me uuid := auth.uid();
  v_other uuid;
  v_msg record;
begin
  if v_me is null then raise exception 'Not authenticated'; end if;
  if p_body is null or length(btrim(p_body)) = 0 then raise exception 'Message body required'; end if;
  if not exists (
    select 1 from public.chat_threads t
    where t.id = p_thread_id and (t.member_a = v_me or t.member_b = v_me)
  ) then raise exception 'Not authorized in this thread'; end if;

  select case when member_a = v_me then member_b else member_a end into v_other
  from public.chat_threads where id = p_thread_id;

  insert into public.chat_messages (thread_id, sender_id, body, status, message_type)
  values (p_thread_id, v_me, btrim(p_body), 'sent', 'direct')
  returning * into v_msg;

  update public.chat_threads
    set last_message = btrim(p_body), last_sender_id = v_me, last_message_at = now(), updated_at = now()
    where id = p_thread_id;

  if not exists (
    select 1 from public.chat_thread_user_settings
    where thread_id = p_thread_id and user_id = v_other and is_muted
  ) then
    insert into public.notifications (user_id, title, message, type, link)
    values (v_other, 'New Message', left(btrim(p_body), 120), 'chat', '/chat');
  end if;

  return jsonb_build_object('ok', true, 'id', v_msg.id, 'thread_id', p_thread_id,
    'body', v_msg.body, 'created_at', v_msg.created_at);
end; $function$;

-- ---------------------------------------------------------------------------
-- A. Remove the last-message trigger and the column it maintains. The
--    backfilled last_message_at / last_message / last_sender_id values are the
--    true latest messages and are left in place (see the data note above).
-- ---------------------------------------------------------------------------
drop trigger if exists trg_chat_messages_last_message on public.chat_messages;
drop function if exists public.touch_conversation_last_message();
drop index if exists public.idx_chat_threads_last_message_at;
alter table public.chat_threads drop column if exists last_message_id;

-- ---------------------------------------------------------------------------
-- Forget the migration version so `supabase db push` may re-apply it.
-- ---------------------------------------------------------------------------
delete from supabase_migrations.schema_migrations where version = '20261112000000';
