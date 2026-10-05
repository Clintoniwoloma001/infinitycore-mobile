-- ============================================================================
-- Automation Command Centre — My Work queue behaviour
--
-- Four cases that must hold together:
--   1. an automation-sourced task assigned to me comes back
--   2. a task of ANOTHER source does not, or the Command Centre would silently
--      become a general task list
--   3. another person's task does not
--   4. unreported progress is NULL rather than an invented 0%
--
-- Requires the function from 20261002000000_automation_my_work_queue.sql.
-- ============================================================================
-- ===========================================================================
-- Behavioural check
--
-- Two cases that must hold together:
--   1. an automation-sourced task assigned to me comes back
--   2. a task of ANOTHER source does not - otherwise the Command Centre would
--      silently become a general task list for its assignee
-- ===========================================================================
begin;

-- The linkage column and the source discriminator arrive from
-- 20261001000000_automation_executive_assignment.sql. Added here so this file
-- runs against a bare schema too; both are `if not exists`.
alter table public.work_tasks
  add column if not exists automation_item_id uuid,
  add column if not exists source text;

-- The assignee FK points at auth.users, so the fixture uses two accounts that
-- actually exist rather than invented ids.
do $$
declare
  v_me uuid;
  v_other uuid;
begin
  select id into v_me from auth.users order by created_at asc limit 1;
  select id into v_other from auth.users order by created_at desc limit 1;

  if v_me is null or v_other is null or v_me = v_other then
    raise notice 'SKIPPED: this database has fewer than two auth users';
    return;
  end if;

  perform set_config('request.jwt.claim.sub', v_me::text, false);

  insert into public.work_tasks
    (id, title, department, status, source, automation_item_id,
     assigned_to_user_id, created_at)
  values
    ('b1111111-1111-1111-1111-111111111111',
     'Automation register work', 'Legal', 'in_progress',
     'automation_centre', 'd1111111-1111-1111-1111-111111111111',
     v_me, now()),
    -- NOT automation work: must never appear in the queue. `work_management`
    -- is the only other value the source CHECK constraint allows.
    ('b2222222-2222-2222-2222-222222222222',
     'HR issued task', 'Human Resources', 'assigned',
     'work_management', null,
     v_me, now()),
    -- automation work, but assigned to someone else
    ('b3333333-3333-3333-3333-333333333333',
     'Someone elses automation work', 'Legal', 'assigned',
     'automation_centre', 'd1111111-1111-1111-1111-111111111111',
     v_other, now());

  -- 1. my automation task is returned
  raise notice '%', case when exists (
      select 1 from jsonb_array_elements(
        public.get_my_automation_work() -> 'tasks') t
     where t ->> 'title' = 'Automation register work'
  ) then 'PASS' else 'FAIL: own automation task missing' end;

  -- 2. a NON-automation task is excluded
  raise notice '%', case when not exists (
      select 1 from jsonb_array_elements(
        public.get_my_automation_work() -> 'tasks') t
     where t ->> 'title' = 'HR issued task'
  ) then 'PASS' else 'FAIL: an HR task leaked into the automation queue' end;

  -- 3. another person's task is excluded
  raise notice '%', case when not exists (
      select 1 from jsonb_array_elements(
        public.get_my_automation_work() -> 'tasks') t
     where t ->> 'title' = 'Someone elses automation work'
  ) then 'PASS' else 'FAIL: someone elses task leaked' end;

  -- 4. unreported progress is NULL rather than an invented 0%
  raise notice '%', case when jsonb_typeof(
      (select t -> 'progress_pct'
         from jsonb_array_elements(
           public.get_my_automation_work() -> 'tasks') t
        where t ->> 'title' = 'Automation register work'
        limit 1)) = 'null'
    then 'PASS' else 'FAIL: unreported progress was invented as a number' end;

  delete from public.work_tasks
   where id in ('b1111111-1111-1111-1111-111111111111',
                'b2222222-2222-2222-2222-222222222222',
                'b3333333-3333-3333-3333-333333333333');
end
$$;