


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "hypopg" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "index_advisor" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "postgis" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE TYPE "public"."mission_status" AS ENUM (
    'open',
    'accepted',
    'live',
    'completed',
    'cancelled',
    'enroute',
    'requested',
    'declined'
);


ALTER TYPE "public"."mission_status" OWNER TO "postgres";


CREATE TYPE "public"."payment_provider" AS ENUM (
    'mpesa',
    'intasend'
);


ALTER TYPE "public"."payment_provider" OWNER TO "postgres";


CREATE TYPE "public"."payment_status" AS ENUM (
    'pending',
    'success',
    'processing',
    'failed',
    'cancelled',
    'refunded'
);


ALTER TYPE "public"."payment_status" OWNER TO "postgres";


CREATE TYPE "public"."payment_txn_type" AS ENUM (
    'disbursement',
    'refund'
);


ALTER TYPE "public"."payment_txn_type" OWNER TO "postgres";


CREATE TYPE "public"."payment_type" AS ENUM (
    'inbound',
    'outbound'
);


ALTER TYPE "public"."payment_type" OWNER TO "postgres";


CREATE TYPE "public"."recording_status" AS ENUM (
    'starting',
    'active',
    'ending',
    'complete',
    'failed'
);


ALTER TYPE "public"."recording_status" OWNER TO "postgres";


CREATE TYPE "public"."role_type" AS ENUM (
    'scout',
    'client',
    'admin'
);


ALTER TYPE "public"."role_type" OWNER TO "postgres";


CREATE TYPE "public"."scout_availability" AS ENUM (
    'available',
    'bookable',
    'offline'
);


ALTER TYPE "public"."scout_availability" OWNER TO "postgres";


CREATE TYPE "public"."session_status" AS ENUM (
    'created',
    'live',
    'ending',
    'ended',
    'failed'
);


ALTER TYPE "public"."session_status" OWNER TO "postgres";


CREATE TYPE "public"."user_status" AS ENUM (
    'active',
    'inactive',
    'suspended'
);


