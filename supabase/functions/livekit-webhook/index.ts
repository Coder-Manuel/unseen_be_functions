// supabase/functions/livekit-webhook/index.ts
import { createClient } from "@supabase/supabase-js";
import { WebhookReceiver } from "livekit-server-sdk";

Deno.serve(async (req) => {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // 1. Verify the webhook is genuinely from LiveKit
  const receiver = new WebhookReceiver(
    Deno.env.get("LIVEKIT_API_KEY")!,
    Deno.env.get("LIVEKIT_API_SECRET")!,
  );

  const body = await req.text();
  const authHeader = req.headers.get("Authorization") || undefined;

  let event;
  try {
    event = await receiver.receive(body, authHeader);
  } catch (e) {
    console.error(e);
    return new Response("Unauthorized", { status: 401 });
  }
  console.log("EVENT: ", event);

  const roomName = event.room?.name;
  if (!roomName) return new Response("OK");

  // Extract mission_id from room name
  const missionId = roomName.replace("msn::", "");
  switch (event.event) {
    case "participant_joined": {
      // Confirm if BOTH scout and client are now in the room
      const { data: mission } = await supabase
        .from("missions")
        .select("client_id")
        .eq("id", missionId)
        .single();

      // Get current participants in the room from the event metadata
      const identity = event.participant?.identity;
      if (identity !== mission?.client_id) break;
      await supabase
        .from("sessions")
        .update({
          status: "live",
          started_at: new Date().toISOString(),
        })
        .eq("room_name", roomName);

      // Also update mission status
      await supabase
        .from("missions")
        .update({ status: "live" })
        .eq("id", missionId);

      break;
    }

    case "room_finished": {
      // Room is fully closed — all participants gone
      const { data: session } = await supabase
        .from("sessions")
        .select("started_at, scheduled_duration_sec")
        .eq("room_name", roomName)
        .single();

      const endedAt = new Date();
      const actualDurationS = session?.scheduled_duration_sec
        ? Math.floor(
          (endedAt.getTime() - new Date(session.started_at).getTime()) / 1000,
        )
        : null;

      await supabase
        .from("sessions")
        .update({
          status: "ended",
          ended_at: endedAt.toISOString(),
          actual_duration_sec: actualDurationS,
          host_token: null,
          client_token: null,
        })
        .eq("room_name", roomName);

      await supabase
        .from("missions")
        .update({
          status: "completed",
          completed_at: endedAt.toISOString(),
        })
        .eq("id", missionId);

      break;
    }
  }

  return new Response("OK", { status: 200 });
});
