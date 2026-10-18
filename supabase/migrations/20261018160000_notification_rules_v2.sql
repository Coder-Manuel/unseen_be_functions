-- Notification rules v2. Re-runnable.
--
--   LIVE_REQUEST_CREATED  scout   live request inserted as requested
--   MISSION_REQUEST_PAID  scout   inbound payment -> success on an accepted live request
--   REQUEST_CANCELLED     scout   payment window ran out
--   PAYMENT_EXPIRED       client  payment window ran out
--   MISSION_DECLINED      client  live request declined; refund_due says whether it was paid
--
-- A scout dropping a live request always ends in 'declined'; a dropped pool
-- mission goes back to 'open'. Older app builds still send their own direct
-- updates, which guard_mission_update rewrites to the same outcome.

alter table public.users
  add column if not exists notifications_enabled boolean not null default true;

drop function if exists public.me();
create function public.me()
returns table(
  id uuid, email text, phone text, is_online boolean,
  status public.user_status, default_role public.role_type,
  notifications_enabled boolean,
  created_at timestamp with time zone, updated_at timestamp with time zone,
  profiles json
)
language plpgsql
security definer
as $function$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  return query
  select
    u.id,
    u.email,
    u.phone,
    u.is_online,
    u.status,
    u.default_role,
    u.notifications_enabled,
    u.created_at,
    u.updated_at,
    json_agg(
    json_build_object(
      'id',               p.id,
      'role',             p.role,
      'first_name',       p.first_name,
      'last_name',        p.last_name,
      'avatar_url',       p.avatar_url,
      'bio',              p.bio,
      'tags',             p.tags,
      'rating',           p.rating,
      'total_reviews',    p.total_reviews,
      'is_verified',      p.is_verified,
      'locality_address', p.locality_address,
      'locality_geo',     p.locality_geo,
      'session_pricing',  p.session_pricing,
      'availability',     p.availability,
      'status',           p.status,
      'profile_clips',
        coalesce(
          (
            select json_agg(
              json_build_object(
                'id', pc.id,
                'title', pc.title,
                'url', pc.url
              )
              order by pc.created_at
            )
            from public.profile_clips pc
            where pc.profile_id = p.id
          ),
          '[]'::json
        )
    )
    order by p.role
  ) as profiles
  from public.users u
  left join public.profiles p on p.user_id = u.id
  where u.id = auth.uid()
  group by u.id, u.email, u.phone, u.is_online, u.status, u.default_role,
           u.notifications_enabled, u.created_at, u.updated_at;
end;
$function$;

revoke execute on function public.me() from public, anon;
grant execute on function public.me() to authenticated, service_role;

insert into public.app_config (key, value, description)
values (
  'live_request_payment',
  '{"minutes": 30}'::jsonb,
  'Minutes a client has to pay after a guide accepts a live request'
)
on conflict (key) do nothing;

create or replace function public.live_request_payment_window()
returns interval
language sql
stable
security definer
set search_path to 'public'
as $$
  select make_interval(mins => coalesce(
    (select (value ->> 'minutes')::int
     from public.app_config
     where key = 'live_request_payment'),
    30
  ));
$$;

create or replace function public.mission_push_data(
  p_mission  public.missions,
  p_scout_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'scout_name',      coalesce(public.profile_display_name(p_scout_id), ''),
    'client_name',     coalesce(public.profile_display_name(p_mission.client_id), ''),
    'mission_type',    coalesce(p_mission.type, ''),
    'address',         coalesce(p_mission.address, ''),
    'amount',          p_mission.price::text,
    'currency',        p_mission.currency,
    'duration_in_sec', p_mission.duration_in_sec::text,
    'scheduled_at',    coalesce(p_mission.scheduled_at::text, '')
  );
$$;

create or replace function public.guard_mission_update()
returns trigger
language plpgsql
set search_path to 'public'
as $$
declare
  v_changed      text[];
  v_live_request boolean := old.type is not distinct from 'live_request';
begin
  if current_user <> 'authenticated' then
    return new;
  end if;

  select coalesce(array_agg(n.key), '{}')
    into v_changed
  from jsonb_each(to_jsonb(new)) n
  where n.key <> 'updated_at'
    and n.value is distinct from (to_jsonb(old) -> n.key);

  if old.scout_id is not null
     and public.owns_profile(old.scout_id)
     and not public.owns_profile(old.client_id) then
    -- Older builds: live request "back to requested" -> declined.
    if v_changed <@ array['status', 'accepted_at']
       and v_live_request
       and old.status in ('accepted', 'enroute')
       and new.status = 'requested'
       and new.accepted_at is null then
      new.status      := 'declined';
      new.accepted_at := old.accepted_at;
      return new;
    end if;

    -- Older builds: pool mission "cancelled" -> back to open.
    if v_changed <@ array['status', 'scout_id', 'accepted_at']
       and not v_live_request
       and old.status in ('accepted', 'enroute')
       and new.status = 'cancelled'
       and new.scout_id is null
       and new.accepted_at is null then
      new.status := 'open';
      return new;
    end if;

    if not (
      v_changed = '{}'
      or (
        v_changed <@ array['status']
        and old.status = 'accepted' and new.status = 'enroute'
      )
      or (
        v_changed <@ array['status']
        and v_live_request
        and old.status in ('requested', 'accepted', 'enroute')
        and new.status = 'declined'
      )
    ) then
      raise exception
        'Scouts can only mark an accepted mission enroute or drop a mission'
        using errcode = '42501';
    end if;
    return new;
  end if;

  if new.status is distinct from old.status
     and new.status in ('accepted', 'enroute', 'declined') then
    raise exception 'Mission status % can only be set by its scout', new.status
      using errcode = '42501';
  end if;

  return new;
