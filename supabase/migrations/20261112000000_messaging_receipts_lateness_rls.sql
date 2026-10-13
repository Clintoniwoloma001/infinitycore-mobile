-- ============================================================================
-- 20261112000000_messaging_receipts_lateness_rls.sql
--
-- Scope: A (true latest-message preview), B/C (delivery + read + ack receipts),
--        D (reply-to reuses the existing parent_message_id column),
--        F (group/channel visibility), G (lateness reasons).
--
-- Non-negotiable properties:
--   * IDEMPOTENT — safe to run twice (create-or-replace / if-not-exists /
--     drop-policy-if-exists everywhere).
--   * NON-DESTRUCTIVE — no data is deleted; existing tables and policies on
--     base tables are left in place; message_receipts is BACKFILLED from the
--     existing message_reads / chat_message_acks history instead of replacing
--     those tables.
--   * Base-table policies are only TIGHTENED (never widened).
--
-- Backup (policies/triggers/function bodies before this change):
--   supabase/backups/20261012160000_pre_migration_policies_triggers.sql
-- Rollback:
--   supabase/backups/20261112000000_migration_rollback.sql
-- ============================================================================

-- ---------------------------------------------------------------------------
-- A. TRUE LAST-MESSAGE MAINTENANCE FOR DIRECT CONVERSATIONS
-- ---------------------------------------------------------------------------
-- Root cause of "an old message shows as the preview while a newer one
-- exists": chat_threads.last_message_at/last_message are written only
-- imperatively by the send RPCs, so any insert path that does not run that
-- RPC body (or any row created before the column existed) leaves a stale
-- preview and sorts the conversation in the wrong place. A trigger makes the
-- preview authoritative for EVERY insert path.

alter table public.chat_threads
  add column if not exists last_message_id uuid references public.chat_messages(id) on delete set null;

create index if not exists idx_chat_threads_last_message_at
  on public.chat_threads(last_message_at desc);

create or replace function public.touch_conversation_last_message()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if new.thread_id is not null then
    update public.chat_threads t
       set last_message_id = new.id,
           last_message = btrim(coalesce(new.body, '')),
           last_sender_id = new.sender_id,
           -- Use the row's SERVER timestamp, never a client clock. A message
           -- that arrives late (an offline outbox sync) must not drag the
           -- conversation's preview backwards, so only move the marker forward.
           last_message_at = new.created_at,
           updated_at = now()
     where t.id = new.thread_id
       and (t.last_message_at is null or t.last_message_at <= new.created_at);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_chat_messages_last_message on public.chat_messages;
create trigger trg_chat_messages_last_message
  after insert on public.chat_messages
  for each row execute function public.touch_conversation_last_message();

-- Set-based backfill: the true latest message per thread (server created_at,
-- id as tie-break) is written ONLY where it is newer than what is stored, so
-- running this on live data can never regress a correct preview.
update public.chat_threads t
   set last_message_id = m.id,
       last_message = btrim(coalesce(m.body, '')),
       last_sender_id = m.sender_id,
       last_message_at = m.created_at
  from (
    select distinct on (c.thread_id)
           c.thread_id, c.id, c.body, c.sender_id, c.created_at
      from public.chat_messages c
     where c.thread_id is not null
     order by c.thread_id, c.created_at desc, c.id desc
  ) m
 where t.id = m.thread_id
   and (t.last_message_at is null or t.last_message_at < m.created_at);

-- ---------------------------------------------------------------------------
-- D. REPLY-TO-SPECIFIC-MESSAGE
-- ---------------------------------------------------------------------------
-- No new column: chat_messages.parent_message_id (nullable FK to
-- chat_messages(id), on delete set null, already indexed by
-- idx_chat_messages_parent) and root_message_id already exist and the server
-- already validates replies through can_read_message() in send_rich_message.
-- What was missing is the parent parameter on the plain-text send RPC.

-- `create or replace` cannot change a function's ARGUMENT LIST, so without
-- this drop the old two-argument signature would survive as an overload and
-- every client call would fail with "function is not unique" (PGRST203).
drop function if exists public.send_chat_message(uuid, text);

create or replace function public.send_chat_message(
  p_thread_id uuid,
  p_body text,
  p_parent_message_id uuid default null
)
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

  -- A reply must point at a message inside the SAME thread, and one the sender
  -- can already read (quotes are only renderable if the quote is readable).
  if p_parent_message_id is not null then
    if not exists (
      select 1 from public.chat_messages c
      where c.id = p_parent_message_id
        and c.thread_id = p_thread_id
        and public.can_read_message(c.id)
    ) then raise exception 'Quoted message is not available in this thread'; end if;
  end if;

  select case when member_a = v_me then member_b else member_a end into v_other
  from public.chat_threads where id = p_thread_id;

  insert into public.chat_messages (thread_id, sender_id, body, status, message_type, parent_message_id)
  values (p_thread_id, v_me, btrim(p_body), 'sent', 'direct', p_parent_message_id)
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
    'body', v_msg.body, 'created_at', v_msg.created_at,
    'parent_message_id', v_msg.parent_message_id);
