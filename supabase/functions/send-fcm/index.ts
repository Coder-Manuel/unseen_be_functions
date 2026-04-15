// Setup type definitions for built-in Supabase Runtime APIs
import "@supabase/functions-js/edge-runtime.d.ts";
import { AuthMiddleware } from "shared";

Deno.serve((r) =>
  AuthMiddleware(r, async (req, _) => {
    const { name } = await req.json();
    const data = {
      message: `Hello ${name}!`,
    };

    return new Response(
      JSON.stringify(data),
      { headers: { "Content-Type": "application/json" } },
    );
  })
);
