-- Scout mission pool: sorted, paged reads and pushed updates. Re-runnable.
--
--   search_missions             one page of the pool, sorted by distance,
--                               newest, pay or duration, capped at 60 km
--   mission_pool broadcast      added / updated / removed on the private
--                               `mission_pool` topic, so scouts patch their
--                               lists instead of re-querying on every
--                               missions write
--   get_missions_within_radius  kept for older app builds; now scout-only,
--                               capped at 60 km / 100 rows, not callable by
--                               anon
--
-- The pool is what scouts see today: published, status open or cancelled.

-- 1. Old builds. Same signature and columns as the live definition; adds the
--    scout check, the radius cap, the row limit and a pinned search_path.
create or replace function public.get_missions_within_radius(
  lat double precision,
  lng double precision,
  radius_m double precision default 5000.0
)
returns table (
  id uuid,
  client_profile_id uuid,
  scout_profile_id uuid,
  description text,
  currency text,
  price numeric,
  duration_in_sec integer,
  address text,
  location extensions.geography,
  status public.mission_status,
  created_at timestamptz,
  updated_at timestamptz,
  accepted_at timestamptz,
  completed_at timestamptz,
  published_at timestamptz,
  session_id uuid,
  type text,
  client json
)
language sql
stable
security definer
set search_path to 'public', 'extensions'
as $function$
  select
    m.id,
    m.client_id,
    m.scout_id,
    m.description,
    m.currency,
    m.price,
    m.duration_in_sec,
    m.address,
    m.location,
    m.status,
    m.created_at,
    m.updated_at,
    m.accepted_at,
    m.completed_at,
    m.published_at,
    m.session_id,
    m.type,
    json_build_object(
      'id',            p.id,
      'user_id',       p.user_id,
      'first_name',    p.first_name,
      'last_name',     p.last_name,
      'avatar_url',    p.avatar_url,
      'rating',        p.rating,
      'total_reviews', p.total_reviews
    ) as client
  from public.missions m
  join public.profiles p on p.id = m.client_id
  where public.is_scout()
    and m.status in ('open'::public.mission_status, 'cancelled'::public.mission_status)
    and m.published_at is not null
    and extensions.st_dwithin(
          m.location,
          extensions.st_setsrid(extensions.st_makepoint(lng, lat), 4326)::extensions.geography,
          least(radius_m, 60000)
        )
  order by m.location operator(extensions.<->) (
    extensions.st_setsrid(extensions.st_makepoint(lng, lat), 4326)::extensions.geography
  )
  limit 100;
$function$;

revoke
execute on function public.get_missions_within_radius (
    double precision,
    double precision,
    double precision
)
from public, anon;

grant
execute on function public.get_missions_within_radius (
    double precision,
    double precision,
    double precision
) to authenticated;

-- 2. The pool is a small slice of missions; a partial index keeps the radius
--    lookup off completed history as it grows.
create index if not exists idx_missions_pool_location on public.missions using gist (location)
where
    published_at is not null
    and status in (
        'open'::public.mission_status,
        'cancelled'::public.mission_status
    );

-- 3. One page of the pool.
--
--    Every sort is expressed as an ascending `sort_key` (newest and pay are
--    negated), ordered by (sort_key, id). The next page passes the last row's
--    sort_key and id as the cursor. total_count is the whole pool within the
--    radius, whatever the cursor.
--
--    p_usd_kes is the app's own USD -> KES rate; it only orders this caller's
--    list. Outside 50..500 it is ignored and USD prices sort unconverted.
create or replace function public.search_missions(
  p_lat double precision,
  p_lng double precision,
  p_sort text default 'distance',
  p_limit integer default 20,
  p_cursor_key double precision default null,
  p_cursor_id uuid default null,
  p_usd_kes numeric default null,
  p_radius_m double precision default 60000
)
returns table (
  id uuid,
  client_id uuid,
  description text,
  currency text,
  price numeric,
  pay_kes numeric,
  duration_in_sec integer,
  address text,
  lat double precision,
  lng double precision,
  status public.mission_status,
  type text,
  published_at timestamptz,
  created_at timestamptz,
  distance_m double precision,
  sort_key double precision,
  total_count bigint,
  client json
)
language plpgsql
stable
security definer
set search_path to 'public', 'extensions'
as $function$
#variable_conflict use_column
declare
  v_origin extensions.geography;
  v_radius double precision := least(greatest(coalesce(p_radius_m, 60000), 0), 60000);
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 50);
  v_rate numeric := case when p_usd_kes between 50 and 500 then p_usd_kes end;
