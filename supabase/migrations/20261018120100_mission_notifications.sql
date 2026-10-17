-- Mission push notifications: the triggers that queue them, decline_mission,
-- and the direct "enroute" update the scout app makes. Re-runnable.
-- Depends on 20261018120000_notifications.sql.
--
--   type                  to      when
--   MISSION_REQUEST_PAID  scout   inbound payment -> success on a requested live_request
--   MISSION_ACCEPTED      client  missions.status -> accepted
--   MISSION_ENROUTE       client  missions.status accepted -> enroute
--   MISSION_DECLINED      client  live_request -> declined (refund to follow)
--   MISSION_RELEASED      client  pool mission accepted/enroute -> open
--   SCOUT_LIVE            client  sessions.host_joined_at set before the client joined
--
-- Targeted requests are missions.type = 'live_request'. When their scout
-- declines they end in 'declined' and stay out of the pool; any other mission
-- a scout drops goes back to 'open'.
--
-- accept_mission, get_missions_within_radius and the rest of the mission
-- functions predate the migrations folder; the ones changed here are based on
-- their live definitions.

-- 1. Helpers.
create or replace function public.profile_display_name(p_profile_id uuid)
returns text
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(
    nullif(trim(concat_ws(' ', first_name, last_name)), ''),
    ''
  )
  from public.profiles
  where id = p_profile_id;
$$;

revoke execute on function public.profile_display_name(uuid)
  from public, anon, authenticated;

