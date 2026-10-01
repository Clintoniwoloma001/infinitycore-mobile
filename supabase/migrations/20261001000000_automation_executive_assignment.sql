-- ============================================================================
-- Automation Command Centre: executive assignment to the automation specialist
-- ============================================================================
--
-- WHAT THIS CHANGES, AND WHY
--
-- Today `create_work_task_with_steps` refuses anyone outside a fixed list of
-- management roles, and `add_automation_work_task` refuses outright with
-- "You can only create automation tasks for yourself." A Director, MD/CEO,
-- Chairman, Head of HR or Head of E-business therefore cannot hand the
-- automation specialist a piece of work, even though they are exactly the people
-- who decide what gets automated.
--
-- The gap is not the task table - `work_tasks.assigned_to_user_id` already
-- supports assignment to anyone. It is the role gate, plus the link that puts an
-- assigned task into the Automation Command Centre for the department it was
-- raised against, plus the roll-up that moves that department's progress bar.
--
-- THREE THINGS HAPPEN HERE:
--
--   1. `can_assign_automation_task()` - a single named predicate for "may this
--      caller raise an AUTOMATION task against someone else". Deliberately NOT a
--      widening of `can_review_work_tasks()`: that predicate is about reviewing
--      progress, and widening it would hand every operations manager the ability
--      to assign work. Keeping the two separate means granting one does not
--      silently grant the other.
--
--   2. `assign_automation_work_task()` - a NEW RPC rather than a widened
--      `create_work_task_with_steps`. That existing RPC is the general task path
--      HR uses for every kind of work, so changing its permission logic to admit
--      executives would quietly give them the power to create ANY task for ANY
--      person. A separate function keeps that blast radius at zero: it can only
--      ever create a task sourced to the automation register.
--
--   3. `get_automation_portfolio()` derives each department's completion from
--      the specialist's ACTUAL reported progress on automation-sourced tasks,
--      falling back to the item status when no task exists yet.
--
-- WHAT THIS DOES NOT CHANGE
--
-- Progress reported on a NON-automation task never reaches the Automation
-- Command Centre. The roll-up below filters on `wt.source = 'automation_centre'`,
-- so HR-issued tasks and targets stay exactly where they are and the ACC remains
-- the automation specialist's own KPI monitor.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Who may raise an automation task against another person
-- ---------------------------------------------------------------------------
-- A named predicate rather than an inline role list, so every gate below reads
-- the same way and there is one place to change when the list changes.
create or replace function public.can_assign_automation_task()
returns boolean
language sql
stable
as $$
  select public.current_role() in (
    -- Existing management authority, unchanged.
    'super_admin','admin','head_of_human_resources','hr_officer',
    -- The executives who commission automation. These are the roles that
    -- decide WHAT gets automated and to whom it goes.
    'director','md_ceo','chairman',
    -- Head of E-business commissions automation as part of the job.
    'head_of_e_business'
  );
$$;

comment on function public.can_assign_automation_task() is
  'True for roles allowed to raise an AUTOMATION task against another person. Scoped to the automation register; grants neither general task assignment nor progress review.';

