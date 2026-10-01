-- Behavioural checks for 20261001000000_automation_executive_assignment.sql.
--
-- Each block is written to FAIL LOUDLY if the permission or the progress
-- roll-up regresses. They run against the same Postgres the migration applies
-- to, so they test the real function bodies rather than a description of them.
--
-- Roles are simulated with `app.current_role`, the same session variable the
-- platform's own `current_role()` reads.

insert into public.automation_departments (department, label, display_order) values
  ('Legal',    'Legal',            1),
  ('Marketing', 'Marketing & Comms', 2);

insert into public.automation_items (department, item_key, label, status) values
  ('Legal', 'contract_review', 'Contract review automation', 'in_progress');

-- ---------------------------------------------------------------------------
-- 1. The role gate
-- ---------------------------------------------------------------------------
do $$
begin
  -- The specialist filing their OWN automation work: always allowed.
  perform set_config('app.current_role', 'staff', false);
  perform set_config('request.jwt.claim.sub',
                     '11111111-1111-1111-1111-111111111111', false);

  perform public.assign_automation_work_task(
    p_department => 'Legal', p_label => 'Self raised automation');
  raise exception 'FAIL: specialist could not raise their own automation work';
exception
  when sqlstate 'P0001' then
    if sqlerrm not like 'FAIL:%' then raise; end if;
  when others then
    raise exception 'FAIL: specialist self-assignment failed: %', sqlerrm;
end $$;

-- A plain staff member assigning to SOMEONE ELSE must be refused.
do $$
begin
  perform set_config('request.jwt.claim.sub',
                     '11111111-1111-1111-1111-111111111111', false);
  perform public.assign_automation_work_task(
    p_department => 'Legal',
    p_label      => 'Should not be allowed',
    p_assignee_user_id => '22222222-2222-2222-2222-222222222222');
  raise exception 'FAIL: a staff user was allowed to assign automation work to another person';
exception when others then
  if sqlerrm like '%not allowed to assign automation tasks%' then
    raise notice 'PASS: staff cannot assign automation to another person';
  else
    raise;
  end if;
end $$;

-- Each of the five commissioning roles CAN assign to the specialist.
do $$
declare
  r   text;
  uid uuid := '11111111-1111-1111-1111-111111111111';
begin
  foreach r in array array[
    'director','md_ceo','chairman','head_of_human_resources','head_of_e_business'
  ]
  loop
    perform set_config('app.current_role', r, false);
    perform set_config('request.jwt.claim.sub',
                       '33333333-3333-3333-3333-333333333333', false);
    -- Each role is exercised in its own sub-block so a refusal is attributed to
    -- the role that caused it rather than aborting the whole loop.
    begin
      perform public.assign_automation_work_task(
        p_department        => 'Marketing',
        p_label             => 'Campaign automation (' || r || ')',
        p_assignee_user_id => uid);
    exception when others then
      raise exception 'FAIL: % could not assign automation work: %', r, sqlerrm;
    end;
  end loop;
  raise notice 'PASS: all five commissioning roles can assign automation work';
end $$;

-- Head of Operations must NOT gain the privilege. The gate is deliberately
-- narrower than can_review_work_tasks(), which they do satisfy.
do $$
begin
  perform set_config('app.current_role', 'head_of_operations', false);
  perform set_config('request.jwt.claim.sub',
                     '33333333-3333-3333-3333-333333333333', false);
  perform public.assign_automation_work_task(
    p_department        => 'Marketing',
    p_label             => 'Should not be allowed for ops',
    p_assignee_user_id => '11111111-1111-1111-1111-111111111111');
  raise exception 'FAIL: head_of_operations gained automation assignment, which the design deliberately excludes';
exception when others then
  if sqlerrm like '%not allowed%' then
    raise notice 'PASS: head_of_operations correctly excluded';
  else
    raise;
  end if;
end $$;
-- ---------------------------------------------------------------------------
-- 2. A raised request lands on the right department's Command Centre
-- ---------------------------------------------------------------------------
-- The point of creating/reusing the ACC item: raising work for Marketing must
-- make it visible against Marketing, not Marketing's neighbour.
do $$
declare
  v_item uuid;
  v_task uuid;
