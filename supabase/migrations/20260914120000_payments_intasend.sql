-- Payments schema changes for the IntaSend integration (inbound M-Pesa/card
-- collections + outbound M-Pesa B2C payouts). Re-runnable.
--
-- No provider-specific columns are added: the existing provider columns are
-- reused by every provider, per this convention.
--
--   provider             'mpesa' (Daraja direct) | 'intasend' | …
--   checkout_request_id  the provider's id for the in-flight request:
--                          Daraja    -> CheckoutRequestID
--                          IntaSend  -> invoice_id (STK) / checkout id (card)
--                                     / tracking_id (payout batch)
--   merchant_request_id  the provider's secondary/settlement id:
--                          Daraja    -> MerchantRequestID
--                          IntaSend  -> invoice_id once the card invoice exists
--                                     / file_id (payout batch)
--   provider_ref         the final receipt, set once and only on success:
--                          M-Pesa receipt number, or the provider reference
--   metadata             { "method": "mpesa" | "card",
--                          "provider_event": <last raw provider payload> }
--
-- Keeping these generic means the next provider needs no migration at all.

-- 1. The one-active-payment guard must be per direction, otherwise a settled
--    inbound payment blocks the scout's payout for the same mission.
drop index if exists public.payments_one_active_per_mission;
create unique index if not exists payments_one_active_per_mission_type
  on public.payments (mission_id, type)
  where status in ('pending', 'processing', 'success');

-- 2. Lookup index for the webhook, which resolves a card invoice id against
--    the secondary id. (checkout_request_id is already uniquely indexed.)
create index if not exists payments_merchant_request_id_idx
  on public.payments (merchant_request_id)
  where merchant_request_id is not null;
