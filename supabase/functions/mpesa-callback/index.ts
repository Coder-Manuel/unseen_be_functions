// Receives Safaricom's async STK push result and finalizes the payment.
// Unauthenticated by design (Daraja calls it directly), so it is guarded by a
// shared-secret token query param and is idempotent.
import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "@supabase/supabase-js";
import { extractCallbackMetadata, type STKCallbackBody } from "shared";

// Safaricom only cares that it receives this acknowledgement shape.
function ack() {
  return Response.json({ ResultCode: 0, ResultDesc: "Accepted" });
}

Deno.serve(async (req) => {
  const expected = Deno.env.get("MPESA_CALLBACK_SECRET");
  const provided = new URL(req.url).searchParams.get("token");
  if (expected && provided !== expected) {
    return new Response("Forbidden", { status: 403 });
  }

  let body: STKCallbackBody;
  try {
    body = await req.json();
  } catch {
    return ack();
  }

  const cb = body?.Body?.stkCallback;
  if (!cb?.CheckoutRequestID) return ack();

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // checkout_request_id is the shared "in-flight provider request" column, so
  // scope the lookup to inbound Daraja payments.
  const { data: payment } = await supabase
    .from("payments")
    .select("id, status, metadata")
    .eq("type", "inbound")
    .eq("provider", "mpesa")
    .eq("checkout_request_id", cb.CheckoutRequestID)
    .maybeSingle();

  if (!payment) {
    console.warn(
      "Callback for unknown CheckoutRequestID:",
      cb.CheckoutRequestID,
    );
    return ack();
  }

  // Idempotent: ignore callbacks once the payment is finalized.
  if (["success", "failed", "cancelled", "refunded"].includes(payment.status)) {
    return ack();
  }

  // Keep whatever the STK push recorded (notably metadata.method).
  const metadata = {
    ...(payment.metadata as Record<string, unknown> ?? {}),
    provider_event: cb,
  };

  if (cb.ResultCode === 0) {
    const meta = extractCallbackMetadata(cb.CallbackMetadata?.Item);
    await supabase
      .from("payments")
      .update({
        status: "success",
        provider_ref: meta.MpesaReceiptNumber
          ? String(meta.MpesaReceiptNumber)
          : null,
        metadata,
      })
      .eq("id", payment.id)
      .in("status", ["pending", "processing"]);
  } else {
    // 1032 = request cancelled by the user; everything else is a failure.
    await supabase
      .from("payments")
      .update({
        status: cb.ResultCode === 1032 ? "cancelled" : "failed",
        failure_reason: cb.ResultDesc,
        metadata,
      })
      .eq("id", payment.id)
      .in("status", ["pending", "processing"]);
  }

  return ack();
});
