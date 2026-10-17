-- Push notifications: a queue the database fills from mission, payment and
-- session triggers (next migration) and send-fcm drains. Rows double as the
-- in-app inbox. Re-runnable.
--
--   insert (enqueue_notification) -> AFTER INSERT trigger -> pg_net
--     -> send-fcm { notification_id } -> claim_notification -> FCM
--   pg_cron retries what did not go out and expires stale alerts.
--
-- Delivery goes through pg_net, which only sends once the transaction that
-- queued the request commits, so a rolled-back status change never pushes.

-- 1. The queue / inbox.
create table if not exists public.notifications (
  id                   uuid primary key default gen_random_uuid(),
  recipient_profile_id uuid not null
    references public.profiles (id) on delete cascade,
  recipient_user_id    uuid not null
    references public.users (id) on delete cascade,
  type                 text not null,
  mission_id           uuid references public.missions (id) on delete cascade,
  -- Facts the template needs (names, address, amount…). Values are strings,
  -- as FCM data payloads require.
  data                 jsonb not null default '{}'::jsonb,
  -- Rendered by send-fcm, kept for the inbox.
  title                text,
  body                 text,
  -- One push per event, however many times the trigger or webhook fires.
  dedupe_key           text not null,
  --   pending  queued, not yet attempted
  --   sending  claimed by a send-fcm call
  --   sent     accepted by FCM
  --   failed   retryable error, the cron job tries again
  --   skipped  will never be sent (no token, dead token, expired, gave up)
  status               text not null default 'pending',
  attempts             integer not null default 0,
  last_error           text,
  fcm_message_id       text,
  read_at              timestamptz,
  created_at           timestamptz not null default now(),
  attempted_at         timestamptz,
  sent_at              timestamptz,
  constraint notifications_status_check check (
    status in ('pending', 'sending', 'sent', 'failed', 'skipped')
  ),
  constraint notifications_dedupe_key_key unique (dedupe_key)
);

create index if not exists notifications_recipient_idx
  on public.notifications (recipient_user_id, created_at desc);

create index if not exists notifications_undelivered_idx
  on public.notifications (created_at)
  where status in ('pending', 'sending', 'failed');

-- 2. Access: users read their own rows and may only mark them read.
--    Rows are only ever written by the definer functions below.
alter table public.notifications enable row level security;

revoke all on public.notifications from anon, authenticated;
grant select on public.notifications to authenticated;
grant update (read_at) on public.notifications to authenticated;

drop policy if exists notifications_select_own on public.notifications;
create policy notifications_select_own on public.notifications
  for select to authenticated
  using (recipient_user_id = auth.uid());

drop policy if exists notifications_update_own on public.notifications;
create policy notifications_update_own on public.notifications
  for update to authenticated
  using (recipient_user_id = auth.uid())
  with check (recipient_user_id = auth.uid());

-- Realtime lets an open app show the notification without waiting for FCM.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public' and tablename = 'notifications'
     ) then
    alter publication supabase_realtime add table public.notifications;
  end if;
end $$;

-- 3. The LiveKit webhook stamps this when the scout connects; the sessions
--    trigger turns that into the SCOUT_LIVE push.
alter table public.sessions
  add column if not exists host_joined_at timestamptz;

