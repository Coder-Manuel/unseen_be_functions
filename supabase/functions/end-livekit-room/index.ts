// Setup type definitions for built-in Supabase Runtime APIs
import "@supabase/functions-js/edge-runtime.d.ts";
import { RoomServiceClient } from "livekit-server-sdk";
import { ServiceAuthMiddleware } from "shared";

Deno.serve((r) =>
  ServiceAuthMiddleware(r, async (req) => {
    const { room_names } = await req.json();

    if (!room_names?.length) {
      return Response.json({ msg: "Missing room_names" }, { status: 400 });
    }

    const roomService = new RoomServiceClient(
      Deno.env.get("LIVEKIT_URL")!,
      Deno.env.get("LIVEKIT_API_KEY")!,
      Deno.env.get("LIVEKIT_API_SECRET")!,
    );

    try {
      // Delete all rooms concurrently
      await Promise.allSettled(
        room_names.map((room: string) =>
          roomService.deleteRoom(room)
            .catch((e) => console.warn(`Could not delete ${room}:`, e))
        ),
      );
      console.log("Rooms deleted:", room_names);
    } catch (e) {
      // Room already empty or gone — not fatal
      console.warn("Could not delete rooms:", room_names, e);
    }

    return Response.json({ msg: "OK", processed: room_names.length }, {
      status: 200,
    });
  })
);
