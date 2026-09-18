import { afterEach, beforeEach, expect, test, vi } from "vitest";
import { RoomServiceClient } from "livekit-server-sdk";
import { api, internal } from "./_generated/api";
import { EVENT_TTL_MS } from "./doors";
import { backend, livekitEnv, person } from "./test.setup";

const waiting = new Map<string, string[]>();
const room = "door:bob:00000000-0000-4000-8000-000000000001";
function claims(token: string) { return JSON.parse(atob(token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))); }
beforeEach(() => {
  waiting.clear();
  for (const [k, v] of Object.entries(livekitEnv)) vi.stubEnv(k, v);
  vi.spyOn(RoomServiceClient.prototype, "listParticipants").mockImplementation(async room =>
    (waiting.get(room) ?? []).map(identity => ({ identity, permission: { hidden: false } })) as never);
});
afterEach(() => { vi.unstubAllEnvs(); vi.restoreAllMocks(); vi.useRealTimers(); });
async function town() {
  const t = backend(), alice = await person(t, "alice"), bob = await person(t, "bob"), carol = await person(t, "carol");
  for (const friend of [alice, carol]) {
    await friend.as.mutation(api.graph.request, { profileId: bob.profileId });
    await bob.as.mutation(api.graph.accept, { profileId: friend.profileId });
  }
  await bob.as.mutation(api.graph.setCloseFriend, { profileId: carol.profileId, on: true });
  return { t, alice, bob, carol };
}
async function arrive(guest: Awaited<ReturnType<typeof person>>, door = "bob", visitId = crypto.randomUUID()) {
  const seat = await guest.as.action(api.doorActions.visit, { door, visitId });
  waiting.set(seat.room, [guest.handle]);
  await guest.as.action(api.doorActions.announce, { door, visitId });
  return { seat, visitId };
}
test("knock rings only after media connects; exact UUID and public profile reach only the owner", async () => {
  const { t, alice, bob, carol } = await town();
  const visitId = crypto.randomUUID();
  const seat = await alice.as.action(api.doorActions.visit, { door: "bob", visitId });
  expect(await bob.as.query(api.doors.events, {})).toEqual([]);
  await expect(alice.as.action(api.doorActions.announce, { door: "bob", visitId })).rejects.toThrow(/no longer/);
  expect(claims(seat.token).video).toMatchObject({ room: `doorstep:bob:${visitId}`, canSubscribe: true, canPublish: true, canPublishData: false });
  expect(claims(seat.token).exp - Math.floor(Date.now() / 1000)).toBeGreaterThanOrEqual(59);
  expect(claims(seat.token).exp - Math.floor(Date.now() / 1000)).toBeLessThanOrEqual(60);
  waiting.set(seat.room, ["alice"]);
  await alice.as.action(api.doorActions.announce, { door: "bob", visitId });
  await alice.as.action(api.doorActions.announce, { door: "bob", visitId });
  expect(await bob.as.query(api.doors.events, {})).toMatchObject([{ visitId, kind: "knock", from: { handle: "alice" }, grant: null }]);
  for (const who of [alice.as, carol.as, t]) expect(await who.query(api.doors.events, {})).toEqual([]);
});
test("close friends also wait outside; simultaneous visitors have separate preview rooms", async () => {
  const { alice, bob, carol } = await town();
  const a = await arrive(alice), c = await arrive(carol);
  expect(c.seat.mode).toBe("walk_in");
  expect(claims(c.seat.token).video.canSubscribe).toBe(true);
  expect(c.seat.room).not.toBe(a.seat.room);
  const peek = await bob.as.action(api.doorActions.answer, { hidden: true, visitId: a.visitId });
  expect(peek.room).toBe(a.seat.room);
  expect(claims(peek.token).video).toMatchObject({ hidden: false, canPublish: true, canPublishSources: ["microphone"], canSubscribe: true, canPublishData: false });
  expect(JSON.parse(claims(peek.token).metadata).doorbellRole).toBe("doorstep-preview");
  expect(await carol.as.query(api.doors.events, {})).toEqual([]); // quiet owner issues no admission
});
test("revoking close permission during media connection downgrades the arrival", async () => {
  const { bob, carol } = await town(), visitId = crypto.randomUUID();
  const seat = await carol.as.action(api.doorActions.visit, { door: "bob", visitId });
  await bob.as.mutation(api.graph.setCloseFriend, { profileId: carol.profileId, on: false });
  waiting.set(seat.room, ["carol"]);
  await carol.as.action(api.doorActions.announce, { door: "bob", visitId });
  expect((await bob.as.query(api.doors.events, {}))[0].kind).toBe("knock");
});
test("stranger, pending, self, signed-out and malformed visits are refused", async () => {
  const { t, alice, bob, carol } = await town();
  await carol.as.mutation(api.graph.request, { profileId: alice.profileId });
  for (const [as, door, error] of [[alice.as, "carol", /don't follow/], [carol.as, "alice", /don't follow/],
    [bob.as, "bob", /own door/], [t, "bob", /Sign in/], [alice.as, "nobody", /No such door/]] as const) {
    await expect(as.action(api.doorActions.visit, { door, visitId: crypto.randomUUID() })).rejects.toThrow(error);
  }
  await expect(alice.as.action(api.doorActions.visit, { door: "bob", visitId: "invalid" })).rejects.toThrow(/Update/);
  expect(await t.run(ctx => ctx.db.query("doorEvents").collect())).toEqual([]);
});
test("cancellation preserves UUID, forbids late announce/admission and can beat visit creation", async () => {
  const { alice, bob } = await town(), { visitId } = await arrive(alice);
  await alice.as.action(api.doorActions.leave, { door: "bob", visitId });
  expect(await bob.as.query(api.doors.events, {})).toMatchObject([{ kind: "left", visitId }]);
  await expect(alice.as.action(api.doorActions.announce, { door: "bob", visitId })).rejects.toThrow(/ended/);
  await expect(bob.as.action(api.doorActions.admit, { guest: "alice", visitId, room })).rejects.toThrow(/ended/);
  const early = crypto.randomUUID();
  await alice.as.action(api.doorActions.leave, { door: "bob", visitId: early });
  await expect(alice.as.action(api.doorActions.visit, { door: "bob", visitId: early })).rejects.toThrow(/ended/);
});
test("an old leave cannot cancel a newer visit and a stolen UUID cannot be reused", async () => {
  const { alice, bob, carol } = await town();
  const old = await arrive(alice), next = await arrive(alice);
  await alice.as.action(api.doorActions.leave, { door: "bob", visitId: old.visitId });
  const events = await bob.as.query(api.doors.events, {});
  expect(events.some(e => e.visitId === next.visitId && e.kind === "knock")).toBe(true);
  await expect(carol.as.action(api.doorActions.visit, { door: "bob", visitId: next.visitId })).rejects.toThrow(/Not your/);
  await expect(carol.as.action(api.doorActions.leave, { door: "bob", visitId: next.visitId })).rejects.toThrow(/Not your/);
});
test("host and visitor must both still occupy their seats; admission reaches only matching guest", async () => {
  const { alice, bob, carol } = await town(), { visitId, seat } = await arrive(alice);
  await expect(bob.as.action(api.doorActions.admit, { guest: "alice", visitId, room })).rejects.toThrow(/no longer/);
  waiting.set(room, ["bob"]);
  waiting.delete(seat.room);
  await expect(bob.as.action(api.doorActions.admit, { guest: "alice", visitId, room })).rejects.toThrow(/no longer/);
  waiting.set(seat.room, ["alice"]);
  await bob.as.action(api.doorActions.admit, { guest: "alice", visitId, room });
  const [event] = await alice.as.query(api.doors.events, {});
  expect(event).toMatchObject({ visitId, kind: "admitted", from: { handle: "bob" }, grant: { room } });
  expect(claims(event.grant!.token).video).toMatchObject({ canSubscribe: true, canPublishData: true, hidden: false });
  expect(await carol.as.query(api.doors.events, {})).toEqual([]);
  await expect(bob.as.action(api.doorActions.admit, { guest: "alice", visitId, room })).rejects.toThrow(/ended/);
});
test("cancellation or unfollow during LiveKit lookup blocks delivery", async () => {
  for (const revoke of [false, true]) {
    const { alice, bob } = await town(), { visitId } = await arrive(alice);
    vi.mocked(RoomServiceClient.prototype.listParticipants).mockImplementation(async target => {
      if (target === room) {
        if (revoke) await bob.as.mutation(api.graph.unfollow, { profileId: alice.profileId });
        else await alice.as.action(api.doorActions.leave, { door: "bob", visitId });
      }
      return [{ identity: target === room ? "bob" : "alice", permission: { hidden: false } }] as never;
    });
    await expect(bob.as.action(api.doorActions.admit, { guest: "alice", visitId, room })).rejects.toThrow();
    expect(await alice.as.query(api.doors.events, {})).toEqual([]);
  }
});
test("strangers and hidden preview seats cannot vouch; provider outage fails closed", async () => {
  const { alice, bob, carol } = await town(), { visitId } = await arrive(alice);
  await expect(carol.as.action(api.doorActions.admit, { guest: "alice", visitId, room })).rejects.toThrow(/Not your/);
  await expect(bob.as.action(api.doorActions.admit, { guest: "alice", visitId, room: "doorstep:bob" })).rejects.toThrow(/Not a room/);
  vi.mocked(RoomServiceClient.prototype.listParticipants).mockResolvedValue([{ identity: "bob", permission: { hidden: true } }] as never);
  await expect(bob.as.action(api.doorActions.admit, { guest: "alice", visitId, room })).rejects.toThrow(/no longer/);
  vi.mocked(RoomServiceClient.prototype.listParticipants).mockRejectedValue(new Error("offline"));
  await expect(bob.as.action(api.doorActions.admit, { guest: "alice", visitId, room })).rejects.toThrow(/offline/);
});
test("ack belongs only to addressee and expiration clears arrivals and visits", async () => {
  vi.useFakeTimers();
  const { t, alice, bob, carol } = await town(), { visitId } = await arrive(alice);
  const [event] = await bob.as.query(api.doors.events, {});
  await carol.as.mutation(api.doors.ack, { eventId: event.id });
  await alice.as.mutation(api.doors.ack, { eventId: event.id });
  expect(await bob.as.query(api.doors.events, {})).toHaveLength(1);
  await expect(t.mutation(api.doors.ack, { eventId: event.id })).rejects.toThrow(/Sign in/);
  await bob.as.mutation(api.doors.ack, { eventId: event.id });
  expect(await bob.as.query(api.doors.events, {})).toEqual([]);
  vi.advanceTimersByTime(EVENT_TTL_MS + 1);
  await expect(bob.as.mutation(internal.doors.deliverAdmit, { visitId, guestId: alice.profileId,
    grant: { room, url: "wss://test", token: "test" } })).rejects.toThrow(/ended/);
  await t.finishAllScheduledFunctions(vi.runAllTimers);
  expect(await t.run(ctx => ctx.db.query("visits").collect())).toEqual([]);
  expect(await t.run(ctx => ctx.db.query("doorEvents").collect())).toEqual([]);
});
test("misconfigured LiveKit creates no ghost visit; host conversations use fresh rooms", async () => {
  const { t, alice, bob } = await town();
  const a = await bob.as.action(api.doorActions.answer, { hidden: false });
  const b = await bob.as.action(api.doorActions.answer, { hidden: false });
  expect(a.room).not.toBe(b.room);
  await expect(bob.as.action(api.doorActions.answer, { hidden: true })).rejects.toThrow(/active visitor/);
  vi.stubEnv("LIVEKIT_API_SECRET", "");
  await expect(alice.as.action(api.doorActions.visit, { door: "bob", visitId: crypto.randomUUID() })).rejects.toThrow(/not configured/);
  expect(await t.run(ctx => ctx.db.query("visits").collect())).toEqual([]);
});
test("100 users can each knock without losing identity and all ephemeral data expires", async () => {
  vi.useFakeTimers();
  const t = backend(), owner = await person(t, "owner");
  const ids = new Set<string>();
  for (let i = 0; i < 99; i++) {
    const guest = await person(t, `guest_${i}`);
    await guest.as.mutation(api.graph.request, { profileId: owner.profileId });
    await owner.as.mutation(api.graph.accept, { profileId: guest.profileId });
    const { visitId } = await arrive(guest, "owner");
    ids.add(visitId);
  }
  const events = await owner.as.query(api.doors.events, {});
  expect(events).toHaveLength(99);
  expect(new Set(events.map(e => e.visitId))).toEqual(ids);
  vi.advanceTimersByTime(EVENT_TTL_MS + 1);
  await t.finishAllScheduledFunctions(vi.runAllTimers);
  expect(await t.run(ctx => ctx.db.query("doorEvents").collect())).toEqual([]);
  expect(await t.run(ctx => ctx.db.query("visits").collect())).toEqual([]);
});