ALTER TYPE "public"."user_status" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."accept_mission"("p_mission_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
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
$$;


ALTER FUNCTION "public"."accept_mission"("p_mission_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."broadcast_mission_pool_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
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
$$;


ALTER FUNCTION "public"."broadcast_mission_pool_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."can_rate_on_mission"("p_mission_id" "uuid", "p_from_profile_id" "uuid", "p_to_profile_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
$$;


ALTER FUNCTION "public"."can_rate_on_mission"("p_mission_id" "uuid", "p_from_profile_id" "uuid", "p_to_profile_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."can_read_recording"("p_object_name" "text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1
    from public.session_recordings r
    join public.sessions s on s.id = r.session_id
    where r.storage_path = p_object_name
      and public.is_mission_participant(s.mission_id)
  );
$$;


ALTER FUNCTION "public"."can_read_recording"("p_object_name" "text") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "recipient_profile_id" "uuid" NOT NULL,
    "recipient_user_id" "uuid" NOT NULL,
    "type" "text" NOT NULL,
    "mission_id" "uuid",
    "data" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "title" "text",
    "body" "text",
    "dedupe_key" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "attempts" integer DEFAULT 0 NOT NULL,
    "last_error" "text",
    "fcm_message_id" "text",
    "read_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "attempted_at" timestamp with time zone,
    "sent_at" timestamp with time zone,
    CONSTRAINT "notifications_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'sending'::"text", 'sent'::"text", 'failed'::"text", 'skipped'::"text"])))
);


ALTER TABLE "public"."notifications" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."claim_notification"("p_id" "uuid") RETURNS SETOF "public"."notifications"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  update public.notifications
  set status       = 'sending',
      attempts     = attempts + 1,
      attempted_at = now()
  where id = p_id
    and attempts < 5
    and (
      status in ('pending', 'failed')
      or (status = 'sending' and attempted_at < now() - interval '2 minutes')
    )
  returning *;
$$;


ALTER FUNCTION "public"."claim_notification"("p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cleanup_stuck_ending_sessions"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
$$;


ALTER FUNCTION "public"."cleanup_stuck_ending_sessions"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."custom_access_token_hook"("event" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$DECLARE
  v_role text;
BEGIN
  SELECT role::text INTO v_role
  FROM public.profiles
  WHERE id = (event ->> 'user_id')::uuid;

  -- Inject role into the JWT claims
  RETURN jsonb_set(
    event,
    '{claims, user_role}',
    to_jsonb(COALESCE(v_role, 'unknown'))
  );
END;$$;


ALTER FUNCTION "public"."custom_access_token_hook"("event" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."decline_mission"("p_mission_id" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."decline_mission"("p_mission_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."dispatch_guide_payouts"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_config jsonb;
  v_since timestamptz;
  v_max_attempts int;
  v_url text;
  v_key text;
  v_count int := 0;
  r record;
begin
  select value into v_config
  from public.app_config
  where key = 'guide_payouts';

  if coalesce((v_config ->> 'enabled')::boolean, false) is not true then
    return 0;
  end if;
  v_since := (v_config ->> 'payouts_since')::timestamptz;
  v_max_attempts := coalesce((v_config ->> 'max_attempts')::int, 3);

  select decrypted_secret into v_url
  from vault.decrypted_secrets
  where name = 'app_supabase_url';

  select decrypted_secret into v_key
  from vault.decrypted_secrets
  where name = 'service_api_key';

  if v_url is null or v_key is null then
    raise warning 'dispatch_guide_payouts: vault secrets missing';
    return 0;
  end if;

  for r in
    select m.id
    from public.missions m
    join public.profiles p on p.id = m.scout_id
    join public.users u on u.id = p.user_id
    where m.status = 'completed'
      and m.completed_at >= v_since
      and m.guide_amount > 0
      and u.phone is not null
      and exists (
        select 1 from public.payments pay
        where pay.mission_id = m.id
          and pay.type = 'inbound'
          and pay.status = 'success'
      )
      and not exists (
        select 1 from public.payments pay
        where pay.mission_id = m.id
          and pay.type = 'outbound'
          and pay.status in ('pending', 'processing', 'success')
      )
      and (
        select count(*) from public.payments pay
        where pay.mission_id = m.id
          and pay.type = 'outbound'
          and pay.status in ('failed', 'cancelled')
      ) < v_max_attempts
    order by m.completed_at
    limit 20
  loop
    perform net.http_post(
      url     := v_url || '/functions/v1/intasend-payout',
      headers := jsonb_build_object(
                   'Content-Type',  'application/json',
                   'Authorization', 'Bearer ' || v_key
                 ),
      body    := jsonb_build_object('mission_id', r.id),
      timeout_milliseconds := 30000
    );
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;


ALTER FUNCTION "public"."dispatch_guide_payouts"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."dispatch_notification"("p_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_url text;
  v_key text;
begin
  select decrypted_secret into v_url
  from vault.decrypted_secrets
  where name = 'app_supabase_url';

  select decrypted_secret into v_key
  from vault.decrypted_secrets
  where name = 'service_api_key';

  if v_url is null or v_key is null then
    raise warning 'dispatch_notification: vault secrets missing, % stays queued', p_id;
    return;
  end if;

  perform net.http_post(
    url     := v_url || '/functions/v1/send-fcm',
    headers := jsonb_build_object(
                 'Content-Type',  'application/json',
                 'Authorization', 'Bearer ' || v_key
               ),
    body    := jsonb_build_object('notification_id', p_id),
    timeout_milliseconds := 10000
  );
end;
$$;


ALTER FUNCTION "public"."dispatch_notification"("p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enqueue_notification"("p_profile_id" "uuid", "p_type" "text", "p_mission_id" "uuid", "p_data" "jsonb", "p_dedupe_key" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_user_id uuid;
begin
  if p_profile_id is null then
    return;
  end if;

  select user_id into v_user_id
  from public.profiles
  where id = p_profile_id;

  if v_user_id is null then
    raise warning 'enqueue_notification: no profile %', p_profile_id;
    return;
  end if;

  insert into public.notifications (
    recipient_profile_id, recipient_user_id, type, mission_id, data, dedupe_key
  )
  values (
    p_profile_id, v_user_id, p_type, p_mission_id,
    coalesce(p_data, '{}'::jsonb), p_dedupe_key
  )
  on conflict (dedupe_key) do nothing;
exception when others then
  raise warning 'enqueue_notification(%, %) failed: %',
    p_type, p_dedupe_key, sqlerrm;
end;
$$;


ALTER FUNCTION "public"."enqueue_notification"("p_profile_id" "uuid", "p_type" "text", "p_mission_id" "uuid", "p_data" "jsonb", "p_dedupe_key" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."expire_live_rooms"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_rooms       text[];
  v_url         text;
  v_service_key text;
BEGIN
  -- Atomically flip live → ending
  SELECT decrypted_secret INTO v_url
  FROM vault.decrypted_secrets
  WHERE name = 'app_supabase_url';

  SELECT decrypted_secret INTO v_service_key
  FROM vault.decrypted_secrets
  WHERE name = 'service_api_key';

  WITH expired AS (
    UPDATE sessions
    SET status = 'ending', updated_at = now()
    WHERE status = 'live'
      AND started_at + (scheduled_duration_sec || ' seconds')::interval <= now()
    RETURNING room_name
  )
  SELECT array_agg(room_name) INTO v_rooms FROM expired;

  IF v_rooms IS NOT NULL THEN
    PERFORM net.http_post(
      url     := v_url || '/functions/v1/end-livekit-room',
      headers := jsonb_build_object(
                   'Content-Type',  'application/json',
                   'Authorization', 'Bearer ' || v_service_key
                 ),
      body    := jsonb_build_object('room_names', v_rooms)
    );
  END IF;
END;
$$;


ALTER FUNCTION "public"."expire_live_rooms"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."expire_unpaid_live_requests"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."expire_unpaid_live_requests"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_missions_within_radius"("lat" double precision, "lng" double precision, "radius_m" double precision DEFAULT 5000.0) RETURNS TABLE("id" "uuid", "client_profile_id" "uuid", "scout_profile_id" "uuid", "description" "text", "currency" "text", "price" numeric, "duration_in_sec" integer, "address" "text", "location" "extensions"."geography", "status" "public"."mission_status", "created_at" timestamp with time zone, "updated_at" timestamp with time zone, "accepted_at" timestamp with time zone, "completed_at" timestamp with time zone, "published_at" timestamp with time zone, "session_id" "uuid", "type" "text", "client" json)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
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
$$;


ALTER FUNCTION "public"."get_missions_within_radius"("lat" double precision, "lng" double precision, "radius_m" double precision) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."guard_mission_update"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."guard_mission_update"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$BEGIN

  -- 1. Create the user (identity layer only)

  INSERT INTO public.users (
    id,
    email,
    phone,
    default_role
  )
  VALUES (
    NEW.id,
    NEW.email,
    NEW.raw_user_meta_data->>'phone',
    (NEW.raw_user_meta_data->>'role')::public.role_type
  );

  -- 2. Create the client profile
  INSERT INTO public.profiles (
    user_id,
    role,
    first_name,
    last_name,
    status
  )
  VALUES (
    NEW.id,
    'client'::public.role_type,
    COALESCE(
      NEW.raw_user_meta_data->>'first_name',
      split_part(NEW.raw_user_meta_data->>'full_name', ' ', 1),
      split_part(NEW.email, '@', 1)
    ),
    COALESCE(
      NEW.raw_user_meta_data->>'last_name',
      NULLIF(split_part(NEW.raw_user_meta_data->>'full_name', ' ', 2), '')
    ),
    'active'
  );

  -- 3. Create the scout profile
  INSERT INTO public.profiles (
    user_id,
    role,
    first_name,
    last_name,
    status
  )
  VALUES (
    NEW.id,
    'scout'::public.role_type,
    COALESCE(
      NEW.raw_user_meta_data->>'first_name',
      split_part(NEW.raw_user_meta_data->>'full_name', ' ', 1),
      split_part(NEW.email, '@', 1)
    ),
    COALESCE(
      NEW.raw_user_meta_data->>'last_name',
      NULLIF(split_part(NEW.raw_user_meta_data->>'full_name', ' ', 2), '')
    ),
    'inactive'
  );

  RETURN NEW;
END;$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_user_update"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$BEGIN
  -- Only run if phone actually changed
  IF NEW.phone IS DISTINCT FROM OLD.phone THEN
    UPDATE public.users
    SET phone = NEW.phone
    WHERE id = NEW.id;
  END IF;

  RETURN NEW;
END;$$;


ALTER FUNCTION "public"."handle_user_update"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_mission_participant"("p_mission_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1
    from public.missions m
    join public.profiles p on p.id in (m.client_id, m.scout_id)
    where m.id = p_mission_id
      and p.user_id = auth.uid()
  );
$$;


ALTER FUNCTION "public"."is_mission_participant"("p_mission_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_scout"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from public.profiles
    where user_id = auth.uid()
      and role = 'scout'::public.role_type
      and status = 'active'::public.user_status
  );
$$;


ALTER FUNCTION "public"."is_scout"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."link_session_to_mission"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.missions WHERE id = NEW.mission_id
  ) THEN
    RAISE EXCEPTION 'Mission % does not exist', NEW.mission_id;
  END IF;

  UPDATE public.missions
  SET session_id = NEW.id
  WHERE id = NEW.mission_id;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."link_session_to_mission"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."live_request_payment_window"() RETURNS interval
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select make_interval(mins => coalesce(
    (select (value ->> 'minutes')::int
     from public.app_config
     where key = 'live_request_payment'),
    30
  ));
$$;


ALTER FUNCTION "public"."live_request_payment_window"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."missions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "client_id" "uuid" NOT NULL,
    "scout_id" "uuid",
    "description" "text" NOT NULL,
    "currency" "text" NOT NULL,
    "price" numeric(10,2) NOT NULL,
    "duration_in_sec" integer NOT NULL,
    "address" "text",
    "location" "extensions"."geography"(Point,4326),
    "status" "public"."mission_status" DEFAULT 'open'::"public"."mission_status" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "accepted_at" timestamp with time zone,
    "completed_at" timestamp with time zone,
    "session_id" "uuid",
    "type" "text" DEFAULT 'custom_task'::"text",
    "scheduled_at" timestamp with time zone,
    "published_at" timestamp with time zone,
    "commission_percent" numeric(5,2),
    "platform_fee" numeric(12,2),
    "guide_amount" numeric(12,2)
);


ALTER TABLE "public"."missions" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mission_push_data"("p_mission" "public"."missions", "p_scout_id" "uuid") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."mission_push_data"("p_mission" "public"."missions", "p_scout_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notifications_dispatch_on_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  perform public.dispatch_notification(new.id);
  return new;
exception when others then
  -- The cron job picks it up; never fail the insert over delivery.
  raise warning 'dispatch of notification % failed: %', new.id, sqlerrm;
  return new;
end;
$$;


ALTER FUNCTION "public"."notifications_dispatch_on_insert"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_live_request_created"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."notify_live_request_created"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_mission_status_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."notify_mission_status_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_request_paid"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."notify_request_paid"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_scout_live"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."notify_scout_live"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_scout_unassigned"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF OLD.scout_id IS NOT NULL
     AND NEW.scout_id IS DISTINCT FROM OLD.scout_id THEN
    INSERT INTO public.mission_scout_events (scout_profile_id, mission_id, type)
    VALUES (OLD.scout_id, OLD.id, 'unassigned');
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."notify_scout_unassigned"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."owns_profile"("p_profile_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from public.profiles
    where id = p_profile_id and user_id = auth.uid()
  );
$$;


ALTER FUNCTION "public"."owns_profile"("p_profile_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."platform_commission_percent"() RETURNS numeric
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(
    (select least(greatest((value ->> 'percent')::numeric, 0), 100)
     from public.app_config
     where key = 'platform_commission'),
    10
  );
$$;


ALTER FUNCTION "public"."platform_commission_percent"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."profile_display_name"("p_profile_id" "uuid") RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(
    nullif(trim(concat_ws(' ', first_name, last_name)), ''),
    ''
  )
  from public.profiles
  where id = p_profile_id;
$$;


ALTER FUNCTION "public"."profile_display_name"("p_profile_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."publish_mission_on_payment"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
begin
  if new.status = 'success'
     and (tg_op = 'INSERT' or old.status is distinct from 'success') then
    update public.missions
       set published_at = now()
     where id = new.mission_id
       and published_at is null;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."publish_mission_on_payment"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reclaim_stale_missions"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."reclaim_stale_missions"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."retry_notifications"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_id    uuid;
  v_count integer := 0;
begin
  -- A late "join now" or "on the way" is worse than none.
  update public.notifications
  set status     = 'skipped',
      last_error = coalesce(last_error || '; ', '') || 'expired'
  where status in ('pending', 'sending', 'failed')
    and created_at < now() - case type
          when 'SCOUT_LIVE'      then interval '5 minutes'
          when 'MISSION_ENROUTE' then interval '30 minutes'
          else interval '6 hours'
        end;

  update public.notifications
  set status     = 'skipped',
      last_error = coalesce(last_error || '; ', '') || 'gave up after 5 attempts'
  where status in ('pending', 'sending', 'failed')
    and attempts >= 5;

  for v_id in
    select id
    from public.notifications
    where (
        status in ('pending', 'failed')
        or (status = 'sending' and attempted_at < now() - interval '2 minutes')
      )
      and coalesce(attempted_at, created_at) < now() - interval '30 seconds'
    order by created_at
    limit 100
  loop
    perform public.dispatch_notification(v_id);
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;


ALTER FUNCTION "public"."retry_notifications"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_auto_enable"() RETURNS "event_trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog'
    AS $$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."rls_auto_enable"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."search_missions"("p_lat" double precision, "p_lng" double precision, "p_sort" "text" DEFAULT 'distance'::"text", "p_limit" integer DEFAULT 20, "p_cursor_key" double precision DEFAULT NULL::double precision, "p_cursor_id" "uuid" DEFAULT NULL::"uuid", "p_usd_kes" numeric DEFAULT NULL::numeric, "p_radius_m" double precision DEFAULT 60000) RETURNS TABLE("id" "uuid", "client_id" "uuid", "description" "text", "currency" "text", "price" numeric, "pay_kes" numeric, "duration_in_sec" integer, "address" "text", "lat" double precision, "lng" double precision, "status" "public"."mission_status", "type" "text", "published_at" timestamp with time zone, "created_at" timestamp with time zone, "distance_m" double precision, "sort_key" double precision, "total_count" bigint, "client" json)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
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
$$;


ALTER FUNCTION "public"."search_missions"("p_lat" double precision, "p_lng" double precision, "p_sort" "text", "p_limit" integer, "p_cursor_key" double precision, "p_cursor_id" "uuid", "p_usd_kes" numeric, "p_radius_m" double precision) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_mission_client_id"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$DECLARE
  v_role        TEXT;
  v_profile_id  UUID;
BEGIN
  -- 1. Must be authenticated
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  -- 2. Look up the client profile for this authenticated user
  SELECT id, role INTO v_profile_id, v_role
  FROM public.profiles
  WHERE user_id = auth.uid()
    AND role = 'client';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Client profile not found for uid %', auth.uid();
  END IF;

  -- 3. Only client profiles may create missions
  IF v_role <> 'client' THEN
    RAISE EXCEPTION 'Only clients can create missions. Role found: %', v_role;
  END IF;

  -- 4. Force client_id to the authenticated user's client profile —
  NEW.client_id := v_profile_id;

  RETURN NEW;
END;$$;


ALTER FUNCTION "public"."set_mission_client_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_mission_commission"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if tg_op = 'INSERT' or old.commission_percent is null then
    new.commission_percent := public.platform_commission_percent();
  else
    new.commission_percent := old.commission_percent;
  end if;

  new.platform_fee := round(
    coalesce(new.price, 0) * new.commission_percent / 100, 2
  );
  new.guide_amount := coalesce(new.price, 0) - new.platform_fee;
  return new;
end;
$$;


ALTER FUNCTION "public"."set_mission_commission"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_rating_from_user_id"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_profile_id uuid;
  v_to_role    public.role_type;
  v_from_role  public.role_type;
BEGIN
  -- Authenticated path: derive the author from the JWT (no spoofing).
  IF auth.uid() IS NOT NULL THEN
    -- A user holds BOTH a client and a scout profile, so user_id alone is
    -- ambiguous. Ratings are cross-role, so the author is the profile whose
    -- role is the opposite of the recipient's.
    IF NEW.to_profile_id IS NULL THEN
      RAISE EXCEPTION 'to_profile_id is required';
    END IF;

    SELECT role INTO v_to_role
    FROM public.profiles
    WHERE id = NEW.to_profile_id;

    IF v_to_role IS NULL THEN
      RAISE EXCEPTION 'Recipient profile % not found', NEW.to_profile_id;
    END IF;

    v_from_role := CASE v_to_role
                     WHEN 'scout'::public.role_type THEN 'client'::public.role_type
                     ELSE 'scout'::public.role_type
                   END;

    SELECT id INTO v_profile_id
    FROM public.profiles
    WHERE user_id = auth.uid()
      AND role    = v_from_role;

    IF v_profile_id IS NULL THEN
      RAISE EXCEPTION 'No % profile found for uid %', v_from_role, auth.uid();
    END IF;

    NEW.from_profile_id := v_profile_id;
    RETURN NEW;
  END IF;

  -- System path (no JWT, e.g. pg_cron): trust an explicitly-set author.
  IF NEW.from_profile_id IS NULL THEN
    RAISE EXCEPTION 'from_profile_id required for unauthenticated rating insert';
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_rating_from_user_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.updated_at = now();
  return new;
end $$;


ALTER FUNCTION "public"."set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."stream_clock"("p_mission_id" "uuid") RETURNS TABLE("status" "text", "started_at" timestamp with time zone, "ends_at" timestamp with time zone, "server_now" timestamp with time zone)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
$$;


ALTER FUNCTION "public"."stream_clock"("p_mission_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_missions_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_missions_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_scout_location"("lat" double precision, "lng" double precision) RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    AS $$UPDATE profiles
  SET
    location = ST_SetSRID(ST_MakePoint(lng, lat), 4326)::geography,
    updated_at = now()
  WHERE user_id = auth.uid()
    AND role    = 'scout'::public.role_type;$$;


ALTER FUNCTION "public"."update_scout_location"("lat" double precision, "lng" double precision) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_sessions_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_sessions_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_user_rating"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$BEGIN
  UPDATE public.profiles
  SET
    rating = (
      SELECT ROUND(AVG(score)::NUMERIC, 2)
      FROM public.ratings
      WHERE to_profile_id = NEW.to_profile_id
    ),
    total_reviews = (
      SELECT COUNT(*)
      FROM public.ratings
      WHERE to_profile_id = NEW.to_profile_id
    )
  WHERE id = NEW.to_profile_id;

  RETURN NEW;
END;$$;


ALTER FUNCTION "public"."update_user_rating"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_user_role"("p_user_id" "uuid", "p_role" "public"."role_type") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  -- Only admins can call this
  IF NOT EXISTS (
    SELECT 1 FROM public.users
    WHERE id = auth.uid()
    AND role = 'admin'::public.role_type
  ) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  UPDATE public.users
  SET role = p_role
  WHERE id = p_user_id;
END;
$$;


ALTER FUNCTION "public"."update_user_role"("p_user_id" "uuid", "p_role" "public"."role_type") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_user_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$BEGIN
   -- Update the updated_at column
   NEW.updated_at := NOW();
   RETURN NEW;
END;$$;


ALTER FUNCTION "public"."update_user_updated_at"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."app_config" (
    "key" "text" NOT NULL,
    "value" "jsonb" NOT NULL,
    "description" "text",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."app_config" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."mission_scout_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "scout_profile_id" "uuid" NOT NULL,
    "mission_id" "uuid",
    "type" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."mission_scout_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "amount" numeric(12,2) DEFAULT '0'::numeric NOT NULL,
    "currency" "text" DEFAULT 'KES'::"text" NOT NULL,
    "provider" "public"."payment_provider" DEFAULT 'mpesa'::"public"."payment_provider" NOT NULL,
    "provider_ref" "text",
    "payer_profile_id" "uuid",
    "payee_profile_id" "uuid",
    "mission_id" "uuid" NOT NULL,
    "checkout_request_id" "text",
    "merchant_request_id" "text",
    "phone_number" "text",
    "failure_reason" "text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "type" "public"."payment_type" NOT NULL,
    "status" "public"."payment_status" DEFAULT 'pending'::"public"."payment_status" NOT NULL,
    CONSTRAINT "payments_amount_positive" CHECK (("amount" > (0)::numeric)),
    CONSTRAINT "payments_status_check" CHECK (("status" = ANY (ARRAY['pending'::"public"."payment_status", 'processing'::"public"."payment_status", 'success'::"public"."payment_status", 'failed'::"public"."payment_status", 'cancelled'::"public"."payment_status", 'refunded'::"public"."payment_status"])))
);


ALTER TABLE "public"."payments" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."payment_statements" WITH ("security_invoker"='true') AS
 SELECT "pay"."id",
    "pay"."created_at",
    "pay"."updated_at",
    "pay"."mission_id",
        CASE
            WHEN ("pay"."type" = 'outbound'::"public"."payment_type") THEN 'payout'::"text"
            ELSE 'payment'::"text"
        END AS "direction",
    "initcap"("replace"(COALESCE("m"."type", 'live check'::"text"), '_'::"text", ' '::"text")) AS "mission_title",
    COALESCE(NULLIF(TRIM(BOTH FROM "split_part"("m"."address", ','::"text", 1)), ''::"text"), ''::"text") AS "location",
    "pay"."amount",
    "pay"."currency",
        CASE
            WHEN ("pay"."status" = 'success'::"public"."payment_status") THEN 'disbursed'::"text"
            WHEN ("pay"."status" = ANY (ARRAY['pending'::"public"."payment_status", 'processing'::"public"."payment_status"])) THEN 'pending'::"text"
            ELSE 'failed'::"text"
        END AS "status",
        CASE
            WHEN (("pay"."metadata" ->> 'method'::"text") = 'card'::"text") THEN 'CARD'::"text"
            WHEN ("pay"."phone_number" ~ '^254[0-9]{9}$'::"text") THEN (((('M-PESA (0'::"text" || "substr"("pay"."phone_number", 4, 2)) || '*****'::"text") || "right"("pay"."phone_number", 2)) || ')'::"text")
            ELSE 'M-PESA'::"text"
        END AS "channel"
   FROM ("public"."payments" "pay"
     LEFT JOIN "public"."missions" "m" ON (("m"."id" = "pay"."mission_id")))
  WHERE ("public"."owns_profile"(
        CASE
            WHEN ("pay"."type" = 'outbound'::"public"."payment_type") THEN "pay"."payee_profile_id"
            ELSE "pay"."payer_profile_id"
        END) AND (NOT (("pay"."type" = 'inbound'::"public"."payment_type") AND ("pay"."status" = ANY (ARRAY['pending'::"public"."payment_status", 'cancelled'::"public"."payment_status"])))));


ALTER VIEW "public"."payment_statements" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profile_clips" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "title" "text",
    "url" "text",
    "profile_id" "uuid"
);


ALTER TABLE "public"."profile_clips" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "role" "public"."role_type" DEFAULT 'client'::"public"."role_type" NOT NULL,
    "first_name" "text",
    "last_name" "text",
    "bio" "text",
    "avatar_url" "text",
    "tags" "text",
    "location" "extensions"."geography",
    "status" "public"."user_status" DEFAULT 'active'::"public"."user_status" NOT NULL,
    "is_verified" boolean DEFAULT false,
    "rating" numeric DEFAULT '0'::numeric,
    "total_reviews" integer DEFAULT 0,
    "user_id" "uuid" NOT NULL,
    "availability" "public"."scout_availability" DEFAULT 'offline'::"public"."scout_availability" NOT NULL,
    "locality_geo" "extensions"."geography",
    "locality_address" "text",
    "session_pricing" "jsonb"[]
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ratings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "mission_id" "uuid",
    "from_profile_id" "uuid" NOT NULL,
    "to_profile_id" "uuid" NOT NULL,
    "score" integer NOT NULL,
    "comment" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "no_self_rating" CHECK (("from_profile_id" <> "to_profile_id")),
    CONSTRAINT "ratings_score_check" CHECK ((("score" >= 1) AND ("score" <= 5)))
);


ALTER TABLE "public"."ratings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."session_recordings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "session_id" "uuid" NOT NULL,
    "egress_id" "text" NOT NULL,
    "participant_identity" "text" NOT NULL,
    "status" "public"."recording_status" DEFAULT 'starting'::"public"."recording_status" NOT NULL,
    "storage_path" "text",
    "size_bytes" bigint,
    "duration_sec" integer,
    "started_at" timestamp with time zone,
    "ended_at" timestamp with time zone,
    "error" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."session_recordings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sessions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "mission_id" "uuid" NOT NULL,
    "provider" "text" DEFAULT 'livekit'::"text" NOT NULL,
    "room_name" "text" NOT NULL,
    "host_token" "text",
    "client_token" "text",
    "status" "public"."session_status" DEFAULT 'created'::"public"."session_status" NOT NULL,
    "scheduled_duration_sec" integer NOT NULL,
    "actual_duration_sec" integer,
    "recording_id" "text",
    "recording_url" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "started_at" timestamp with time zone,
    "ended_at" timestamp with time zone,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "host_joined_at" timestamp with time zone,
    "host_left_at" timestamp with time zone,
    "client_left_at" timestamp with time zone,
    "last_disconnect_reason" "text",
    CONSTRAINT "sessions_provider_check" CHECK (("provider" = ANY (ARRAY['livekit'::"text", 'agora'::"text"])))
);


ALTER TABLE "public"."sessions" OWNER TO "postgres";


COMMENT ON COLUMN "public"."sessions"."recording_id" IS 'Deprecated: use session_recordings.egress_id. Drop once no app selects it.';



COMMENT ON COLUMN "public"."sessions"."recording_url" IS 'Deprecated: use session_recordings.storage_path. Drop once no app selects it.';



CREATE TABLE IF NOT EXISTS "public"."users" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "email" "text" NOT NULL,
    "phone" "text",
    "status" "public"."user_status" DEFAULT 'active'::"public"."user_status" NOT NULL,
    "fcm_token" "text",
    "is_online" boolean DEFAULT true NOT NULL,
    "default_role" "public"."role_type" DEFAULT 'client'::"public"."role_type",
    "notifications_enabled" boolean DEFAULT true NOT NULL
);


ALTER TABLE "public"."users" OWNER TO "postgres";


ALTER TABLE ONLY "public"."app_config"
    ADD CONSTRAINT "app_config_pkey" PRIMARY KEY ("key");



ALTER TABLE ONLY "public"."mission_scout_events"
    ADD CONSTRAINT "mission_scout_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."missions"
    ADD CONSTRAINT "missions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."missions"
    ADD CONSTRAINT "missions_session_id_key" UNIQUE ("session_id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_dedupe_key_key" UNIQUE ("dedupe_key");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profile_clips"
    ADD CONSTRAINT "profile_clips_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_user_role_unique" UNIQUE ("user_id", "role");



ALTER TABLE ONLY "public"."ratings"
    ADD CONSTRAINT "ratings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."session_recordings"
    ADD CONSTRAINT "session_recordings_egress_id_key" UNIQUE ("egress_id");



ALTER TABLE ONLY "public"."session_recordings"
    ADD CONSTRAINT "session_recordings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sessions"
    ADD CONSTRAINT "sessions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sessions"
    ADD CONSTRAINT "sessions_room_name_key" UNIQUE ("room_name");



ALTER TABLE ONLY "public"."sessions"
    ADD CONSTRAINT "unique_mission_session" UNIQUE ("mission_id");



ALTER TABLE ONLY "public"."ratings"
    ADD CONSTRAINT "unique_rating_per_mission" UNIQUE ("mission_id", "from_profile_id", "to_profile_id");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_pkey" PRIMARY KEY ("id");



CREATE INDEX "idx_missions_client_id" ON "public"."missions" USING "btree" ("client_id");



CREATE INDEX "idx_missions_location_geo" ON "public"."missions" USING "gist" ("location");



CREATE INDEX "idx_missions_pool_location" ON "public"."missions" USING "gist" ("location") WHERE (("published_at" IS NOT NULL) AND ("status" = ANY (ARRAY['open'::"public"."mission_status", 'cancelled'::"public"."mission_status"])));



CREATE INDEX "idx_missions_scout_id" ON "public"."missions" USING "btree" ("scout_id");



CREATE INDEX "idx_missions_status" ON "public"."missions" USING "btree" ("status");



CREATE UNIQUE INDEX "idx_one_active_mission_per_scout" ON "public"."missions" USING "btree" ("scout_id") WHERE ("status" = ANY (ARRAY['accepted'::"public"."mission_status", 'live'::"public"."mission_status"]));



CREATE INDEX "idx_open_missions" ON "public"."missions" USING "btree" ("id") WHERE ("status" = 'open'::"public"."mission_status");



CREATE UNIQUE INDEX "idx_payments_checkout_request_id_key" ON "public"."payments" USING "btree" ("checkout_request_id") WHERE ("checkout_request_id" IS NOT NULL);



CREATE INDEX "idx_payments_mission_id" ON "public"."payments" USING "btree" ("mission_id");



CREATE INDEX "idx_payments_payee_profile_id" ON "public"."payments" USING "btree" ("payee_profile_id");



CREATE INDEX "idx_payments_payer" ON "public"."payments" USING "btree" ("payer_profile_id");



CREATE INDEX "idx_payments_payer_profile_id" ON "public"."payments" USING "btree" ("payer_profile_id");



CREATE UNIQUE INDEX "idx_payments_provider_ref_key" ON "public"."payments" USING "btree" ("provider", "provider_ref") WHERE ("provider_ref" IS NOT NULL);



CREATE INDEX "idx_payments_status" ON "public"."payments" USING "btree" ("status");



CREATE INDEX "idx_profiles_user_id" ON "public"."profiles" USING "btree" ("user_id");



CREATE INDEX "idx_ratings_from_user_id" ON "public"."ratings" USING "btree" ("from_profile_id");



CREATE INDEX "idx_ratings_mission_id" ON "public"."ratings" USING "btree" ("mission_id");



CREATE INDEX "idx_ratings_to_user_id" ON "public"."ratings" USING "btree" ("to_profile_id");



CREATE INDEX "mission_scout_events_scout_idx" ON "public"."mission_scout_events" USING "btree" ("scout_profile_id", "created_at" DESC);



CREATE INDEX "missions_accepted_accepted_at_idx" ON "public"."missions" USING "btree" ("accepted_at") WHERE ("status" = 'accepted'::"public"."mission_status");



CREATE INDEX "missions_scout_id_status_idx" ON "public"."missions" USING "btree" ("scout_id", "status") WHERE ("scout_id" IS NOT NULL);



CREATE INDEX "notifications_recipient_idx" ON "public"."notifications" USING "btree" ("recipient_user_id", "created_at" DESC);



CREATE INDEX "notifications_undelivered_idx" ON "public"."notifications" USING "btree" ("created_at") WHERE ("status" = ANY (ARRAY['pending'::"text", 'sending'::"text", 'failed'::"text"]));



CREATE UNIQUE INDEX "one_active_mission_per_scout" ON "public"."missions" USING "btree" ("scout_id") WHERE ("status" = ANY (ARRAY['accepted'::"public"."mission_status", 'live'::"public"."mission_status", 'enroute'::"public"."mission_status"]));



CREATE UNIQUE INDEX "payments_checkout_request_id_key" ON "public"."payments" USING "btree" ("checkout_request_id") WHERE ("checkout_request_id" IS NOT NULL);



CREATE INDEX "payments_merchant_request_id_idx" ON "public"."payments" USING "btree" ("merchant_request_id") WHERE ("merchant_request_id" IS NOT NULL);



CREATE INDEX "payments_mission_id_idx" ON "public"."payments" USING "btree" ("mission_id");



CREATE UNIQUE INDEX "payments_one_active_per_mission_type" ON "public"."payments" USING "btree" ("mission_id", "type") WHERE ("status" = ANY (ARRAY['pending'::"public"."payment_status", 'processing'::"public"."payment_status", 'success'::"public"."payment_status"]));



CREATE INDEX "payments_payee_idx" ON "public"."payments" USING "btree" ("payee_profile_id");



CREATE INDEX "payments_payer_idx" ON "public"."payments" USING "btree" ("payer_profile_id");



CREATE UNIQUE INDEX "payments_provider_ref_key" ON "public"."payments" USING "btree" ("provider", "provider_ref") WHERE ("provider_ref" IS NOT NULL);



CREATE INDEX "payments_status_idx" ON "public"."payments" USING "btree" ("status");



CREATE INDEX "profiles_user_id_role_idx" ON "public"."profiles" USING "btree" ("user_id", "role");



CREATE INDEX "session_recordings_session_idx" ON "public"."session_recordings" USING "btree" ("session_id", "created_at");



CREATE UNIQUE INDEX "sessions_mission_id" ON "public"."sessions" USING "btree" ("mission_id");



CREATE OR REPLACE TRIGGER "on_session_created" AFTER INSERT ON "public"."sessions" FOR EACH ROW EXECUTE FUNCTION "public"."link_session_to_mission"();



CREATE OR REPLACE TRIGGER "payments_set_updated_at" BEFORE UPDATE ON "public"."payments" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_broadcast_mission_pool_change" AFTER INSERT OR DELETE OR UPDATE ON "public"."missions" FOR EACH ROW EXECUTE FUNCTION "public"."broadcast_mission_pool_change"();



CREATE OR REPLACE TRIGGER "trg_dispatch_notification" AFTER INSERT ON "public"."notifications" FOR EACH ROW EXECUTE FUNCTION "public"."notifications_dispatch_on_insert"();



CREATE OR REPLACE TRIGGER "trg_guard_mission_update" BEFORE UPDATE ON "public"."missions" FOR EACH ROW EXECUTE FUNCTION "public"."guard_mission_update"();



CREATE OR REPLACE TRIGGER "trg_notify_live_request_created" AFTER INSERT ON "public"."missions" FOR EACH ROW EXECUTE FUNCTION "public"."notify_live_request_created"();



CREATE OR REPLACE TRIGGER "trg_notify_mission_status" AFTER UPDATE OF "status" ON "public"."missions" FOR EACH ROW EXECUTE FUNCTION "public"."notify_mission_status_change"();



CREATE OR REPLACE TRIGGER "trg_notify_request_paid" AFTER INSERT OR UPDATE OF "status" ON "public"."payments" FOR EACH ROW EXECUTE FUNCTION "public"."notify_request_paid"();



CREATE OR REPLACE TRIGGER "trg_notify_scout_live" AFTER UPDATE OF "host_joined_at" ON "public"."sessions" FOR EACH ROW EXECUTE FUNCTION "public"."notify_scout_live"();



CREATE OR REPLACE TRIGGER "trg_notify_scout_unassigned" AFTER UPDATE OF "scout_id" ON "public"."missions" FOR EACH ROW EXECUTE FUNCTION "public"."notify_scout_unassigned"();



CREATE OR REPLACE TRIGGER "trg_publish_mission_on_payment" AFTER INSERT OR UPDATE OF "status" ON "public"."payments" FOR EACH ROW EXECUTE FUNCTION "public"."publish_mission_on_payment"();



CREATE OR REPLACE TRIGGER "trg_ratings_update_user_score" AFTER INSERT ON "public"."ratings" FOR EACH ROW EXECUTE FUNCTION "public"."update_user_rating"();



CREATE OR REPLACE TRIGGER "trg_session_recordings_updated_at" BEFORE UPDATE ON "public"."session_recordings" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_set_mission_client_id" BEFORE INSERT ON "public"."missions" FOR EACH ROW EXECUTE FUNCTION "public"."set_mission_client_id"();



CREATE OR REPLACE TRIGGER "trg_set_mission_commission" BEFORE INSERT OR UPDATE OF "price", "commission_percent", "platform_fee", "guide_amount" ON "public"."missions" FOR EACH ROW EXECUTE FUNCTION "public"."set_mission_commission"();



CREATE OR REPLACE TRIGGER "trg_set_rating_from_user_id" BEFORE INSERT ON "public"."ratings" FOR EACH ROW EXECUTE FUNCTION "public"."set_rating_from_user_id"();



CREATE OR REPLACE TRIGGER "trg_update_missions_updated_at" BEFORE UPDATE ON "public"."missions" FOR EACH ROW EXECUTE FUNCTION "public"."update_missions_updated_at"();



CREATE OR REPLACE TRIGGER "trg_update_sessions_updated_at" BEFORE UPDATE ON "public"."sessions" FOR EACH ROW EXECUTE FUNCTION "public"."update_sessions_updated_at"();



CREATE OR REPLACE TRIGGER "trg_update_user_updated_at" BEFORE UPDATE ON "public"."users" FOR EACH ROW EXECUTE FUNCTION "public"."update_user_updated_at"();



ALTER TABLE ONLY "public"."mission_scout_events"
    ADD CONSTRAINT "mission_scout_events_mission_id_fkey" FOREIGN KEY ("mission_id") REFERENCES "public"."missions"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."mission_scout_events"
    ADD CONSTRAINT "mission_scout_events_scout_profile_id_fkey" FOREIGN KEY ("scout_profile_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."missions"
    ADD CONSTRAINT "missions_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."missions"
    ADD CONSTRAINT "missions_scout_id_fkey" FOREIGN KEY ("scout_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."missions"
    ADD CONSTRAINT "missions_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_mission_id_fkey" FOREIGN KEY ("mission_id") REFERENCES "public"."missions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_recipient_profile_id_fkey" FOREIGN KEY ("recipient_profile_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_recipient_user_id_fkey" FOREIGN KEY ("recipient_user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_mission_id_fkey" FOREIGN KEY ("mission_id") REFERENCES "public"."missions"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_payee_profile_id_fkey" FOREIGN KEY ("payee_profile_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_payer_profile_id_fkey" FOREIGN KEY ("payer_profile_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."profile_clips"
    ADD CONSTRAINT "profile_clips_profile_id_fkey" FOREIGN KEY ("profile_id") REFERENCES "public"."profiles"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ratings"
    ADD CONSTRAINT "ratings_from_profile_id_fkey" FOREIGN KEY ("from_profile_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."ratings"
    ADD CONSTRAINT "ratings_mission_id_fkey" FOREIGN KEY ("mission_id") REFERENCES "public"."missions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ratings"
    ADD CONSTRAINT "ratings_to_profile_id_fkey" FOREIGN KEY ("to_profile_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."session_recordings"
    ADD CONSTRAINT "session_recordings_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sessions"
    ADD CONSTRAINT "sessions_mission_id_fkey" FOREIGN KEY ("mission_id") REFERENCES "public"."missions"("id") ON DELETE CASCADE;



CREATE POLICY "Enable read access for all users" ON "public"."ratings" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Enable read access for auth users" ON "public"."profile_clips" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Enable read access for auth users" ON "public"."profiles" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Enable update for users based on user_id" ON "public"."profiles" FOR UPDATE TO "authenticated" USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Mission participants can read ratings" ON "public"."ratings" FOR SELECT USING (("mission_id" IN ( SELECT "missions"."id"
   FROM "public"."missions"
  WHERE (("missions"."client_id" = "auth"."uid"()) OR ("missions"."scout_id" = "auth"."uid"())))));



ALTER TABLE "public"."app_config" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "app_config authenticated read" ON "public"."app_config" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "clients can insert own missions" ON "public"."missions" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."user_id" = "auth"."uid"()) AND ("profiles"."role" = 'client'::"public"."role_type")))));



ALTER TABLE "public"."mission_scout_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."missions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "missions_select_assigned_scout" ON "public"."missions" FOR SELECT TO "authenticated" USING ((("scout_id" IS NOT NULL) AND "public"."owns_profile"("scout_id")));



CREATE POLICY "missions_select_own_client" ON "public"."missions" FOR SELECT TO "authenticated" USING ("public"."owns_profile"("client_id"));



CREATE POLICY "missions_select_pool_for_scouts" ON "public"."missions" FOR SELECT TO "authenticated" USING ((("scout_id" IS NULL) AND ("published_at" IS NOT NULL) AND ("status" = ANY (ARRAY['open'::"public"."mission_status", 'cancelled'::"public"."mission_status"])) AND "public"."is_scout"()));



CREATE POLICY "missions_update_assigned_scout" ON "public"."missions" FOR UPDATE TO "authenticated" USING ((("scout_id" IS NOT NULL) AND "public"."owns_profile"("scout_id"))) WITH CHECK ((("scout_id" IS NULL) OR "public"."owns_profile"("scout_id")));



CREATE POLICY "missions_update_own_client" ON "public"."missions" FOR UPDATE TO "authenticated" USING ("public"."owns_profile"("client_id")) WITH CHECK ("public"."owns_profile"("client_id"));



ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "notifications_select_own" ON "public"."notifications" FOR SELECT TO "authenticated" USING (("recipient_user_id" = "auth"."uid"()));



CREATE POLICY "notifications_update_own" ON "public"."notifications" FOR UPDATE TO "authenticated" USING (("recipient_user_id" = "auth"."uid"())) WITH CHECK (("recipient_user_id" = "auth"."uid"()));



ALTER TABLE "public"."payments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "payments_participant_read" ON "public"."payments" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."user_id" = "auth"."uid"()) AND ("p"."id" = ANY (ARRAY["payments"."payer_profile_id", "payments"."payee_profile_id"]))))));



CREATE POLICY "payments_select_own_party" ON "public"."payments" FOR SELECT TO "authenticated" USING (("public"."owns_profile"("payer_profile_id") OR "public"."owns_profile"("payee_profile_id")));



ALTER TABLE "public"."profile_clips" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "profile_clips_delete_own" ON "public"."profile_clips" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "profile_clips"."profile_id") AND ("profiles"."user_id" = "auth"."uid"())))));



CREATE POLICY "profile_clips_insert_own" ON "public"."profile_clips" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "profile_clips"."profile_id") AND ("profiles"."user_id" = "auth"."uid"())))));



