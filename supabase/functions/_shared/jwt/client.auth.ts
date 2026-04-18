import * as jose from "jsr:@panva/jose@6";

type AuthUser = {
  id: string;
  role: string | unknown;
};

const SUPABASE_JWT_ISSUER = Deno.env.get("SB_JWT_ISSUER") ??
  Deno.env.get("SUPABASE_URL") + "/auth/v1";

const SUPABASE_JWT_KEYS = jose.createRemoteJWKSet(
  new URL(Deno.env.get("SUPABASE_URL")! + "/auth/v1/.well-known/jwks.json"),
);

function getAuthToken(req: Request) {
  const authHeader = req.headers.get("authorization");
  if (!authHeader) {
    throw new Error("Missing authorization header");
  }
  const [bearer, token] = authHeader.split(" ");
  if (bearer !== "Bearer") {
    throw new Error(`Auth header is not 'Bearer {token}'`);
  }

  return token;
}

function verifySupabaseJWT(jwt: string) {
  return jose.jwtVerify(jwt, SUPABASE_JWT_KEYS, {
    issuer: SUPABASE_JWT_ISSUER,
  });
}

// Validates authorization header
export async function ClientAuthMiddleware(
  req: Request,
  next: (req: Request, authUser: AuthUser) => Promise<Response>,
) {
  try {
    const token = getAuthToken(req);
    const jwtData = await verifySupabaseJWT(token);

    if (jwtData.payload.sub) {
      const authUser: AuthUser = {
        id: jwtData.payload.sub,
        role: jwtData.payload.role,
      };
      return await next(req, authUser);
    }

    return Response.json(
      { msg: "Invalid JWT" },
      {
        status: 401,
      },
    );
  } catch (e) {
    return Response.json(
      { msg: e?.toString() },
      {
        status: 401,
      },
    );
  }
}
