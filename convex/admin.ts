import { ConvexError, v } from "convex/values";
import { internal } from "./_generated/api";
import type { Doc } from "./_generated/dataModel";
import { action, internalMutation, mutation, query } from "./_generated/server";

// Reset the deployment to zero users. Internal: only the CLI or dashboard can run it.
//   npx convex run --prod admin:wipeAll
export const wipeAll = internalMutation({
  args: {},
  handler: async (ctx) => {
    const tables = [
      "callSessions", "adminSessions",
      "doorEvents", "visits", "avatarUploads", "closeFriends", "follows", "profiles",
      "authVerificationCodes", "authVerifiers", "authRefreshTokens", "authSessions",
      "authRateLimits", "authAccounts", "users",
    ] as const;
    const counts: Record<string, number> = {};
    for (const table of tables) {
      const rows = await ctx.db.query(table).collect();
      for (const row of rows) await ctx.db.delete(row._id);
      counts[table] = rows.length;
    }
    const files = await ctx.db.system.query("_storage").collect();
    for (const file of files) await ctx.storage.delete(file._id);
    counts._storage = files.length;
    return counts;
  },
});

// --- /admin dashboard ---------------------------------------------------------
// The password never touches the database: only its SHA-256 lives on the
// deployment (ADMIN_PASSWORD_SHA256, set by scripts/admin-setup.sh). A correct
// password buys a random session token that expires by scheduled mutation, so
// the stats query never reads the wall clock.

const SESSION_TTL_MS = 12 * 60 * 60 * 1000;