CREATE POLICY "profile_clips_update_own" ON "public"."profile_clips" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "profile_clips"."profile_id") AND ("profiles"."user_id" = "auth"."uid"()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "profile_clips"."profile_id") AND ("profiles"."user_id" = "auth"."uid"())))));



ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ratings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "ratings_insert_mission_participants" ON "public"."ratings" FOR INSERT TO "authenticated" WITH CHECK ("public"."can_rate_on_mission"("mission_id", "from_profile_id", "to_profile_id"));



CREATE POLICY "scout reads own events" ON "public"."mission_scout_events" FOR SELECT USING (("scout_profile_id" IN ( SELECT "profiles"."id"
   FROM "public"."profiles"
  WHERE ("profiles"."user_id" = "auth"."uid"()))));



ALTER TABLE "public"."session_recordings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "session_recordings_select_participants" ON "public"."session_recordings" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."sessions" "s"
  WHERE (("s"."id" = "session_recordings"."session_id") AND "public"."is_mission_participant"("s"."mission_id")))));



ALTER TABLE "public"."sessions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "sessions_select_participants" ON "public"."sessions" FOR SELECT TO "authenticated" USING ("public"."is_mission_participant"("mission_id"));



ALTER TABLE "public"."users" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "users_delete_admin_only" ON "public"."users" FOR DELETE TO "supabase_admin" USING (true);



