import * as jose from "jsr:@panva/jose@6";

export async function ServiceAuthMiddleware(
    req: Request,
    next: (req: Request) => Promise<Response>,
): Promise<Response> {
    const authHeader = req.headers.get("Authorization") ?? "";
    const token = authHeader.replace("Bearer ", "").trim();

    if (!token) {
        return Response.json({ msg: "Missing authorization header" }, {
            status: 401,
        });
    }

    try {
        const secret = new TextEncoder().encode(
            Deno.env.get("UNSEEN_FN_KEY")!,
        );

        const { payload } = await jose.jwtVerify(token, secret, {
            issuer: "unseen-internal",
        });

        if (payload.role !== "service") {
            return Response.json({ msg: "Forbidden" }, { status: 403 });
        }

        return await next(req);
    } catch (e) {
        return Response.json({ msg: `Unauthorized: ${e}` }, { status: 401 });
    }
}
