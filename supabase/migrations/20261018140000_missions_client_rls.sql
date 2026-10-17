-- Missions: clients may only read and update their own missions. Re-runnable.
--
-- The client policies only checked that the caller had *a* client profile, so
-- every client could read and update every mission. They now check ownership
-- of the row, the same way the scout policies already do.
--
-- Inserts are unchanged: trg_set_mission_client_id forces client_id to the
-- caller's client profile, and trg_guard_mission_update still limits which
-- status changes an update may make.

drop policy if exists missions_select_own_client on public.missions;
create policy missions_select_own_client on public.missions
  for select to authenticated
  using (public.owns_profile(client_id));

-- WITH CHECK stops a client from handing a mission to another client.
drop policy if exists missions_update_own_client on public.missions;
create policy missions_update_own_client on public.missions
  for update to authenticated
  using (public.owns_profile(client_id))
  with check (public.owns_profile(client_id));
