import { ConvexError, v } from "convex/values";
import { internal } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import { internalMutation, mutation, type MutationCtx, type QueryCtx } from "./_generated/server";
import { requireProfile } from "./lib";

export const STATUS_TTL_MS = 6 * 60 * 60 * 1000;
/// The app keeps statuses to 40 characters; this only stops abuse of the API.
const MAX_CODE_POINTS = 160;

export const statusValidator = v.object({ text: v.string(), expiresAt: v.number() });

/// "in a meeting till 4". Mine alone to write; my friends see it over my door.
export const set = mutation({
  args: { text: v.string() }, returns: statusValidator,
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx);
    const text = args.text.replace(/\s+/g, " ").trim();
    if (text.length === 0) throw new ConvexError("Write something first.");
    if ([...text].length > MAX_CODE_POINTS) throw new ConvexError("Keep it short.");
    const expiresAt = Date.now() + STATUS_TTL_MS;
    const existing = await mine(ctx, me._id);
    if (existing) await ctx.db.patch(existing._id, { text, expiresAt });
    else await ctx.db.insert("doorStatus", { profileId: me._id, text, expiresAt });
    await ctx.scheduler.runAfter(STATUS_TTL_MS, internal.status.expire, { profileId: me._id, expiresAt });
    return { text, expiresAt };
  },
});

export const clear = mutation({
  args: {}, returns: v.null(),
  handler: async (ctx) => {
    const me = await requireProfile(ctx);
    const existing = await mine(ctx, me._id);
    if (existing) await ctx.db.delete(existing._id);
    return null;
  },
});

export const expire = internalMutation({
  args: { profileId: v.id("profiles"), expiresAt: v.number() }, returns: v.null(),
  handler: async (ctx, args) => {
    const row = await mine(ctx, args.profileId);
    // A newer status carries its own expiry.
    if (row && row.expiresAt === args.expiresAt) await ctx.db.delete(row._id);
    return null;
  },
});

export async function statusOf(ctx: QueryCtx | MutationCtx, profileId: Id<"profiles">) {
  const row = await mine(ctx, profileId);
  return row ? { text: row.text, expiresAt: row.expiresAt } : null;
}

async function mine(ctx: QueryCtx | MutationCtx, profileId: Id<"profiles">) {
  return ctx.db.query("doorStatus").withIndex("by_profile", q => q.eq("profileId", profileId)).unique();
}
