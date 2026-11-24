-- payment_statements runs as the querying user (security_invoker), so the
-- payments, profiles and missions policies apply. Re-runnable.
--
-- The view ran as its owner, which the Supabase linter flags. Ownership is now
-- checked with owns_profile() (definer) instead of joining profiles, and a
-- payments policy lets each party read their own rows: the payer their
-- payment, the guide their payout.

drop policy if exists payments_select_own_party on public.payments;
create policy payments_select_own_party
  on public.payments
  for select
  to authenticated
  using (
    public.owns_profile(payer_profile_id)
    or public.owns_profile(payee_profile_id)
  );

create or replace view public.payment_statements
with (security_invoker = true)
as
select
  pay.id,
  pay.created_at,
  pay.updated_at,
  pay.mission_id,
  case when pay.type = 'outbound' then 'payout' else 'payment' end as direction,
  initcap(replace(coalesce(m.type::text, 'live check'), '_', ' ')) as mission_title,
  coalesce(nullif(trim(split_part(m.address, ',', 1)), ''), '') as location,
  pay.amount,
  pay.currency,
  case
    when pay.status = 'success' then 'disbursed'
    when pay.status in ('pending', 'processing') then 'pending'
    else 'failed'
  end as status,
  case
    when pay.metadata ->> 'method' = 'card' then 'CARD'
    when pay.phone_number ~ '^254[0-9]{9}$' then
      'M-PESA (0' || substr(pay.phone_number, 4, 2) || '*****'
        || right(pay.phone_number, 2) || ')'
    else 'M-PESA'
  end as channel
from public.payments pay
left join public.missions m on m.id = pay.mission_id
where public.owns_profile(
    case
      when pay.type = 'outbound' then pay.payee_profile_id
      else pay.payer_profile_id
    end
  )
  -- Prompts never sent, and attempts the client cancelled or replaced.
  and not (pay.type = 'inbound' and pay.status in ('pending', 'cancelled'));

revoke all on public.payment_statements from public, anon;
grant select on public.payment_statements to authenticated;