test("automatic admission rechecks close permission after external lookup", async () => {
  const { bob, carol } = await town(), { visitId } = await arrive(carol);
  waiting.set(room, ["bob"]);
  await bob.as.mutation(api.graph.setCloseFriend, { profileId: carol.profileId, on: false });
  await expect(bob.as.action(api.doorActions.admit, { guest: "carol", visitId, room, automatically: true })).rejects.toThrow(/permission was removed/);
  expect(await carol.as.query(api.doors.events, {})).toEqual([]);
  await bob.as.action(api.doorActions.admit, { guest: "carol", visitId, room, automatically: false });
  expect((await carol.as.query(api.doors.events, {}))[0].kind).toBe("admitted");
});


test("Open Door Policy defaults off and only updates the authenticated owner's profile", async () => {
  const t = backend(), alice = await person(t, "alice"), bob = await person(t, "bob");
  expect((await bob.as.query(api.profiles.account, {})).me?.openDoorPolicy).toBe(false);
  await expect(t.mutation(api.profiles.setOpenDoorPolicy, { enabled: true })).rejects.toThrow(/Sign in/);
  const updated = await alice.as.mutation(api.profiles.setOpenDoorPolicy, { enabled: true });
  expect(updated.openDoorPolicy).toBe(true);
  expect((await bob.as.query(api.profiles.account, {})).me?.openDoorPolicy).toBe(false);
  expect((await bob.as.query(api.profiles.search, { q: "alice" }))[0].openDoorPolicy).toBe(true);
  await alice.as.mutation(api.profiles.setOpenDoorPolicy, { enabled: false });
  expect((await alice.as.query(api.profiles.account, {})).me?.openDoorPolicy).toBe(false);
});

