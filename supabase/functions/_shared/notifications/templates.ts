// Title, body and delivery options for each notification type. The triggers
// only record facts in notifications.data; the wording lives here.
import { NotifType } from "../types.ts";

export type Audience = "client" | "scout";

// Android channels the app must create.
//   mission_updates  default importance
//   live_alerts      high importance, sound; things to act on now
export type ChannelId = "mission_updates" | "live_alerts";

export interface RenderedNotification {
  title: string;
  body: string;
  audience: Audience;
  // Screen the app opens on tap.
  route: string;
  channelId: ChannelId;
  // How long FCM keeps trying to reach an offline device.
  ttlSec: number;
  timeSensitive: boolean;
}

type Data = Record<string, string | undefined>;

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

export function renderNotification(
  type: string,
  data: Data,
  missionId: string,
): RenderedNotification | null {
  const scout = name(data.scout_name, "Your scout");
  const address = data.address?.trim();

  switch (type) {
    case NotifType.missionRequestPaid: {
      const client = name(data.client_name, "A client");
      const amount = money(data.amount, data.currency);
      const length = minutes(data.duration_in_sec);
      return {
        title: amount ? `New live request · ${amount}` : "New live request",
        body: `${client} wants a ${length ? `${length} ` : ""}stream${
          address ? ` at ${address}` : ""
        }. Tap to accept or decline.`,
        audience: "scout",
        route: `/scout/requests/${missionId}`,
        channelId: "live_alerts",
        ttlSec: 6 * 3600,
        timeSensitive: true,
      };
    }

    case NotifType.missionAccepted:
      return {
        title: "Mission accepted",
        body: `${scout} accepted your mission.`,
        audience: "client",
        route: `/missions/${missionId}`,
        channelId: "mission_updates",
        ttlSec: 6 * 3600,
        timeSensitive: false,
      };

    case NotifType.missionEnroute:
      return {
        title: `${scout} is on the way`,
        body: address
          ? `${scout} is heading to ${address}.`
          : `${scout} is heading to your mission location.`,
        audience: "client",
        route: `/missions/${missionId}`,
        channelId: "mission_updates",
        ttlSec: 30 * 60,
        timeSensitive: false,
      };

    case NotifType.missionDeclined: {
      const amount = money(data.amount, data.currency);
      return {
        title: "Request declined",
        body: `${scout} couldn't take your live request. Your refund${
          amount ? ` of ${amount}` : ""
        } will be scheduled.`,
        audience: "client",
        route: `/missions/${missionId}`,
        channelId: "mission_updates",
        ttlSec: 6 * 3600,
        timeSensitive: false,
      };
    }

    case NotifType.missionReleased:
      return {
        title: "Scout dropped out",
        body:
          `${scout} can no longer make it. Your mission is back on the board for other scouts.`,
        audience: "client",
        route: `/missions/${missionId}`,
        channelId: "mission_updates",
        ttlSec: 6 * 3600,
        timeSensitive: false,
      };

    case NotifType.scoutLive:
      return {
        title: `${scout} is live, join now`,
        body: "Your stream has started and is waiting for you.",
        audience: "client",
        route: `/missions/${missionId}/live`,
        channelId: "live_alerts",
        ttlSec: 5 * 60,
        timeSensitive: true,
      };

    default:
      return null;
  }
}
