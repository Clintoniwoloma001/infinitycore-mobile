-- Minimal stand-ins for the helpers the migration calls.
--
-- The `auth` schema stub is needed because `progress_reports.submitted_by`
-- defaults to `auth.uid()`, a Supabase-owned function. Production has it; this
-- harness does not, so it is declared here rather than weakening the column
-- default that production relies on.
create schema if not exists auth;

create or replace function auth.uid() returns uuid
  language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;

create or replace function public.current_role() returns text
  language sql stable as $$ select coalesce(nullif(current_setting('app.current_role', true), ''), 'staff') $$;

create or replace function public.can_review_work_tasks() returns boolean
  language sql stable as $$ select false $$;

-- Minimal stand-in for the production schema, used ONLY to execute-parse
-- 20261001000000_automation_executive_assignment.sql in CI. It reproduces the
-- columns and constraints the migration actually touches, so a typo, a missing
-- column or a broken plpgsql body fails here rather than in production.
create table if not exists public.automation_departments (
  department    text primary key,
  label         text not null,
  description   text,
  is_configurable boolean not null default true,
  display_order integer not null default 0
);

create table if not exists public.automation_items (
  id          uuid primary key default gen_random_uuid(),
  department  text not null references public.automation_departments(department),
  item_key    text not null,
  label       text not null,
  description text,
  status      text not null default 'not_started'
    check (status in ('not_started','in_progress','live')),
  updated_by  uuid,
  updated_at  timestamptz not null default now(),
  unique (department, item_key)
);

create table if not exists public.work_tasks (
  id                  uuid primary key default gen_random_uuid(),
  title               text not null,
  description         text,
  assigned_to_user_id uuid,
  employee_id         uuid,
  department          text,
  branch              text,
  priority            text not null default 'medium',
  start_date          date,
  due_date            date,
  sla_review_hours    integer not null default 48,
  task_weight         numeric not null default 1,
  requires_evidence   boolean not null default false,
  assigned_by         uuid,
  status              text not null default 'not_started',
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create table if not exists public.work_task_steps (
  id       uuid primary key default gen_random_uuid(),
  task_id  uuid not null references public.work_tasks(id) on delete cascade,
  step_no  integer not null,
  title    text not null,
  weight   numeric not null default 1
);

create table if not exists public.progress_reports (
  id                  uuid primary key default gen_random_uuid(),
  task_id             uuid not null references public.work_tasks(id) on delete cascade,
  submitted_by        uuid not null default auth.uid(),
  pending_percentage  numeric not null default 0
    check (pending_percentage >= 0 and pending_percentage <= 100),
  summary_comment     text,
  status              text not null default 'pending_review',
  created_at          timestamptz not null default now()
);
