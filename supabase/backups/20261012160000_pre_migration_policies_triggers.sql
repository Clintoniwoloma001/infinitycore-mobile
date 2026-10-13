-- ============================================================================
-- PRE-MIGRATION BACKUP — affected tables' policies / triggers / columns
-- Project: atzomqicwjufuxhfexxd (production, release 1.1.9+24)
-- Captured: 2026-10-12 (before 20261112000000_messaging_receipts_lateness_rls.sql)
-- Method: targeted `supabase db query --linked` dumps of pg_policies,
--         pg_trigger/pg_get_triggerdef, pg_get_functiondef and
--         information_schema.columns for exactly the objects this migration
--         touches. (A full `db dump` of `public` timed out at 10 minutes on
--         this schema, so the affected objects were dumped individually.)
--
-- This file is the source of truth for
-- supabase/backups/20261112000000_migration_rollback.sql.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. RLS POLICIES BEFORE THE MIGRATION (public schema)
-- ---------------------------------------------------------------------------

-- message_groups (SELECT only policy exists on this table)
create policy "msg_groups read_member" on public.message_groups
  for select to public using (
    is_group_member(id)
    or creator_id = auth.uid()
    or is_communication_admin()
    or is_super_admin()
    or (is_public = true)
  );

-- message_group_members
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

-- message_channels
create policy "msg_channels read_member" on public.message_channels
  for select to public using (
    is_channel_member(id)
    or creator_id = auth.uid()
    or is_communication_admin()
    or is_super_admin()
    or (is_public = true)
  );

-- message_channel_members
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

-- chat_messages (already member-scoped through can_read_message; UNCHANGED by
-- the migration — recorded here to prove it)
create policy "chat_messages read own" on public.chat_messages
  for select to public using (can_read_message(id));

-- chat_threads (already member-scoped; UNCHANGED by the migration)
create policy "chat_threads read own" on public.chat_threads
  for select to public using ((member_a = auth.uid()) or (member_b = auth.uid()));

-- notifications (insert is open to any authenticated user for any user_id —
-- this is what lets the clock-in insert an HR-head notification row)
create policy "notif insert" on public.notifications
  for insert to authenticated with check (auth.role() = 'authenticated'::text);

-- ---------------------------------------------------------------------------
-- 2. TRIGGERS BEFORE THE MIGRATION
-- ---------------------------------------------------------------------------
-- chat_messages (no trigger maintains chat_threads.last_message_at today; the
-- send RPCs do it imperatively, which is why non-RPC insert paths leave a
-- stale preview behind):
create trigger trg_chat_messages_audit after insert or update on public.chat_messages
  for each row execute function trg_chat_messages_audit();
create trigger trg_chat_messages_hash before insert on public.chat_messages
  for each row execute function trg_chat_messages_hash();
create trigger trg_chat_messages_immutable before delete or update on public.chat_messages
  for each row execute function trg_chat_messages_immutable();
create trigger trg_chat_messages_suspension before insert on public.chat_messages
  for each row execute function trg_chat_messages_suspension();

-- ---------------------------------------------------------------------------
-- 3. COLUMNS BEFORE THE MIGRATION
-- ---------------------------------------------------------------------------
-- chat_threads: id, member_a, member_b, last_message, last_sender_id,
--   last_message_at, created_at, updated_at
--   (NO last_message_id — the migration adds it)
-- chat_messages: ... parent_message_id uuid (FK -> chat_messages, on delete
--   set null), root_message_id uuid, ... (the existing reply/thread links; the
--   migration reuses these instead of adding a duplicate reply_to_id)
-- message_groups / message_channels: ... is_public boolean ...
--   (NO last_message_at / last_message_id)
-- message_reads: id, message_id, user_id, read_at            (used for backfill)
-- chat_message_acks: id, message_id, user_id, status,
--   acknowledged_at, ip_address, user_agent, created_at, updated_at
--   (used for backfill)
-- notifications: id, user_id, title, message, type, read, link, created_at
-- attendance_records: exists (the lateness FK target)
-- message_receipts: DOES NOT EXIST (created by the migration)
-- lateness_reasons: DOES NOT EXIST (created by the migration)

-- ---------------------------------------------------------------------------
-- 4. FUNCTIONS THE MIGRATION REPLACES (verbatim definitions)
-- ---------------------------------------------------------------------------

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

-- can_read_message (chat_messages read policy predicate) is already
-- member-scoped (super_admin / author / channel member or public channel /
-- group member or public group / thread participant / announcement audience)
-- and is therefore NOT modified by the migration. See the dump in the commit
-- message of this change for its full definition.

-- is_communication_admin() (the predicate being REMOVED from the four read
-- policies) is true for: super_admin, admin, hr_manager, hr_officer — this is
-- exactly why a non-member ADMIN could read every private group.

-- ---------------------------------------------------------------------------
-- 5. ROLES PRESENT IN public.profiles (for the HR-head set)
-- ---------------------------------------------------------------------------
-- staff(29), hr_officer(4), admin(2), md_ceo(1), head_of_human_resources(1),
-- chairman(1), director(1), super_admin(1), head_of_e_business(1),
-- head_of_audit(1). NOTE: `hr_manager` has 0 rows — it is the legacy spelling
-- kept in the helpers; `head_of_human_resources` is the live HR-head role.
