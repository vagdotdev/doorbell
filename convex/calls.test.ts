import { afterEach, beforeEach, expect, test, vi } from "vitest";
import { AccessToken } from "livekit-server-sdk";
import { backend, livekitEnv } from "./test.setup";

beforeEach(() => { for (const [k, v] of Object.entries(livekitEnv)) vi.stubEnv(k, v); });
afterEach(() => { vi.unstubAllEnvs(); });

const room = "door:bob:00000000-0000-4000-8000-000000000001";

// Sign a body the way LiveKit Cloud does: a JWT whose sha256 claim is the
// base64 digest of the exact bytes posted.
async function signed(body: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(body));
  const sha = btoa(Array.from(new Uint8Array(digest)).map((b) => String.fromCharCode(b)).join(""));
  const at = new AccessToken(livekitEnv.LIVEKIT_API_KEY, livekitEnv.LIVEKIT_API_SECRET, { identity: "livekit-cloud" });
  at.sha256 = sha;
  return await at.toJwt();
}

type T = ReturnType<typeof backend>;
async function post(t: T, body: string, sign = true) {
  return await t.fetch("/livekit/webhook", {
    method: "POST",
    body,
    headers: sign ? { Authorization: await signed(body) } : {},
  });
}
const rows = (t: T) => t.run((ctx) => ctx.db.query("callSessions").collect());

test("unsigned or tampered posts are refused and record nothing", async () => {
  const t = backend();
  const body = JSON.stringify({ event: "participant_joined", id: "EV_1", createdAt: "1000",
    room: { sid: "RM_1", name: room }, participant: { sid: "PA_1", identity: "alice" } });
  expect((await post(t, body, false)).status).toBe(401);
  const auth = await signed(JSON.stringify({ event: "room_finished" }));
  const forged = await t.fetch("/livekit/webhook", { method: "POST", body, headers: { Authorization: auth } });
  expect(forged.status).toBe(401);
  expect(await rows(t)).toEqual([]);
});

test("join and leave are recorded once; retries don't double-count", async () => {
  const t = backend();
  const join = JSON.stringify({ event: "participant_joined", id: "EV_1", createdAt: "1000",
    room: { sid: "RM_1", name: room },
    participant: { sid: "PA_1", identity: "alice", metadata: JSON.stringify({ handle: "alice" }) } });
  expect((await post(t, join)).status).toBe(200);
  expect((await post(t, join)).status).toBe(200); // LiveKit retry
  expect(await rows(t)).toMatchObject([
    { roomName: room, roomSid: "RM_1", kind: "door", ownerHandle: "bob", identity: "alice", preview: false, joinedAt: 1_000_000 },
  ]);

  const left = JSON.stringify({ event: "participant_left", id: "EV_2", createdAt: "1060",
    room: { sid: "RM_1", name: room }, participant: { sid: "PA_1", identity: "alice" } });
  expect((await post(t, left)).status).toBe(200);
  expect(await rows(t)).toMatchObject([{ identity: "alice", joinedAt: 1_000_000, leftAt: 1_060_000 }]);
});

test("room_finished closes every open seat; preview metadata is flagged", async () => {
  const t = backend();
  const step = "doorstep:bob:00000000-0000-4000-8000-000000000002";
  const preview = JSON.stringify({ handle: "bob", doorbellRole: "doorstep-preview" });
  for (const [identity, metadata] of [["alice", "{}"], ["bob", preview]] as const) {
    await post(t, JSON.stringify({ event: "participant_joined", id: `EV_${identity}`, createdAt: "2000",
      room: { sid: "RM_2", name: step }, participant: { sid: `PA_${identity}`, identity, metadata } }));
  }
  await post(t, JSON.stringify({ event: "room_finished", id: "EV_end", createdAt: "2090",
    room: { sid: "RM_2", name: step } }));
  const all = await rows(t);
  expect(all).toHaveLength(2);
  expect(all.find((r) => r.identity === "alice")).toMatchObject({ kind: "doorstep", preview: false, leftAt: 2_090_000 });
  expect(all.find((r) => r.identity === "bob")).toMatchObject({ kind: "doorstep", preview: true, leftAt: 2_090_000 });
});

test("rooms that aren't Doorbell's are acknowledged and ignored", async () => {
  const t = backend();
  const body = JSON.stringify({ event: "participant_joined", id: "EV_x", createdAt: "3000",
    room: { sid: "RM_3", name: "playground" }, participant: { sid: "PA_x", identity: "alice" } });
  expect((await post(t, body)).status).toBe(200);
  const other = JSON.stringify({ event: "track_published", id: "EV_y", createdAt: "3001",
    room: { sid: "RM_1", name: room }, participant: { sid: "PA_1", identity: "alice" } });
  expect((await post(t, other)).status).toBe(200);
  expect(await rows(t)).toEqual([]);
});
