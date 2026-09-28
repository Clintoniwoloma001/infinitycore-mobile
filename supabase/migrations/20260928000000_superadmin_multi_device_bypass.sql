-- ===========================================================================
-- Super-admin multi-device sign-in
-- ===========================================================================
-- Every other account is locked to ONE active device by the partial unique
-- index `uq_mobile_device_sessions_one_active`. That is the real control: it
-- lives in the database, so it holds no matter what the mobile app believes.
--
-- This migration carves out a single named Super Admin so they can be signed
-- in on several devices at once (owner's working account: phone + tablet).
-- Two deliberate properties:
--
--  1. THE CHECK IS SERVER-SIDE AND ROLE-BACKED. The allowlist is matched
--     against auth.users.email - the authoritative identity - and the account
--     must ALSO hold the super_admin role. It is deliberately NOT hardcoded in
--     the Flutter app: a value shipped in an APK is readable by anyone who
--     unzips it, and a client-side check enforces nothing because it can be
--     patched out. Here it is enforced by the index, so it actually binds.
--
--  2. ONLY THAT ONE ACCOUNT. Every other super admin, and every other role,
--     keeps the existing one-device-at-a-time behaviour untouched.
--
-- The identifier below is matched against the email LOCAL PART, because the
-- value supplied for the allowlist entry was not a complete address. If the
-- real auth email is tamunosikiiwolomaclinton@gmail.com, the local part is
-- tamunosikiiwolomaclinton and the match fires. If the address is literally
-- the bare string, the match also fires. Correct this one value if the
-- intended account is different - everything else keys off the same string.
-- ===========================================================================

begin;

-- 1. Flag carried on the row so the one-active-device index can exempt it.
alter table public.mobile_device_sessions
  add column if not exists multi_device boolean not null default false;

comment on column public.mobile_device_sessions.multi_device is
  'True for the allow-listed super admin, who may hold several active device '
  'sessions. Set by mobile_device_register from a server-side role check; '
  'never from client input.';

-- 2. Rebase the one-active-device guarantee. The allow-listed account is not
--    constrained; every other account is, exactly as before. A partial unique
--    index cannot have its predicate altered in place, so it is recreated.
drop index if exists public.uq_mobile_device_sessions_one_active;

create unique index if not exists uq_mobile_device_sessions_one_active
  on public.mobile_device_sessions (user_id)
  where is_active = true and multi_device = false;

-- 3. Registration, rebuilt on the CURRENT six-argument definition from
--    20260922000012. The behaviour that blocks a second device is preserved
--    exactly for everybody else; only the allow-listed account skips it.
create or replace function public.mobile_device_register(
  p_device_id text,
  p_device_model text default null,
  p_os_version text default null,
  p_app_version text default null,
  p_biometric_capability text default 'none',
  p_platform text default 'mobile'
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_session_id uuid;
  v_employee_id uuid;
  v_existing record;
  v_multi boolean := false;
begin
  if auth.uid() is null then raise exception 'Not authenticated.'; end if;
  if coalesce(p_device_id, '') = '' then
    raise exception 'MOBILE_SESSION:Missing device identity.';
  end if;

  select id into v_employee_id
    from public.employees
   where user_id = auth.uid()
     and coalesce(is_archived, false) = false
   order by created_at desc
   limit 1;

  -- Server-side allowlist, evaluated on the AUTHORITATIVE identity:
  -- auth.users.email (not anything the client sent) AND the super_admin role.
  -- Requiring both means granting a second device is a deliberate,
  -- role-gated decision that no other account can opt into.
  select exists (
           select 1
             from auth.users u
             join public.profiles p on p.id = u.id
            where u.id = auth.uid()
              and lower(split_part(coalesce(u.email, ''), '@', 1))
                  = 'tamunosikiiwolomaclinton'
              and lower(coalesce(p.role, '')) = 'super_admin'
         ) into v_multi;

  -- Enforce one active mobile device per user. Do not silently replace.
  -- Skipped only for the allow-listed account, which is the entire point.
  if not v_multi then
    select * into v_existing
      from public.mobile_device_sessions
     where user_id = auth.uid()
       and is_active = true
       and device_id is distinct from p_device_id
     limit 1;

    if found then
      perform public.mobile_audit_log(
        'MOBILE_UNAUTHORIZED_DEVICE',
        'MobileDeviceSession',
        v_existing.id::text,
        format('Attempt to register device %s while %s is already active for user %s',
               p_device_id, v_existing.device_id, auth.uid()),
        'warning'
      );
      raise exception 'MOBILE_UNAUTHORIZED_DEVICE:This account is already linked to another mobile device. Please contact HR or Super Admin to authorize this device.';
    end if;
  end if;

  -- Re-registering the SAME device must refresh that row rather than stack
  -- duplicates. The allow-listed account is not covered by the unique index,
  -- so this cannot be left to ON CONFLICT.
  update public.mobile_device_sessions
     set employee_id = v_employee_id,
         device_model = coalesce(p_device_model, device_model),
         os_version = coalesce(p_os_version, os_version),
         app_version = coalesce(p_app_version, app_version),
         platform = coalesce(nullif(p_platform, ''), platform),
         biometric_capability = coalesce(p_biometric_capability, biometric_capability),
         multi_device = v_multi,
         last_seen_at = clock_timestamp(),
         status = 'active',
         is_active = true
   where user_id = auth.uid()
     and device_id = p_device_id
  returning id into v_session_id;

  if v_session_id is null then
    insert into mobile_device_sessions (
      user_id, employee_id, device_id, device_model, os_version,
      app_version, platform, biometric_capability, status, is_active,
      multi_device
    )
    values (
      auth.uid(), v_employee_id, p_device_id, p_device_model, p_os_version,
      p_app_version, coalesce(nullif(p_platform, ''), 'mobile'),
      p_biometric_capability, 'active', true, v_multi
    )
    returning id into v_session_id;
  end if;

  perform public.mobile_audit_log(
    'MOBILE_DEVICE_LINKED',
    'MobileDeviceSession',
    v_session_id::text,
    format('Device %s registered for user %s (platform %s, multi_device=%s)',
           p_device_id, auth.uid(), coalesce(p_platform, 'mobile'), v_multi),
    'info'
  );

  return jsonb_build_object(
    'ok', true,
    'session_id', v_session_id,
    'employee_id', v_employee_id,
    'device_id', p_device_id,
    'multi_device', v_multi,
    'reason', case when v_multi then 'multi_device_allowed' else 'registered' end
  );
end;
$$;

-- The inference predicate must match the new index exactly.
grant execute on function public.mobile_device_register(text,text,text,text,text,text) to authenticated;
revoke execute on function public.mobile_device_register(text,text,text,text,text,text) from anon, public;

commit;