begin
  if not public.is_scout() then
    raise exception 'Only active scouts can browse live checks'
      using errcode = '42501';
  end if;

  if p_lat is null or p_lng is null then
    raise exception 'p_lat and p_lng are required' using errcode = '22004';
  end if;

  if p_sort is null or p_sort not in ('distance', 'newest', 'pay_desc', 'duration_asc') then
    raise exception 'Unknown sort: %', p_sort using errcode = '22023';
  end if;

  v_origin := extensions.st_setsrid(
    extensions.st_makepoint(p_lng, p_lat), 4326
  )::extensions.geography;

  return query
  with pool as (
    select
      m.id,
      m.client_id,
      m.description,
      m.currency,
      m.price,
      case
        when upper(m.currency) = 'USD' and v_rate is not null then m.price * v_rate
        else m.price
      end as pay_kes,
      m.duration_in_sec,
      m.address,
      extensions.st_y(m.location::extensions.geometry) as lat,
      extensions.st_x(m.location::extensions.geometry) as lng,
      m.status,
      m.type,
      m.published_at,
      m.created_at,
      extensions.st_distance(m.location, v_origin) as distance_m
    from public.missions m
    where m.published_at is not null
      and m.status in ('open'::public.mission_status, 'cancelled'::public.mission_status)
      and extensions.st_dwithin(m.location, v_origin, v_radius)
  ),
  keyed as (
    select
      pool.*,
      case p_sort
        when 'distance' then pool.distance_m
        when 'newest' then -extract(epoch from pool.published_at)::double precision
        when 'pay_desc' then -pool.pay_kes::double precision
        else pool.duration_in_sec::double precision
      end as sort_key,
      count(*) over () as total_count
    from pool
  )
  select
    k.id,
    k.client_id,
    k.description,
    k.currency,
    k.price,
    k.pay_kes,
    k.duration_in_sec,
    k.address,
    k.lat,
    k.lng,
    k.status,
    k.type,
    k.published_at,
    k.created_at,
    k.distance_m,
    k.sort_key,
    k.total_count,
    json_build_object(
      'id',            p.id,
      'user_id',       p.user_id,
      'first_name',    p.first_name,
      'last_name',     p.last_name,
      'avatar_url',    p.avatar_url,
      'rating',        p.rating,
      'total_reviews', p.total_reviews
    ) as client
  from keyed k
  join public.profiles p on p.id = k.client_id
  where p_cursor_key is null
     or (k.sort_key, k.id) > (
          p_cursor_key,
          coalesce(p_cursor_id, '00000000-0000-0000-0000-000000000000'::uuid)
        )
  order by k.sort_key, k.id
  limit v_limit;
end;
$function$;

revoke
execute on function public.search_missions (
    double precision,
    double precision,
    text,
    integer,
    double precision,
    uuid,
    numeric,
    double precision
)
from public, anon;

grant
execute on function public.search_missions (
    double precision,
    double precision,
    text,
    integer,
    double precision,
    uuid,
    numeric,
    double precision
) to authenticated;

-- 4. Push pool changes. Payload is {id, lat, lng}; the app drops events
--    outside its radius and only refetches when something it shows changed.
--    A failed broadcast never blocks the mission write.
create or replace function public.broadcast_mission_pool_change()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare
  v_was boolean := false;
  v_is boolean := false;
  v_event text;
  v_id uuid;
  v_location extensions.geography;
begin
  if tg_op in ('UPDATE', 'DELETE') then
    v_was := old.published_at is not null
      and old.status in ('open'::public.mission_status, 'cancelled'::public.mission_status);
  end if;

  if tg_op in ('INSERT', 'UPDATE') then
    v_is := new.published_at is not null
      and new.status in ('open'::public.mission_status, 'cancelled'::public.mission_status);
  end if;

  if v_is and not v_was then
    v_event := 'added';
  elsif v_was and not v_is then
    v_event := 'removed';
  elsif v_is and v_was and (
    new.status, new.price, new.currency, new.duration_in_sec,
    new.address, new.description, new.type, new.location::text
  ) is distinct from (
    old.status, old.price, old.currency, old.duration_in_sec,
    old.address, old.description, old.type, old.location::text
  ) then
    v_event := 'updated';
  else
    return null;
  end if;

  if v_event = 'removed' then
    v_id := old.id;
    v_location := old.location;
  else
    v_id := new.id;
    v_location := new.location;
  end if;

  begin
    perform realtime.send(
      jsonb_build_object(
        'id',  v_id,
        'lat', extensions.st_y(v_location::extensions.geometry),
        'lng', extensions.st_x(v_location::extensions.geometry)
      ),
      v_event,
      'mission_pool',
      true
    );
  exception when others then
    raise warning 'mission_pool broadcast failed for %: %', v_id, sqlerrm;
  end;

  return null;
end;
$function$;

revoke
execute on function public.broadcast_mission_pool_change ()
from public, anon, authenticated;

drop trigger if exists trg_broadcast_mission_pool_change on public.missions;

create trigger trg_broadcast_mission_pool_change
  after insert or update or delete on public.missions
  for each row execute function public.broadcast_mission_pool_change();

-- 5. Only active scouts may join the private mission_pool topic.
drop policy if exists mission_pool_scouts_receive on realtime.messages;

create policy mission_pool_scouts_receive on realtime.messages for
select to authenticated using (
        (
            select realtime.topic ()
        ) = 'mission_pool'
        and realtime.messages.extension = 'broadcast'
        and public.is_scout ()
    );