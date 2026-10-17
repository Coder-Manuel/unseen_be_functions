export const jsonHeader = { "Content-Type": "application/json" };

// Must match the types the triggers in
// migrations/20261018120100_mission_notifications.sql queue.
export enum NotifType {
    missionRequestPaid = "MISSION_REQUEST_PAID",
    missionAccepted = "MISSION_ACCEPTED",
    missionEnroute = "MISSION_ENROUTE",
    missionDeclined = "MISSION_DECLINED",
    missionReleased = "MISSION_RELEASED",
    scoutLive = "SCOUT_LIVE",
}