test("an open door permits ordinary friends but still requires owner-controlled admission", async () => {
  const t = backend(), guest = await person(t, "guest"), bob = await person(t, "bob"), stranger = await person(t, "stranger");
  await guest.as.mutation(api.graph.request, { profileId: bob.profileId });
  await bob.as.mutation(api.graph.accept, { profileId: guest.profileId });
  await bob.as.mutation(api.profiles.setOpenDoorPolicy, { enabled: true });
  await expect(t.action(api.doorActions.visit, { door: "bob", visitId: crypto.randomUUID() })).rejects.toThrow(/Sign in/);
  const { visitId, seat } = await arrive(guest);
  expect(seat.mode).toBe("walk_in");
  expect(seat.room).toBe(`doorstep:bob:${visitId}`);
  expect(await guest.as.query(api.doors.events, {})).toEqual([]);
  expect((await bob.as.query(api.doors.events, {}))[0]).toMatchObject({ kind: "walk_in", visitId });
  await expect(stranger.as.action(api.doorActions.answer, { hidden: true, visitId })).rejects.toThrow(/Not your/);
  await expect(stranger.as.action(api.doorActions.admit, { guest: "guest", visitId, room, automatically: true })).rejects.toThrow(/Not your/);
  waiting.set(room, ["bob"]);
  await bob.as.action(api.doorActions.admit, { guest: "guest", visitId, room, automatically: true });
  expect((await guest.as.query(api.doors.events, {}))[0]).toMatchObject({ kind: "admitted", visitId });
  expect(await stranger.as.query(api.doors.events, {})).toEqual([]);
});

