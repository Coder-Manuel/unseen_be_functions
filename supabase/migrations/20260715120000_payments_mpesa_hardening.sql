-- Payments schema hardening for the M-Pesa (Daraja) integration.
-- The `payments` table already exists; this migration makes it safe for
-- idempotent, auditable payment processing. It is written to be re-runnable.
--
-- Assumes the table is not yet populated with rows that would violate the
-- NOT NULL / CHECK constraints below.

-- 1. Fix the misspelled column: update_at -> updated_at
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'payments'
      and column_name = 'update_at'
  ) and not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'payments'
      and column_name = 'updated_at'
  ) then
    alter table public.payments rename column update_at to updated_at;
  end if;
end $$;

-- 2. Tighten money/provider/status columns.
alter table public.payments
  alter column amount   type numeric(12, 2),
  alter column amount   set not null,
  alter column currency set default 'KES',
  alter column currency set not null,
  alter column provider set default 'mpesa',
  alter column provider set not null,
  alter column status   set default 'pending',
  alter column status   set not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'payments_amount_positive'
  ) then
    alter table public.payments
      add constraint payments_amount_positive check (amount > 0);
  end if;

  if not exists (
    select 1 from pg_constraint where conname = 'payments_status_check'
  ) then
    alter table public.payments
      add constraint payments_status_check check (
        status in (
          'pending', 'processing', 'success',
          'failed', 'cancelled', 'refunded'
        )
      );
  end if;
end $$;

-- 3. M-Pesa-specific columns.
--    checkout_request_id / merchant_request_id come from the STK push;
--    provider_ref stores the final M-Pesa receipt number;
--    metadata keeps the raw callback for auditing/reconciliation.
alter table public.payments
  add column if not exists checkout_request_id text,
  add column if not exists merchant_request_id text,
  add column if not exists phone_number        text,
  add column if not exists failure_reason      text,
  add column if not exists metadata            jsonb not null default '{}'::jsonb;

-- 4. Idempotency & lookup indexes.
-- Daraja's CheckoutRequestID uniquely identifies an STK push attempt.
create unique index if not exists payments_checkout_request_id_key
  on public.payments (checkout_request_id)
  where checkout_request_id is not null;

-- The provider receipt (M-Pesa code) must never be recorded twice.
create unique index if not exists payments_provider_ref_key
  on public.payments (provider, provider_ref)
  where provider_ref is not null;

-- At most one in-flight/settled payment per mission — prevents double charging.
create unique index if not exists payments_one_active_per_mission
  on public.payments (mission_id)
  where status in ('pending', 'processing', 'success');

create index if not exists payments_mission_id_idx on public.payments (mission_id);
create index if not exists payments_payer_idx       on public.payments (payer_profile_id);
create index if not exists payments_status_idx      on public.payments (status);

-- 5. Auto-maintain updated_at on every UPDATE.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end $$;

drop trigger if exists payments_set_updated_at on public.payments;
create trigger payments_set_updated_at
  before update on public.payments
  for each row execute function public.set_updated_at();