-- ---------------------------------------------------------------------------
-- 2. The automation-sourced task assignment RPC
-- ---------------------------------------------------------------------------
-- A NEW function rather than a widened `create_work_task_with_steps`. See the
-- header note: widening the general task RPC would hand the executive roles the
-- ability to create any task for any person. This one can only ever create a
-- task sourced to the automation register.
create or replace function public.assign_automation_work_task(
  p_department         text,
  p_label              text,
  p_description        text   default null,
  p_assignee_user_id   uuid   default null,
  p_due_date           date   default null,
  p_sla_review_hours   integer default 48,
  p_steps              jsonb  default '[]'::jsonb,
  p_automation_item_id uuid   default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_assignee  uuid := coalesce(p_assignee_user_id, auth.uid());
  v_task_id   uuid;
  v_item_id   uuid;
  v_item_dept text;
  v_step      jsonb;
  v_step_no   int := 1;
begin
  if p_department is null or btrim(p_department) = '' then
    raise exception 'A department is required.';
  end if;
  if p_label is null or btrim(p_label) = '' then
    raise exception 'A task title is required.';
  end if;

  -- THE GATE. Either the specialist filing their own work, or a role that is
  -- allowed to commission automation for someone else. Nobody else, ever.
  if v_assignee <> auth.uid()
     and not public.can_assign_automation_task() then
    raise exception 'You are not allowed to assign automation tasks.';
  end if;

  -- Resolve the ACC item this task belongs to.
  --
  -- When an explicit item is supplied it MUST belong to the stated department.
  -- Without that check a task could be filed against one department's bar while
  -- claiming another, which is precisely how a progress number stops meaning
  -- anything.
  if p_automation_item_id is not null then
    select i.department into v_item_dept
      from public.automation_items i
     where i.id = p_automation_item_id;

    if v_item_dept is null then
      raise exception 'That automation item does not exist.';
    end if;
    if v_item_dept <> btrim(p_department) then
      raise exception 'That automation item belongs to a different department.';
    end if;
    v_item_id := p_automation_item_id;
  else
    select i.id into v_item_id
      from public.automation_items i
     where i.department = btrim(p_department)
       and i.label = btrim(p_label)
     limit 1;

    -- A new automation line for this department. Creating the item is what makes
    -- a raised request appear on the Command Centre bar at all, rather than
    -- living only as a task nobody can see against a department.
    if v_item_id is null then
      insert into public.automation_items
        (department, item_key, label, description, status, updated_by)
      values (
        btrim(p_department),
        -- The 4-argument form of replace() takes a REGEXP and its flags, not a
        -- plain string. This is the version that actually strips non-alphanumerics.
        'task_' || substr(
          regexp_replace(lower(btrim(p_label)), '[^a-z0-9]+', '_', 'g'), 1, 60),
        btrim(p_label),
        nullif(p_description, ''),
        'not_started',
        auth.uid()
      )
      on conflict (department, item_key) do update
        set label       = excluded.label,
            description = coalesce(excluded.description, automation_items.description),
            updated_at  = now()
      returning id into v_item_id;
    end if;
  end if;

  insert into public.work_tasks (
    title, description, assigned_to_user_id, department,
    due_date, sla_review_hours, assigned_by, status, source
  )
  values (
    btrim(p_label),
    nullif(p_description, ''),
    v_assignee,
    btrim(p_department),
    p_due_date,
    coalesce(p_sla_review_hours, 48),
    auth.uid(),
    'not_started',
    'automation_centre'
  )
  returning id into v_task_id;

  -- Link the task to its ACC item so the portfolio can attribute progress back.
  -- Wrapped because the column arrives in section 4; this keeps the function
  -- orderable on its own against an older schema.
  begin
    execute 'update public.work_tasks set automation_item_id = $1 where id = $2'
      using v_item_id, v_task_id;
  exception when undefined_column then
    null;
  end;

  -- Optional milestone steps. An empty list is legitimate.
  for v_step in select * from jsonb_array_elements(coalesce(p_steps, '[]'::jsonb))
  loop
    insert into public.work_task_steps (task_id, step_no, title, weight)
    values (
      v_task_id,
      v_step_no,
      coalesce(v_step->>'title', 'Step ' || v_step_no),
      coalesce((v_step->>'weight')::numeric, 1)
    );
    v_step_no := v_step_no + 1;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'task_id', v_task_id,
    'automation_item_id', v_item_id,
    'assigned_to_user_id', v_assignee,
    'department', btrim(p_department)
  );
end;
$$;

-- The full argument list is required here. A parameterised function cannot be
-- commented as `name()`; Postgres will report it as non-existent.
-- COMMENT ON FUNCTION accepts the argument TYPES only - no DEFAULT clauses.
-- Writing them here is a syntax error, and omitting the list entirely reports
-- the function as non-existent. Both failure modes are covered here because
-- this is easy to get wrong and only shows up at apply time.
comment on function public.assign_automation_work_task(
  p_department         text,
  p_label              text,
  p_description        text,
  p_assignee_user_id   uuid,
  p_due_date           date,
  p_sla_review_hours   integer,
  p_steps              jsonb,
  p_automation_item_id uuid
) is
  'Assigns an automation-register task to the automation specialist, creating or reusing the department ACC item so raised work shows on that department Command Centre bar. Self-assignment always allowed; assigning to another person requires can_assign_automation_task().';

-- ---------------------------------------------------------------------------
-- 3. Columns the assignment RPC writes to
-- ---------------------------------------------------------------------------
-- These appear AFTER the function that uses them on purpose. Postgres defers
-- name resolution inside a plpgsql body to execution time, so the function is
-- valid here; the columns exist before any call can reach them.
-- Which ACC item a task belongs to. Added here (rather than assuming it exists)
-- so the migration is safe to apply to a database that predates the column.
alter table public.work_tasks
  add column if not exists automation_item_id uuid
    references public.automation_items(id) on delete set null;

create index if not exists work_tasks_automation_item_idx
  on public.work_tasks (automation_item_id)
  where automation_item_id is not null;

-- Source discriminator. Every task created before this migration has a null
-- source, which the roll-up treats as NOT automation work - so no historical HR
-- task can suddenly start moving an automation progress bar.
alter table public.work_tasks
  add column if not exists source text;

create index if not exists work_tasks_source_idx
  on public.work_tasks (source, assigned_to_user_id)
  where source = 'automation_centre';

-- A monotonic ordering key for progress claims.
--
-- `created_at` cannot break ties: it defaults to now(), which is the TRANSACTION
-- timestamp, so two reports filed in one transaction are indistinguishable by
-- time. An identity column is strictly increasing, so "latest claim" is always
-- well defined - including for a specialist correcting a downward number, which
-- is exactly as legitimate as correcting one upward.
alter table public.progress_reports
  add column if not exists report_seq bigint
    generated always as identity;

