-- Ratings: only a mission's client and guide can rate, and only each other.
-- Re-runnable.
--
-- The insert policy only checked that the caller had some profile. The app
-- sent the scout as the recipient on both rating pages, so a guide rating
-- their client rated themselves: set_rating_from_user_id picks the author as
-- the profile opposite the recipient's role, which was the guide's own client
-- profile, and no_self_rating (profile ids) let it through.
--
-- The check runs after BEFORE triggers, so from_profile_id is the author
-- set_rating_from_user_id derived from the JWT. The mission status is not
-- checked: the guide rates while the session is still ending.
-- pg_cron penalty ratings insert as the table owner and bypass RLS.

create or replace function public.can_rate_on_mission(
  p_mission_id uuid,
  p_from_profile_id uuid,
  p_to_profile_id uuid
)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select exists (
    select 1
    from missions m
    join profiles me on me.id = p_from_profile_id
    where m.id = p_mission_id
      and me.user_id = auth.uid()
      and (
        (p_from_profile_id = m.client_id and p_to_profile_id = m.scout_id)
        or (p_from_profile_id = m.scout_id and p_to_profile_id = m.client_id)
      )
  );
$function$;

revoke all on function public.can_rate_on_mission(uuid, uuid, uuid)
  from public, anon;
grant execute on function public.can_rate_on_mission(uuid, uuid, uuid)
  to authenticated;

drop policy if exists "Enable insert for users based on user_id"
  on public.ratings;
drop policy if exists ratings_insert_mission_participants on public.ratings;
create policy ratings_insert_mission_participants
  on public.ratings
  for insert
  to authenticated
  with check (
    public.can_rate_on_mission(mission_id, from_profile_id, to_profile_id)
  );