test("an open door denies strangers, pending requests and removed friends before issuing a token", async () => {
  const { t, alice, bob } = await town(), stranger = await person(t, "stranger"), pending = await person(t, "pending");
  await bob.as.mutation(api.profiles.setOpenDoorPolicy, { enabled: true });
  await pending.as.mutation(api.graph.request, { profileId: bob.profileId });
  await bob.as.mutation(api.graph.unfollow, { profileId: alice.profileId });
  for (const guest of [stranger, pending, alice]) {
    await expect(guest.as.action(api.doorActions.visit, { door: "bob", visitId: crypto.randomUUID() })).rejects.toThrow(/don't follow/);
  }
  expect(await t.run(ctx => ctx.db.query("visits").collect())).toEqual([]);
  expect(await bob.as.query(api.doors.events, {})).toEqual([]);
});

test("legacy stranger visits cannot announce, preview or receive a grant while the policy is on", async () => {
  const t = backend(), guest = await person(t, "guest"), bob = await person(t, "bob");
  await bob.as.mutation(api.profiles.setOpenDoorPolicy, { enabled: true });
  const visitId = crypto.randomUUID();
  await t.run(ctx => ctx.db.insert("visits", { visitId, ownerId: bob.profileId, guestId: guest.profileId,
    mode: "walk_in", status: "announced", expiresAt: Date.now() + EVENT_TTL_MS }));
  waiting.set(`doorstep:bob:${visitId}`, ["guest"]);
  waiting.set(room, ["bob"]);
  await expect(guest.as.action(api.doorActions.announce, { door: "bob", visitId })).rejects.toThrow(/friendship ended/);
  await expect(bob.as.action(api.doorActions.answer, { hidden: true, visitId })).rejects.toThrow(/friendship ended/);
  for (const automatically of [false, true]) {
    await expect(bob.as.action(api.doorActions.admit, { guest: "guest", visitId, room, automatically })).rejects.toThrow(/friendship ended/);
    await expect(bob.as.mutation(internal.doors.deliverAdmit, { visitId, guestId: guest.profileId, automatically,
      grant: { room, url: "wss://test", token: "test" } })).rejects.toThrow(/friendship ended/);
  }
  expect(await guest.as.query(api.doors.events, {})).toEqual([]);
});

test("closing an open door downgrades a friend and blocks stale automatic permission", async () => {
  const { alice, bob } = await town();
  await bob.as.mutation(api.profiles.setOpenDoorPolicy, { enabled: true });
  const visitId = crypto.randomUUID(), seat = await alice.as.action(api.doorActions.visit, { door: "bob", visitId });
  expect(seat.mode).toBe("walk_in");
  await bob.as.mutation(api.profiles.setOpenDoorPolicy, { enabled: false });
  waiting.set(seat.room, ["alice"]);
  await alice.as.action(api.doorActions.announce, { door: "bob", visitId });
  expect((await bob.as.query(api.doors.events, {}))[0].kind).toBe("knock");
  waiting.set(room, ["bob"]);
  await expect(bob.as.action(api.doorActions.admit, { guest: "alice", visitId, room, automatically: true })).rejects.toThrow(/permission was removed/);
  await bob.as.action(api.doorActions.admit, { guest: "alice", visitId, room, automatically: false });
  expect((await alice.as.query(api.doors.events, {}))[0].kind).toBe("admitted");
});

test("open-door preview rechecks friendship after LiveKit responds", async () => {
  const { alice, bob } = await town();
  await bob.as.mutation(api.profiles.setOpenDoorPolicy, { enabled: true });
  const { visitId } = await arrive(alice);
  vi.mocked(RoomServiceClient.prototype.listParticipants).mockImplementation(async () => {
    await bob.as.mutation(api.graph.unfollow, { profileId: alice.profileId });
    return [{ identity: "alice", permission: { hidden: false } }] as never;
  });
  await expect(bob.as.action(api.doorActions.answer, { hidden: true, visitId })).rejects.toThrow(/ended/);
});

test("closing Open Door during LiveKit lookup blocks automatic friend admission", async () => {
  const { alice, bob } = await town();
  await bob.as.mutation(api.profiles.setOpenDoorPolicy, { enabled: true });
  const { visitId } = await arrive(alice);
  vi.mocked(RoomServiceClient.prototype.listParticipants).mockImplementation(async target => {
    await bob.as.mutation(api.profiles.setOpenDoorPolicy, { enabled: false });
    return [{ identity: target === room ? "bob" : "alice", permission: { hidden: false } }] as never;
  });
  await expect(bob.as.action(api.doorActions.admit, { guest: "alice", visitId, room, automatically: true })).rejects.toThrow(/permission was removed/);
  expect(await alice.as.query(api.doors.events, {})).toEqual([]);
  await bob.as.action(api.doorActions.admit, { guest: "alice", visitId, room, automatically: false });
  expect((await alice.as.query(api.doors.events, {}))[0].kind).toBe("admitted");
});

test("Open Door uses the owner's accepted-follower permission, never a reverse-only or pending edge", async () => {
  const t = backend(), bob = await person(t, "bob"), accepted = await person(t, "accepted"), reverse = await person(t, "reverse");
  await bob.as.mutation(api.profiles.setOpenDoorPolicy, { enabled: true });
  await t.run(async ctx => {
    await ctx.db.insert("follows", { followerId: accepted.profileId, followeeId: bob.profileId, status: "accepted" });
    await ctx.db.insert("follows", { followerId: bob.profileId, followeeId: reverse.profileId, status: "accepted" });
  });
  expect((await arrive(accepted)).seat.mode).toBe("walk_in");
  await expect(reverse.as.action(api.doorActions.visit, { door: "bob", visitId: crypto.randomUUID() })).rejects.toThrow(/don't follow/);
});

test("a camera-private preview seat cannot vouch for a room even when visible", async () => {
  const { alice, bob } = await town(), { visitId } = await arrive(alice);
  vi.mocked(RoomServiceClient.prototype.listParticipants).mockResolvedValue([
    { identity: "bob", permission: { hidden: false }, metadata: JSON.stringify({ doorbellRole: "doorstep-preview" }) },
  ] as never);
  await expect(bob.as.action(api.doorActions.admit, { guest: "alice", visitId, room })).rejects.toThrow(/no longer/);
  expect(await alice.as.query(api.doors.events, {})).toEqual([]);
});


test("saving either policy state cancels legacy nonfriend previews and keeps friends", async () => {
  for (const enabled of [false, true]) {
    const { t, alice, bob } = await town(), stranger = await person(t, "stranger");
    await bob.as.mutation(api.profiles.setOpenDoorPolicy, { enabled: true });
    const outsiderId = crypto.randomUUID(), friend = await arrive(alice);
    await t.run(ctx => ctx.db.insert("visits", { visitId: outsiderId, ownerId: bob.profileId, guestId: stranger.profileId,
      mode: "walk_in", status: "announced", expiresAt: Date.now() + EVENT_TTL_MS }));
    await bob.as.mutation(api.profiles.setOpenDoorPolicy, { enabled });
    const events = await bob.as.query(api.doors.events, {});
    expect(events).toEqual(expect.arrayContaining([
      expect.objectContaining({ visitId: outsiderId, kind: "left" }),
      expect.objectContaining({ visitId: friend.visitId, kind: "walk_in" }),
    ]));
    await expect(bob.as.action(api.doorActions.answer, { hidden: true, visitId: outsiderId })).rejects.toThrow(/ended/);
    await bob.as.action(api.doorActions.answer, { hidden: true, visitId: friend.visitId });
  }
});

test("removing a friend cancels both doorstep previews despite either open policy", async () => {
  const { alice, bob } = await town();
  for (const owner of [alice, bob]) await owner.as.mutation(api.profiles.setOpenDoorPolicy, { enabled: true });
  const incoming = await arrive(alice), outgoing = await arrive(bob, "alice");
  await bob.as.action(api.doorActions.answer, { hidden: true, visitId: incoming.visitId });
  await alice.as.action(api.doorActions.answer, { hidden: true, visitId: outgoing.visitId });
  await bob.as.mutation(api.graph.unfollow, { profileId: alice.profileId });
  expect(await bob.as.query(api.doors.events, {})).toEqual([expect.objectContaining({ kind: "left", visitId: incoming.visitId })]);
  expect(await alice.as.query(api.doors.events, {})).toEqual([expect.objectContaining({ kind: "left", visitId: outgoing.visitId })]);
  for (const [owner, visitId] of [[bob, incoming.visitId], [alice, outgoing.visitId]] as const) {
    await expect(owner.as.action(api.doorActions.answer, { hidden: true, visitId })).rejects.toThrow(/ended/);
  }
  // Re-friending does not resurrect the old microphone seats.
  await alice.as.mutation(api.graph.request, { profileId: bob.profileId });
  await bob.as.mutation(api.graph.accept, { profileId: alice.profileId });
  await expect(alice.as.action(api.doorActions.visit, { door: "bob", visitId: incoming.visitId })).rejects.toThrow(/ended/);
});

test("close friends keep walk-in permission when Open Door is off", async () => {
  const { bob, carol } = await town();
  await bob.as.mutation(api.profiles.setOpenDoorPolicy, { enabled: true });
  const { visitId } = await arrive(carol);
  await bob.as.mutation(api.profiles.setOpenDoorPolicy, { enabled: false });
  waiting.set(room, ["bob"]);
  await bob.as.action(api.doorActions.admit, { guest: "carol", visitId, room, automatically: true });
  expect((await carol.as.query(api.doors.events, {}))[0]).toMatchObject({ kind: "admitted", visitId });
});
