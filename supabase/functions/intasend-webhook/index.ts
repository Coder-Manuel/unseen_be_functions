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
    .select(
      "id, status, amount, currency, metadata, mission_id, merchant_request_id",
    )
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

  const previous = payment.metadata as Record<string, unknown> | null ?? {};
  const superseded = (previous.superseded_invoices as string[] | undefined) ??
    [];

  // A retry re-prompted under the same row; the earlier prompt timing out or
  // being cancelled says nothing about the current one.
  if (status !== "success" && superseded.includes(invoice.invoice_id)) return;

  // Keep whatever the initiating call recorded (notably metadata.method).
  const metadata = { ...previous, provider_event: invoice };

  if (status === "processing") {
    await supabase
      .from("payments")
      .update({ merchant_request_id: invoice.invoice_id, metadata })
      .eq("id", payment.id)
      .in("status", ["pending", "processing"]);
    return;
  }

  if (payment.status === "success") {
    if (
      status === "success" && payment.merchant_request_id !== invoice.invoice_id
    ) {
      console.error(
        "Duplicate collection, refund needed:",
        payment.id,
        invoice.invoice_id,
      );
      await supabase
        .from("payments")
        .update({
          metadata: {
            ...previous,
            duplicate_invoices: [
              ...((previous.duplicate_invoices as string[] | undefined) ?? []),
              invoice.invoice_id,
            ],
          },
        })
        .eq("id", payment.id);
    }
    return;
  }

  // A success is recorded even after the row was failed or cancelled (a
  // timed-out or superseded prompt that the payer completed anyway).
  const lateSuccess = status === "success" && FINAL.includes(payment.status);
  if (FINAL.includes(payment.status) && !lateSuccess) return;

  const update = {
    status,
    merchant_request_id: invoice.invoice_id,
    provider_ref: status === "success"
      ? invoice.mpesa_reference ?? invoice.invoice_id
      : null,
    failure_reason: status === "success" ? null : failureReason,
    metadata,
  };
  const fromStatuses = lateSuccess
    ? [payment.status]
    : ["pending", "processing"];

  const { error } = await supabase
    .from("payments")
    .update(update)
    .eq("id", payment.id)
    .in("status", fromStatuses);

  // 23505: a newer attempt is the mission's active payment.
  if (error?.code === "23505" && payment.mission_id) {
    await settleOverNewerAttempt(supabase, payment.id, payment.mission_id);
    await supabase
      .from("payments")
      .update(update)
      .eq("id", payment.id)
      .in("status", fromStatuses);
  } else if (error) {
    throw error;
  }
}

// Clears the mission's newer in-flight attempt so a late success on an older
// one can become the mission's payment. A newer attempt that already
// succeeded means the client paid twice.
async function settleOverNewerAttempt(
  supabase: Supabase,
  paymentId: string,
  missionId: string,
) {
  const { data: other } = await supabase
    .from("payments")
    .select("id, status, metadata")
    .eq("mission_id", missionId)
    .eq("type", "inbound")
    .neq("id", paymentId)
    .in("status", ["pending", "processing", "success"])
    .maybeSingle();
  if (!other) return;

  if (other.status === "success") {
    console.error("Duplicate collection, refund needed:", paymentId, other.id);
    throw new Error(`Mission ${missionId} already paid by ${other.id}`);
  }

  await supabase
    .from("payments")
    .update({
      status: "cancelled",
      failure_reason: "Paid by an earlier M-Pesa request",
      metadata: {
        ...(other.metadata as Record<string, unknown> | null ?? {}),
        settled_by: paymentId,
      },
    })
    .eq("id", other.id)
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
