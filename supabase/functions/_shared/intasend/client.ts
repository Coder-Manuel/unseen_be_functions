// Thin IntaSend REST client (collections + M-Pesa B2C) with no external deps.
import type {
  IntaSendB2CInput,
  IntaSendCheckoutInput,
  IntaSendCheckoutResponse,
  IntaSendInvoiceState,
  IntaSendPaymentStatusResponse,
  IntaSendSendMoneyResult,
  IntaSendSTKPushInput,
  IntaSendSTKPushResponse,
} from "./types.ts";
import type { PaymentStatus } from "../mpesa/types.ts";

// Sandbox: https://sandbox.intasend.com, live: https://payment.intasend.com
const INTASEND_BASE_URL = Deno.env.get("INTASEND_BASE_URL") ??
  "https://sandbox.intasend.com";

function requireEnv(key: string): string {
  const value = Deno.env.get(key);
  if (!value) throw new Error(`Missing required env var: ${key}`);
  return value;
}

async function intasendRequest<T>(
  path: string,
  body: unknown,
  auth: "secret" | "public" = "secret",
): Promise<T> {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    Accept: "application/json",
  };
  if (auth === "secret") {
    headers.Authorization = `Bearer ${requireEnv("INTASEND_SECRET_KEY")}`;
  } else {
    headers["X-IntaSend-Public-API-Key"] = requireEnv("INTASEND_PUBLIC_KEY");
  }

  const res = await fetch(`${INTASEND_BASE_URL}${path}`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });

  const text = await res.text();
  let data: unknown;
  try {
    data = JSON.parse(text);
  } catch {
    data = text;
  }
  if (!res.ok) {
    throw new Error(
      `IntaSend ${path} failed (${res.status}): ${JSON.stringify(data)}`,
    );
  }
  return data as T;
}

// Map an IntaSend invoice state onto our payments.status.
export function mapInvoiceState(state: IntaSendInvoiceState): PaymentStatus {
  switch (state) {
    case "COMPLETE":
      return "success";
    case "FAILED":
      return "failed";
    case "CANCELED":
      return "cancelled";
    default:
      // PENDING | PROCESSING | RETRY | PARTIAL are still in flight.
      return "processing";
  }
}

// Map a single-transaction send money result onto our payments.status.
export function mapSendMoneyStatus(
  result: IntaSendSendMoneyResult,
): PaymentStatus {
  const txn = result.transactions?.[0];
  if (txn?.status_code === "TS100") return "success";
  if (txn?.status_code?.startsWith("TF")) return "failed";
  if (/fail/i.test(result.status) || /fail/i.test(txn?.status ?? "")) {
    return "failed";
  }
  if (/cancel/i.test(txn?.status ?? "")) return "cancelled";
  return "processing";
}

// Trigger an M-Pesa STK push prompt through IntaSend.
export function intasendSTKPush(
  input: IntaSendSTKPushInput,
): Promise<IntaSendSTKPushResponse> {
  return intasendRequest("/api/v1/payment/mpesa-stk-push/", {
    amount: input.amount,
    phone_number: input.phoneNumber,
    api_ref: input.apiRef,
  });
}

// Create a hosted checkout (used for card payments). Returns a URL the app
// opens in a browser/webview.
export function intasendCreateCheckout(
  input: IntaSendCheckoutInput,
): Promise<IntaSendCheckoutResponse> {
  return intasendRequest(
    "/api/v1/checkout/",
    {
      amount: input.amount,
      currency: input.currency,
      api_ref: input.apiRef,
      method: input.method,
      redirect_url: input.redirectUrl,
      email: input.email,
      first_name: input.firstName,
      last_name: input.lastName,
    },
    "public",
  );
}

// Authoritative collection status lookup.
export function intasendPaymentStatus(
  invoiceId: string,
): Promise<IntaSendPaymentStatusResponse> {
  return intasendRequest("/api/v1/payment/status/", { invoice_id: invoiceId });
}

// Send money to M-Pesa numbers (B2C). Straight-through: no approval step.
export function intasendMpesaB2C(
  input: IntaSendB2CInput,
): Promise<IntaSendSendMoneyResult> {
  return intasendRequest("/api/v1/send-money/initiate/", {
    provider: "MPESA-B2C",
    currency: input.currency,
    requires_approval: "NO",
    batch_reference: input.batchReference,
    callback_url: input.callbackUrl,
    transactions: input.transactions,
  });
}

// Authoritative send money status lookup.
export function intasendSendMoneyStatus(
  trackingId: string,
): Promise<IntaSendSendMoneyResult> {
  return intasendRequest("/api/v1/send-money/status/", {
    tracking_id: trackingId,
  });
}
