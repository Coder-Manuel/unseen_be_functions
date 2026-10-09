// Receives IntaSend collection and send money events and finalizes payments.
// Unauthenticated by design (IntaSend calls it directly), so it checks the
// dashboard-configured challenge and never trusts the event body: the real
// status is always re-fetched from the IntaSend API. Idempotent.
import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import {
  intasendPaymentStatus,
  intasendSendMoneyStatus,
  type IntaSendWebhookBody,
  mapInvoiceState,
  mapSendMoneyStatus,
} from "shared";

const FINAL = ["success", "failed", "cancelled", "refunded"];
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// Safe to interpolate into a PostgREST `or` filter.
const SAFE_ID_RE = /^[A-Za-z0-9_-]{1,64}$/;

function ok() {
  return Response.json({ received: true });
}

Deno.serve(async (req) => {
  let body: IntaSendWebhookBody;
  try {
    body = await req.json();
  } catch {
    return ok();
  }

  const expected = Deno.env.get("INTASEND_WEBHOOK_CHALLENGE");
  if (!expected || body?.challenge !== expected) {
    return new Response("Forbidden", { status: 403 });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  try {
    if (body.tracking_id) {
      await handleSendMoney(supabase, body.tracking_id);
    } else if (body.invoice_id) {
      await handleCollection(supabase, body.invoice_id, body.api_ref);
    }
  } catch (e) {
    // Non-2xx makes IntaSend retry with backoff.
    console.error("IntaSend webhook processing failed:", e);
    return Response.json({ error: "Processing failed" }, { status: 500 });
  }

  return ok();
});

type Supabase = SupabaseClient;

async function handleCollection(
  supabase: Supabase,
  invoiceId: string,
  apiRef?: string,
) {
  const { invoice } = await intasendPaymentStatus(invoiceId);

  // api_ref is our payment id (set for both STK push and card checkout).
  // Without it, fall back to either provider id: the in-flight one for an STK
  // push, the settlement one for a card invoice.
  const ref = invoice.api_ref ?? apiRef;
  let query = supabase
    .from("payments")
    .select("id, status, amount, currency, metadata")
    .eq("type", "inbound");

  if (ref && UUID_RE.test(ref)) {
    query = query.eq("id", ref);
  } else if (SAFE_ID_RE.test(invoice.invoice_id)) {
    // The id goes into PostgREST's filter grammar, so only ever interpolate
    // one that cannot contain its delimiters.
    query = query.or(
      `checkout_request_id.eq.${invoice.invoice_id},` +
        `merchant_request_id.eq.${invoice.invoice_id}`,
    );
  } else {
    console.warn("Unusable invoice id, skipping:", invoice.invoice_id);
    return;
  }

  const { data: payment } = await query.maybeSingle();

  if (!payment) {
    console.warn("Collection event for unknown payment:", invoiceId, ref);
    return;
  }
  if (FINAL.includes(payment.status)) return;

  let status = mapInvoiceState(invoice.state);
  let failureReason = invoice.failed_reason ?? null;

  // Guard against underpayment / currency mismatch.
  if (
    status === "success" &&
    (Number(invoice.value) < Number(payment.amount) ||
      invoice.currency !== payment.currency)
  ) {
    status = "failed";
    failureReason =
      `Amount mismatch: got ${invoice.value} ${invoice.currency}, expected ${payment.amount} ${payment.currency}`;
  }

  // Keep whatever the initiating call recorded (notably metadata.method).
  const metadata = {
    ...(payment.metadata as Record<string, unknown> ?? {}),
    provider_event: invoice,
  };

  if (status === "processing") {
    await supabase
      .from("payments")
      .update({ merchant_request_id: invoice.invoice_id, metadata })
      .eq("id", payment.id)
      .in("status", ["pending", "processing"]);
    return;
  }

  await supabase
    .from("payments")
    .update({
      status,
      merchant_request_id: invoice.invoice_id,
      provider_ref: status === "success"
        ? invoice.mpesa_reference ?? invoice.invoice_id
        : null,
      failure_reason: status === "success" ? null : failureReason,
      metadata,
    })
    .eq("id", payment.id)
    .in("status", ["pending", "processing"]);
}

async function handleSendMoney(supabase: Supabase, trackingId: string) {
  const { data: payment } = await supabase
    .from("payments")
    .select("id, status, metadata")
    .eq("type", "outbound")
    .eq("checkout_request_id", trackingId)
    .maybeSingle();

  if (!payment) {
    console.warn("Send money event for unknown tracking_id:", trackingId);
    return;
  }
  if (FINAL.includes(payment.status)) return;

  const result = await intasendSendMoneyStatus(trackingId);
  const status = mapSendMoneyStatus(result);
  const txn = result.transactions?.[0];

  await supabase
    .from("payments")
    .update({
      status,
      provider_ref: status === "success"
        ? txn?.provider_reference ?? txn?.transaction_id ?? null
        : null,
      merchant_request_id: result.file_id ?? null,
      failure_reason: status === "failed" || status === "cancelled"
        ? txn?.status_description ?? result.status
        : null,
      metadata: {
        ...(payment.metadata as Record<string, unknown> ?? {}),
        provider_event: result,
      },
    })
    .eq("id", payment.id)
    .in("status", ["pending", "processing"]);
}
