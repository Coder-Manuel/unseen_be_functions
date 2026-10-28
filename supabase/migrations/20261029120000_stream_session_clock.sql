-- Server-owned stream clock and disconnect tracking (BUG-008). Re-runnable.
--
-- The apps used to count down from missions.duration_in_sec on every join, so
-- a viewer who rejoined got a fresh clock. The deadline is now read from the
-- server: started_at (stamped once, on the client's first join) plus the
-- scheduled duration, the same deadline expire_live_rooms enforces.
--
--   stream_clock(mission_id)  deadline + server time, for both participants
--   sessions.host_left_at     set by the participant_left webhook, cleared on
--   sessions.client_left_at   rejoin; null while that side is in the room
--   sessions.last_disconnect_reason

alter table public.sessions
  add column if not exists host_left_at timestamptz,
  add column if not exists client_left_at timestamptz,
  add column if not exists last_disconnect_reason text;

-- server_now lets the app correct for its own clock being off.
create or replace function public.stream_clock(p_mission_id uuid)
returns table (
  status text,
  started_at timestamptz,
  ends_at timestamptz,
  server_now timestamptz
)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select
    s.status::text,
    s.started_at,
    s.started_at + make_interval(secs => s.scheduled_duration_sec),
    now()
  from missions m
  join sessions s on s.mission_id = m.id
  where m.id = p_mission_id
    and exists (
      select 1
      from profiles p
      where p.user_id = auth.uid()
        and p.id in (m.client_id, m.scout_id)
    )
  limit 1;
$function$;

revoke all on function public.stream_clock(uuid) from public, anon;
grant execute on function public.stream_clock(uuid) to authenticated;
