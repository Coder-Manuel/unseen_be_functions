export interface LiveKitTokenInput {
  room: string;
  identity: string;
  canPublish: boolean;
  canSubscribe: boolean;
  durationSec: number;
}
