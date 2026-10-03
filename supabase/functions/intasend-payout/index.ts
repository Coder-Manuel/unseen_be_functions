// Pays a completed mission's scout via IntaSend M-Pesa B2C.
// Service-authenticated: money-out is only triggered by trusted backends.
import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "@supabase/supabase-js";
import {
  intasendMpesaB2C,
  mapSendMoneyStatus,
  normalizeKenyanPhone,
  ServiceAuthMiddleware,
} from "shared";

Deno.serve((r) =>
  ServiceAuthMiddleware(r, async (req) => {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    let payload: {
      mission_id?: string;
      phone_number?: string;
      amount?: number;
    };
    try {
      payload = await req.json();
    } catch {
      return Response.json({ error: "Invalid JSON body" }, { status: 400 });
    }

    const { mission_id, phone_number } = payload;
    if (!mission_id || !phone_number) {
      return Response.json(
        { error: "mission_id and phone_number are required" },
        { status: 400 },
      );
    }

    const phone = normalizeKenyanPhone(phone_number);
    if (!phone) {
      return Response.json(
        { error: "Invalid phone number, expected format 2547XXXXXXXX" },
        { status: 400 },
      );
    }

    const { data: mission, error } = await supabase
      .from("missions")
      .select(`
        id,
        status,
        price,
        currency,
        scout:profiles!missions_scout_id_fkey (id, user_id)
      `)
      .eq("id", mission_id)
      .maybeSingle();

    if (error) return Response.json({ error: error.message }, { status: 400 });
    if (!mission) {
      return Response.json({ error: "Mission not found" }, { status: 404 });
    }

    const scout = Array.isArray(mission.scout)
      ? mission.scout[0]
      : mission.scout;
    if (!scout?.id) {
      return Response.json(
        { error: "Mission has no scout to pay" },
        { status: 400 },
      );
    }
    if (mission.status !== "completed") {
      return Response.json(
        { error: "Mission must be completed before payout" },
        { status: 409 },
      );
    }

    // The client must have paid before the scout is paid out.
    const { data: inbound } = await supabase
      .from("payments")
      .select("id, amount")
      .eq("mission_id", mission_id)
      .eq("type", "inbound")
      .eq("status", "success")
      .limit(1)
      .maybeSingle();
    if (!inbound) {
      return Response.json(
        { error: "Mission has not been paid by the client" },
        { status: 409 },
      );
    }

    // Defaults to the collected amount; a smaller amount (e.g. net of
    // platform fees) may be passed, never more.
    const collected = Number(inbound.amount);
    const amount = payload.amount === undefined
      ? collected
      : Number(payload.amount);
    if (!Number.isFinite(amount) || amount <= 0 || amount > collected) {
      return Response.json(
        { error: `amount must be > 0 and <= ${collected}` },
        { status: 400 },
      );
    }

    // Never send twice: only an unsent pending row may be retried.
    const { data: activeRows } = await supabase
      .from("payments")
      .select("id, status")
      .eq("mission_id", mission_id)
      .eq("type", "outbound")
      .in("status", ["pending", "processing", "success"])
      .order("created_at", { ascending: false })
      .limit(1);
    const active = activeRows?.[0];

    if (active && active.status !== "pending") {
      return Response.json(
        { error: `Payout already ${active.status}`, payment_id: active.id },
        { status: 409 },
      );
    }

    let paymentId = active?.id as string | undefined;
    if (!paymentId) {
      const { data: created, error: insErr } = await supabase
        .from("payments")
        .insert({
          amount,
          currency: mission.currency ?? "KES",
          provider: "intasend",
          status: "pending",
          type: "outbound",
          metadata: { method: "mpesa" },
          phone_number: phone,
          payee_profile_id: scout.id,
          mission_id,
        })
        .select("id")
        .single();
      if (insErr) {
        // 23505: a concurrent request created the payout first.
        const status = insErr.code === "23505" ? 409 : 400;
        return Response.json({ error: insErr.message }, { status });
      }
      paymentId = created.id;
    }

    try {
      const result = await intasendMpesaB2C({
        currency: mission.currency ?? "KES",
        batchReference: paymentId,
        callbackUrl: `${
          Deno.env.get("SUPABASE_URL")
        }/functions/v1/intasend-webhook`,
        transactions: [{
          account: phone,
          amount,
          narrative: `Mission ${String(mission_id).slice(0, 8)} payout`,
        }],
      });

      const mapped = mapSendMoneyStatus(result);
      const txn = result.transactions?.[0];
      await supabase
        .from("payments")
        .update({
          // Terminal success only arrives via the webhook/status check.
          status: mapped === "failed" ? "failed" : "processing",
          phone_number: phone,
          checkout_request_id: result.tracking_id,
          merchant_request_id: result.file_id ?? null,
          failure_reason: mapped === "failed"
            ? txn?.status_description ?? result.status
            : null,
          metadata: { method: "mpesa", provider_event: result },
        })
        .eq("id", paymentId);

      return Response.json({
        payment_id: paymentId,
        tracking_id: result.tracking_id,
        status: result.status,
      });
    } catch (e) {
      console.error("IntaSend payout failed:", e);
      await supabase
        .from("payments")
        .update({ status: "failed", failure_reason: String(e) })
        .eq("id", paymentId);
      return Response.json(
        { error: "Failed to initiate payout" },
        { status: 502 },
      );
    }
  })
);
