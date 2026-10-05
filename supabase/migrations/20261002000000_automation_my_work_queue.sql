begin;

-- ===========================================================================
-- Automation Command Centre — the specialist's own work queue
--
-- WHY
-- The ACC shows PORTFOLIO percentages for every department, but an executive
-- commissioning automation work, and the automation specialist carrying it out,
-- had nowhere on mobile to see what had actually been assigned to them. The
-- tasks already existed in `work_tasks` with `source = 'automation_centre'`;
-- they simply had no reader scoped to the signed-in person.
--
-- SCOPE (the important part)
-- Only `source = 'automation_centre'` tasks are returned. This is the same rule
-- `automation_item_progress` already applies, and it is what stops the Command
-- Centre from turning into a general task list: HR-issued tasks, targets and
-- every other team's work are excluded, so the queue stays the automation
-- specialist's own KPI surface.
--
-- READ ONLY
-- This function grants no writes. Assignment is `assign_automation_work_task`
-- and status reporting is the progress-report path; neither is widened here.
-- ===========================================================================

create or replace function public.get_my_automation_work()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_rows jsonb;
begin
  if v_uid is null then
    return jsonb_build_object(
      'ok', false,
      'message', 'Not signed in.'
    );
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by
           case when x.due_date is null then 1 else 0 end,
           x.due_date asc,
           x.created_at desc), '[]')
    into v_rows
    from (
      select wt.id,
             wt.title,
             wt.description,
             wt.department,
             wt.status,
             wt.priority,
             wt.automation_item_id,
             wt.assigned_to_user_id,
             wt.due_date,
             wt.created_at,
             wt.updated_at,
             -- Latest REPORTED progress, not a status guess. Null when nobody
             -- has reported, so the UI can say "not reported" rather than 0%.
             (select pr.pending_percentage
                from public.progress_reports pr
               where pr.task_id = wt.id
               order by pr.created_at desc
               limit 1) as progress_pct,
             (select pr.status
                from public.progress_reports pr
               where pr.task_id = wt.id
               order by pr.created_at desc
               limit 1) as report_status,
             (select pr.created_at
                from public.progress_reports pr
               where pr.task_id = wt.id
               order by pr.created_at desc
               limit 1) as reported_at
        from public.work_tasks wt
       where wt.assigned_to_user_id = v_uid
         -- `automation_item_id` is the linkage assign_automation_work_task
         -- writes, and requiring it is what keeps this the automation
         -- specialist's queue rather than a general task list: a task with no
         -- ACC item behind it is not automation work, whoever raised it.
         and coalesce(wt.source, '') = 'automation_centre'
         and wt.automation_item_id is not null
    ) x;

  return jsonb_build_object('ok', true, 'tasks', v_rows);
end;
$$;

comment on function public.get_my_automation_work() is
  'Automation-sourced tasks assigned to the signed-in person. Read only. Scoped to source = ''automation_centre'' so the Command Centre stays the automation specialist queue and never becomes a cross-team task list.';

revoke all on function public.get_my_automation_work() from public;
grant execute on function public.get_my_automation_work() to authenticated;

commit;
