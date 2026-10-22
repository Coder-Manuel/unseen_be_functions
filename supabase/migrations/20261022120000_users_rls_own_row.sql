-- Users: each user may only read their own row. Re-runnable.
--
-- users_select_public was USING (true), so any signed-in user could read every
-- user's email, phone and push token. get_nearby_scouts handed out scouts'
-- phone and fcm_token too; it now returns neither. users_update_own is
-- unchanged.

drop policy if exists users_select_public on public.users;

drop policy if exists users_select_own on public.users;

create policy users_select_own on public.users for
select to authenticated using (id = auth.uid ());

-- The return type changes, so the function is dropped and recreated.
drop function if exists public.get_nearby_scouts(double precision, double precision, double precision);

create function public.get_nearby_scouts(
  lat double precision,
  lng double precision,
  radius_km double precision default 5.0
)
returns table (
  id uuid,
  first_name text,
  last_name text,
  rating numeric,
  total_reviews integer,
  tags text,
  avatar_url text,
  is_online boolean,
  created_at timestamptz,
  updated_at timestamptz,
  distance_meters double precision
)
language sql
stable
security definer
as $function$
  SELECT
    p.id,
    p.first_name,
    p.last_name,
    p.rating,
    p.total_reviews,
    p.tags,
    p.avatar_url,
    u.is_online,
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
$function$;

grant
execute on function public.get_nearby_scouts (
    double precision,
    double precision,
    double precision
) to anon,
authenticated,
service_role;