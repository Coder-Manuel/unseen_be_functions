// M-Pesa Daraja (Lipa na M-Pesa Online / STK Push) types.

export type PaymentStatus =
  | "pending"
  | "processing"
  | "success"
  | "failed"
  | "cancelled"
  | "refunded";

export interface STKPushInput {
  phoneNumber: string; // Normalized MSISDN, e.g. 2547XXXXXXXX
  amount: number; // Whole KES; Daraja rejects decimals
  accountReference: string; // Shown on the customer prompt (<= 12 chars)
  transactionDesc: string; // <= 13 chars
  callbackUrl: string;
}

// Response from POST /mpesa/stkpush/v1/processrequest
export interface STKPushResponse {
  MerchantRequestID: string;
  CheckoutRequestID: string;
  ResponseCode: string; // "0" on success
  ResponseDescription: string;
  CustomerMessage: string;
}

export interface STKCallbackItem {
  Name: string;
  Value?: string | number;
}

// Body.stkCallback of the async callback Safaricom POSTs back
export interface STKCallback {
  MerchantRequestID: string;
  CheckoutRequestID: string;
  ResultCode: number; // 0 = success, 1032 = cancelled by user, others = failed
  ResultDesc: string;
  CallbackMetadata?: { Item: STKCallbackItem[] };
}

export interface STKCallbackBody {
  Body: { stkCallback: STKCallback };
}
