import { createHandler, type Dependencies, type Participant, type SeatGrant } from "./handler.ts";

function assert(condition: unknown, message = "Assertion failed"): asserts condition { if (!condition) throw new Error(message); }
const visitor = { id: "00000000-0000-0000-0000-000000000001", handle: "alice", display_name: "Alice" };
const owner = { id: "00000000-0000-0000-0000-000000000002", handle: "owner", display_name: "Owner" };
const stranger = { id: "00000000-0000-0000-0000-000000000003", handle: "stranger", display_name: "Stranger" };
const visit = "00000000-0000-0000-0000-000000000009";
const doorstep = `doorstep:${owner.id}:${visit}`;
function fixture() {
  const peers = new Map<string, Participant[]>();
  const signals: { handle: string; event: string; payload: Record<string, string> }[] = [];
  const seats: { identity: string; room: string; grant: SeatGrant }[] = [];
  let follows = true, close = false, allowed = true, ringFails = false;
  const d: Dependencies = {
    url: "wss://media.example.test",
    user: async h => [visitor, owner, stranger].find(p => p.id === h)?.id ?? null,
    profile: async (c, v) => [visitor, owner, stranger].find(p => p[c] === v) ?? null,
    follows: async (f, o) => follows && f === visitor.id && o === owner.id,
    close: async () => close,
    allow: async () => allowed,
    participants: async room => peers.get(room) ?? [],
    ensureRoom: async () => {},
    ring: async (handle, event, payload) => { if (ringFails) throw new Error("offline"); signals.push({ handle, event, payload }); },
    seat: async (who, room, _via, _visit, grant) => { seats.push({ identity: who.handle, room, grant }); return "opaque-test-token"; },
    revoke: async () => { follows = false; },
  };
  const handler = createHandler(d);
  return { peers, signals, seats, d, handler,
    setFollow: (v: boolean) => follows = v, setClose: (v: boolean) => close = v,
    setAllowed: (v: boolean) => allowed = v, failRing: () => ringFails = true,
    post: (intent: string, extra: Record<string, unknown> = {}, uid = visitor.id) => handler(new Request("http://local/door-token", {
      method: "POST", headers: { authorization: uid }, body: JSON.stringify({ version: 2, intent, door: owner.handle, visit, ...extra }),
    })),
  };
}
Deno.test("unauthenticated requests cannot mint seats", async () => {
  const f = fixture(); const r = await f.post("visit", {}, "invalid"); assert(r.status === 401); assert(f.seats.length === 0);
});
Deno.test("old clients must update instead of using unsafe protocol", async () => {
  const f = fixture(); assert((await f.post("visit", { version: 1 })).status === 409); assert(f.seats.length === 0);
});
Deno.test("ordinary visit is isolated, publish-only, and does not ring early", async () => {
  const f = fixture(); const r = await f.post("visit"); assert(r.status === 200);
  assert(f.seats[0].room === doorstep); assert(!f.seats[0].grant.subscribe); assert(f.seats[0].grant.publish); assert(f.signals.length === 0);
});
Deno.test("close friend waits on doorstep until owner admits", async () => {
  const f = fixture(); f.setClose(true); const r = await f.post("visit"); assert((await r.json()).mode === "walk_in");
  assert(f.seats[0].room === doorstep && !f.seats[0].grant.subscribe);
});
Deno.test("stale close-friend row never bypasses accepted-follow check", async () => {
  const f = fixture(); f.setClose(true); f.setFollow(false); assert((await f.post("visit")).status === 403); assert(f.seats.length === 0);
});
Deno.test("signal requires caller actually present on exact doorstep", async () => {
  const f = fixture(); assert((await f.post("ring")).status === 409); assert(f.signals.length === 0);
  f.peers.set(doorstep, [{ identity: "stranger" }]); assert((await f.post("ring")).status === 409);
  f.peers.set(doorstep, [{ identity: "alice" }]); assert((await f.post("ring", { from: "stranger" })).status === 200);
  assert(f.signals[0].payload.from === "alice" && f.signals[0].payload.visit === visit);
});
Deno.test("observer seat cannot publish camera microphone or chat", async () => {
  const f = fixture(); assert((await f.post("answer", { hidden: true }, owner.id)).status === 200);
  assert(!f.seats[0].grant.publish && f.seats[0].grant.hidden && f.seats[0].grant.subscribe);
});
Deno.test("visitors cannot answer or admit through someone else's door", async () => {
  const f = fixture(); assert((await f.post("answer")).status === 403);
  assert((await f.post("admit", { guest: "alice" })).status === 403); assert(f.seats.length === 0);
});
Deno.test("admission rejects departed guest and absent owner", async () => {
  const f = fixture(); assert((await f.post("admit", { guest: "alice" }, owner.id)).status === 409);
  f.peers.set(doorstep, [{ identity: "alice" }]);
  assert((await f.post("admit", { guest: "alice" }, owner.id)).status === 403); assert(f.seats.length === 0);
});
Deno.test("hidden owner cannot vouch into a different room", async () => {
  const f = fixture(); f.peers.set(doorstep, [{ identity: "alice" }]); f.peers.set("door:bob", [{ identity: "owner", hidden: true }]);
  assert((await f.post("admit", { guest: "alice", room: "door:bob" }, owner.id)).status === 403);
});
Deno.test("visible owner admits matching visitor into current room privately", async () => {
  const f = fixture(); f.peers.set(doorstep, [{ identity: "alice" }]); f.peers.set("door:bob", [{ identity: "owner" }]);
  const r = await f.post("admit", { guest: "alice", room: "door:bob" }, owner.id); assert(r.status === 200);
  assert(!(await r.json()).token); assert(f.seats[0].room === "door:bob" && f.seats[0].identity === "alice");
  assert(f.signals[0].handle === "alice" && f.signals[0].payload.visit === visit);
});
Deno.test("guest cannot replay another visit ID to get admitted", async () => {
  const f = fixture(); f.peers.set(doorstep, [{ identity: "alice" }]); f.peers.set("door:owner", [{ identity: "owner" }]);
  assert((await f.post("admit", { guest: "alice", visit: "00000000-0000-0000-0000-000000000008" }, owner.id)).status === 409);
});
Deno.test("signal failure is returned instead of claiming success", async () => {
  const f = fixture(); f.peers.set(doorstep, [{ identity: "alice" }]); f.failRing(); assert((await f.post("ring")).status === 503);
});
Deno.test("rate limit blocks signaling while local leave remains successful", async () => {
  const f = fixture(); f.setAllowed(false); assert((await f.post("visit")).status === 429);
  assert(f.seats.length === 0); assert((await f.post("leave")).status === 200);
  assert(f.signals.length === 0);
});
Deno.test("malformed input and oversized streamed input fail without token", async () => {
  const f = fixture();
  for (const extra of [{ visit: "bad" }, { hidden: "false" }, { door: "../owner" }]) {
    assert((await f.post("visit", extra)).status === 400);
  }
  assert((await f.post("visit", { pad: "x".repeat(5000) })).status === 413);
  assert((await f.handler(new Request("http://local", { method: "POST", headers: { authorization: visitor.id }, body: "null" }))).status === 400);
  assert(f.seats.length === 0);
});
Deno.test("revocation is owner-only and rejects future visits", async () => {
  const f = fixture(); assert((await f.post("revoke", { guest: "alice" })).status === 403);
  assert((await f.post("revoke", { guest: "alice" }, owner.id)).status === 200);
  assert((await f.post("visit")).status === 403);
});