-- 4. Hand a notification to send-fcm. Same transport as expire_live_rooms.
create or replace function public.dispatch_notification(p_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_url text;
  v_key text;
begin
  select decrypted_secret into v_url
  from vault.decrypted_secrets
  where name = 'app_supabase_url';

  select decrypted_secret into v_key
  from vault.decrypted_secrets
  where name = 'service_api_key';

  if v_url is null or v_key is null then
    raise warning 'dispatch_notification: vault secrets missing, % stays queued', p_id;
    return;
  end if;

  perform net.http_post(
    url     := v_url || '/functions/v1/send-fcm',
    headers := jsonb_build_object(
                 'Content-Type',  'application/json',
                 'Authorization', 'Bearer ' || v_key
               ),
    body    := jsonb_build_object('notification_id', p_id),
    timeout_milliseconds := 10000
  );
end;
$$;

create or replace function public.notifications_dispatch_on_insert()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  perform public.dispatch_notification(new.id);
  return new;
exception when others then
  -- The cron job picks it up; never fail the insert over delivery.
  raise warning 'dispatch of notification % failed: %', new.id, sqlerrm;
  return new;
end;
$$;

drop trigger if exists trg_dispatch_notification on public.notifications;
create trigger trg_dispatch_notification
  after insert on public.notifications
  for each row execute function public.notifications_dispatch_on_insert();

-- 5. Queue a notification. Called from triggers, so it must never raise:
--    a push is not worth rolling back an accept or a payment for.
create or replace function public.enqueue_notification(
  p_profile_id uuid,
  p_type       text,
  p_mission_id uuid,
  p_data       jsonb,
  p_dedupe_key text
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_user_id uuid;
begin
  if p_profile_id is null then
    return;
  end if;

  select user_id into v_user_id
  from public.profiles
  where id = p_profile_id;

  if v_user_id is null then
    raise warning 'enqueue_notification: no profile %', p_profile_id;
    return;
  end if;

  insert into public.notifications (
    recipient_profile_id, recipient_user_id, type, mission_id, data, dedupe_key
  )
  values (
    p_profile_id, v_user_id, p_type, p_mission_id,
    coalesce(p_data, '{}'::jsonb), p_dedupe_key
  )
  on conflict (dedupe_key) do nothing;
exception when others then
  raise warning 'enqueue_notification(%, %) failed: %',
    p_type, p_dedupe_key, sqlerrm;
end;
$$;

-- 6. Claim a notification for sending. Atomic, so the insert-time call and a
--    cron retry can never both send it. A 'sending' row whose send-fcm call
--    died is reclaimable after 2 minutes.
create or replace function public.claim_notification(p_id uuid)
returns setof public.notifications
language sql
security definer
set search_path to 'public'
as $$
  update public.notifications
  set status       = 'sending',
      attempts     = attempts + 1,
      attempted_at = now()
  where id = p_id
    and attempts < 5
    and (
      status in ('pending', 'failed')
      or (status = 'sending' and attempted_at < now() - interval '2 minutes')
    )
  returning *;
$$;

-- 7. Retry and expiry, run every minute by pg_cron.
create or replace function public.retry_notifications()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_id    uuid;
  v_count integer := 0;
begin
  -- A late "join now" or "on the way" is worse than none.
  update public.notifications
  set status     = 'skipped',
      last_error = coalesce(last_error || '; ', '') || 'expired'
  where status in ('pending', 'sending', 'failed')
    and created_at < now() - case type
          when 'SCOUT_LIVE'      then interval '5 minutes'
          when 'MISSION_ENROUTE' then interval '30 minutes'
          else interval '6 hours'
        end;

  update public.notifications
  set status     = 'skipped',
      last_error = coalesce(last_error || '; ', '') || 'gave up after 5 attempts'
  where status in ('pending', 'sending', 'failed')
    and attempts >= 5;

  for v_id in
    select id
    from public.notifications
    where (
        status in ('pending', 'failed')
        or (status = 'sending' and attempted_at < now() - interval '2 minutes')
      )
      and coalesce(attempted_at, created_at) < now() - interval '30 seconds'
    order by created_at
    limit 100
  loop
    perform public.dispatch_notification(v_id);
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- Definer functions are callable over the API by default; these are internal.
revoke execute on function public.dispatch_notification(uuid)
  from public, anon, authenticated;
revoke execute on function public.notifications_dispatch_on_insert()
  from public, anon, authenticated;
revoke execute on function public.enqueue_notification(uuid, text, uuid, jsonb, text)
  from public, anon, authenticated;
revoke execute on function public.claim_notification(uuid)
  from public, anon, authenticated;
revoke execute on function public.retry_notifications()
  from public, anon, authenticated;
grant execute on function public.claim_notification(uuid) to service_role;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'retry-notifications') then
    perform cron.unschedule('retry-notifications');
  end if;
  perform cron.schedule(
    'retry-notifications',
    '* * * * *',
    ' SELECT public.retry_notifications(); '
  );
end $$;
