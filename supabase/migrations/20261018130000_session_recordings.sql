-- Session recordings: LiveKit egress records the scout's stream straight into
-- the private `recordings` bucket (S3 protocol), and livekit-webhook keeps one
-- row per egress here. Re-runnable.
--
--   session live -> livekit-webhook starts participant egress (scout only)
--     -> egress_started / egress_updated / egress_ended -> session_recordings
--
-- A participant egress ends when the scout drops out of the room, so a
-- reconnect starts a new egress and one session can have several parts.
--
-- Objects are stored as <mission_id>/<session_id>/<epoch_ms>.mp4.

-- 1. Lifecycle of one egress, mirroring LiveKit's EgressStatus:
--      starting  EGRESS_STARTING, requested but not yet recording
--      active    EGRESS_ACTIVE, recording
--      ending    EGRESS_ENDING, finalising and uploading the file
--      complete  EGRESS_COMPLETE or EGRESS_LIMIT_REACHED, file is in storage
--      failed    EGRESS_FAILED or EGRESS_ABORTED, no usable file
do $$
begin
  create type public.recording_status as enum (
    'starting', 'active', 'ending', 'complete', 'failed'
  );
exception
  when duplicate_object then null;
end $$;

-- 2. One row per egress.
create table if not exists public.session_recordings (
  id                   uuid primary key default gen_random_uuid(),
  session_id           uuid not null
    references public.sessions (id) on delete cascade,
  -- LiveKit EgressInfo.egressId; the webhook looks rows up by it.
  egress_id            text not null,
  -- LiveKit identity of the recorded participant (the scout's profile id).
  participant_identity text not null,
  status               public.recording_status not null default 'starting',
  -- Object key inside the `recordings` bucket, set once the file is uploaded.
  storage_path         text,
  size_bytes           bigint,
  duration_sec         integer,
  started_at           timestamptz,
  ended_at             timestamptz,
  error                text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint session_recordings_egress_id_key unique (egress_id)
);

create index if not exists session_recordings_session_idx
  on public.session_recordings (session_id, created_at);

drop trigger if exists trg_session_recordings_updated_at
  on public.session_recordings;
create trigger trg_session_recordings_updated_at
  before update on public.session_recordings
  for each row execute function public.set_updated_at();

-- 3. The old single-recording columns were never written. The zuru app still
--    selects them by name, so they stay until that release is gone.
comment on column public.sessions.recording_id is
  'Deprecated: use session_recordings.egress_id. Drop once no app selects it.';
comment on column public.sessions.recording_url is
  'Deprecated: use session_recordings.storage_path. Drop once no app selects it.';

-- 4. Who belongs to a mission: its client or its assigned scout.
--    Definer so policies can call it without tripping missions' own RLS.
create or replace function public.is_mission_participant(p_mission_id uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select exists (
    select 1
    from public.missions m
    join public.profiles p on p.id in (m.client_id, m.scout_id)
    where m.id = p_mission_id
      and p.user_id = auth.uid()
  );
$$;

-- 5. Sessions: only the mission's client and scout may read a session.
--    It used to be readable by every signed-in user, room tokens included.
drop policy if exists "Enable read access for all users" on public.sessions;
drop policy if exists sessions_select_participants on public.sessions;
create policy sessions_select_participants on public.sessions
  for select to authenticated
  using (public.is_mission_participant(mission_id));

-- 6. Recordings: participants read them, only the webhook (service role)
--    writes them.
alter table public.session_recordings enable row level security;

revoke all on public.session_recordings from anon, authenticated;
grant select on public.session_recordings to authenticated;

drop policy if exists session_recordings_select_participants
  on public.session_recordings;
create policy session_recordings_select_participants
  on public.session_recordings
  for select to authenticated
  using (
    exists (
      select 1 from public.sessions s
      where s.id = session_id
        and public.is_mission_participant(s.mission_id)
    )
  );

-- Realtime lets the app flip a recording from processing to ready.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public' and tablename = 'session_recordings'
     ) then
    alter publication supabase_realtime add table public.session_recordings;
  end if;
end $$;

-- 7. The bucket: private, MP4 only, no per-bucket size limit. Uploads are
--    still capped by the project-wide limit, which must fit a 30 minute
--    720p recording (roughly 700MB).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('recordings', 'recordings', false, null, array['video/mp4'])
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- 8. Objects: participants may read (and so sign URLs for) the files of their
--    own missions' recordings. Egress uploads with the S3 access keys, which
--    bypass RLS, so there are no write policies.
create or replace function public.can_read_recording(p_object_name text)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select exists (
    select 1
    from public.session_recordings r
    join public.sessions s on s.id = r.session_id
    where r.storage_path = p_object_name
      and public.is_mission_participant(s.mission_id)
  );
$$;

drop policy if exists recordings_select_participants on storage.objects;
create policy recordings_select_participants on storage.objects
  for select to authenticated
  using (
    bucket_id = 'recordings'
    and public.can_read_recording(name)
  );
