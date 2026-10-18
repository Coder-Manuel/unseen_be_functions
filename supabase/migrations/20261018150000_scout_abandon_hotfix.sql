-- Hotfix: let current app builds abandon a mission with their direct update
-- until they move to decline_mission. Re-runnable.
--
--   live_request accepted/enroute -> requested, accepted_at cleared
--   pool mission accepted/enroute -> cancelled, scout_id and accepted_at cleared
--
-- Also lets a scout repeat an update that changes nothing (enroute -> enroute).

create or replace function public.is_scout()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select exists (
    select 1 from public.profiles
    where user_id = auth.uid()
      and role = 'scout'::public.role_type
      and status = 'active'::public.user_status
  );
$$;

revoke execute on function public.is_scout() from public, anon;
grant execute on function public.is_scout() to authenticated;

-- The app reads the row back after abandoning (update ... select), and by
-- then scout_id is null. Scouts already see these rows through
-- get_missions_within_radius.
drop policy if exists missions_select_pool_for_scouts on public.missions;
create policy missions_select_pool_for_scouts on public.missions
  for select to authenticated
  using (
    scout_id is null
    and published_at is not null
    and status in ('open', 'cancelled')
    and public.is_scout()
  );

drop policy if exists missions_update_assigned_scout on public.missions;
create policy missions_update_assigned_scout on public.missions
  for update to authenticated
  using (scout_id is not null and public.owns_profile(scout_id))
  with check (scout_id is null or public.owns_profile(scout_id));

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
      or (
        v_changed <@ array['status', 'accepted_at']
        and v_live_request
        and old.status in ('accepted', 'enroute')
        and new.status = 'requested'
        and new.accepted_at is null
      )
      or (
        v_changed <@ array['status', 'scout_id', 'accepted_at']
        and not v_live_request
        and old.status in ('accepted', 'enroute')
        and new.status = 'cancelled'
        and new.scout_id is null
        and new.accepted_at is null
      )
    ) then
      raise exception
        'Scouts can only mark an accepted mission enroute, decline a live request or abandon a mission'
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
