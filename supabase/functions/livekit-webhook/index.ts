// supabase/functions/livekit-webhook/index.ts
import { createClient } from "@supabase/supabase-js";
import { WebhookReceiver } from "livekit-server-sdk";
import { recordEgress, startScoutRecording } from "./recordings.ts";

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

  // egress_* events carry egressInfo instead of room. A failure is retried
  // by LiveKit, which is safe since recordEgress upserts.
  if (event.egressInfo) {
    try {
      await recordEgress(supabase, event.egressInfo);
    } catch (e) {
      console.error("Could not record egress:", event.egressInfo.egressId, e);
      return new Response("Error", { status: 500 });
    }
    return new Response("OK", { status: 200 });
  }

  const roomName = event.room?.name;
  if (!roomName) return new Response("OK");

  // Extract mission_id from room name
  const missionId = roomName.replace("msn::", "");
  switch (event.event) {
    case "participant_joined": {
      // Confirm if BOTH scout and client are now in the room
      const { data: mission } = await supabase
        .from("missions")
        .select("client_id, scout_id")
        .eq("id", missionId)
        .single();

      // Get current participants in the room from the event metadata
      const identity = event.participant?.identity;

      const { data: session } = await supabase
        .from("sessions")
        .select("id, status")
        .eq("room_name", roomName)
        .maybeSingle();

      // Only the scout is recorded, and only once the session is live.
      // Recording must never block the session, so failures are just logged.
      const recordScout = async () => {
        if (!session || !mission?.scout_id) return;
        try {
          await startScoutRecording(supabase, {
            roomName,
            missionId,
            sessionId: session.id,
            scoutIdentity: mission.scout_id,
          });
        } catch (e) {
          console.error("Could not start recording:", roomName, e);
        }
      };

      // Scout is streaming: stamp it once, which queues the SCOUT_LIVE push
      // (trg_notify_scout_live) if the client has not joined yet.
      if (identity && identity === mission?.scout_id) {
        await supabase
          .from("sessions")
          .update({ host_joined_at: new Date().toISOString() })
          .eq("room_name", roomName)
          .is("host_joined_at", null);

        // Rejoining a live session: their previous recording ended on leave.
        if (session?.status === "live") await recordScout();
        break;
      }

      if (identity !== mission?.client_id) break;

      // Time's up or over: a late rejoin must not revive the session.
      if (session?.status === "ending" || session?.status === "ended") break;

      // Only the client's first join starts the clock. Re-stamping started_at
      // on a rejoin pushed expire_live_rooms back and kept the mission live
      // (and on the radar) long after the stream ended.
      const { data: started } = await supabase
        .from("sessions")
        .update({
          status: "live",
          started_at: new Date().toISOString(),
        })
        .eq("room_name", roomName)
        .is("started_at", null)
        .select("id");

      if (started?.length) {
        await supabase
          .from("missions")
          .update({ status: "live" })
          .eq("id", missionId)
          .in("status", ["accepted", "enroute"]);
      }

      await recordScout();

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
      // A room the client never joined has no started_at to measure from.
      const actualDurationS = session?.started_at
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