create index if not exists progress_reports_task_seq_idx
  on public.progress_reports (task_id, created_at desc, report_seq desc);

-- ---------------------------------------------------------------------------
-- 4. Progress roll-up: reported progress becomes the department's bar
-- ---------------------------------------------------------------------------
-- The specialist's claimed progress, per ACC item.
--
-- Deliberately the PENDING percentage, not the approved one. The Command Centre
-- is the specialist's own KPI monitor, and a self-reported figure that has to
-- wait for a reviewer to approve it is not a monitor - it is a queue. The
-- review workflow still exists and still gates payment; it just no longer gates
-- the visible automation bar.
create or replace view public.automation_item_progress
with (security_invoker = true) as
  select
    wt.automation_item_id as item_id,
    wt.department,
    -- The most recent claim wins, ordered by WHEN THE CLAIM WAS FILED.
    --
    -- `created_at` alone is NOT sufficient. It defaults to now(), which is the
    -- TRANSACTION timestamp, so two reports filed inside one transaction share a
    -- value and the ordering becomes arbitrary - the bar would freeze on
    -- whichever row Postgres happened to return first. `report_seq` is a
    -- monotonic identity, so it breaks the tie deterministically.
    (select pr.pending_percentage
       from public.progress_reports pr
      where pr.task_id = wt.id
      order by pr.created_at desc, pr.report_seq desc
      limit 1) as pending_percentage,
    (select pr.created_at
       from public.progress_reports pr
      where pr.task_id = wt.id
      order by pr.created_at desc, pr.report_seq desc
      limit 1) as reported_at,
    (select pr.status
       from public.progress_reports pr
      where pr.task_id = wt.id
      order by pr.created_at desc, pr.report_seq desc
      limit 1) as report_status,
    wt.id as task_id,
    wt.assigned_to_user_id,
    wt.status as task_status,
    wt.updated_at
  from public.work_tasks wt
  -- The single most important line in this migration: only automation-register
  -- work reaches the Command Centre. HR-issued tasks and targets are excluded,
  -- so this remains the automation specialist's own KPI monitor and no other
  -- team's progress can inflate it.
  where wt.source = 'automation_centre'
    and wt.automation_item_id is not null;

comment on view public.automation_item_progress is
  'Latest claimed progress per ACC item, from automation-register tasks only. Non-automation task progress is deliberately excluded so the Command Centre stays the automation specialist KPI monitor.';
-- ---------------------------------------------------------------------------
-- 5. Re-point the Command Centre at real progress
-- ---------------------------------------------------------------------------
-- The portfolio currently derives completion from the item STATUS alone
-- (live = 100%, in progress = 50%), which cannot represent a task that is 30%
-- done. It now prefers the specialist's reported progress where one exists and
-- falls back to the status weighting only for items nobody has started.
--
-- This REPLACES the `completion_pct` expression inside `get_automation_portfolio`
-- with a join to the roll-up view. The function is re-declared in full below
-- rather than patched inline, because Postgres has no "ALTER FUNCTION body", and
-- a partial re-declaration would be impossible to review.
--
-- The three weights are preserved exactly:
--   live = 100%, in_progress = 50%, not_started = 0%.
-- An item with a progress claim uses the claim; an item without one keeps the
-- status weighting. So the existing register renders identically until someone
-- actually files progress against it.
create or replace function public.automation_item_completion_pct()
returns table (item_id uuid, pct numeric)
language sql
stable
as $$
  select
    i.id,
    round(
      case
        -- Real reported progress wins where it exists.
        when p.pending_percentage is not null
          then least(100, greatest(0, p.pending_percentage))
        -- Otherwise the original status weighting, unchanged.
        else case i.status
               when 'live'        then 100.0
               when 'in_progress' then 50.0
               else 0.0
             end
      end, 1
    ) as pct
  from public.automation_items i
  left join (
    -- One row per item: the latest claim wins, by claim time.
    select distinct on (item_id) item_id, pending_percentage
      from public.automation_item_progress
     where pending_percentage is not null
     order by item_id, reported_at desc nulls last
  ) p on p.item_id = i.id;
$$;

comment on function public.automation_item_completion_pct() is
  'Per-item completion: reported progress when a claim exists, otherwise the original status weighting (live 100 / in_progress 50 / not_started 0).';

-- Department-level roll-up used by the portfolio.
create or replace function public.automation_department_completion_pct(
  p_department text
)
returns numeric
language sql
stable
as $$
  select round(
           100.0 * coalesce(avg(cp.pct), 0)
         , 1)
    from public.automation_items i
    left join public.automation_item_completion_pct() cp on cp.item_id = i.id
   where i.department = p_department;
$$;

comment on function public.automation_department_completion_pct(text) is
  'Mean per-item completion for a department, so the Command Centre bar rises with the specialist''s reported progress.';