// IntaSend (collections + send money) types.

export type IntaSendInvoiceState =
  | "PENDING"
  | "PROCESSING"
  | "FAILED"
  | "CANCELED"
  | "PARTIAL"
  | "COMPLETE"
  | "RETRY";

export type IntaSendCurrency = "KES" | "GHS" | "NGN" | "UGX" | "TZS" | "USD";

export interface IntaSendInvoice {
  invoice_id: string;
  state: IntaSendInvoiceState;
  provider: string; // M-PESA | CARD-PAYMENT | ...
  charges: string;
  net_amount: string;
  currency: string;
  value: string;
  api_ref?: string | null;
  mpesa_reference?: string | null;
  failed_reason?: string | null;
  failed_code?: string | null;
  created_at: string;
  updated_at: string;
}

export interface IntaSendSTKPushInput {
  phoneNumber: string; // Normalized MSISDN, e.g. 2547XXXXXXXX
  amount: number;
  apiRef: string;
}

// Response from POST /api/v1/payment/mpesa-stk-push/
export interface IntaSendSTKPushResponse {
  id: string;
  invoice: IntaSendInvoice;
}

export interface IntaSendCheckoutInput {
  amount: number;
  currency: string;
  apiRef: string;
  method: "CARD-PAYMENT" | "M-PESA";
  redirectUrl?: string;
  email?: string;
  firstName?: string;
  lastName?: string;
}

// Response from POST /api/v1/checkout/
export interface IntaSendCheckoutResponse {
  id: string;
  url: string;
  signature: string;
  paid: boolean;
}

// Response from POST /api/v1/payment/status/
export interface IntaSendPaymentStatusResponse {
  invoice: IntaSendInvoice;
  meta?: Record<string, unknown>;
}

export interface IntaSendB2CTransactionInput {
  name?: string;
  account: string; // Normalized MSISDN
  amount: number;
  narrative?: string;
}

export interface IntaSendB2CInput {
  currency: string;
  transactions: IntaSendB2CTransactionInput[];
  batchReference?: string;
  callbackUrl?: string;
}

export interface IntaSendSendMoneyTransaction {
  transaction_id?: string;
  status: string;
  status_code?: string; // TS100 = successful, TF* = failed
  status_description?: string;
  request_reference_id?: string;
  provider_reference?: string | null;
  account: string;
  amount: string;
  narrative?: string;
}

// Response from send-money initiate/status and the send money webhook.
export interface IntaSendSendMoneyResult {
  file_id?: string;
  tracking_id: string;
  batch_reference?: string | null;
  status: string; // e.g. "Completed", "Failed Processing"
  status_code?: string;
  nonce?: string;
  transactions: IntaSendSendMoneyTransaction[];
  failed_amount?: string;
  paid_amount?: string;
}

// Webhook body: collection events carry invoice_id, send money events
// carry tracking_id. Both carry the challenge configured on the dashboard.
export interface IntaSendWebhookBody {
  challenge?: string;
  invoice_id?: string;
  api_ref?: string;
  state?: IntaSendInvoiceState;
  tracking_id?: string;
  [key: string]: unknown;
}
