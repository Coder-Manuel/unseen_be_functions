export const jsonHeader = { "Content-Type": "application/json" };

// Must match the types the notification triggers queue.
export enum NotifType {
    liveRequestCreated = "LIVE_REQUEST_CREATED",
    missionRequestPaid = "MISSION_REQUEST_PAID",
    requestCancelled = "REQUEST_CANCELLED",
    missionAccepted = "MISSION_ACCEPTED",
    missionEnroute = "MISSION_ENROUTE",
    scoutLive = "SCOUT_LIVE",
    missionDeclined = "MISSION_DECLINED",
    missionReleased = "MISSION_RELEASED",
    paymentExpired = "PAYMENT_EXPIRED",
}
