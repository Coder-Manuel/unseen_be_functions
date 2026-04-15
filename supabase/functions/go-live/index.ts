import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "@supabase/supabase-js";
import { AccessToken } from "livekit-server-sdk";
import { LiveKitTokenInput } from "./interface.ts";
import { AuthMiddleware } from "shared";

Deno.serve((r) =>
  AuthMiddleware(r, async (req, ctx) => {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { mission_id } = await req.json();
    const scoutId = ctx.user.id;

    const { data: mission, error } = await supabase
      .from("missions")
      .select(
        "id, status, duration_in_sec, client:users!missions_client_id_fkey!inner (id, fcm_token)",
      )
      .eq("id", mission_id)
      .eq("scout_id", scoutId)
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

    // 2. Generate unique room name
    const room = `mission-${mission_id}`;
    const client = Array.isArray(mission.client)
      ? mission.client[0]
      : mission.client;

    // 3. Generate tokens for BOTH scout and client
    const scoutToken = await generateLiveKitToken({
      room,
      identity: scoutId,
      canPublish: true,
      canSubscribe: true,
      durationSec: mission.duration_in_sec,
    });

    const clientToken = await generateLiveKitToken({
      room,
      identity: client.id,
      canPublish: false,
      canSubscribe: true,
      durationSec: mission.duration_in_sec,
    });

    await supabase.from("sessions").insert({
      mission_id,
      room_name: room,
      host_token: scoutToken,
      client_token: clientToken,
      scheduled_duration_sec: mission.duration_in_sec,
    });

    return Response.json(
      {
        room_name: room,
        token: scoutToken,
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
  });

  return token.toJwt();
}
