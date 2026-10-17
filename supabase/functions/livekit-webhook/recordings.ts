import { SupabaseClient } from "@supabase/supabase-js";
import {
  EgressClient,
  EgressInfo,
  EgressStatus,
  EncodedFileOutput,
  EncodedFileType,
  RoomServiceClient,
  S3Upload,
} from "livekit-server-sdk";

// Must match public.recording_status in
// migrations/20261018130000_session_recordings.sql.
type RecordingStatus = "starting" | "active" | "ending" | "complete" | "failed";

const finished: RecordingStatus[] = ["complete", "failed"];

interface ScoutRecordingInput {
  roomName: string;
  missionId: string;
  sessionId: string;
  scoutIdentity: string;
}

function livekitArgs(): [string, string, string] {
  return [
    Deno.env.get("LIVEKIT_URL")!,
    Deno.env.get("LIVEKIT_API_KEY")!,
    Deno.env.get("LIVEKIT_API_SECRET")!,
  ];
}

function toStatus(status: EgressStatus): RecordingStatus {
  switch (status) {
    case EgressStatus.EGRESS_STARTING:
      return "starting";
    case EgressStatus.EGRESS_ACTIVE:
      return "active";
    case EgressStatus.EGRESS_ENDING:
      return "ending";
    // The time limit still leaves a usable file.
    case EgressStatus.EGRESS_COMPLETE:
    case EgressStatus.EGRESS_LIMIT_REACHED:
      return "complete";
    default:
      return "failed";
  }
}

// LiveKit timestamps and durations are nanoseconds; 0 means unset.
function nsToIso(ns: bigint): string | undefined {
  return ns > 0n ? new Date(Number(ns / 1_000_000n)).toISOString() : undefined;
}

// Records the scout's camera and mic straight into the recordings bucket.
// A participant egress stops when the scout leaves, so this runs again on
// every join and skips when LiveKit is already recording them.
export async function startScoutRecording(
  supabase: SupabaseClient,
  input: ScoutRecordingInput,
): Promise<void> {
  const { roomName, missionId, sessionId, scoutIdentity } = input;
  const egress = new EgressClient(...livekitArgs());

  const active = await egress.listEgress({ roomName, active: true });
  const recording = active.some((e) =>
    e.request.case === "participant" &&
    e.request.value.identity === scoutIdentity
  );
  if (recording) return;

  // Nothing to record until the scout is in the room; their join retries.
  try {
    await new RoomServiceClient(...livekitArgs())
      .getParticipant(roomName, scoutIdentity);
  } catch {
    return;
  }

  const info = await egress.startParticipantEgress(roomName, scoutIdentity, {
    file: new EncodedFileOutput({
      fileType: EncodedFileType.MP4,
      filepath: `${missionId}/${sessionId}/${Date.now()}.mp4`,
      output: {
        case: "s3",
        value: new S3Upload({
          endpoint: Deno.env.get("RECORDINGS_S3_ENDPOINT")!,
          region: Deno.env.get("RECORDINGS_S3_REGION")!,
          accessKey: Deno.env.get("RECORDINGS_S3_ACCESS_KEY")!,
          secret: Deno.env.get("RECORDINGS_S3_SECRET")!,
          bucket: Deno.env.get("RECORDINGS_BUCKET") ?? "recordings",
          // Supabase Storage only serves path-style S3 URLs.
          forcePathStyle: true,
        }),
      },
    }),
  });

  // egress_started may already have written this row; keep what it wrote.
  const { error } = await supabase.from("session_recordings").upsert(
    {
      session_id: sessionId,
      egress_id: info.egressId,
      participant_identity: scoutIdentity,
      status: toStatus(info.status),
    },
    { onConflict: "egress_id", ignoreDuplicates: true },
  );
  if (error) throw error;
}

// Mirrors egress_started / egress_updated / egress_ended onto the row.
export async function recordEgress(
  supabase: SupabaseClient,
  info: EgressInfo,
): Promise<void> {
  if (info.request.case !== "participant") return;

  const { data: session, error: sessionError } = await supabase
    .from("sessions")
    .select("id")
    .eq("room_name", info.roomName)
    .maybeSingle();
  if (sessionError) throw sessionError;
  if (!session) return;

  const status = toStatus(info.status);

  // Webhooks can arrive out of order: never reopen a finished recording.
  const { data: existing, error: existingError } = await supabase
    .from("session_recordings")
    .select("status")
    .eq("egress_id", info.egressId)
    .maybeSingle();
  if (existingError) throw existingError;
  if (
    existing && finished.includes(existing.status) && !finished.includes(status)
  ) {
    return;
  }

  // Only send what this event knows, so earlier values are not nulled.
  const row: Record<string, unknown> = {
    session_id: session.id,
    egress_id: info.egressId,
    participant_identity: info.request.value.identity,
    status,
    error: info.error || null,
  };
  const startedAt = nsToIso(info.startedAt);
  if (startedAt) row.started_at = startedAt;
  const endedAt = nsToIso(info.endedAt);
  if (endedAt) row.ended_at = endedAt;

  const file = info.fileResults[0];
  if (status === "complete" && file?.filename) {
    row.storage_path = file.filename;
    row.size_bytes = Number(file.size);
    row.duration_sec = Math.round(Number(file.duration / 1_000_000n) / 1000);
  }

  const { error } = await supabase
    .from("session_recordings")
    .upsert(row, { onConflict: "egress_id" });
  if (error) throw error;
}
