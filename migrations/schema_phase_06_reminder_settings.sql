-- ---------------------------------------------------------------------------
-- Phase 06 — clock-in / clock-out reminder settings (HR-configurable).
--
-- Server stores only the HR-configured times; the mobile client turns them
-- into repeating local notifications (no FCM credentials exist in the
-- project, so delivery is client-side scheduled notificiations).
-- ---------------------------------------------------------------------------

create table if not exists public.app_settings (
  key text primary key,
  value text not null default '',
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

create or replace function public.mobile_reminder_settings_get()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  return jsonb_build_object(
    'clock_in_time', coalesce((select value from public.app_settings where key = 'reminder.clock_in_time'), '08:00'),
    'clock_out_time', coalesce((select value from public.app_settings where key = 'reminder.clock_out_time'), '18:00'),
    'grace_minutes', coalesce((select value from public.app_settings where key = 'reminder.grace_minutes'), '30')::int,
    'enabled', coalesce((select value from public.app_settings where key = 'reminder.enabled'), 'true') = 'true'
  );
end;
$$;

create or replace function public.mobile_reminder_settings_set(
  p_clock_in_time text,
  p_clock_out_time text,
  p_grace_minutes integer default 30,
  p_enabled boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated.';
  end if;

  if public.current_role() not in ('super_admin', 'admin', 'head_of_human_resources', 'branch_manager') then
    raise exception 'Not authorized to configure attendance reminder settings.';
  end if;

  if p_clock_in_time is null or p_clock_in_time !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
    raise exception 'INVALID_TIME:clock-in time must be in HH:MM 24h format.';
  end if;
  if p_clock_out_time is null or p_clock_out_time !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
    raise exception 'INVALID_TIME:clock-out time must be in HH:MM 24h format.';
  end if;
  if p_grace_minutes is null or p_grace_minutes < 0 or p_grace_minutes > 180 then
    raise exception 'INVALID_TIME:grace minutes must be between 0 and 180.';
  end if;

  insert into public.app_settings(key, value, updated_at, updated_by) values
    ('reminder.clock_in_time', p_clock_in_time, now(), auth.uid()),
    ('reminder.clock_out_time', p_clock_out_time, now(), auth.uid()),
    ('reminder.grace_minutes', p_grace_minutes::text, now(), auth.uid()),
    ('reminder.enabled', p_enabled::text, now(), auth.uid())
  on conflict (key) do update
    set value = excluded.value, updated_at = excluded.updated_at, updated_by = excluded.updated_by;

  return public.mobile_reminder_settings_get();
end;
$$;

grant execute on function public.mobile_reminder_settings_get() to authenticated;
grant execute on function public.mobile_reminder_settings_set(text, text, integer, boolean) to authenticated;