CREATE POLICY "users_insert_admin_only" ON "public"."users" FOR INSERT TO "supabase_admin" WITH CHECK (true);



CREATE POLICY "users_select_own" ON "public"."users" FOR SELECT TO "authenticated" USING (("id" = "auth"."uid"()));



CREATE POLICY "users_update_own" ON "public"."users" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "id"));





ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";






ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."mission_scout_events";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."missions";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."notifications";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."payments";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."profiles";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."session_recordings";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."sessions";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."users";









GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";
GRANT USAGE ON SCHEMA "public" TO "supabase_auth_admin";








































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































GRANT ALL ON FUNCTION "public"."accept_mission"("p_mission_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."accept_mission"("p_mission_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."accept_mission"("p_mission_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."broadcast_mission_pool_change"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."broadcast_mission_pool_change"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."can_rate_on_mission"("p_mission_id" "uuid", "p_from_profile_id" "uuid", "p_to_profile_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."can_rate_on_mission"("p_mission_id" "uuid", "p_from_profile_id" "uuid", "p_to_profile_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."can_rate_on_mission"("p_mission_id" "uuid", "p_from_profile_id" "uuid", "p_to_profile_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."can_read_recording"("p_object_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."can_read_recording"("p_object_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."can_read_recording"("p_object_name" "text") TO "service_role";



GRANT ALL ON TABLE "public"."notifications" TO "service_role";
GRANT SELECT ON TABLE "public"."notifications" TO "authenticated";



GRANT UPDATE("read_at") ON TABLE "public"."notifications" TO "authenticated";



REVOKE ALL ON FUNCTION "public"."claim_notification"("p_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."claim_notification"("p_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."cleanup_stuck_ending_sessions"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cleanup_stuck_ending_sessions"() TO "anon";
GRANT ALL ON FUNCTION "public"."cleanup_stuck_ending_sessions"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."cleanup_stuck_ending_sessions"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."custom_access_token_hook"("event" "jsonb") FROM PUBLIC;
REVOKE ALL ON FUNCTION "public"."custom_access_token_hook"("event" "jsonb") FROM "anon";
REVOKE ALL ON FUNCTION "public"."custom_access_token_hook"("event" "jsonb") FROM "authenticated";
GRANT ALL ON FUNCTION "public"."custom_access_token_hook"("event" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."custom_access_token_hook"("event" "jsonb") TO "supabase_auth_admin";



REVOKE ALL ON FUNCTION "public"."decline_mission"("p_mission_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."decline_mission"("p_mission_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."decline_mission"("p_mission_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."dispatch_guide_payouts"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."dispatch_guide_payouts"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."dispatch_notification"("p_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."dispatch_notification"("p_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."enqueue_notification"("p_profile_id" "uuid", "p_type" "text", "p_mission_id" "uuid", "p_data" "jsonb", "p_dedupe_key" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."enqueue_notification"("p_profile_id" "uuid", "p_type" "text", "p_mission_id" "uuid", "p_data" "jsonb", "p_dedupe_key" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."expire_live_rooms"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."expire_live_rooms"() TO "anon";
GRANT ALL ON FUNCTION "public"."expire_live_rooms"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."expire_live_rooms"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."expire_unpaid_live_requests"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."expire_unpaid_live_requests"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_missions_within_radius"("lat" double precision, "lng" double precision, "radius_m" double precision) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_missions_within_radius"("lat" double precision, "lng" double precision, "radius_m" double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_missions_within_radius"("lat" double precision, "lng" double precision, "radius_m" double precision) TO "service_role";



GRANT ALL ON FUNCTION "public"."guard_mission_update"() TO "anon";
GRANT ALL ON FUNCTION "public"."guard_mission_update"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."guard_mission_update"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_user_update"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_user_update"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_user_update"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_mission_participant"("p_mission_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_mission_participant"("p_mission_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_mission_participant"("p_mission_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."is_scout"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_scout"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_scout"() TO "service_role";



GRANT ALL ON FUNCTION "public"."link_session_to_mission"() TO "anon";
GRANT ALL ON FUNCTION "public"."link_session_to_mission"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."link_session_to_mission"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."live_request_payment_window"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."live_request_payment_window"() TO "service_role";



GRANT ALL ON TABLE "public"."missions" TO "anon";
GRANT ALL ON TABLE "public"."missions" TO "authenticated";
GRANT ALL ON TABLE "public"."missions" TO "service_role";



REVOKE ALL ON FUNCTION "public"."mission_push_data"("p_mission" "public"."missions", "p_scout_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."mission_push_data"("p_mission" "public"."missions", "p_scout_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."notifications_dispatch_on_insert"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."notifications_dispatch_on_insert"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."notify_live_request_created"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."notify_live_request_created"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."notify_mission_status_change"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."notify_mission_status_change"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."notify_request_paid"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."notify_request_paid"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."notify_scout_live"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."notify_scout_live"() TO "service_role";



GRANT ALL ON FUNCTION "public"."notify_scout_unassigned"() TO "anon";
GRANT ALL ON FUNCTION "public"."notify_scout_unassigned"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."notify_scout_unassigned"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."owns_profile"("p_profile_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."owns_profile"("p_profile_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."owns_profile"("p_profile_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."platform_commission_percent"() TO "anon";
GRANT ALL ON FUNCTION "public"."platform_commission_percent"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."platform_commission_percent"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."profile_display_name"("p_profile_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."profile_display_name"("p_profile_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."publish_mission_on_payment"() TO "anon";
GRANT ALL ON FUNCTION "public"."publish_mission_on_payment"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."publish_mission_on_payment"() TO "service_role";



GRANT ALL ON FUNCTION "public"."reclaim_stale_missions"() TO "anon";
GRANT ALL ON FUNCTION "public"."reclaim_stale_missions"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."reclaim_stale_missions"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."retry_notifications"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."retry_notifications"() TO "service_role";



GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "anon";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."search_missions"("p_lat" double precision, "p_lng" double precision, "p_sort" "text", "p_limit" integer, "p_cursor_key" double precision, "p_cursor_id" "uuid", "p_usd_kes" numeric, "p_radius_m" double precision) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."search_missions"("p_lat" double precision, "p_lng" double precision, "p_sort" "text", "p_limit" integer, "p_cursor_key" double precision, "p_cursor_id" "uuid", "p_usd_kes" numeric, "p_radius_m" double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."search_missions"("p_lat" double precision, "p_lng" double precision, "p_sort" "text", "p_limit" integer, "p_cursor_key" double precision, "p_cursor_id" "uuid", "p_usd_kes" numeric, "p_radius_m" double precision) TO "service_role";



GRANT ALL ON FUNCTION "public"."set_mission_client_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_mission_client_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_mission_client_id"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_mission_commission"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_mission_commission"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_rating_from_user_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_rating_from_user_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_rating_from_user_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."stream_clock"("p_mission_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."stream_clock"("p_mission_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."stream_clock"("p_mission_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_missions_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_missions_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_missions_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_scout_location"("lat" double precision, "lng" double precision) TO "anon";
GRANT ALL ON FUNCTION "public"."update_scout_location"("lat" double precision, "lng" double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_scout_location"("lat" double precision, "lng" double precision) TO "service_role";



GRANT ALL ON FUNCTION "public"."update_sessions_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_sessions_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_sessions_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_user_rating"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_user_rating"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_user_rating"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_user_role"("p_user_id" "uuid", "p_role" "public"."role_type") TO "anon";
GRANT ALL ON FUNCTION "public"."update_user_role"("p_user_id" "uuid", "p_role" "public"."role_type") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_user_role"("p_user_id" "uuid", "p_role" "public"."role_type") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_user_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_user_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_user_updated_at"() TO "service_role";





























































































GRANT ALL ON TABLE "public"."app_config" TO "anon";
GRANT ALL ON TABLE "public"."app_config" TO "authenticated";
GRANT ALL ON TABLE "public"."app_config" TO "service_role";



GRANT ALL ON TABLE "public"."mission_scout_events" TO "anon";
GRANT ALL ON TABLE "public"."mission_scout_events" TO "authenticated";
GRANT ALL ON TABLE "public"."mission_scout_events" TO "service_role";



GRANT ALL ON TABLE "public"."payments" TO "anon";
GRANT ALL ON TABLE "public"."payments" TO "authenticated";
GRANT ALL ON TABLE "public"."payments" TO "service_role";



GRANT ALL ON TABLE "public"."payment_statements" TO "authenticated";
GRANT ALL ON TABLE "public"."payment_statements" TO "service_role";



GRANT ALL ON TABLE "public"."profile_clips" TO "anon";
GRANT ALL ON TABLE "public"."profile_clips" TO "authenticated";
GRANT ALL ON TABLE "public"."profile_clips" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."ratings" TO "anon";
GRANT ALL ON TABLE "public"."ratings" TO "authenticated";
GRANT ALL ON TABLE "public"."ratings" TO "service_role";



GRANT ALL ON TABLE "public"."session_recordings" TO "service_role";
GRANT SELECT ON TABLE "public"."session_recordings" TO "authenticated";



GRANT ALL ON TABLE "public"."sessions" TO "anon";
GRANT ALL ON TABLE "public"."sessions" TO "authenticated";
GRANT ALL ON TABLE "public"."sessions" TO "service_role";



GRANT ALL ON TABLE "public"."users" TO "anon";
GRANT ALL ON TABLE "public"."users" TO "authenticated";
GRANT ALL ON TABLE "public"."users" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";
