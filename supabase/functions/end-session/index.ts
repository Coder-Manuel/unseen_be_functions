import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "@supabase/supabase-js";
import { RoomServiceClient } from "livekit-server-sdk";
import { ClientAuthMiddleware } from "shared";

// The guide ends the live check for both sides. Leaving the room alone used
// to leave the viewer waiting on a guide who was never coming back.
//
// Same path as time running out (expire_live_rooms): the session goes to
// `ending` and the room is deleted, so the viewer's app closes on the
// room-deleted event and the room_finished webhook completes the mission.
Deno.serve((r) =>
  ClientAuthMiddleware(r, async (req, authUser) => {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { mission_id } = await req.json();
    if (!mission_id) {
      return Response.json({ error: "Missing mission_id" }, { status: 400 });
    }

    const { data: mission, error } = await supabase
      .from("missions")
      .select(
        `
        id,
        scout:profiles!missions_scout_id_fkey (user_id)
        `,
      )
      .eq("id", mission_id)
      .maybeSingle();

    if (error) return Response.json({ error }, { status: 400 });
    if (!mission) {
      return Response.json({ error: "Mission not found" }, { status: 404 });
    }

    const scout = Array.isArray(mission.scout) ? mission.scout[0] : mission.scout;
    if (authUser.id !== scout?.user_id) {
      return Response.json(
        { error: "Only the guide can end this live check" },
        { status: 403 },
      );
    }

    const { data: ending } = await supabase
      .from("sessions")
      .update({ status: "ending", updated_at: new Date().toISOString() })
      .eq("mission_id", mission_id)
      .in("status", ["created", "live"])
      .select("room_name");

    // Already ending or ended: the room is gone or going.
    const roomName = ending?.[0]?.room_name;
    if (!roomName) return Response.json({ ended: false });

    const roomService = new RoomServiceClient(
      Deno.env.get("LIVEKIT_URL")!,
      Deno.env.get("LIVEKIT_API_KEY")!,
      Deno.env.get("LIVEKIT_API_SECRET")!,
    );
    try {
      await roomService.deleteRoom(roomName);
    } catch (e) {
      // Already empty or gone; cleanup_stuck_ending_sessions finishes it.
      console.warn(`Could not delete ${roomName}:`, e);
    }

    return Response.json({ ended: true });
  })
);