end; $function$;

-- ---------------------------------------------------------------------------
-- B/C. DELIVERY / READ / ACKNOWLEDGEMENT RECEIPTS
-- ---------------------------------------------------------------------------
-- One row per (message, recipient). RLS:
--   * a user upserts ONLY their own row (delivered/read/acknowledged)
--   * the message's SENDER and SUPERADMIN read all rows for those messages
--     (that is what powers sender-side ticks and Message info)
--   * a recipient reads ONLY their own row
-- Existing history is backfilled from message_reads + chat_message_acks so no
-- read/ack state is lost; those tables are left untouched.

create table if not exists public.message_receipts (
  message_id      uuid not null references public.chat_messages(id) on delete cascade,
  user_id         uuid not null references auth.users(id) on delete cascade,
  delivered_at    timestamptz,
  read_at         timestamptz,
  acknowledged_at timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  primary key (message_id, user_id)
);

create index if not exists idx_message_receipts_user on public.message_receipts(user_id);
create index if not exists idx_message_receipts_message on public.message_receipts(message_id);

alter table public.message_receipts enable row level security;

drop policy if exists "receipts upsert own" on public.message_receipts;
create policy "receipts upsert own" on public.message_receipts
  for insert to authenticated with check (user_id = auth.uid());

drop policy if exists "receipts update own" on public.message_receipts;
create policy "receipts update own" on public.message_receipts
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists "receipts read own or sender or superadmin" on public.message_receipts;
create policy "receipts read own or sender or superadmin" on public.message_receipts
  for select to authenticated using (
    user_id = auth.uid()
    or exists (
      select 1 from public.chat_messages m
      where m.id = message_receipts.message_id and m.sender_id = auth.uid()
    )
    or public.is_super_admin()
  );

grant select, insert, update on public.message_receipts to authenticated;

-- Realtime: sender-side ticks and Message info must update live.
do $$
begin
  begin
    alter publication supabase_realtime add table public.message_receipts;
  exception when duplicate_object then null;
  end;
end $$;

-- Batched read marking: the receiver marks the open conversation's messages
-- read in one call. SECURITY DEFINER + an explicit can_read_message() guard
-- keeps the write limited to messages the caller may actually read.
create or replace function public.mark_messages_read(p_message_ids uuid[])
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_me uuid := auth.uid();
  v_count integer := 0;
begin
  if v_me is null then raise exception 'Not authenticated'; end if;
  if p_message_ids is null or array_length(p_message_ids, 1) is null then
    return 0;
  end if;

  with allowed as (
    select m.id
      from public.chat_messages m
     where m.id = any (p_message_ids)
       and public.can_read_message(m.id)
  ), upserted as (
    insert into public.message_receipts (message_id, user_id, read_at, updated_at)
    select a.id, v_me, now(), now() from allowed a
    on conflict (message_id, user_id) do update
      set read_at = coalesce(message_receipts.read_at, excluded.read_at),
          updated_at = now()
    returning message_id
  )
  select count(*) into v_count from upserted;

  return v_count;
end;
$$;

grant execute on function public.mark_messages_read(uuid[]) to authenticated;

-- Backfill from the existing read history (message_reads) + acknowledgement
-- history (chat_message_acks). Earliest non-null value wins; nothing existing
-- is modified.
insert into public.message_receipts
  (message_id, user_id, delivered_at, read_at, acknowledged_at, created_at, updated_at)
select r.message_id,
       r.user_id,
       null,
       min(r.read_at),
       (select min(a.acknowledged_at)
          from public.chat_message_acks a
         where a.message_id = r.message_id
           and a.user_id = r.user_id
           and a.status = 'acknowledged'),
       now(),
       now()
  from public.message_reads r
 group by r.message_id, r.user_id
on conflict (message_id, user_id) do update
  set read_at = coalesce(message_receipts.read_at, excluded.read_at),
      acknowledged_at = coalesce(message_receipts.acknowledged_at, excluded.acknowledged_at),
      updated_at = now();

-- Acknowledgements with no corresponding message_reads row still owe a receipt.
insert into public.message_receipts
  (message_id, user_id, delivered_at, read_at, acknowledged_at, created_at, updated_at)
select a.message_id,
       a.user_id,
       null,
       null,
       a.acknowledged_at,
       now(),
       now()
  from public.chat_message_acks a
 where a.status = 'acknowledged'
 group by a.message_id, a.user_id, a.acknowledged_at
