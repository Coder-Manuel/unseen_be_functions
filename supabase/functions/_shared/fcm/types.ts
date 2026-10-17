// Firebase service account JSON (FIREBASE_SERVICE_ACCOUNT), the fields used.
export interface FirebaseServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
  private_key_id?: string;
}

// FCM HTTP v1 message, the subset this app sends.
// https://firebase.google.com/docs/reference/fcm/rest/v1/projects.messages
export interface FCMMessage {
  token: string;
  notification: { title: string; body: string };
  // FCM only accepts string values here.
  data: Record<string, string>;
  android?: {
    priority?: "NORMAL" | "HIGH";
    ttl?: string; // e.g. "300s"
    collapse_key?: string;
    notification?: {
      channel_id?: string;
      tag?: string;
      sound?: string;
    };
  };
  apns?: {
    headers?: Record<string, string>;
    payload?: {
      aps: {
        sound?: string;
        "thread-id"?: string;
        "interruption-level"?:
          | "passive"
          | "active"
          | "time-sensitive"
          | "critical";
      };
    };
  };
}

//   sent           FCM accepted it
//   invalid_token  the token is dead; clear it and do not retry
//   rejected       FCM refused the message itself; retrying will not help
//   retryable      quota, outage or auth hiccup; try again later
export type FCMSendResult =
  | { outcome: "sent"; messageId: string }
  | { outcome: "invalid_token" | "rejected" | "retryable"; error: string };
