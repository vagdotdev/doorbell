import { ConvexError, v } from "convex/values";
import { internal } from "./_generated/api";
import type { Doc, Id } from "./_generated/dataModel";
import { internalMutation, internalQuery, mutation, query, type MutationCtx, type QueryCtx } from "./_generated/server";
import { closeFriendEdge, follows, profileValidator, publicProfile, requireProfile } from "./lib";

export const EVENT_TTL_MS = 45_000;
const grantValidator = v.object({ url: v.string(), token: v.string(), room: v.string() });
const kindValidator = v.union(v.literal("knock"), v.literal("walk_in"), v.literal("left"), v.literal("admitted"));
const who = v.object({ id: v.id("profiles"), handle: v.string(), displayName: v.string() });
const slim = (p: Doc<"profiles">) => ({ id: p._id, handle: p.handle, displayName: p.displayName });
const decision = v.object({ mode: v.union(v.literal("knock"), v.literal("walk_in")), me: who, owner: who });

export const events = query({
  args: {},
  returns: v.array(v.object({ id: v.id("doorEvents"), visitId: v.string(), kind: kindValidator,
    from: profileValidator, grant: v.union(grantValidator, v.null()) })),
  handler: async (ctx) => {
    const me = await requireProfile(ctx).catch(() => null);
    if (!me) return [];
    const rows = await ctx.db.query("doorEvents").withIndex("by_to", q => q.eq("toProfileId", me._id)).take(200);
    const out = [];
    for (const row of rows) {
      if (!row.visitId) continue; // Old clients cannot create valid v2 arrivals.
      const from = await ctx.db.get(row.fromProfileId);
      if (from) out.push({ id: row._id, visitId: row.visitId, kind: row.kind,
        from: await publicProfile(ctx, from), grant: row.grant ?? null });
    }
    return out;
  },
});
export const ack = mutation({
  args: { eventId: v.id("doorEvents") }, returns: v.null(),
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx);
    const row = await ctx.db.get(args.eventId);
    if (row?.toProfileId === me._id) await ctx.db.delete(row._id);
    return null;
  },
});
export const whoAmI = internalQuery({ args: {}, returns: who, handler: async ctx => slim(await requireProfile(ctx)) });