on conflict (message_id, user_id) do update
  set acknowledged_at = coalesce(message_receipts.acknowledged_at, excluded.acknowledged_at),
      updated_at = now();

-- ---------------------------------------------------------------------------
-- F. GROUP / CHANNEL VISIBILITY (SECURITY)
-- ---------------------------------------------------------------------------
-- Before: member OR creator OR is_communication_admin() OR is_super_admin()
--         OR is_public — and is_communication_admin() is true for
--         super_admin + admin + hr_manager + hr_officer, so a non-member
--         ADMIN/HR user read every private group.
-- After:  member OR creator OR super_admin OR is_public.
-- Public/all-staff channels keep working exactly as today (is_public stays).
-- chat_messages already gates on can_read_message() (member / super_admin /
-- public / author) and is intentionally NOT redefined here.

drop policy if exists "msg_groups read_member" on public.message_groups;
create policy "msg_groups read_member" on public.message_groups
  for select to public using (
    public.is_group_member(id)
    or creator_id = auth.uid()
    or public.is_super_admin()
    or (is_public = true)
  );

drop policy if exists "msg_group_members read_member" on public.message_group_members;
create policy "msg_group_members read_member" on public.message_group_members
  for select to public using (
    public.is_group_member(group_id)
    or public.is_super_admin()
    or (exists (
      select 1 from public.message_groups g
      where g.id = message_group_members.group_id and g.is_public = true
    ))
  );

drop policy if exists "msg_channels read_member" on public.message_channels;
create policy "msg_channels read_member" on public.message_channels
  for select to public using (
    public.is_channel_member(id)
    or creator_id = auth.uid()
    or public.is_super_admin()
    or (is_public = true)
  );

drop policy if exists "msg_channel_members read_member" on public.message_channel_members;
create policy "msg_channel_members read_member" on public.message_channel_members
  for select to public using (
    public.is_channel_member(channel_id)
    or public.is_super_admin()
    or (exists (
      select 1 from public.message_channels c
      where c.id = message_channel_members.channel_id and c.is_public = true
    ))
  );

-- ---------------------------------------------------------------------------
-- G. LATENESS REASONS
-- ---------------------------------------------------------------------------
-- One row per (late) clock-in; attendance_id is UNIQUE when present (an
-- offline-queued submission that could not resolve the attendance row keeps a
-- NULL and the partial unique index simply does not constrain it).

create table if not exists public.lateness_reasons (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users(id) on delete cascade,
  attendance_id   uuid,
  work_date       date not null default current_date,
  clocked_in_at   timestamptz not null default now(),
  minutes_late    integer not null default 0,
  branch_id       uuid,
  branch_name     text,
  reason_category text not null check (reason_category in
                    ('traffic', 'transport_issue', 'health',
                     'family_emergency', 'official_assignment', 'others')),
  reason_text     text,
  created_at      timestamptz not null default now()
);

-- The FK to attendance_records is added only if that table exposes an `id`
-- column, so this file cannot fail on a schema that renames it.
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'attendance_records' and column_name = 'id'
  ) then
    begin
      execute 'alter table public.lateness_reasons
                 add constraint lateness_reasons_attendance_fk
                 foreign key (attendance_id) references public.attendance_records(id) on delete set null';
    exception when duplicate_object then null;
    end;
  end if;
end $$;

create unique index if not exists lateness_reasons_attendance_uidx
  on public.lateness_reasons(attendance_id)
  where attendance_id is not null;

create index if not exists idx_lateness_reasons_work_date
  on public.lateness_reasons(work_date desc);
create index if not exists idx_lateness_reasons_user
  on public.lateness_reasons(user_id);

alter table public.lateness_reasons enable row level security;

-- HR-head reviewer set. `hr_manager` is the legacy spelling carried for
-- rename tolerance (0 rows today); `head_of_human_resources` is the live
-- HR-head role; hr_officer and super_admin complete the set.
create or replace function public.is_hr_reviewer()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid()
      and role in ('head_of_human_resources', 'hr_manager', 'hr_officer', 'super_admin')
  );
$$;

grant execute on function public.is_hr_reviewer() to authenticated;

drop policy if exists "lateness insert own" on public.lateness_reasons;
create policy "lateness insert own" on public.lateness_reasons
  for insert to authenticated with check (user_id = auth.uid());

drop policy if exists "lateness select own or reviewer" on public.lateness_reasons;
create policy "lateness select own or reviewer" on public.lateness_reasons
  for select to authenticated using (
    user_id = auth.uid() or public.is_hr_reviewer()
  );

grant select, insert on public.lateness_reasons to authenticated;
