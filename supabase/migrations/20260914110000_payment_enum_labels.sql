-- Every status/type label the edge functions write must exist as an enum label.
-- These live in their own migration on purpose: Postgres forbids USING a label
-- in the same transaction that adds it, and the next migration's partial
-- indexes reference these labels in their WHERE clause.
alter type public.payment_status add value if not exists 'pending';
alter type public.payment_status add value if not exists 'processing';
alter type public.payment_status add value if not exists 'success';
alter type public.payment_status add value if not exists 'failed';
alter type public.payment_status add value if not exists 'cancelled';
alter type public.payment_status add value if not exists 'refunded';

alter type public.payment_type add value if not exists 'inbound';
alter type public.payment_type add value if not exists 'outbound';