export const decideVisit = internalMutation({
  args: { door: v.string(), visitId: v.string() }, returns: decision,
  handler: async (ctx, args) => {
    validateVisitId(args.visitId);
    const me = await requireProfile(ctx), owner = await byHandle(ctx, args.door);
    if (owner._id === me._id) throw new ConvexError("That's your own door.");
    if (!(await canVisit(ctx, me._id, owner))) throw new ConvexError("You don't follow this door.");
    const existing = await findVisit(ctx, args.visitId);
    if (existing) {
      if (existing.guestId !== me._id || existing.ownerId !== owner._id) throw new ConvexError("Not your visit.");
      active(existing);
      return { mode: existing.mode, me: slim(me), owner: slim(owner) };
    }
    // One outbound visit per person. Superseding a slow old request informs its owner.
    const previous = await ctx.db.query("visits").withIndex("by_guestId", q => q.eq("guestId", me._id)).take(100);
    if (previous.length >= 100) throw new ConvexError("Too many attempts. Wait a minute and try again.");
    for (const row of previous) {
      if (row.status === "prepared" || row.status === "announced") await cancel(ctx, row);
    }
    const pending = await pendingVisits(ctx, owner._id);
    if (pending.length >= 100) {
      throw new ConvexError("That door is busy. Try again shortly.");
    }
    const mode = await mayWalkIn(ctx, me._id, owner) ? "walk_in" as const : "knock" as const;
    const id = await ctx.db.insert("visits", { visitId: args.visitId, ownerId: owner._id, guestId: me._id,
      mode, status: "prepared", expiresAt: Date.now() + EVENT_TTL_MS });
    await ctx.scheduler.runAfter(EVENT_TTL_MS, internal.doors.expireVisit, { id });
    return { mode, me: slim(me), owner: slim(owner) };
  },
});
export const inspectVisit = internalQuery({
  args: { visitId: v.string(), side: v.union(v.literal("owner"), v.literal("guest")) },
  returns: v.object({ me: who, guest: who, owner: who }),
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx), visit = await findVisit(ctx, args.visitId);
    if (!visit || (args.side === "owner" ? visit.ownerId : visit.guestId) !== me._id) throw new ConvexError("Not your visit.");
    // Time is enforced again in mutations, where the clock is a transactional input.
    if (visit.status === "canceled" || visit.status === "admitted") throw new ConvexError("That visit ended.");
    const guest = await ctx.db.get(visit.guestId), owner = await ctx.db.get(visit.ownerId);
    if (!guest || !owner || !(await canVisit(ctx, guest._id, owner))) throw new ConvexError("That friendship ended.");
    return { me: slim(me), guest: slim(guest), owner: slim(owner) };
  },
});
export const announce = internalMutation({
  args: { visitId: v.string() }, returns: v.null(),
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx), visit = await findVisit(ctx, args.visitId);
    if (!visit || visit.guestId !== me._id) throw new ConvexError("Not your visit.");
    active(visit);
    const owner = await ctx.db.get(visit.ownerId);
    if (!owner || !(await canVisit(ctx, me._id, owner))) throw new ConvexError("That friendship ended or the door closed.");
    if (visit.status === "announced") return null;
    // Close permission can be revoked while the media connection is being established.
    const mode = await mayWalkIn(ctx, me._id, owner) ? "walk_in" as const : "knock" as const;
    await ctx.db.patch(visit._id, { status: "announced", mode });
    await ring(ctx, visit.ownerId, me._id, visit.visitId, mode);
    return null;
  },
});
export const ringLeft = internalMutation({
  args: { door: v.string(), visitId: v.string() }, returns: v.null(),
  handler: async (ctx, args) => {
    validateVisitId(args.visitId);
    const me = await requireProfile(ctx), owner = await byHandle(ctx, args.door);
    const visit = await findVisit(ctx, args.visitId);
    if (visit) {
      if (visit.guestId !== me._id || visit.ownerId !== owner._id) throw new ConvexError("Not your visit.");
      await cancel(ctx, visit);
    } else {
      // A cancellation can beat a slow visit request. A tombstone forbids resurrection.
      if (!(await canVisit(ctx, me._id, owner))) return null;
      const id = await ctx.db.insert("visits", { visitId: args.visitId, ownerId: owner._id, guestId: me._id,
        mode: "knock", status: "canceled", expiresAt: Date.now() + EVENT_TTL_MS });
      await ctx.scheduler.runAfter(EVENT_TTL_MS, internal.doors.expireVisit, { id });
    }
    return null;
  },
});
export const deliverAdmit = internalMutation({
  args: { visitId: v.string(), guestId: v.id("profiles"), grant: grantValidator, automatically: v.optional(v.boolean()) }, returns: v.null(),
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx), visit = await findVisit(ctx, args.visitId);
    if (!visit || visit.ownerId !== me._id || visit.guestId !== args.guestId) throw new ConvexError("Not your visit.");
    active(visit);
    if (visit.status !== "announced") throw new ConvexError("They haven't arrived yet.");
    if (!(await canVisit(ctx, visit.guestId, me))) throw new ConvexError("That friendship ended or the door closed.");
    if (args.automatically && !(await mayWalkIn(ctx, visit.guestId, me))) throw new ConvexError("Walk-in permission was removed. Answer this knock yourself.");
    await ctx.db.patch(visit._id, { status: "admitted" });
    await ring(ctx, args.guestId, me._id, visit.visitId, "admitted", args.grant);
    return null;
  },
});
// Clear legacy nonfriend visits when the policy is saved. Open Door never grants
// friendship, including when an older build already created a visitor's seat.
export const cancelNonfriendVisits = internalMutation({
  args: {}, returns: v.null(),
  handler: async ctx => {
    const owner = await requireProfile(ctx);
    for (const visit of await pendingVisits(ctx, owner._id)) {
      if (!(await follows(ctx, visit.guestId, owner._id))) await cancel(ctx, visit);
    }
    return null;
  },
});
// Removing a friend tears down both pending doorstep previews immediately. The
// owner receives the same exact-visit departure signal as an explicit leave.
export const cancelFriendshipVisits = internalMutation({
  args: { profileId: v.id("profiles") }, returns: v.null(),
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx);
    for (const [ownerId, guestId] of [[me._id, args.profileId], [args.profileId, me._id]]) {
      if (await follows(ctx, guestId, ownerId)) continue;
      for (const visit of await pendingVisits(ctx, ownerId)) {
        if (visit.guestId === guestId) await cancel(ctx, visit);
      }
    }
    return null;
  },
});
export const expireVisit = internalMutation({
  args: { id: v.id("visits") }, returns: v.null(),
  handler: async (ctx, { id }) => {
    const visit = await ctx.db.get(id);
    if (!visit) return null;
    if (visit.status === "prepared" || visit.status === "announced") await cancel(ctx, visit);
    await ctx.db.delete(id);
    return null;
  },
});
export const sweep = internalMutation({ args: { eventId: v.id("doorEvents") }, returns: v.null(),
  handler: async (ctx, { eventId }) => { if (await ctx.db.get(eventId)) await ctx.db.delete(eventId); return null; } });

