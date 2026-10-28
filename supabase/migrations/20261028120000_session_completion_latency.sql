-- Finish expired live checks sooner. Re-runnable.
--
-- A live check is completed by: expire_live_rooms (live -> ending, deletes the
-- LiveKit room) -> room_finished webhook (ending -> ended, mission completed).
-- When the webhook never lands, cleanup_stuck_ending_sessions is the fallback.
-- At */2 and */5 with a 3 minute grace, a mission could stay `live` (and on
-- the guide's radar) for up to ~10 minutes after its time ran out.
--
--   expire-livekit-rooms           every minute (was every 2)
--   cleanup-stuck-ending-sessions  every minute, after 90 s in `ending`
--                                  (was every 5, after 3 minutes)
--
-- Also stops cleanup writing an epoch-sized actual_duration_sec when the
-- client never joined (started_at is null).

create or replace function public.cleanup_stuck_ending_sessions()
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  -- 1. Force sessions from ending -> ended
  with stuck as (
    update sessions
    set
      status              = 'ended',
      ended_at            = now(),
      actual_duration_sec = case
        when started_at is not null
          then extract(epoch from (now() - started_at))::int
      end,
      host_token          = null,
      client_token        = null,
      updated_at          = now()
    where status = 'ending'
      and updated_at < now() - interval '90 seconds'
    returning id
  )
  -- 2. Sync corresponding missions -> completed
  update missions
  set
    status       = 'completed',
    completed_at = now()
  where session_id in (select id from stuck)
    and status != 'completed';
end;
$function$;

select cron.schedule(
  'expire-livekit-rooms',
  '* * * * *',
  $$ SELECT public.expire_live_rooms(); $$
);

select cron.schedule(
  'cleanup-stuck-ending-sessions',
  '* * * * *',
  $$ SELECT public.cleanup_stuck_ending_sessions(); $$
);
