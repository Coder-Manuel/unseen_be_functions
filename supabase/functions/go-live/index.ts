import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "@supabase/supabase-js";
import { AccessToken } from "livekit-server-sdk";
import { LiveKitTokenInput } from "./interface.ts";
import { AuthMiddleware } from "shared";

Deno.serve((r) =>
  AuthMiddleware(r, async (req, authUser) => {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { mission_id } = await req.json();
    const { data: mission, error } = await supabase
      .from("missions")
      .select(
        `
        id, 
        status, 
        duration_in_sec, 
        client:users!missions_client_id_fkey!inner (id, fcm_token), 
        scout:users!missions_scout_id_fkey (id, fcm_token), 
        session:sessions!missions_session_id_fkey (id, room_name, status, host_token, client_token)
        `,
      )
      .eq("id", mission_id)
      .maybeSingle();

    if (error) {
      return Response.json(
        { error: error },
        { status: 400 },
      );
    }
    if (!mission) {
      return Response.json(
        { error: "Mission not found" },
        { status: 404 },
      );
    }

    const client = Array.isArray(mission.client)
      ? mission.client[0]
      : mission.client;
    const scout = Array.isArray(mission.scout)
      ? mission.scout[0]
      : mission.scout;
    const session = Array.isArray(mission.session)
      ? mission.session[0]
      : mission.session;

    if (!scout?.id) {
      return Response.json(
        { error: "Mission is not accepted" },
        { status: 400 },
      );
    }
    if (authUser.id !== scout.id && authUser.id !== client.id) {
      return Response.json(
        { error: "Unauthorized for this mission" },
        { status: 403 },
      );
    }

    let room: string;
    if (session?.room_name) {
      room = session.room_name;
    } else {
      room = `msn::${mission_id}`;
    }
    const isScout = authUser.id === scout.id;

    // Generate token for scout | client
    const token = await generateLiveKitToken({
      room,
      identity: authUser.id,
      canPublish: isScout,
      canSubscribe: true,
      durationSec: mission.duration_in_sec,
    });

    if (!session) {
      const { error: insertError } = await supabase.from("sessions").insert({
        mission_id,
        room_name: room,
        host_token: isScout ? token : null,
        client_token: !isScout ? token : null,
        scheduled_duration_sec: mission.duration_in_sec,
      });
      if (insertError && insertError.code !== "23505") {
        throw insertError;
      }
    } else {
      await supabase.from("sessions").update({
        room_name: room,
        host_token: isScout ? token : session.host_token,
        client_token: !isScout ? token : session.client_token,
      }).eq("id", session.id);
    }

    return Response.json(
      {
        room_name: room,
        token: token,
        url: Deno.env.get("LIVEKIT_URL"),
      },
    );
  })
);

// Token generator helper
function generateLiveKitToken(
  input: LiveKitTokenInput,
): Promise<string> {
  const { room, identity, canPublish, canSubscribe, durationSec } = input;
  const token = new AccessToken(
    Deno.env.get("LIVEKIT_API_KEY")!,
    Deno.env.get("LIVEKIT_API_SECRET")!,
    {
      identity,
      ttl: `${durationSec + 15}s`,
    },
  );

  token.addGrant({
    room,
    canPublish,
    canSubscribe,
    roomJoin: true,
    roomRecord: canPublish,
  });

  return token.toJwt();
}
