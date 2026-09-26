import { afterEach, beforeEach, expect, test, vi } from "vitest";
import { api } from "./_generated/api";
import { backend, person } from "./test.setup";

const PASSWORD = "correct-horse-battery-staple";

async function sha256hex(s: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

beforeEach(async () => {
  vi.stubEnv("ADMIN_PASSWORD_SHA256", await sha256hex(PASSWORD));
});
afterEach(() => { vi.unstubAllEnvs(); vi.useRealTimers(); });

test("wrong password and unconfigured deployments are refused", async () => {
  const t = backend();
  await expect(t.action(api.admin.login, { password: "nope" })).rejects.toThrow(/Wrong password/);
  await expect(t.action(api.admin.login, { password: PASSWORD + " " })).rejects.toThrow(/Wrong password/);
  vi.stubEnv("ADMIN_PASSWORD_SHA256", "");
  await expect(t.action(api.admin.login, { password: PASSWORD })).rejects.toThrow(/not configured/);
});

test("stats requires a live token and aggregates calls, minutes, knocks and pairs", async () => {
  const t = backend();
  const now = Date.now();
  const T = now - 1_200_000; // room A started 20 minutes ago

  await person(t, "alice", "Alice");
  await person(t, "bob", "Bob");

  await expect(t.query(api.admin.stats, { token: "bogus", now })).rejects.toThrow(/Sign in/);
  const { token } = await t.action(api.admin.login, { password: PASSWORD });

  await t.run(async (ctx) => {
    const roomA = "door:bob:00000000-0000-4000-8000-00000000000a";
    const roomB = "door:alice:00000000-0000-4000-8000-00000000000b";
    const step = "doorstep:bob:00000000-0000-4000-8000-00000000000c";
    // Room A: a finished 2-person call at bob's door.
    await ctx.db.insert("callSessions", { roomName: roomA, roomSid: "RM_A", kind: "door", ownerHandle: "bob", identity: "bob", preview: false, joinedAt: T, leftAt: T + 600_000 });
    await ctx.db.insert("callSessions", { roomName: roomA, roomSid: "RM_A", kind: "door", ownerHandle: "bob", identity: "alice", preview: false, joinedAt: T + 60_000, leftAt: T + 540_000 });
    // Room B: a call at alice's door, still open (5 minutes so far).
    await ctx.db.insert("callSessions", { roomName: roomB, roomSid: "RM_B", kind: "door", ownerHandle: "alice", identity: "alice", preview: false, joinedAt: T + 900_000 });
    await ctx.db.insert("callSessions", { roomName: roomB, roomSid: "RM_B", kind: "door", ownerHandle: "alice", identity: "bob", preview: false, joinedAt: T + 900_000 });
    // Alice knocked on bob's doorstep; bob peeked with a preview seat (not a call).
    await ctx.db.insert("callSessions", { roomName: step, roomSid: "RM_C", kind: "doorstep", ownerHandle: "bob", identity: "alice", preview: false, joinedAt: T + 30_000, leftAt: T + 50_000 });
    await ctx.db.insert("callSessions", { roomName: step, roomSid: "RM_C", kind: "doorstep", ownerHandle: "bob", identity: "bob", preview: true, joinedAt: T + 35_000, leftAt: T + 50_000 });
  });

  const stats = await t.query(api.admin.stats, { token, now });
  expect(stats.totals).toEqual({ people: 2, calls: 2, minutes: 28, knocks: 1, inCallNow: 2 });
  expect(stats.signupsByDay).toHaveLength(30);
  expect(stats.signupsByDay.reduce((sum, d) => sum + d.count, 0)).toBe(2);
  expect(stats.people).toMatchObject([
    { handle: "bob", calls: 2, minutes: 15, knocksOut: 0, knocksIn: 1 },
    { handle: "alice", calls: 2, minutes: 13, knocksOut: 1, knocksIn: 0 },
  ]);
  expect(stats.pairs).toEqual([
    { guest: "alice", owner: "bob", calls: 1, minutes: 8 },
    { guest: "bob", owner: "alice", calls: 1, minutes: 5 },
  ]);
  expect(stats.recent).toHaveLength(6);

  await t.mutation(api.admin.logout, { token });
  await expect(t.query(api.admin.stats, { token, now })).rejects.toThrow(/Sign in/);
});

test("sessions expire on schedule and stale tokens are refused by time", async () => {
  vi.useFakeTimers();
  const t = backend();
  const { token, expiresAt } = await t.action(api.admin.login, { password: PASSWORD });
  // A token past its expiry is dead even before the sweep runs.
  await expect(t.query(api.admin.stats, { token, now: expiresAt + 1 })).rejects.toThrow(/Sign in/);

  await t.finishAllScheduledFunctions(vi.runAllTimers);
  await expect(t.query(api.admin.stats, { token, now: 0 })).rejects.toThrow(/Sign in/);
});