end;
$$;

-- Same as before, except an expired (cancelled) live request can no longer
-- be accepted.
create or replace function public.accept_mission(p_mission_id uuid)
returns boolean
language plpgsql
security definer
as $function$
declare
  v_scout_profile_id uuid;
  v_mission_status   public.mission_status;
  v_mission_scout_id uuid;
  v_mission_type     text;
begin
  if auth.uid() is null then
    raise exception 'User not authenticated'
      using errcode = '28000';
  end if;

  select id into v_scout_profile_id
  from public.profiles
  where user_id = auth.uid()
    and role    = 'scout'::public.role_type
    and status  = 'active'::public.user_status;

  if not found then
    raise exception 'No active scout profile found for uid %', auth.uid()
      using errcode = 'P0002';
  end if;

  if exists (
    select 1
    from public.missions
    where scout_id = v_scout_profile_id
      and status in ('accepted'::public.mission_status,
                     'live'::public.mission_status,
                     'enroute'::public.mission_status)
  ) then
    raise exception 'Scout % already has an active mission', v_scout_profile_id
      using errcode = 'P0001';
  end if;

  select status, scout_id, type
    into v_mission_status, v_mission_scout_id, v_mission_type
  from public.missions
  where id = p_mission_id
  for update;

  if not found then
    raise exception 'Mission % not found', p_mission_id
      using errcode = 'P0002';
  end if;

  if v_mission_status not in (
       'open'::public.mission_status,
       'requested'::public.mission_status,
       'cancelled'::public.mission_status
     )
     or (
       v_mission_status = 'cancelled'::public.mission_status
       and v_mission_type is not distinct from 'live_request'
     ) then
    raise exception 'Mission % is no longer available (status: %)',
      p_mission_id, v_mission_status
      using errcode = 'P0001';
  end if;

  if v_mission_status = 'requested'::public.mission_status
     and v_mission_scout_id is distinct from v_scout_profile_id then
    raise exception 'Request % is assigned to another scout', p_mission_id
      using errcode = 'P0001';
  end if;

  update public.missions
  set scout_id    = v_scout_profile_id,
      status      = 'accepted'::public.mission_status,
      accepted_at = now()
  where id = p_mission_id;

  return true;
end;
$function$;

