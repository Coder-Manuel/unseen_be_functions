-- Platform commission and automatic guide payouts. Re-runnable.
--
-- The client pays the mission price; the guide is paid that price less the
-- platform commission (app_config.platform_commission, default 10%). The
-- percent is snapshotted on each mission so a later rate change never alters
-- what an existing mission pays out.

-- 1. Two of the "one active payment per mission" indexes ignore the payment
--    type, so a mission whose client payment succeeded could never get an
--    active payout row. The (mission_id, type) index keeps one active row of
--    each kind.
create unique index if not exists payments_one_active_per_mission_type
  on public.payments (mission_id, type)
  where status in ('pending', 'processing', 'success');
drop index if exists public.payments_one_active_per_mission;
drop index if exists public.idx_payments_one_active_per_mission;

-- 2. Config. `payouts_since` keeps the payout job off missions completed
--    before it existed, which may already have been paid by hand.
insert into public.app_config (key, value, description)
values (
  'platform_commission',
  '{"percent": 10}'::jsonb,
  'Percent of the mission price the platform keeps; the guide is paid the rest'
)
on conflict (key) do nothing;

insert into public.app_config (key, value, description)
values (
  'guide_payouts',
  jsonb_build_object('enabled', true, 'payouts_since', now(), 'max_attempts', 3),
  'Automatic M-Pesa payouts to guides for completed, paid missions'
)
on conflict (key) do nothing;

create or replace function public.platform_commission_percent()
returns numeric
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(
    (select least(greatest((value ->> 'percent')::numeric, 0), 100)
     from public.app_config
     where key = 'platform_commission'),
    10
  );
$$;

-- 3. Per-mission split.
alter table public.missions
  add column if not exists commission_percent numeric(5, 2),
  add column if not exists platform_fee numeric(12, 2),
  add column if not exists guide_amount numeric(12, 2);

-- Always derived here, so a client cannot write its own split.
create or replace function public.set_mission_commission()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
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

drop trigger if exists trg_set_mission_commission on public.missions;
create trigger trg_set_mission_commission
  before insert or update of price, commission_percent, platform_fee, guide_amount
  on public.missions
  for each row
  execute function public.set_mission_commission();

-- Fires the trigger for existing rows.
update public.missions
set commission_percent = null
where commission_percent is null;

-- 4. Payout dispatch. Same transport as dispatch_notification; intasend-payout
--    computes the amount itself and guards against paying twice.
create or replace function public.dispatch_guide_payouts()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
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

revoke execute on function public.dispatch_guide_payouts()
  from public, anon, authenticated;
revoke execute on function public.set_mission_commission()
  from public, anon, authenticated;
grant execute on function public.platform_commission_percent()
  to authenticated, service_role;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'dispatch-guide-payouts') then
    perform cron.unschedule('dispatch-guide-payouts');
  end if;
  perform cron.schedule(
    'dispatch-guide-payouts',
    '*/5 * * * *',
    ' SELECT public.dispatch_guide_payouts(); '
  );
end $$;
