-- ============================================================================
-- P0-A — fix "column b.name does not exist" (SQLSTATE 42703)
-- ============================================================================
-- SYMPTOM
--   Mobile: Menu > Branch Performance > tap a branch (e.g. "Head Office") >
--   the "<branch> · Attribution" screen failed with
--     PostgrestException(message: column b.name does not exist, code: 42703)
--
-- ROOT CAUSE
--   Two MPR RPCs read `branches.name`, but `public.branches` has never had a
--   `name` column — the column is `branch_name` (verified against
--   information_schema for the live database). The functions were written
--   against an assumed shape and only fail at runtime, because the reference
--   sits in a plpgsql SELECT ... INTO that is only reached when called.
--
-- SCOPE
--   * rpc_get_branch_drag_and_soaring_staff — the Attribution screen.
--   * rpc_get_staff_mpr_summary            — the same bug, same table, hit
--     from the employee MPR card. Found by scanning every function and view
--     for `b.name`; these two are the ONLY real occurrences.
--
-- SAFETY
--   CREATE OR REPLACE with the IDENTICAL signature, return shape and grants,
--   so no app change is needed and no caller is broken. Nothing else in either
--   function is touched: only the single `b.name` -> `b.branch_name` reference.
--   Idempotent — re-running it changes nothing.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Attribution screen — rpc_get_branch_drag_and_soaring_staff(uuid, text)
-- ----------------------------------------------------------------------------
create or replace function public.rpc_get_branch_drag_and_soaring_staff(
  p_branch_id uuid,
  p_period_label text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_branch_name text;
  v_headcount   integer;
  v_rows        jsonb;
  v_measured    integer;
begin
  if p_branch_id is null or p_period_label is null or p_period_label = '' then
    return jsonb_build_object('ok', false, 'message', 'branch_id and period_label are required');
  end if;

  -- FIX (was: select b.name): public.branches has `branch_name`, not `name`.
  select b.branch_name into v_branch_name from public.branches b where b.id = p_branch_id;
  if not found then
    return jsonb_build_object('ok', false, 'message', 'Branch not found');
  end if;

  select count(*) into v_headcount
    from public.employees e
   where e.branch_id = p_branch_id;

  -- Rank only fully-measured employees. compute_mpr_score() is the single
  -- source of truth for both the score and the `complete` flag.
  with scored as (
    select
      e.id,
      e.full_name,
      s as engine
    from public.employees e
    cross join lateral public.compute_mpr_score(e.id, p_period_label, p_branch_id) s
    where e.branch_id = p_branch_id
      and (s ->> 'complete')::boolean is true      -- <-- the honesty gate
  ),
  annotated as (
    select
      sc.id,
      sc.full_name,
      (sc.engine ->> 'total')::numeric                as total,
      (sc.engine ->> 'par_percent')::numeric          as par_percent,
      (sc.engine ->> 'at_risk_principal')::numeric    as at_risk_principal,
      (sc.engine ->> 'disbursement_score')::numeric   as disbursement_score,
      (sc.engine ->> 'par_score')::numeric            as par_score,
      (sc.engine ->> 'caseload_score')::numeric       as caseload_score,
      sc.engine ->> 'grade'                            as grade,
      sc.engine ->> 'grade_rating'                     as grade_rating,
      sc.engine ->> 'grade_hex'                        as grade_hex,
      sc.engine ->> 'badge'                            as badge,
      (select max(t.actual_value) from public.mpr_targets t
        where t.employee_id = sc.id and t.period_label = p_period_label
          and t.metric_code = 'pass_watch')           as pass_watch_principal,
      (select max(t.actual_value) from public.mpr_targets t
        where t.employee_id = sc.id and t.period_label = p_period_label
          and t.metric_code = 'disbursement_value')   as disbursement_actual,
      (select max(t.target_value) from public.mpr_targets t
        where t.employee_id = sc.id and t.period_label = p_period_label
          and t.metric_code = 'disbursement_value')   as disbursement_target,
      (select max(t.actual_value) from public.mpr_targets t
        where t.employee_id = sc.id and t.period_label = p_period_label
          and t.metric_code = 'case_load')            as caseload_actual
    from scored sc
  ),
  shares as (
    select
      a.*,
      case when sum(a.total) over () > 0
           then round((a.total / sum(a.total) over ()) * 100, 2)
           else null end                as share_of_branch_mpr_pct,
      count(*) over ()                  as measured_count
    from annotated a
  )
  select
    coalesce(
      jsonb_agg(to_jsonb(sh) - 'measured_count'
                order by sh.total asc nulls last),
      '[]'::jsonb
    ),
    coalesce(max(sh.measured_count), 0)
  into v_rows, v_measured
  from shares sh;

  return jsonb_build_object(
    'ok', true,
    'branch_id', p_branch_id,
    'branch_name', v_branch_name,
    'period_label', p_period_label,
    'headcount', v_headcount,
    'measured_count', v_measured,
    'coverage_pct', case when v_headcount > 0
      then round((v_measured::numeric / v_headcount) * 100, 1)
      else null end,
    'staff', v_rows
  );
end;
$$;

comment on function public.rpc_get_branch_drag_and_soaring_staff(uuid, text) is
  'Drag 5 / Soaring 5 attribution for one branch and period. Reads branches.branch_name (the b.name reference was SQLSTATE 42703 and broke the Attribution screen).';

-- ----------------------------------------------------------------------------
-- 2. Employee MPR card — rpc_get_staff_mpr_summary(uuid, text, uuid)
--    Same bug, same table. Only the single join predicate line changes.
-- ----------------------------------------------------------------------------
create or replace function public.rpc_get_staff_mpr_summary(
  p_employee_id uuid,
  p_period_label text,
  p_branch_id uuid default null   -- preserved: the live function has this default
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_emp     record;
  v_score   jsonb;
  v_bank_par numeric;
  v_as_at    date;
begin
  if p_employee_id is null or p_period_label is null or p_period_label = '' then
    return jsonb_build_object('ok', false, 'message', 'employee_id and period_label are required');
  end if;

  -- FIX (was: b.name as branch_name): the column is branch_name.
  select e.id, e.full_name, e.branch_id, b.branch_name as branch_name
    into v_emp
    from public.employees e
    left join public.branches b on b.id = e.branch_id
   where e.id = p_employee_id;

  if not found then
    return jsonb_build_object('ok', false, 'message', 'Employee not found');
  end if;

  -- The engine decides completeness. We never compute a total here.
  v_score := public.compute_mpr_score(p_employee_id, p_period_label, coalesce(p_branch_id, v_emp.branch_id));

  -- BANK-WIDE context from the newest PUBLISHED snapshot only. A pending or
  -- rejected batch must never surface as a performance figure.
  --
  -- SCOPE WARNING: public.bankone_portfolio_snapshots has NO branch_id column
  -- (verified against the DDL in 20260931000002 and every later migration) and
  -- no ALTER ever added one. It holds ORGANISATION-WIDE totals only. So this is
  -- the bank PAR benchmark, which is exactly the "<= 5.0% bank benchmark" the
  -- spec compares an employee against - and it can never be presented as a
  -- branch or employee figure.
  select s.par_ratio, s.as_at_date
    into v_bank_par, v_as_at
    from public.bankone_portfolio_snapshots s
   where s.status = 'published'
   order by s.as_at_date desc, s.published_at desc
   limit 1;

  return jsonb_build_object(
    'ok', true,
    'employee_id', v_emp.id,
    'employee_name', v_emp.full_name,
    'branch_id', v_emp.branch_id,
    'branch_name', v_emp.branch_name,
    'period_label', p_period_label,
    -- engine output, passed through verbatim
    'par_percent',       v_score -> 'par_percent',
    'at_risk_principal', v_score -> 'at_risk_principal',
    'disbursement_score',v_score -> 'disbursement_score',
    'par_score',         v_score -> 'par_score',
    'caseload_score',    v_score -> 'caseload_score',
    'subtotal',          v_score -> 'subtotal',
    'total',             v_score -> 'total',
    'grade',             v_score -> 'grade',
    'grade_rating',      v_score -> 'grade_rating',
    'grade_hex',         v_score -> 'grade_hex',
    'badge',             v_score -> 'badge',
    'complete',          v_score -> 'complete',
    'missing',           v_score -> 'missing',
    -- BANK-WIDE context, explicitly NOT the employee's or branch's own figure
    'bank_par_ratio',   v_bank_par,
    'bank_par_as_at',   v_as_at
  );
end;
$$;

comment on function public.rpc_get_staff_mpr_summary(uuid, text, uuid) is
  'One employee MPR summary for a period. Reads branches.branch_name (the b.name reference was SQLSTATE 42703).';
