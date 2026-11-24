-- payment_statements: the statements page's rows. Re-runnable.
--
-- The app has read this view for a while, but it was never created. One row
-- per payment the caller is party to: payouts to their guide profile and
-- payments from their client profile. The view runs as its owner, so it
-- filters to the caller's own profiles itself rather than relying on the
-- payments policies.

create or replace view public.payment_statements as
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
join public.profiles p
  on p.id = case
    when pay.type = 'outbound' then pay.payee_profile_id
    else pay.payer_profile_id
  end
left join public.missions m on m.id = pay.mission_id
where p.user_id = auth.uid()
  -- Prompts never sent, and attempts the client cancelled or replaced.
  and not (pay.type = 'inbound' and pay.status in ('pending', 'cancelled'));

revoke all on public.payment_statements from public, anon;
grant select on public.payment_statements to authenticated;
