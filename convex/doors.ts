import { ConvexError, v } from "convex/values";
import { internal } from "./_generated/api";
import type { Doc, Id } from "./_generated/dataModel";
import {
  internalMutation,
  internalQuery,
  mutation,
  query,
  type MutationCtx,
  type QueryCtx,
} from "./_generated/server";
import { closeFriendEdge, follows, profileValidator, publicProfile, requireProfile } from "./lib";

/// How long an unread event may sit in the table before the sweep removes it. The
/// knocker's app gives up at 30 s; this is the backstop, not the timer.
export const EVENT_TTL_MS = 90_000;

const grantValidator = v.object({ url: v.string(), token: v.string(), room: v.string() });
const kindValidator = v.union(
  v.literal("knock"),
  v.literal("walk_in"),
  v.literal("left"),
  v.literal("admitted"),
);

/// What is happening at my door right now. The app subscribes, acts on each new row,
/// then calls `ack`. Only rows addressed to me are ever returned.
export const events = query({
  args: {},
  returns: v.array(
    v.object({
      id: v.id("doorEvents"),
      kind: kindValidator,
      from: profileValidator,
      grant: v.union(grantValidator, v.null()),
    }),
  ),
  handler: async (ctx) => {
    const me = await requireProfile(ctx).catch(() => null);
    if (me === null) return [];
    const rows = await ctx.db
      .query("doorEvents")
      .withIndex("by_to", (q) => q.eq("toProfileId", me._id))
      .order("asc")
      .take(50);
    const out = [];
    for (const row of rows) {
      const from = await ctx.db.get(row.fromProfileId);
      if (from === null) continue;
      out.push({ id: row._id, kind: row.kind, from: await publicProfile(ctx, from), grant: row.grant ?? null });
    }
    return out;
  },
});

/// Seen it. Only the addressee may delete.
export const ack = mutation({
  args: { eventId: v.id("doorEvents") },
  returns: v.null(),
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx);
    const row = await ctx.db.get(args.eventId);
    if (row !== null && row.toProfileId === me._id) await ctx.db.delete(args.eventId);
    return null;
  },
});

// MARK: - For the door actions (doorActions.ts). Internal: the client never calls these.

const who = v.object({ id: v.id("profiles"), handle: v.string(), displayName: v.string() });
const slim = (p: Doc<"profiles">) => ({ id: p._id, handle: p.handle, displayName: p.displayName });

/// Me, for minting my own seat.
export const whoAmI = internalQuery({
  args: {},
  returns: who,
  handler: async (ctx) => slim(await requireProfile(ctx)),
});

/// Decide knock vs walk-in from the owner's list, and ring the door. Returns what the
/// action needs to mint the seat.
export const decideVisit = internalMutation({
  args: { door: v.string() },
  returns: v.object({ mode: v.union(v.literal("knock"), v.literal("walk_in")), me: who, owner: who }),
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx);
    const owner = await byHandle(ctx, args.door);
    if (owner._id === me._id) throw new ConvexError("That's your own door.");

    const close = await closeFriendEdge(ctx, owner._id, me._id);
    if (close !== null) {
      await ring(ctx, owner._id, me._id, "walk_in");
      return { mode: "walk_in" as const, me: slim(me), owner: slim(owner) };
    }
    if (!(await follows(ctx, me._id, owner._id))) throw new ConvexError("You don't follow this door.");
    await ring(ctx, owner._id, me._id, "knock");
    return { mode: "knock" as const, me: slim(me), owner: slim(owner) };
  },
});

/// Stepped away from their door.
export const ringLeft = internalMutation({
  args: { door: v.string() },
  returns: v.null(),
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx);
    const owner = await byHandle(ctx, args.door);
    if (!(await follows(ctx, me._id, owner._id))) throw new ConvexError("You don't follow this door.");
    await ring(ctx, owner._id, me._id, "left");
    return null;
  },
});

/// The owner lets a knocker in: check they may, and name the guest.
export const prepareAdmit = internalQuery({
  args: { guest: v.string() },
  returns: v.object({ me: who, guest: who }),
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx);
    const guest = await byHandle(ctx, args.guest);
    if (guest._id === me._id) throw new ConvexError("That's you.");
    if (!(await follows(ctx, guest._id, me._id))) throw new ConvexError("They don't follow you.");
    return { me: slim(me), guest: slim(guest) };
  },
});

/// Hand the guest their seat, on their own door. Only ever written by `admit`.
export const deliverAdmit = internalMutation({
  args: { guestId: v.id("profiles"), grant: grantValidator },
  returns: v.null(),
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx);
    if (!(await follows(ctx, args.guestId, me._id))) throw new ConvexError("They don't follow you.");
    await ring(ctx, args.guestId, me._id, "admitted", args.grant);
    return null;
  },
});

/// Backstop: an event nobody read.
export const sweep = internalMutation({
  args: { eventId: v.id("doorEvents") },
  returns: v.null(),
  handler: async (ctx, args) => {
    if ((await ctx.db.get(args.eventId)) !== null) await ctx.db.delete(args.eventId);
    return null;
  },
});

// MARK: - helpers

async function byHandle(ctx: QueryCtx | MutationCtx, handle: string) {
  const p = await ctx.db
    .query("profiles")
    .withIndex("by_handle", (q) => q.eq("handle", handle.toLowerCase()))
    .unique();
  if (p === null) throw new ConvexError("No such door.");
  return p;
}

/// One live event per (to, from): a new knock replaces the old one, `left` replaces the
/// knock it ends. Every row gets a sweep so nothing lingers.
async function ring(
  ctx: MutationCtx,
  to: Id<"profiles">,
  from: Id<"profiles">,
  kind: Doc<"doorEvents">["kind"],
  grant?: { url: string; token: string; room: string },
) {
  const stale = await ctx.db
    .query("doorEvents")
    .withIndex("by_pair", (q) => q.eq("toProfileId", to).eq("fromProfileId", from))
    .take(20);
  for (const row of stale) await ctx.db.delete(row._id);
  const id = await ctx.db.insert("doorEvents", { toProfileId: to, fromProfileId: from, kind, grant });
  await ctx.scheduler.runAfter(EVENT_TTL_MS, internal.doors.sweep, { eventId: id });
}