-- Same as before; the 'declined' scout event now comes from the status
-- trigger so the older-build path logs it too.
create or replace function public.decline_mission(p_mission_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_scout_profile_id uuid;
  v_status           public.mission_status;
  v_scout_id         uuid;
  v_type             text;
begin
  if auth.uid() is null then
    raise exception 'User not authenticated' using errcode = '28000';
  end if;

  select id into v_scout_profile_id
  from public.profiles
  where user_id = auth.uid()
    and role    = 'scout'::public.role_type
    and status  = 'active'::public.user_status;

  if not found then
    raise exception 'No active scout profile found for uid %', auth.uid()
      using errcode = 'P0002';
  end if;

  select status, scout_id, type
    into v_status, v_scout_id, v_type
  from public.missions
  where id = p_mission_id
  for update;

  if not found then
    raise exception 'Mission % not found', p_mission_id
      using errcode = 'P0002';
  end if;

  if v_scout_id is distinct from v_scout_profile_id then
    raise exception 'Mission % is not assigned to you', p_mission_id
      using errcode = 'P0001';
  end if;

  if v_type = 'live_request'
     and v_status in ('requested', 'accepted', 'enroute') then
    update public.missions
    set status = 'declined'::public.mission_status
    where id = p_mission_id;
    return 'declined';
  end if;

  if v_type is distinct from 'live_request'
     and v_status in ('accepted', 'enroute') then
    update public.missions
    set status      = 'open'::public.mission_status,
        scout_id    = null,
        accepted_at = null
    where id = p_mission_id;
    return 'released';
  end if;

  raise exception 'Mission % cannot be declined (status: %)',
    p_mission_id, v_status
    using errcode = 'P0001';
end;
$$;

create or replace function public.notify_mission_status_change()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_scout_id uuid := coalesce(new.scout_id, old.scout_id);
  v_data     jsonb;
begin
  if new.status is not distinct from old.status then
    return new;
  end if;

  v_data := public.mission_push_data(new, v_scout_id);

  if new.status = 'accepted' then
    if new.type is not distinct from 'live_request' and new.published_at is null then
      v_data := v_data || jsonb_build_object(
        'payment_window_min',
        (extract(epoch from public.live_request_payment_window()) / 60)::int::text
      );
    end if;
    perform public.enqueue_notification(
      new.client_id, 'MISSION_ACCEPTED', new.id, v_data,
      format('accepted:%s:%s:%s', new.id, new.scout_id,
             extract(epoch from coalesce(new.accepted_at, now()))::bigint)
    );

  elsif new.status = 'enroute' and old.status = 'accepted' then
    perform public.enqueue_notification(
      new.client_id, 'MISSION_ENROUTE', new.id, v_data,
      format('enroute:%s:%s:%s', new.id, new.scout_id,
             extract(epoch from coalesce(new.accepted_at, now()))::bigint)
    );

  elsif new.status = 'declined' then
    if v_scout_id is not null then
      insert into public.mission_scout_events (scout_profile_id, mission_id, type)
      values (v_scout_id, new.id, 'declined');
    end if;

    v_data := v_data || jsonb_build_object(
      'refund_due',
      (exists (
        select 1 from public.payments
        where mission_id = new.id
          and type = 'inbound'
          and status = 'success'
      ))::text
    );
    perform public.enqueue_notification(
      new.client_id, 'MISSION_DECLINED', new.id, v_data,
      format('declined:%s', new.id)
    );

  elsif new.status = 'open'
        and old.status in ('accepted', 'enroute')
        and old.scout_id is not null then
    perform public.enqueue_notification(
      new.client_id, 'MISSION_RELEASED', new.id, v_data,
      format('released:%s:%s:%s', new.id, old.scout_id,
             extract(epoch from coalesce(old.accepted_at, now()))::bigint)
    );
  end if;

  return new;
end;
$$;

create or replace function public.notify_request_paid()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_mission public.missions%rowtype;
begin
  if new.type <> 'inbound'
     or new.status <> 'success'
     or (tg_op = 'UPDATE' and old.status = 'success') then
    return new;
  end if;

  select * into v_mission
  from public.missions
  where id = new.mission_id;

  if not found
     or v_mission.type is distinct from 'live_request'
     or v_mission.status not in ('accepted', 'enroute')
     or v_mission.scout_id is null then
    return new;
  end if;

  perform public.enqueue_notification(
    v_mission.scout_id, 'MISSION_REQUEST_PAID', v_mission.id,
    public.mission_push_data(v_mission, v_mission.scout_id)
      || jsonb_build_object('amount', new.amount::text, 'currency', new.currency),
    format('paid:%s', new.id)
  );

  return new;
end;
$$;

create or replace function public.notify_live_request_created()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if new.type is distinct from 'live_request'
     or new.status <> 'requested'
     or new.scout_id is null then
    return new;
  end if;

  perform public.enqueue_notification(
    new.scout_id, 'LIVE_REQUEST_CREATED', new.id,
    public.mission_push_data(new, new.scout_id),
    format('live_request:%s', new.id)
  );

  return new;
end;
$$;

drop trigger if exists trg_notify_live_request_created on public.missions;
create trigger trg_notify_live_request_created
  after insert on public.missions
  for each row execute function public.notify_live_request_created();

-- An in-flight payment holds off expiry for up to 10 minutes so a client is
-- never charged for a request that was cancelled under them.
create or replace function public.expire_unpaid_live_requests()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_mission public.missions%rowtype;
  v_data    jsonb;
  v_key     text;
  v_count   integer := 0;
begin
  for v_mission in
    select m.*
    from public.missions m
    where m.type = 'live_request'
      and m.status = 'accepted'
      and m.published_at is null
      and m.accepted_at < now() - public.live_request_payment_window()
      and not exists (
        select 1 from public.payments p
        where p.mission_id = m.id
          and p.type = 'inbound'
          and p.status in ('pending', 'processing')
          and p.updated_at > now() - interval '10 minutes'
      )
    for update of m skip locked
  loop
    update public.missions
    set status = 'cancelled'::public.mission_status
    where id = v_mission.id;

    v_data := public.mission_push_data(v_mission, v_mission.scout_id);
    v_key  := format('%s:%s', v_mission.id,
                     extract(epoch from v_mission.accepted_at)::bigint);

    perform public.enqueue_notification(
      v_mission.client_id, 'PAYMENT_EXPIRED', v_mission.id, v_data,
      'payment_expired:' || v_key
    );
    perform public.enqueue_notification(
      v_mission.scout_id, 'REQUEST_CANCELLED', v_mission.id, v_data,
      'request_cancelled:' || v_key
    );

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'expire-unpaid-live-requests') then
    perform cron.unschedule('expire-unpaid-live-requests');
  end if;
  perform cron.schedule(
    'expire-unpaid-live-requests',
    '* * * * *',
    ' SELECT public.expire_unpaid_live_requests(); '
  );
end $$;

revoke execute on function public.live_request_payment_window()
  from public, anon, authenticated;
revoke execute on function public.mission_push_data(public.missions, uuid)
  from public, anon, authenticated;
revoke execute on function public.notify_live_request_created()
  from public, anon, authenticated;
revoke execute on function public.expire_unpaid_live_requests()
  from public, anon, authenticated;
