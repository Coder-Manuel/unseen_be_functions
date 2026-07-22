// Thin M-Pesa Daraja client (OAuth + STK Push) with no external deps.
import type {
  STKCallbackItem,
  STKPushInput,
  STKPushResponse,
} from "./types.ts";

const MPESA_BASE_URL = Deno.env.get("MPESA_BASE_URL") ??
  "https://sandbox.safaricom.co.ke";

function requireEnv(key: string): string {
  const value = Deno.env.get(key);
  if (!value) throw new Error(`Missing required env var: ${key}`);
  return value;
}

// East Africa Time (UTC+3, no DST) in Daraja's YYYYMMDDHHmmss format.
// The password below must be derived from this same timestamp.
function darajaTimestamp(now = new Date()): string {
  const eat = new Date(now.getTime() + 3 * 60 * 60 * 1000);
  const p = (n: number) => n.toString().padStart(2, "0");
  return `${eat.getUTCFullYear()}${p(eat.getUTCMonth() + 1)}${
    p(eat.getUTCDate())
  }${p(eat.getUTCHours())}${p(eat.getUTCMinutes())}${p(eat.getUTCSeconds())}`;
}

// Normalize a Kenyan phone number to Daraja's MSISDN form (2547XXXXXXXX /
// 2541XXXXXXXX). Returns null when the input isn't a valid Safaricom number.
export function normalizeKenyanPhone(input: string): string | null {
  const digits = input.replace(/\D/g, "");
  if (/^254[17]\d{8}$/.test(digits)) return digits;
  if (/^0[17]\d{8}$/.test(digits)) return "254" + digits.slice(1);
  if (/^[17]\d{8}$/.test(digits)) return "254" + digits;
  return null;
}

// Flatten CallbackMetadata.Item[] into a plain object keyed by Name.
export function extractCallbackMetadata(
  items: STKCallbackItem[] = [],
): Record<string, string | number> {
  const out: Record<string, string | number> = {};
  for (const item of items) {
    if (item.Value !== undefined && item.Value !== null) {
      out[item.Name] = item.Value;
    }
  }
  return out;
}

// Fetch a short-lived Daraja OAuth access token.
export async function getMpesaAccessToken(): Promise<string> {
  const auth = btoa(
    `${requireEnv("MPESA_CONSUMER_KEY")}:${
      requireEnv("MPESA_CONSUMER_SECRET")
    }`,
  );
  const res = await fetch(
    `${MPESA_BASE_URL}/oauth/v1/generate?grant_type=client_credentials`,
    { headers: { Authorization: `Basic ${auth}` } },
  );
  if (!res.ok) {
    throw new Error(`Daraja OAuth failed (${res.status}): ${await res.text()}`);
  }
  const data = await res.json();
  if (!data.access_token) {
    throw new Error(`Daraja OAuth returned no token: ${JSON.stringify(data)}`);
  }
  return data.access_token as string;
}

// Initiate an STK push (Lipa na M-Pesa Online) prompt on the customer's phone.
export async function initiateSTKPush(
  input: STKPushInput,
): Promise<STKPushResponse> {
  const shortcode = requireEnv("MPESA_SHORTCODE");
  const passkey = requireEnv("MPESA_PASSKEY");
  const transactionType = Deno.env.get("MPESA_TRANSACTION_TYPE") ??
    "CustomerPayBillOnline";

  const token = await getMpesaAccessToken();
  const timestamp = darajaTimestamp();
  const password = btoa(`${shortcode}${passkey}${timestamp}`);

  const body = {
    BusinessShortCode: shortcode,
    Password: password,
    Timestamp: timestamp,
    TransactionType: transactionType,
    Amount: Math.round(input.amount),
    PartyA: input.phoneNumber,
    PartyB: shortcode,
    PhoneNumber: input.phoneNumber,
    CallBackURL: input.callbackUrl,
    AccountReference: input.accountReference.slice(0, 12),
    TransactionDesc: input.transactionDesc.slice(0, 13),
  };

  const res = await fetch(
    `${MPESA_BASE_URL}/mpesa/stkpush/v1/processrequest`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
    },
  );

  const data = await res.json();
  if (!res.ok || data.ResponseCode !== "0") {
    throw new Error(`STK push rejected: ${JSON.stringify(data)}`);
  }
  return data as STKPushResponse;
}
