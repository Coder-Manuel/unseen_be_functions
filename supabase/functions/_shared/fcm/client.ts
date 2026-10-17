// Thin FCM HTTP v1 client. Authenticates with the Firebase service account
// in FIREBASE_SERVICE_ACCOUNT (the JSON file, as a string).
import * as jose from "jsr:@panva/jose@6";
import type {
  FCMMessage,
  FCMSendResult,
  FirebaseServiceAccount,
} from "./types.ts";

const TOKEN_URL = "https://oauth2.googleapis.com/token";
const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";

let serviceAccount: FirebaseServiceAccount | undefined;
let cachedToken: { value: string; expiresAt: number } | undefined;

function getServiceAccount(): FirebaseServiceAccount {
  if (serviceAccount) return serviceAccount;
  const raw = Deno.env.get("FIREBASE_SERVICE_ACCOUNT");
  if (!raw) {
    throw new Error("Missing required env var: FIREBASE_SERVICE_ACCOUNT");
  }
  serviceAccount = JSON.parse(raw) as FirebaseServiceAccount;
  return serviceAccount;
}

// OAuth access token for FCM, cached until a minute before it expires.
async function getAccessToken(): Promise<string> {
  if (cachedToken && cachedToken.expiresAt > Date.now() + 60_000) {
    return cachedToken.value;
  }

  const sa = getServiceAccount();
  const key = await jose.importPKCS8(sa.private_key, "RS256");
  const assertion = await new jose.SignJWT({ scope: FCM_SCOPE })
    .setProtectedHeader({ alg: "RS256", typ: "JWT", kid: sa.private_key_id })
    .setIssuer(sa.client_email)
    .setSubject(sa.client_email)
    .setAudience(TOKEN_URL)
    .setIssuedAt()
    .setExpirationTime("1h")
    .sign(key);

  const res = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  const data = await res.json();
  if (!res.ok || !data.access_token) {
    throw new Error(
      `Google token exchange failed (${res.status}): ${JSON.stringify(data)}`,
    );
  }

  cachedToken = {
    value: data.access_token,
    expiresAt: Date.now() + Number(data.expires_in ?? 3600) * 1000,
  };
  return cachedToken.value;
}

// Send one message. Never throws for FCM errors: the outcome says whether to
// retry, so the caller can record it on the notification row.
export async function sendFcm(
  message: FCMMessage,
  options: { validateOnly?: boolean } = {},
): Promise<FCMSendResult> {
  let accessToken: string;
  try {
    accessToken = await getAccessToken();
  } catch (e) {
    return { outcome: "retryable", error: String(e) };
  }

  const url =
    `https://fcm.googleapis.com/v1/projects/${getServiceAccount().project_id}/messages:send`;

  let res: Response;
  try {
    res = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${accessToken}`,
      },
      body: JSON.stringify({
        message,
        validate_only: options.validateOnly ?? false,
      }),
    });
  } catch (e) {
    return { outcome: "retryable", error: String(e) };
  }

  const text = await res.text();
  let data: Record<string, unknown> = {};
  try {
    data = JSON.parse(text);
  } catch {
    // Non-JSON error body; keep the raw text below.
  }

  if (res.ok) {
    return { outcome: "sent", messageId: String(data.name ?? "") };
  }

  const error = `FCM ${res.status}: ${text.slice(0, 500)}`;
  const fcmError = data.error as
    | { status?: string; details?: { errorCode?: string }[] }
    | undefined;
  const code = fcmError?.details?.find((d) => d.errorCode)?.errorCode ??
    fcmError?.status;

  switch (code) {
    case "UNREGISTERED":
    case "SENDER_ID_MISMATCH":
      return { outcome: "invalid_token", error };
    case "INVALID_ARGUMENT":
      return { outcome: "rejected", error };
    case "UNAUTHENTICATED":
      // Force a fresh access token next time.
      cachedToken = undefined;
      return { outcome: "retryable", error };
    default:
      return { outcome: "retryable", error };
  }
}
