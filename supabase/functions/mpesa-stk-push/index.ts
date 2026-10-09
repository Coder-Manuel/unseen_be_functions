// Initiates an M-Pesa STK push so a mission's client can pay for it.
// Authenticated: only the mission's client may trigger a charge.
import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "@supabase/supabase-js";
import {
  ClientAuthMiddleware,
  initiateSTKPush,
  normalizeKenyanPhone,
} from "shared";

Deno.serve((r) =>
  ClientAuthMiddleware(r, async (req, authUser) => {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    let payload: { mission_id?: string; phone_number?: string };
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

    // Load the mission; price/currency are server-authoritative.
    const { data: mission, error } = await supabase
      .from("missions")
      .select(`
        id,
        status,
        price,
        currency,
        client:profiles!missions_client_id_fkey!inner (id, user_id)
      `)
      .eq("id", mission_id)
      .maybeSingle();

    if (error) return Response.json({ error: error.message }, { status: 400 });
    if (!mission) {
      return Response.json({ error: "Mission not found" }, { status: 404 });
    }

    const client = Array.isArray(mission.client)
      ? mission.client[0]
      : mission.client;

    // Only the mission's own client may pay for it.
    if (!client || client.user_id !== authUser.id) {
      return Response.json(
        { error: "Only the mission client can pay for this mission" },
        { status: 403 },
      );
    }

    const amount = Number(mission.price);
    if (!Number.isFinite(amount) || amount <= 0) {
      return Response.json(
        { error: "Mission has no payable price" },
        { status: 400 },
      );
    }

    // Reuse an in-flight payment; reject if it is already paid.
    // Scoped to inbound: a mission's outbound payout row must not count here.
    const { data: activeRows } = await supabase
      .from("payments")
      .select("id, status")
      .eq("mission_id", mission_id)
      .eq("type", "inbound")
      .in("status", ["pending", "processing", "success"])
      .order("created_at", { ascending: false })
      .limit(1);
    const active = activeRows?.[0];

    if (active?.status === "success") {
      return Response.json({ error: "Mission already paid" }, { status: 409 });
    }

    let paymentId = active?.id as string | undefined;
    if (!paymentId) {
      const { data: created, error: insErr } = await supabase
        .from("payments")
        .insert({
          amount,
          currency: mission.currency ?? "KES",
          provider: "mpesa",
          status: "pending",
          type: "inbound",
          metadata: { method: "mpesa" },
          phone_number: phone,
          payer_profile_id: client.id,
          mission_id,
        })
        .select("id")
        .single();
      if (insErr) {
        return Response.json({ error: insErr.message }, { status: 400 });
      }
      paymentId = created.id;
    }

    // Callback is unauthenticated; guard it with a shared-secret token.
    const callbackBase = `${
      Deno.env.get("SUPABASE_URL")
    }/functions/v1/mpesa-callback`;
    const callbackSecret = Deno.env.get("MPESA_CALLBACK_SECRET") ?? "";
    const callbackUrl = `${callbackBase}?token=${
      encodeURIComponent(callbackSecret)
    }`;

    try {
      const stk = await initiateSTKPush({
        phoneNumber: phone,
        amount,
        accountReference: String(mission_id).slice(0, 12),
        transactionDesc: "Mission payment",
        callbackUrl,
      });

      await supabase
        .from("payments")
        .update({
          status: "processing",
          phone_number: phone,
          checkout_request_id: stk.CheckoutRequestID,
          merchant_request_id: stk.MerchantRequestID,
        })
        .eq("id", paymentId);

      return Response.json({
        message: stk.CustomerMessage,
        payment_id: paymentId,
        checkout_request_id: stk.CheckoutRequestID,
      });
    } catch (e) {
      console.error("STK push failed:", e);
      await supabase
        .from("payments")
        .update({ status: "failed", failure_reason: String(e) })
        .eq("id", paymentId);
      return Response.json(
        { error: "Failed to initiate M-Pesa payment" },
        { status: 502 },
      );
    }
  })
);