-- Whether the caller owns a profile. Definer, so policies and the guard
-- trigger below do not depend on the profiles RLS.
create or replace function public.owns_profile(p_profile_id uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select exists (
    select 1 from public.profiles
    where id = p_profile_id and user_id = auth.uid()
  );
$$;

revoke execute on function public.owns_profile(uuid) from public, anon;
grant execute on function public.owns_profile(uuid) to authenticated;

-- 2. Scouts update their assigned mission directly (accepted -> enroute).
--    The policy lets them reach the row; the guard trigger limits what they
--    may change.
drop policy if exists missions_select_assigned_scout on public.missions;
create policy missions_select_assigned_scout on public.missions
  for select to authenticated
  using (scout_id is not null and public.owns_profile(scout_id));

drop policy if exists missions_update_assigned_scout on public.missions;
create policy missions_update_assigned_scout on public.missions
  for update to authenticated
  using (scout_id is not null and public.owns_profile(scout_id))
  with check (scout_id is not null and public.owns_profile(scout_id));

-- Invoker on purpose: current_user is 'authenticated' for a direct API
-- update and the function owner inside accept_mission / decline_mission /
-- the cron functions, which do their own checks.
create or replace function public.guard_mission_update()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  if current_user <> 'authenticated' then
    return new;
  end if;

  -- The assigned scout may change the status only, and only like this:
  --   accepted -> enroute
  --   live_request requested/accepted/enroute -> declined (older app builds;
  --   new ones call decline_mission)
  if old.scout_id is not null
     and public.owns_profile(old.scout_id)
     and not public.owns_profile(old.client_id) then
    if (to_jsonb(new) - array['status', 'updated_at'])
         is distinct from (to_jsonb(old) - array['status', 'updated_at'])
       or not (
         (old.status = 'accepted' and new.status = 'enroute')
         or (
           old.type is not distinct from 'live_request'
           and old.status in ('requested', 'accepted', 'enroute')
           and new.status = 'declined'
         )
       ) then
      raise exception
        'Scouts can only mark an accepted mission enroute or decline a live request'
        using errcode = '42501';
    end if;
    return new;
  end if;

  -- These statuses send pushes, so nobody else may set them directly.
  if new.status is distinct from old.status
     and new.status in ('accepted', 'enroute', 'declined') then
    raise exception 'Mission status % can only be set by its scout', new.status
      using errcode = '42501';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_guard_mission_update on public.missions;
create trigger trg_guard_mission_update
  before update on public.missions
  for each row execute function public.guard_mission_update();

-- 3. Decline / drop a mission. Mirrors accept_mission.
--    Returns 'declined' (live_request, stays out of the pool) or 'released'
--    (pool mission, back to open).
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

    insert into public.mission_scout_events (scout_profile_id, mission_id, type)
    values (v_scout_profile_id, p_mission_id, 'declined');

    return 'declined';
  end if;

  if v_type is distinct from 'live_request'
     and v_status in ('accepted', 'enroute') then
    -- notify_scout_unassigned logs the 'unassigned' event.
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

revoke execute on function public.decline_mission(uuid) from public, anon;
grant execute on function public.decline_mission(uuid) to authenticated;

-- 4. Stale accepted missions: a live_request is declined (the client is
--    refunded) instead of being dropped into the pool. Otherwise unchanged.
create or replace function public.reclaim_stale_missions()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_count integer;
begin
  with stale as (
    -- Lock the rows we're about to reclaim; capture the ORIGINAL assignment.
    select id, scout_id, client_id, type
    from public.missions
    where status      = 'accepted'::public.mission_status
      and scout_id    is not null
      and accepted_at is not null
      and accepted_at < now() - interval '5 hours'
    for update skip locked
  ),
  reopened as (
    -- Pool missions go back to the open pool.
    update public.missions m
    set status      = 'open'::public.mission_status,
        scout_id    = null,
        accepted_at = null
    from stale
    where m.id = stale.id
      and stale.type is distinct from 'live_request'
    returning stale.scout_id as scout_id, stale.client_id as client_id
  ),
  declined as (
    -- Targeted requests never re-enter the pool.
    update public.missions m
    set status = 'declined'::public.mission_status
    from stale
    where m.id = stale.id
      and stale.type = 'live_request'
    returning stale.id as mission_id,
              stale.scout_id as scout_id,
              stale.client_id as client_id
  ),
  declined_events as (
    -- scout_id is kept, so notify_scout_unassigned does not fire; log the
    -- same event it would have.
    insert into public.mission_scout_events (scout_profile_id, mission_id, type)
    select scout_id, mission_id, 'unassigned'
    from declined
    returning 1
  ),
  penalties as (
    -- One-star the no-show scout, authored by the mission's client.
    -- mission_id left NULL; the ratings trigger recomputes the scout's aggregate.
    insert into public.ratings (from_profile_id, to_profile_id, score, comment)
    select client_id,
           scout_id,
           1,
           'Penalty: scout accepted but did not start the mission within 5 hours.'
    from (
      select scout_id, client_id from reopened
      union all
      select scout_id, client_id from declined
    ) r
    where client_id is not null   -- from_profile_id is NOT NULL
      and scout_id  is not null
    returning 1
  )
  select (select count(*) from reopened) + (select count(*) from declined)
    into v_count;

  return v_count;  -- number of missions reclaimed (handy in cron logs)
end;
$$;

-- 5. A scout who is enroute is busy too.
--    PostGIS lives in the extensions schema, which the migration runner's
--    search_path does not include, so its type and operator are qualified.
create or replace function public.get_nearby_scouts(
  lat double precision,
  lng double precision,
  radius_km double precision default 5.0
)
returns table(
  id uuid, first_name text, last_name text, phone text, rating numeric,
  total_reviews integer, tags text, avatar_url text, is_online boolean,
  fcm_token text, created_at timestamp with time zone,
  updated_at timestamp with time zone, distance_meters double precision
)
language sql
stable
security definer
as $$
  SELECT
    p.id,
    p.first_name,
    p.last_name,
    u.phone,
    p.rating,
    p.total_reviews,
    p.tags,
    p.avatar_url,
    u.is_online,
    u.fcm_token,
    p.created_at,
    p.updated_at,
    extensions.ST_Distance(
      p.location,
      extensions.ST_SetSRID(
        extensions.ST_MakePoint(lng, lat),
        4326
      )::extensions.geography
    ) AS distance_meters
  FROM public.profiles p
  JOIN public.users u ON u.id = p.user_id
  WHERE
    p.role         = 'scout'::public.role_type
    AND p.status       = 'active'::public.user_status
    AND u.is_online    = TRUE
    AND u.status       = 'active'::public.user_status
    AND p.location     IS NOT NULL
    AND extensions.ST_DWithin(
          p.location,
          extensions.ST_SetSRID(
            extensions.ST_MakePoint(lng, lat),
            4326
          )::extensions.geography,
          radius_km * 1000
        )
    AND NOT EXISTS (
      SELECT 1
      FROM public.missions m
      WHERE m.scout_id = p.id
        AND m.status IN (
              'accepted'::public.mission_status,
              'enroute'::public.mission_status,
              'live'::public.mission_status
            )
    )
  ORDER BY
    p.location OPERATOR(extensions.<->) (
      extensions.ST_SetSRID(
        extensions.ST_MakePoint(lng, lat),
        4326
      )::extensions.geography
    );
$$;

-- 6. Mission status pushes (all to the client).
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

  v_data := jsonb_build_object(
    'scout_name',      coalesce(public.profile_display_name(v_scout_id), ''),
    'mission_type',    coalesce(new.type, ''),
    'address',         coalesce(new.address, ''),
    'amount',          new.price::text,
    'currency',        new.currency,
    'duration_in_sec', new.duration_in_sec::text
  );

  if new.status = 'accepted' then
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

drop trigger if exists trg_notify_mission_status on public.missions;
create trigger trg_notify_mission_status
  after update of status on public.missions
  for each row execute function public.notify_mission_status_change();

-- 7. Paid targeted request -> its scout.
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
     or v_mission.status <> 'requested'
     or v_mission.scout_id is null then
    return new;
  end if;

  perform public.enqueue_notification(
    v_mission.scout_id, 'MISSION_REQUEST_PAID', v_mission.id,
    jsonb_build_object(
      'client_name',     coalesce(public.profile_display_name(v_mission.client_id), ''),
      'mission_type',    coalesce(v_mission.type, ''),
      'address',         coalesce(v_mission.address, ''),
      'amount',          new.amount::text,
      'currency',        new.currency,
      'duration_in_sec', v_mission.duration_in_sec::text,
      'scheduled_at',    coalesce(v_mission.scheduled_at::text, '')
    ),
    format('paid:%s', new.id)
  );

  return new;
end;
$$;

drop trigger if exists trg_notify_request_paid on public.payments;
create trigger trg_notify_request_paid
  after insert or update of status on public.payments
  for each row execute function public.notify_request_paid();

-- 8. Scout connected to the room and the client has not -> client.
create or replace function public.notify_scout_live()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_mission public.missions%rowtype;
begin
  if old.host_joined_at is not null
     or new.host_joined_at is null
     or new.status <> 'created' then
    return new;
  end if;

  select * into v_mission
  from public.missions
  where id = new.mission_id;

  if not found then
    return new;
  end if;

  perform public.enqueue_notification(
    v_mission.client_id, 'SCOUT_LIVE', v_mission.id,
    jsonb_build_object(
      'scout_name',      coalesce(public.profile_display_name(v_mission.scout_id), ''),
      'duration_in_sec', v_mission.duration_in_sec::text
    ),
    format('scout_live:%s', new.id)
  );

  return new;
end;
$$;

drop trigger if exists trg_notify_scout_live on public.sessions;
create trigger trg_notify_scout_live
  after update of host_joined_at on public.sessions
  for each row execute function public.notify_scout_live();

revoke execute on function public.notify_mission_status_change()
  from public, anon, authenticated;
revoke execute on function public.notify_request_paid()
  from public, anon, authenticated;
revoke execute on function public.notify_scout_live()
  from public, anon, authenticated;
