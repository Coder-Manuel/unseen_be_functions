export const jsonHeader = { "Content-Type": "application/json" };

export enum NotifType {
    goLive = "GO_LIVE",
    newMission = "NEW_MISSION",
    missionUpdate = "MISSION_UPDATE",
}

export interface FCMNotifInput {
    token?: string;
    topic?: string;
    notification: {
        title: string;
        body: string;
    };
    data?: Record<string, never>;
}
