import { describe, expect, test } from "vitest";
import { api } from "./_generated/api";
import { backend, person, signedIn } from "./test.setup";

describe("account", () => {
  test("signed out → needs handle → ready", async () => {
    const t = backend();
    expect(await t.query(api.profiles.account, {})).toEqual({
      state: "signedOut",
      me: null,
      email: null,
      nameQuota: { remaining: 2, resetsAt: null },
    });

    const { as } = await signedIn(t, "a@test.local");
    expect(await as.query(api.profiles.account, {})).toEqual({
      state: "needsHandle",
      me: null,
      email: "a@test.local",
      nameQuota: { remaining: 2, resetsAt: null },
    });

    const me = await as.mutation(api.profiles.claimHandle, { handle: "Alice", displayName: " Alice Rao " });
    expect(me.handle).toBe("alice");
    expect(me.displayName).toBe("Alice Rao");
    const after = await as.query(api.profiles.account, {});
    expect(after.state).toBe("ready");
    expect(after.me).toEqual(me);
    expect(after.email).toBe("a@test.local");
    expect(after.nameQuota).toEqual({ remaining: 2, resetsAt: null });
    // Only public fields leave the server.
    expect(Object.keys(me).sort()).toEqual(["avatarUrl", "displayName", "handle", "id", "openDoorPolicy"]);
  });

  test("handle rules: format, uniqueness (case-insensitive), once per account", async () => {
    const t = backend();
    const a = await signedIn(t, "a@test.local");
    const b = await signedIn(t, "b@test.local");
    await expect(a.as.mutation(api.profiles.claimHandle, { handle: "ab", displayName: "x" })).rejects.toThrow(/3–20/);
    await expect(a.as.mutation(api.profiles.claimHandle, { handle: "has space", displayName: "x" })).rejects.toThrow(/3–20/);
    await expect(a.as.mutation(api.profiles.claimHandle, { handle: "alice", displayName: "  " })).rejects.toThrow(/name/);
    await a.as.mutation(api.profiles.claimHandle, { handle: "alice", displayName: "A" });
    await expect(b.as.mutation(api.profiles.claimHandle, { handle: "ALICE", displayName: "B" })).rejects.toThrow(/taken/);
    await expect(a.as.mutation(api.profiles.claimHandle, { handle: "alice2", displayName: "A" })).rejects.toThrow(/already/);
    await expect(t.mutation(api.profiles.claimHandle, { handle: "nobody", displayName: "N" })).rejects.toThrow(/Sign in/);
  });

  test("update name, set and clear avatar", async () => {
    const t = backend();
    const alice = await person(t, "alice", "Alice");
    const renamed = await alice.as.mutation(api.profiles.update, { displayName: " Alice Rao " });
    expect(renamed.displayName).toBe("Alice Rao");
    await expect(alice.as.mutation(api.profiles.update, { displayName: "  " })).rejects.toThrow(/name/);
    await expect(t.mutation(api.profiles.update, { displayName: "X" })).rejects.toThrow(/Sign in/);

    const second = await alice.as.mutation(api.profiles.update, { displayName: "Alice R." });
    expect(second.displayName).toBe("Alice R.");
    await expect(alice.as.mutation(api.profiles.update, { displayName: "Ali" })).rejects.toThrow(
      /twice every 14 days/,
    );
    const account = await alice.as.query(api.profiles.account, {});
    expect(account.nameQuota.remaining).toBe(0);
    expect(account.nameQuota.resetsAt).toEqual(expect.any(Number));
    // Same name is a no-op and does not burn quota.
    const noop = await alice.as.mutation(api.profiles.update, { displayName: "Alice R." });
    expect(noop.displayName).toBe("Alice R.");

    const bytes = new Uint8Array([0xff, 0xd8, 0xff, 1]).buffer;
    const withPhoto = await alice.as.action(api.profiles.uploadAvatar, { bytes, contentType: "image/jpeg" });
    expect(withPhoto.avatarUrl).toEqual(expect.any(String));
    const storageId = (await t.run(ctx => ctx.db.get(alice.profileId)))!.avatarStorageId!;
    await alice.as.mutation(api.profiles.setAvatar, { storageId }); // idempotent, never deletes own current image
    expect(await t.run(ctx => ctx.storage.getUrl(storageId))).not.toBeNull();
    await alice.as.action(api.profiles.uploadAvatar, { bytes, contentType: "image/jpeg" });
    expect(await t.run(ctx => ctx.storage.getUrl(storageId))).toBeNull();
    const nextId = (await t.run(ctx => ctx.db.get(alice.profileId)))!.avatarStorageId!;
    expect((await alice.as.mutation(api.profiles.clearAvatar, {})).avatarUrl).toBeNull();
    expect(await t.run(ctx => ctx.storage.getUrl(nextId))).toBeNull();
    await expect(t.action(api.profiles.uploadAvatar, { bytes, contentType: "image/jpeg" })).rejects.toThrow(/Sign in/);
    await expect(alice.as.action(api.profiles.uploadAvatar, { bytes, contentType: "text/html" })).rejects.toThrow(/JPEG/);
    await expect(alice.as.mutation(api.profiles.generateUploadUrl, {})).rejects.toThrow(/Update/);
  });
});

