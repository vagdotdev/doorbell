import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { api } from "./_generated/api";
import { EVENT_TTL_MS } from "./doors";
import { backend, livekitEnv, person } from "./test.setup";

/// What LiveKit will read out of a seat.
function claims(token: string) {
  const payload = token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
  return JSON.parse(atob(payload)) as {
    sub: string;
    name: string;
    metadata: string;
    video: { room: string; roomJoin: boolean; canPublish: boolean; canSubscribe: boolean; canPublishData: boolean; hidden: boolean };
  };
}

beforeEach(() => {
  for (const [k, v] of Object.entries(livekitEnv)) vi.stubEnv(k, v);
});
afterEach(() => vi.unstubAllEnvs());

/// alice and bob are friends. bob and carol are friends; bob is on carol's close list. carol does not know alice.
async function town() {
  const t = backend();
  const alice = await person(t, "alice", "Alice Rao");
  const bob = await person(t, "bob", "Bob Menon");
  const carol = await person(t, "carol", "Carol Iyer");
  await alice.as.mutation(api.graph.request, { profileId: bob.profileId });
  await bob.as.mutation(api.graph.accept, { profileId: alice.profileId });
  await bob.as.mutation(api.graph.request, { profileId: carol.profileId });
  await carol.as.mutation(api.graph.accept, { profileId: bob.profileId });
  await carol.as.mutation(api.graph.setCloseFriend, { profileId: bob.profileId, on: true });
  return { t, alice, bob, carol };
}

