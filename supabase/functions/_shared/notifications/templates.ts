// The triggers only record facts in notifications.data; the wording lives here.
import { NotifType } from "../types.ts";

// Android channels the app creates.
export type ChannelId = "mission_updates" | "live_alerts";

export interface RenderedNotification {
  title: string;
  body: string;
  channelId: ChannelId;
  ttlSec: number;
  timeSensitive: boolean;
}

type Data = Record<string, string | undefined>;

const HOUR = 3600;

function money(amount?: string, currency?: string) {
  const n = Number(amount);
  if (!amount || !Number.isFinite(n)) return "";
  return `${currency || "KES"} ${n.toLocaleString("en-KE")}`;
}

function minutes(durationSec?: string) {
  const n = Math.round(Number(durationSec) / 60);
  return Number.isFinite(n) && n > 0 ? `${n}-min` : "";
}

function name(value: string | undefined, fallback: string) {
  return value?.trim() || fallback;
}

function at(address?: string) {
  return address?.trim() ? ` at ${address.trim()}` : "";
}

export function renderNotification(
  type: string,
  data: Data,
): RenderedNotification | null {
  const guide = name(data.scout_name, "Your guide");
  const viewer = name(data.client_name, "A viewer");
  const amount = money(data.amount, data.currency);
  const length = minutes(data.duration_in_sec);

  switch (type) {
    case NotifType.liveRequestCreated:
      return {
        title: amount ? `New live request · ${amount}` : "New live request",
        body: `${viewer} wants a ${length ? `${length} ` : ""}live${
          at(data.address)
        }. Tap to accept or decline.`,
        channelId: "live_alerts",
        ttlSec: 6 * HOUR,
        timeSensitive: true,
      };

    case NotifType.missionRequestPaid:
      return {
        title: "Payment received",
        body: `${viewer} paid${
          amount ? ` ${amount}` : ""
        }. You're cleared to start the live.`,
        channelId: "live_alerts",
        ttlSec: 6 * HOUR,
        timeSensitive: true,
      };

    case NotifType.requestCancelled:
      return {
        title: "Request cancelled",
        body:
          `${viewer} didn't pay in time, so the live request was cancelled.`,
        channelId: "mission_updates",
        ttlSec: 6 * HOUR,
        timeSensitive: false,
      };

    case NotifType.missionAccepted: {
      const window = Number(data.payment_window_min);
      return {
        title: "Request accepted",
        body: Number.isFinite(window) && window > 0
          ? `${guide} accepted. Pay within ${window} minutes to confirm the live.`
          : `${guide} accepted your live check.`,
        channelId: window > 0 ? "live_alerts" : "mission_updates",
        ttlSec: window > 0 ? window * 60 : 6 * HOUR,
        timeSensitive: window > 0,
      };
    }

    case NotifType.missionEnroute:
      return {
        title: `${guide} is on the way`,
        body: `${guide} is heading to ${
          data.address?.trim() || "your location"
        }.`,
        channelId: "mission_updates",
        ttlSec: 30 * 60,
        timeSensitive: false,
      };

    case NotifType.scoutLive:
      return {
        title: `${guide} is live, join now`,
        body: "Your live has started and is waiting for you.",
        channelId: "live_alerts",
        ttlSec: 5 * 60,
        timeSensitive: true,
      };

    case NotifType.missionDeclined:
      return {
        title: "Request declined",
        body: data.refund_due === "true"
          ? `${guide} couldn't take your live request. Your refund${
            amount ? ` of ${amount}` : ""
          } will be scheduled.`
          : `${guide} couldn't take your live request. Pick another guide to try again.`,
        channelId: "mission_updates",
        ttlSec: 6 * HOUR,
        timeSensitive: false,
      };

    case NotifType.missionReleased:
      return {
        title: "Guide dropped out",
        body:
          `${guide} can no longer make it. Your live check is back on the board for other guides.`,
        channelId: "mission_updates",
        ttlSec: 6 * HOUR,
        timeSensitive: false,
      };

    case NotifType.paymentExpired:
      return {
        title: "Request expired",
        body:
          `You didn't pay in time, so your live request with ${guide} was cancelled.`,
        channelId: "mission_updates",
        ttlSec: 6 * HOUR,
        timeSensitive: false,
      };

    default:
      return null;
  }
}