function validateVisitId(id: string) {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id)) throw new ConvexError("Update Doorbell to make this call.");
}
function active(visit: Doc<"visits">) {
  if (visit.expiresAt <= Date.now() || visit.status === "canceled" || visit.status === "admitted") throw new ConvexError("That visit ended.");
}
async function findVisit(ctx: QueryCtx | MutationCtx, visitId: string) {
  return ctx.db.query("visits").withIndex("by_visitId", q => q.eq("visitId", visitId)).unique();
}
async function byHandle(ctx: QueryCtx | MutationCtx, handle: string) {
  const p = await ctx.db.query("profiles").withIndex("by_handle", q => q.eq("handle", handle.toLowerCase())).unique();
  if (!p) throw new ConvexError("No such door.");
  return p;
}
async function cancel(ctx: MutationCtx, visit: Doc<"visits">) {
  if (visit.status === "canceled") return;
  await ctx.db.patch(visit._id, { status: "canceled" });
  // Remove a pending admission as well as the owner's arrival.
  const guestEvents = await ctx.db.query("doorEvents").withIndex("by_pair", q => q.eq("toProfileId", visit.guestId).eq("fromProfileId", visit.ownerId)).take(100);
  for (const e of guestEvents) if (e.visitId === visit.visitId) await ctx.db.delete(e._id);
  await ring(ctx, visit.ownerId, visit.guestId, visit.visitId, "left");
}
async function ring(ctx: MutationCtx, to: Id<"profiles">, from: Id<"profiles">, visitId: string,
  kind: Doc<"doorEvents">["kind"], grant?: { url: string; token: string; room: string }) {
  const stale = await ctx.db.query("doorEvents").withIndex("by_pair", q => q.eq("toProfileId", to).eq("fromProfileId", from)).take(100);
  for (const row of stale) if (row.visitId === visitId) await ctx.db.delete(row._id);
  const id = await ctx.db.insert("doorEvents", { toProfileId: to, fromProfileId: from, visitId, kind, grant });
  await ctx.scheduler.runAfter(EVENT_TTL_MS, internal.doors.sweep, { eventId: id });
}

// Every visit requires an accepted guest→owner friendship edge. Open Door only
// changes how a friend is admitted; it never bypasses friendship authorization.
async function canVisit(ctx: QueryCtx | MutationCtx, guestId: Id<"profiles">, owner: Doc<"profiles">) {
  return follows(ctx, guestId, owner._id);
}
async function mayWalkIn(ctx: QueryCtx | MutationCtx, guestId: Id<"profiles">, owner: Doc<"profiles">) {
  return await canVisit(ctx, guestId, owner)
    && (owner.openDoorPolicy === true || !!(await closeFriendEdge(ctx, owner._id, guestId)));
}

async function pendingVisits(ctx: MutationCtx, ownerId: Id<"profiles">) {
  const pending: Doc<"visits">[] = [];
  for (const status of ["prepared", "announced"] as const) {
    pending.push(...await ctx.db.query("visits")
      .withIndex("by_ownerId_and_status", q => q.eq("ownerId", ownerId).eq("status", status))
      .take(100));
  }
  return pending;
}
