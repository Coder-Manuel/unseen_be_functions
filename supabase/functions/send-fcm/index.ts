// Delivers one queued notification (public.notifications) through FCM.
// Internal: called by the database (dispatch_notification / the
// retry-notifications cron job) with an UNSEEN_FN_KEY-signed token, never by
// the apps. Idempotent: claim_notification lets only one call send a row.
import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "@supabase/supabase-js";
import {
  type FCMMessage,
  renderNotification,
  sendFcm,
  ServiceAuthMiddleware,
} from "shared";

Deno.serve((r) =>
  ServiceAuthMiddleware(r, async (req) => {
    let notificationId: string | undefined;
    try {
      ({ notification_id: notificationId } = await req.json());
    } catch {
      return Response.json({ error: "Invalid JSON body" }, { status: 400 });
    }
    if (!notificationId) {
      return Response.json(
        { error: "notification_id is required" },
        { status: 400 },
      );
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data: claimed, error: claimErr } = await supabase
      .rpc("claim_notification", { p_id: notificationId });
    if (claimErr) {
      return Response.json({ error: claimErr.message }, { status: 500 });
    }
    const notification = claimed?.[0];
    if (!notification) {
      // Already sent, being sent, or given up on.
      return Response.json({ status: "not_claimable" });
    }

    const finish = (fields: Record<string, unknown>) =>
      supabase.from("notifications").update(fields).eq("id", notification.id);

    const rendered = renderNotification(
      notification.type,
      notification.data ?? {},
      notification.mission_id ?? "",
    );
    if (!rendered) {
      await finish({
        status: "skipped",
        last_error: `Unknown type ${notification.type}`,
      });
      return Response.json({ status: "skipped", reason: "unknown_type" });
    }

    // Keep the wording on the row for the in-app inbox, sent or not.
    const content = { title: rendered.title, body: rendered.body };

    const { data: user } = await supabase
      .from("users")
      .select("fcm_token")
      .eq("id", notification.recipient_user_id)
      .maybeSingle();
    const token = user?.fcm_token;
    if (!token) {
      await finish({ ...content, status: "skipped", last_error: "No token" });
      return Response.json({ status: "skipped", reason: "no_token" });
    }

    const data: Record<string, string> = {};
    for (const [key, value] of Object.entries(notification.data ?? {})) {
      if (value !== null && value !== undefined) data[key] = String(value);
    }
    Object.assign(data, {
      notification_id: notification.id,
      type: notification.type,
      mission_id: notification.mission_id ?? "",
      audience: rendered.audience,
      route: rendered.route,
    });

    // Tag / collapse id = mission, so a newer update for the same mission
    // replaces the older one in the tray.
    const collapseId = notification.mission_id ?? notification.id;
    const message: FCMMessage = {
      fid: token,
      notification: content,
      data,
      android: {
        priority: "HIGH",
        ttl: `${rendered.ttlSec}s`,
        notification: {
          channel_id: rendered.channelId,
          tag: collapseId,
          sound: "default",
        },
      },
      apns: {
        headers: {
          "apns-priority": "10",
          "apns-collapse-id": collapseId,
          "apns-expiration": String(
            Math.floor(Date.now() / 1000) + rendered.ttlSec,
          ),
        },
        payload: {
          aps: {
            sound: "default",
            "thread-id": collapseId,
            "interruption-level": rendered.timeSensitive
              ? "time-sensitive"
              : "active",
          },
        },
      },
    };

    const result = await sendFcm(message);

    switch (result.outcome) {
      case "sent":
        await finish({
          ...content,
          status: "sent",
          sent_at: new Date().toISOString(),
          fcm_message_id: result.messageId,
          last_error: null,
        });
        break;
      case "invalid_token":
        // Only clear it if the app has not registered a new one meanwhile.
        await supabase
          .from("users")
          .update({ fcm_token: null })
          .eq("id", notification.recipient_user_id)
          .eq("fcm_token", token);
        await finish({
          ...content,
          status: "skipped",
          last_error: result.error,
        });
        break;
      case "rejected":
        console.error("FCM rejected notification", notification.id, result);
        await finish({
          ...content,
          status: "skipped",
          last_error: result.error,
        });
        break;
      case "retryable":
        await finish({
          ...content,
          status: "failed",
          last_error: result.error,
        });
        break;
    }

    return Response.json({ status: result.outcome });
  })
);
