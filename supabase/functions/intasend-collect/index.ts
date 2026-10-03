// Collects a mission payment from its client through IntaSend, either by
// M-Pesa STK push or by card (hosted checkout URL).
// Authenticated: only the mission's client may trigger a charge.
import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "@supabase/supabase-js";
import {
  ClientAuthMiddleware,
  intasendCreateCheckout,
  intasendSTKPush,
  normalizeKenyanPhone,
} from "shared";

type Method = "mpesa" | "card";

Deno.serve((r) =>
  ClientAuthMiddleware(r, async (req, authUser) => {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    let payload: {
      mission_id?: string;
      method?: Method;
      phone_number?: string;
      email?: string;
      redirect_url?: string;
    };
    try {
      payload = await req.json();
    } catch {
      return Response.json({ error: "Invalid JSON body" }, { status: 400 });
    }

    const { mission_id, method, phone_number, email, redirect_url } = payload;
    if (!mission_id || (method !== "mpesa" && method !== "card")) {
      return Response.json(
        { error: "mission_id and method ('mpesa' | 'card') are required" },
        { status: 400 },
      );
    }

    let phone: string | null = null;
    if (method === "mpesa") {
      phone = phone_number ? normalizeKenyanPhone(phone_number) : null;
      if (!phone) {
        return Response.json(
          { error: "Invalid phone number, expected format 2547XXXXXXXX" },
          { status: 400 },
        );
      }
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
    const currency = mission.currency ?? "KES";

    // Reuse an in-flight inbound payment; reject if it is already paid.
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
          currency,
          provider: "intasend",
          status: "pending",
          type: "inbound",
          metadata: { method },
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

    try {
      // api_ref = our payment id; the webhook uses it to find the row.
      if (method === "mpesa") {
        const stk = await intasendSTKPush({
          phoneNumber: phone!,
          amount,
          apiRef: paymentId!,
        });

        await supabase
          .from("payments")
          .update({
            status: "processing",
            provider: "intasend",
            phone_number: phone,
            // The invoice is both the in-flight id and the settlement id here.
            checkout_request_id: stk.invoice.invoice_id,
            merchant_request_id: stk.invoice.invoice_id,
            metadata: { method, provider_event: stk },
          })
          .eq("id", paymentId);

        return Response.json({
          message: "Check your phone to complete the M-Pesa payment",
          payment_id: paymentId,
          invoice_id: stk.invoice.invoice_id,
        });
      }

      const checkout = await intasendCreateCheckout({
        amount,
        currency,
        apiRef: paymentId!,
        method: "CARD-PAYMENT",
        email,
        redirectUrl: redirect_url ?? Deno.env.get("INTASEND_REDIRECT_URL"),
      });

      await supabase
        .from("payments")
        .update({
          status: "processing",
          provider: "intasend",
          // The invoice id only exists once the card is charged; the webhook
          // fills merchant_request_id in then.
          checkout_request_id: checkout.id,
          metadata: { method, provider_event: checkout },
        })
        .eq("id", paymentId);

      return Response.json({
        payment_id: paymentId,
        checkout_id: checkout.id,
        checkout_url: checkout.url,
      });
    } catch (e) {
      console.error("IntaSend collection failed:", e);
      await supabase
        .from("payments")
        .update({ status: "failed", failure_reason: String(e) })
        .eq("id", paymentId);
      return Response.json(
        { error: "Failed to initiate payment" },
        { status: 502 },
      );
    }
  })
);