describe("search", () => {
  test("prefix on handle, name search, never me, public fields only", async () => {
    const t = backend();
    const alice = await person(t, "alice", "Alice Rao");
    await person(t, "albert", "Albert Pinto");
    await person(t, "bob", "Robert Menon");

    const byPrefix = await alice.as.query(api.profiles.search, { q: "@AL" });
    expect(byPrefix.map((p) => p.handle)).toEqual(["albert"]); // alice is me
    const byName = await alice.as.query(api.profiles.search, { q: "Robert" });
    expect(byName.map((p) => p.handle)).toEqual(["bob"]);
    expect(await alice.as.query(api.profiles.search, { q: "a" })).toEqual([]);
    expect(await t.query(api.profiles.search, { q: "alice" })).toEqual([]); // signed out
    for (const p of byPrefix) expect(Object.keys(p).sort()).toEqual(["avatarUrl", "displayName", "handle", "id", "openDoorPolicy"]);
  });
});

describe("friendships", () => {
  test("crossed requests settle with one acceptance and no pending requests", async () => {
    const t = backend();
    const alice = await person(t, "alice");
    const bob = await person(t, "bob");
    await alice.as.mutation(api.graph.request, { profileId: bob.profileId });
    await bob.as.mutation(api.graph.request, { profileId: alice.profileId });
    await bob.as.mutation(api.graph.accept, { profileId: alice.profileId });
    for (const who of [alice, bob]) {
      const hallway = await who.as.query(api.graph.hallway, {});
      expect(hallway!.doors).toHaveLength(1);
      expect(hallway!.requests).toEqual([]);
      expect(hallway!.outgoing).toEqual([]);
    }
    // A stale Decline click from the other client cannot undo the acceptance.
    await alice.as.mutation(api.graph.ignore, { profileId: bob.profileId });
    expect(await t.run((ctx) => ctx.db.query("follows").collect())).toHaveLength(2);
  });

  test("a stranger cannot accept someone else's request or remove their friendship", async () => {
    const t = backend();
    const alice = await person(t, "alice");
    const bob = await person(t, "bob");
    const carol = await person(t, "carol");
    await alice.as.mutation(api.graph.request, { profileId: bob.profileId });
    await expect(carol.as.mutation(api.graph.accept, { profileId: alice.profileId })).rejects.toThrow(/No request/);
    await expect(t.mutation(api.graph.accept, { profileId: alice.profileId })).rejects.toThrow(/Sign in/);
    await bob.as.mutation(api.graph.accept, { profileId: alice.profileId });
    await carol.as.mutation(api.graph.unfollow, { profileId: alice.profileId });
    expect(await t.run((ctx) => ctx.db.query("follows").collect())).toHaveLength(2);
  });

  test("acceptance lets both friends knock; removing the friendship refuses both", async () => {
    const t = backend();
    const alice = await person(t, "alice");
    const bob = await person(t, "bob");
    await alice.as.mutation(api.graph.request, { profileId: bob.profileId });
    await bob.as.mutation(api.graph.accept, { profileId: alice.profileId });
    const { internal } = await import("./_generated/api");
    expect((await alice.as.mutation(internal.doors.decideVisit, { door: "bob", visitId: crypto.randomUUID() })).mode).toBe("knock");
    expect((await bob.as.mutation(internal.doors.decideVisit, { door: "alice", visitId: crypto.randomUUID() })).mode).toBe("knock");
    await alice.as.mutation(api.graph.unfollow, { profileId: bob.profileId });
    await expect(alice.as.mutation(internal.doors.decideVisit, { door: "bob", visitId: crypto.randomUUID() })).rejects.toThrow(/don't follow/);
    await expect(bob.as.mutation(internal.doors.decideVisit, { door: "alice", visitId: crypto.randomUUID() })).rejects.toThrow(/don't follow/);
  });

  test("request → accept by the followee only → doors on both sides", async () => {
    const t = backend();
    const alice = await person(t, "alice");
    const bob = await person(t, "bob");

    await alice.as.mutation(api.graph.request, { profileId: bob.profileId });
    await alice.as.mutation(api.graph.request, { profileId: bob.profileId }); // idempotent
    await expect(alice.as.mutation(api.graph.request, { profileId: alice.profileId })).rejects.toThrow(/you/);

    let a = await alice.as.query(api.graph.hallway, {});
    let b = await bob.as.query(api.graph.hallway, {});
    expect(a!.outgoing).toEqual([bob.profileId]);
    expect(a!.doors).toEqual([]);
    expect(b!.requests.map((p) => p.handle)).toEqual(["alice"]);

    // The requester cannot accept their own request.
    await expect(alice.as.mutation(api.graph.accept, { profileId: bob.profileId })).rejects.toThrow(/No request/);
    await bob.as.mutation(api.graph.accept, { profileId: alice.profileId });

    a = await alice.as.query(api.graph.hallway, {});
    b = await bob.as.query(api.graph.hallway, {});
    expect(a!.doors.map((d) => [d.profile.handle, d.followsMe, d.isCloseFriend])).toEqual([["bob", true, false]]);
    expect(a!.outgoing).toEqual([]);
    expect(b!.requests).toEqual([]);
    expect(b!.doors.map((d) => [d.profile.handle, d.followsMe, d.isCloseFriend]))
      .toEqual([["alice", true, false]]);
    // Neither side gets walk-in permission merely by becoming friends.
    expect(await t.run((ctx) => ctx.db.query("closeFriends").collect())).toEqual([]);
    await bob.as.mutation(api.graph.accept, { profileId: alice.profileId });
    expect(await t.run((ctx) => ctx.db.query("follows").collect())).toHaveLength(2);
  });

  test("ignore drops a request; unfollow drops the edge and the close-friend standing", async () => {
    const t = backend();
    const alice = await person(t, "alice");
    const bob = await person(t, "bob");
    await alice.as.mutation(api.graph.request, { profileId: bob.profileId });
    await bob.as.mutation(api.graph.ignore, { profileId: alice.profileId });
    expect((await bob.as.query(api.graph.hallway, {}))!.requests).toEqual([]);
    expect((await alice.as.query(api.graph.hallway, {}))!.outgoing).toEqual([]);

    await alice.as.mutation(api.graph.request, { profileId: bob.profileId });
    await bob.as.mutation(api.graph.accept, { profileId: alice.profileId });
    await bob.as.mutation(api.graph.setCloseFriend, { profileId: alice.profileId, on: true });
    await alice.as.mutation(api.graph.setCloseFriend, { profileId: bob.profileId, on: true });
    expect(await t.run((ctx) => ctx.db.query("closeFriends").collect())).toHaveLength(2);

    await alice.as.mutation(api.graph.unfollow, { profileId: bob.profileId });
    expect((await alice.as.query(api.graph.hallway, {}))!.doors).toEqual([]);
    expect((await bob.as.query(api.graph.hallway, {}))!.doors).toEqual([]);
    expect(await t.run((ctx) => ctx.db.query("follows").collect())).toEqual([]);
    expect(await t.run((ctx) => ctx.db.query("closeFriends").collect())).toEqual([]);
  });

  test("close friends: only accepted followers; only my list shows it", async () => {
    const t = backend();
    const alice = await person(t, "alice");
    const bob = await person(t, "bob");
    await expect(bob.as.mutation(api.graph.setCloseFriend, { profileId: alice.profileId, on: true })).rejects.toThrow(/follow you first/);
    await alice.as.mutation(api.graph.request, { profileId: bob.profileId });
    await expect(bob.as.mutation(api.graph.setCloseFriend, { profileId: alice.profileId, on: true })).rejects.toThrow(/follow you first/);
    await bob.as.mutation(api.graph.accept, { profileId: alice.profileId });
    await bob.as.mutation(api.graph.setCloseFriend, { profileId: alice.profileId, on: true });
    await bob.as.mutation(api.graph.setCloseFriend, { profileId: alice.profileId, on: true }); // idempotent
    expect(await t.run((ctx) => ctx.db.query("closeFriends").collect())).toHaveLength(1);

    // alice follows bob, so bob is a door for alice — and alice is never told she is close.
    const a = await alice.as.query(api.graph.hallway, {});
    expect(a!.doors[0].isCloseFriend).toBe(false);
    await bob.as.mutation(api.graph.setCloseFriend, { profileId: alice.profileId, on: false });
    expect(await t.run((ctx) => ctx.db.query("closeFriends").collect())).toEqual([]);
  });

  test("signed out or no handle: reads are empty, writes refuse", async () => {
    const t = backend();
    const bob = await person(t, "bob");
    expect(await t.query(api.graph.hallway, {})).toBeNull();
    await expect(t.mutation(api.graph.request, { profileId: bob.profileId })).rejects.toThrow(/Sign in/);
    const { as } = await signedIn(t, "nohandle@test.local");
    expect(await as.query(api.graph.hallway, {})).toBeNull();
    await expect(as.mutation(api.graph.request, { profileId: bob.profileId })).rejects.toThrow(/handle/);
  });
});