describe("visit", () => {
  test("a follower knocks from the doorstep and the owner alone hears it", async () => {
    const { t, alice, bob, carol } = await town();
    const seat = await alice.as.action(api.doorActions.visit, { door: "bob" });
    expect(seat.mode).toBe("knock");
    expect(seat.room).toBe("doorstep:bob");
    expect(seat.url).toBe(livekitEnv.LIVEKIT_PUBLIC_URL);
    const c = claims(seat.token);
    expect(c.sub).toBe("alice");
    expect(c.name).toBe("Alice Rao");
    expect(c.video).toMatchObject({ room: "doorstep:bob", roomJoin: true, canPublish: true, canSubscribe: false, canPublishData: false });
    expect(JSON.parse(c.metadata)).toEqual({ handle: "alice", display_name: "Alice Rao", via: "bob" });

    const atBob = await bob.as.query(api.doors.events, {});
    expect(atBob).toHaveLength(1);
    expect(atBob[0]).toMatchObject({ kind: "knock", grant: null });
    expect(atBob[0].from.handle).toBe("alice");
    expect(await alice.as.query(api.doors.events, {})).toEqual([]);
    expect(await carol.as.query(api.doors.events, {})).toEqual([]);
    expect(await t.query(api.doors.events, {})).toEqual([]);
  });

  test("a close friend walks straight into the room", async () => {
    const { bob, carol } = await town();
    const seat = await bob.as.action(api.doorActions.visit, { door: "carol" });
    expect(seat.mode).toBe("walk_in");
    expect(seat.room).toBe("door:carol");
    expect(claims(seat.token).video).toMatchObject({ room: "door:carol", canSubscribe: true, canPublishData: true, hidden: false });
    const atCarol = await carol.as.query(api.doors.events, {});
    expect(atCarol.map((e) => [e.kind, e.from.handle])).toEqual([["walk_in", "bob"]]);
  });

  test("strangers, pending requests and your own door are refused, and nothing rings", async () => {
    const { t, alice, bob, carol } = await town();
    await expect(alice.as.action(api.doorActions.visit, { door: "carol" })).rejects.toThrow(/don't follow/);
    await expect(carol.as.action(api.doorActions.visit, { door: "alice" })).rejects.toThrow(/don't follow/);
    await carol.as.mutation(api.graph.request, { profileId: alice.profileId });
    await expect(carol.as.action(api.doorActions.visit, { door: "alice" })).rejects.toThrow(/don't follow/);
    await expect(bob.as.action(api.doorActions.visit, { door: "bob" })).rejects.toThrow(/own door/);
    await expect(bob.as.action(api.doorActions.visit, { door: "nobody" })).rejects.toThrow(/No such door/);
    await expect(t.action(api.doorActions.visit, { door: "bob" })).rejects.toThrow(/Sign in/);
    expect(await t.run((ctx) => ctx.db.query("doorEvents").collect())).toEqual([]);
  });

  test("one live event per pair: a second knock replaces the first; leave replaces the knock", async () => {
    const { t, alice, bob } = await town();
    await alice.as.action(api.doorActions.visit, { door: "bob" });
    await alice.as.action(api.doorActions.visit, { door: "bob" });
    expect(await t.run((ctx) => ctx.db.query("doorEvents").collect())).toHaveLength(1);
    await alice.as.action(api.doorActions.leave, { door: "bob" });
    const atBob = await bob.as.query(api.doors.events, {});
    expect(atBob.map((e) => e.kind)).toEqual(["left"]);
  });

  test("leave needs the follow too", async () => {
    const { alice } = await town();
    await expect(alice.as.action(api.doorActions.leave, { door: "carol" })).rejects.toThrow(/don't follow/);
  });

  test("without LiveKit configured, nothing is minted and nothing rings", async () => {
    vi.stubEnv("LIVEKIT_API_SECRET", "");
    const { t, alice, bob } = await town();
    await expect(alice.as.action(api.doorActions.visit, { door: "bob" })).rejects.toThrow(/not configured/);
    await expect(bob.as.action(api.doorActions.answer, { hidden: true })).rejects.toThrow(/not configured/);
    await expect(bob.as.action(api.doorActions.admit, { guest: "alice" })).rejects.toThrow(/not configured/);
    // No ghost knock: the config check runs before the ring is written.
    expect(await t.run((ctx) => ctx.db.query("doorEvents").collect())).toEqual([]);
    expect(await bob.as.query(api.doors.events, {})).toEqual([]);
  });
});

describe("events", () => {
  test("only the addressee can ack; the sweep clears what nobody read", async () => {
    vi.useFakeTimers();
    try {
      const { t, alice, bob, carol } = await town();
      await alice.as.action(api.doorActions.visit, { door: "bob" });
      const [ev] = await bob.as.query(api.doors.events, {});

      await carol.as.mutation(api.doors.ack, { eventId: ev.id });
      await alice.as.mutation(api.doors.ack, { eventId: ev.id });
      expect(await bob.as.query(api.doors.events, {})).toHaveLength(1);
      await expect(t.mutation(api.doors.ack, { eventId: ev.id })).rejects.toThrow(/Sign in/);

      await bob.as.mutation(api.doors.ack, { eventId: ev.id });
      expect(await bob.as.query(api.doors.events, {})).toEqual([]);
      await bob.as.mutation(api.doors.ack, { eventId: ev.id }); // gone already: fine

      await alice.as.action(api.doorActions.visit, { door: "bob" });
      expect(await t.run((ctx) => ctx.db.query("doorEvents").collect())).toHaveLength(1);
      vi.advanceTimersByTime(EVENT_TTL_MS + 1);
      await t.finishAllScheduledFunctions(vi.runAllTimers);
      expect(await t.run((ctx) => ctx.db.query("doorEvents").collect())).toEqual([]);
    } finally {
      vi.useRealTimers();
    }
  });
});

describe("answer", () => {
  test("hidden peeks from the doorstep; open hosts the room", async () => {
    const { bob } = await town();
    const peek = await bob.as.action(api.doorActions.answer, { hidden: true });
    expect(peek).toMatchObject({ mode: "answer", room: "doorstep:bob" });
    expect(claims(peek.token).video).toMatchObject({ room: "doorstep:bob", hidden: true, canSubscribe: true });
    const host = await bob.as.action(api.doorActions.answer, { hidden: false });
    expect(host.room).toBe("door:bob");
    expect(claims(host.token).video).toMatchObject({ room: "door:bob", hidden: false });
  });

  test("needs a handle", async () => {
    const t = backend();
    await expect(t.action(api.doorActions.answer, { hidden: true })).rejects.toThrow(/Sign in/);
  });
});

describe("admit", () => {
  test("the owner lets a follower in; the seat goes to the guest's door only", async () => {
    const { t, alice, bob } = await town();
    await alice.as.action(api.doorActions.visit, { door: "bob" });
    const result = await bob.as.action(api.doorActions.admit, { guest: "alice" });
    expect(result).toBeNull(); // the owner never sees the guest's token

    const atAlice = await alice.as.query(api.doors.events, {});
    expect(atAlice).toHaveLength(1);
    expect(atAlice[0].kind).toBe("admitted");
    expect(atAlice[0].from.handle).toBe("bob");
    expect(atAlice[0].grant).toMatchObject({ room: "door:bob", url: livekitEnv.LIVEKIT_PUBLIC_URL });
    const c = claims(atAlice[0].grant!.token);
    expect(c.sub).toBe("alice");
    expect(c.video).toMatchObject({ room: "door:bob", canSubscribe: true, canPublishData: true, hidden: false });
    expect(JSON.parse(c.metadata).via).toBe("bob");

    // bob's own knock row is still his; alice's admitted row is hers.
    const rows = await t.run((ctx) => ctx.db.query("doorEvents").collect());
    expect(rows.map((r) => r.kind).sort()).toEqual(["admitted", "knock"]);
    expect(await bob.as.query(api.doors.events, {})).toHaveLength(1);
  });

  test("only followers can be admitted, and only by the door's owner", async () => {
    const { alice, bob, carol } = await town();
    await expect(alice.as.action(api.doorActions.admit, { guest: "carol" })).rejects.toThrow(/don't follow you/);
    await expect(carol.as.action(api.doorActions.admit, { guest: "alice" })).rejects.toThrow(/don't follow you/);
    await expect(bob.as.action(api.doorActions.admit, { guest: "bob" })).rejects.toThrow(/you/);
    await expect(bob.as.action(api.doorActions.admit, { guest: "nobody" })).rejects.toThrow(/No such door/);
    expect(await alice.as.query(api.doors.events, {})).toEqual([]);
  });

  test("vouching into another room needs to be a room, and needs me in it (fails closed)", async () => {
    const { alice, bob } = await town();
    await expect(bob.as.action(api.doorActions.admit, { guest: "alice", room: "doorstep:carol" })).rejects.toThrow(/Not a room/);
    // No LiveKit server is reachable in tests: the participant check must refuse, not allow.
    await expect(bob.as.action(api.doorActions.admit, { guest: "alice", room: "door:carol" })).rejects.toThrow(/not in that room/);
    expect(await alice.as.query(api.doors.events, {})).toEqual([]);
  });
});