function constantTimeEqual(a: string, b: string): boolean {
  let diff = a.length === b.length ? 0 : 1;
  const length = Math.max(a.length, b.length);
  for (let i = 0; i < length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/// Trade the admin password for a dashboard session token.
export const login = action({
  args: { password: v.string() },
  returns: v.object({ token: v.string(), expiresAt: v.number() }),
  handler: async (ctx, args): Promise<{ token: string; expiresAt: number }> => {
    const expected = process.env.ADMIN_PASSWORD_SHA256;
    if (!expected) throw new ConvexError("Admin is not configured on this deployment.");
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(args.password));
    const hex = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
    if (!constantTimeEqual(hex, expected.toLowerCase())) {
      console.warn("admin login rejected");
      throw new ConvexError("Wrong password.");
    }
    const bytes = new Uint8Array(32);
    crypto.getRandomValues(bytes);
    const token = [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
    return await ctx.runMutation(internal.admin.createSession, { token });
  },
});

export const createSession = internalMutation({
  args: { token: v.string() },
  returns: v.object({ token: v.string(), expiresAt: v.number() }),
  handler: async (ctx, args) => {
    const expiresAt = Date.now() + SESSION_TTL_MS;
    const id = await ctx.db.insert("adminSessions", { token: args.token, expiresAt });
    await ctx.scheduler.runAfter(SESSION_TTL_MS, internal.admin.expireSession, { id });
    return { token: args.token, expiresAt };
  },
});

export const expireSession = internalMutation({
  args: { id: v.id("adminSessions") },
  returns: v.null(),
  handler: async (ctx, args) => {
    if (await ctx.db.get(args.id)) await ctx.db.delete(args.id);
    return null;
  },
});

export const logout = mutation({
  args: { token: v.string() },
  returns: v.null(),
  handler: async (ctx, args) => {
    const session = await ctx.db
      .query("adminSessions")
      .withIndex("by_token", (q) => q.eq("token", args.token))
      .unique();
    if (session) await ctx.db.delete(session._id);
    return null;
  },
});

const personRow = v.object({
  handle: v.string(),
  displayName: v.string(),
  joinedAt: v.number(),
  calls: v.number(),
  minutes: v.number(),
  knocksOut: v.number(),
  knocksIn: v.number(),
  lastActive: v.union(v.number(), v.null()),
});
const pairRow = v.object({
  guest: v.string(),
  owner: v.string(),
  calls: v.number(),
  minutes: v.number(),
});
const sessionRow = v.object({
  roomName: v.string(),
  kind: v.union(v.literal("door"), v.literal("doorstep")),
  ownerHandle: v.string(),
  identity: v.string(),
  preview: v.boolean(),
  joinedAt: v.number(),
  leftAt: v.union(v.number(), v.null()),
});

const minutes = (ms: number) => Math.round(Math.max(0, ms) / 6000) / 10;

/// Everything the /admin dashboard shows. `now` comes from the client so the
/// query stays cacheable (see convex guidelines on wall clocks in queries).
/// A "call" is a `door:` room where two different people (not doorstep
/// previews) actually connected. A "knock" is a `doorstep:` room a guest
/// reached. Data starts at the moment the LiveKit webhook was configured.
export const stats = query({
  args: { token: v.string(), now: v.number() },
  returns: v.object({
    totals: v.object({
      people: v.number(),
      calls: v.number(),
      minutes: v.number(),
      knocks: v.number(),
      inCallNow: v.number(),
    }),
    signupsByDay: v.array(v.object({ day: v.string(), count: v.number() })),
    people: v.array(personRow),
    pairs: v.array(pairRow),
    recent: v.array(sessionRow),
    expiresAt: v.number(),
  }),
  handler: async (ctx, args) => {
    const session = await ctx.db
      .query("adminSessions")
      .withIndex("by_token", (q) => q.eq("token", args.token))
      .unique();
    if (!session || session.expiresAt <= args.now) throw new ConvexError("Sign in again.");

    const profiles = await ctx.db.query("profiles").take(1000);
    const sessions = await ctx.db.query("callSessions").order("desc").take(5000);

    // Signups per day, last 30 days (UTC), oldest first.
    const dayOf = (t: number) => new Date(t).toISOString().slice(0, 10);
    const signupsByDay: { day: string; count: number }[] = [];
    const dayIndex = new Map<string, number>();
    for (let back = 29; back >= 0; back--) {
      const day = dayOf(args.now - back * 24 * 60 * 60 * 1000);
      dayIndex.set(day, signupsByDay.length);
      signupsByDay.push({ day, count: 0 });
    }
    for (const p of profiles) {
      const i = dayIndex.get(dayOf(p._creationTime));
      if (i !== undefined) signupsByDay[i]!.count++;
    }

    const people = new Map<string, {
      handle: string; displayName: string; joinedAt: number;
      calls: number; minutes: number; knocksOut: number; knocksIn: number;
      lastActive: number | null;
    }>();
    for (const p of profiles) {
      people.set(p.handle, {
        handle: p.handle, displayName: p.displayName, joinedAt: p._creationTime,
        calls: 0, minutes: 0, knocksOut: 0, knocksIn: 0, lastActive: null,
      });
    }
    const touch = (handle: string, at: number) => {
      const row = people.get(handle);
      if (row) row.lastActive = Math.max(row.lastActive ?? 0, at);
    };

    const rooms = new Map<string, Doc<"callSessions">[]>();
    for (const s of sessions) {
      const list = rooms.get(s.roomName);
      if (list) list.push(s);
      else rooms.set(s.roomName, [s]);
      touch(s.identity, s.leftAt ?? s.joinedAt);
    }

    const totals = { people: profiles.length, calls: 0, minutes: 0, knocks: 0, inCallNow: 0 };
    const pairs = new Map<string, { guest: string; owner: string; calls: number; minutes: number }>();
    const inCallNow = new Set<string>();

    for (const list of rooms.values()) {
      const kind = list[0]!.kind;
      const owner = list[0]!.ownerHandle;
      const real = list.filter((s) => !s.preview);
      const identities = new Set(real.map((s) => s.identity));
      if (kind === "door" && identities.size >= 2) {
        totals.calls++;
        const perPerson = new Map<string, number>();
        for (const s of real) {
          const ms = (s.leftAt ?? args.now) - s.joinedAt;
          perPerson.set(s.identity, (perPerson.get(s.identity) ?? 0) + Math.max(0, ms));
          if (s.leftAt === undefined) inCallNow.add(s.identity);
        }
        for (const [identity, ms] of perPerson) {
          totals.minutes += minutes(ms);
          const row = people.get(identity);
          if (row) {
            row.calls++;
            row.minutes += minutes(ms);
          }
          if (identity !== owner) {
            const key = `${identity}\u0000${owner}`;
            const pair = pairs.get(key) ?? { guest: identity, owner, calls: 0, minutes: 0 };
            pair.calls++;
            pair.minutes += minutes(ms);
            pairs.set(key, pair);
          }
        }
      } else if (kind === "doorstep") {
        const guests = new Set(real.filter((s) => s.identity !== owner).map((s) => s.identity));
        if (guests.size > 0) totals.knocks++;
        for (const guest of guests) {
          const g = people.get(guest);
          if (g) g.knocksOut++;
          const o = people.get(owner);
          if (o) o.knocksIn++;
        }
      }
    }
    totals.inCallNow = inCallNow.size;
    totals.minutes = Math.round(totals.minutes * 10) / 10;

    const peopleRows = [...people.values()]
      .map((r) => ({ ...r, minutes: Math.round(r.minutes * 10) / 10 }))
      .sort((a, b) => b.minutes - a.minutes || (b.lastActive ?? 0) - (a.lastActive ?? 0) || b.joinedAt - a.joinedAt);
    const pairRows = [...pairs.values()]
      .map((r) => ({ ...r, minutes: Math.round(r.minutes * 10) / 10 }))
      .sort((a, b) => b.calls - a.calls || b.minutes - a.minutes);
    const recent = sessions.slice(0, 20).map((s) => ({
      roomName: s.roomName, kind: s.kind, ownerHandle: s.ownerHandle, identity: s.identity,
      preview: s.preview, joinedAt: s.joinedAt, leftAt: s.leftAt ?? null,
    }));

    return { totals, signupsByDay, people: peopleRows, pairs: pairRows, recent, expiresAt: session.expiresAt };
  },
});