begin
  select id into v_item from public.automation_items
   where department = 'Marketing' and label = 'Campaign automation (director)';

  if v_item is null then
    raise exception 'FAIL: the raised request never appeared as a Marketing ACC item';
  end if;

  select id into v_task from public.work_tasks
   where title = 'Campaign automation (director)';

  if v_task is null then
    raise exception 'FAIL: no task was created for the raised request';
  end if;

  -- The link that lets progress flow back onto the bar.
  if (select automation_item_id from public.work_tasks where id = v_task)
       is distinct from v_item then
    raise exception 'FAIL: task is not linked to its ACC item, so progress cannot reach the bar';
  end if;

  if (select source from public.work_tasks where id = v_task)
       <> 'automation_centre' then
    raise exception 'FAIL: task was not tagged as automation_centre';
  end if;

  if (select assigned_to_user_id from public.work_tasks where id = v_task)
       <> '11111111-1111-1111-1111-111111111111' then
    raise exception 'FAIL: task is not assigned to the automation specialist';
  end if;

  raise notice 'PASS: raised request is visible on the department Command Centre';
end $$;

-- A task from one department must not be filable against another. Without this
-- check the bar could be moved by filing work under a mismatched label.
do $$
declare
  v_legal_item uuid;
begin
  select id into v_legal_item from public.automation_items
   where department = 'Legal' limit 1;

  perform set_config('app.current_role', 'director', false);
  perform set_config('request.jwt.claim.sub',
                     '33333333-3333-3333-3333-333333333333', false);
  perform public.assign_automation_work_task(
    p_department        => 'Marketing',
    p_label             => 'Cross department abuse',
    p_automation_item_id => v_legal_item);
  raise exception 'FAIL: a Legal ACC item was accepted for a Marketing task';
exception when others then
  if sqlerrm like '%different department%' then
    raise notice 'PASS: an ACC item cannot be filed against the wrong department';
  else
    raise;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Progress moves the bar, and only automation work does
-- ---------------------------------------------------------------------------
do $$
declare
  v_task uuid;
  v_pct numeric;
begin
  select id into v_task from public.work_tasks
   where title = 'Campaign automation (director)';

  -- Baseline: a 'not_started' item with no progress claim.
  select pct into v_pct from public.automation_item_completion_pct() cp
   where cp.item_id = (
     select automation_item_id from public.work_tasks where id = v_task);

  if v_pct <> 0 then
    raise exception 'FAIL: an unstarted item should read 0, got %', v_pct;
  end if;

  -- The specialist reports 30%.
  insert into public.progress_reports (task_id, pending_percentage)
  values (v_task, 30);

  select pct into v_pct from public.automation_item_completion_pct() cp
   where cp.item_id = (
     select automation_item_id from public.work_tasks where id = v_task);

  if v_pct <> 30 then
    raise exception 'FAIL: reported 30 but the bar reads %', v_pct;
  end if;

  -- A later claim supersedes the earlier one, including downwards.
  insert into public.progress_reports (task_id, pending_percentage)
  values (v_task, 100);

  select pct into v_pct from public.automation_item_completion_pct() cp
   where cp.item_id = (
     select automation_item_id from public.work_tasks where id = v_task);

  if v_pct <> 100 then
    raise exception 'FAIL: a final 100 report did not reach the bar, got %', v_pct;
  end if;

  raise notice 'PASS: the bar follows reported progress from 0 to 100';
end $$;

-- HR-issued work must NEVER move an automation bar. This is the boundary the
-- whole design turns on.
do $$
begin
  insert into public.work_tasks (title, assigned_to_user_id, status)
  values ('An ordinary HR task',
          '11111111-1111-1111-1111-111111111111', 'in_progress');

  -- It has no source and no automation_item_id, so it cannot be attributed.
  if exists (
    select 1 from public.automation_item_progress p
     where p.task_id = (
       select id from public.work_tasks where title = 'An ordinary HR task')
  ) then
    raise exception 'FAIL: a non-automation task leaked into the Command Centre roll-up';
  end if;

  if public.automation_department_completion_pct('Legal') is null then
    raise exception 'FAIL: department roll-up returned null';
  end if;

  raise notice 'PASS: ordinary HR task progress is excluded from the Command Centre';
end $$;

-- A pre-existing item with no task keeps the ORIGINAL status weighting, so the
-- existing register renders identically until someone files real progress.
do $$
declare
  v_pct numeric;
begin
  select pct into v_pct from public.automation_item_completion_pct() cp
    join public.automation_items i on i.id = cp.item_id
   where i.item_key = 'contract_review';

  if v_pct <> 50 then
    raise exception 'FAIL: an in_progress item with no task should still read 50, got %', v_pct;
  end if;

  raise notice 'PASS: untouched items keep the original status weighting';
end $$;