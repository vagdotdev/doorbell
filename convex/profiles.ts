import { getAuthUserId } from "@convex-dev/auth/server";
import { ConvexError, v } from "convex/values";
import { mutation, query } from "./_generated/server";
import {
  HANDLE,
  currentProfile,
  profileValidator,
  publicProfile,
  requireProfile,
} from "./lib";

/// Where the account stands. The Mac app subscribes to this.
export const account = query({
  args: {},
  returns: v.object({
    state: v.union(v.literal("signedOut"), v.literal("needsHandle"), v.literal("ready")),
    me: v.union(profileValidator, v.null()),
    email: v.union(v.string(), v.null()),
  }),
  handler: async (ctx) => {
    const userId = await getAuthUserId(ctx);
    if (userId === null) return { state: "signedOut" as const, me: null, email: null };
    const user = await ctx.db.get(userId);
    const email = user?.email ?? null;
    const me = await currentProfile(ctx);
    if (me === null) return { state: "needsHandle" as const, me: null, email };
    return { state: "ready" as const, me: await publicProfile(ctx, me), email };
  },
});

/// Put a name on the door. Once per account; handles are unique and lowercase.
export const claimHandle = mutation({
  args: { handle: v.string(), displayName: v.string() },
  returns: profileValidator,
  handler: async (ctx, args) => {
    const userId = await getAuthUserId(ctx);
    if (userId === null) throw new ConvexError("Sign in first.");
    if ((await currentProfile(ctx)) !== null) throw new ConvexError("You already have a handle.");

    const handle = args.handle.trim().toLowerCase();
    if (!HANDLE.test(handle)) {
      throw new ConvexError("Handles are 3–20 characters: a–z, 0–9, underscore.");
    }
    const displayName = args.displayName.trim().slice(0, 60);
    if (displayName.length === 0) throw new ConvexError("Add a name.");

    const taken = await ctx.db
      .query("profiles")
      .withIndex("by_handle", (q) => q.eq("handle", handle))
      .unique();
    if (taken !== null) throw new ConvexError("That handle is taken.");

    const id = await ctx.db.insert("profiles", { userId, handle, displayName });
    const me = await ctx.db.get(id);
    if (me === null) throw new ConvexError("Could not save the profile.");
    return await publicProfile(ctx, me);
  },
});

/// Prefix match on handle, plus a name search. Never returns the caller. Only what a
/// search result needs.
export const search = query({
  args: { q: v.string() },
  returns: v.array(profileValidator),
  handler: async (ctx, args) => {
    const me = await currentProfile(ctx);
    if (me === null) return [];
    const raw = args.q.trim();
    if (raw.length < 2) return [];
    const prefix = raw.toLowerCase().replace(/^@/, "").replace(/[^a-z0-9_]/g, "");

    const seen = new Set<string>();
    const out: Awaited<ReturnType<typeof publicProfile>>[] = [];
    const add = async (p: (typeof byHandle)[number]) => {
      if (p._id === me._id || seen.has(p._id)) return;
      seen.add(p._id);
      out.push(await publicProfile(ctx, p));
    };

    const byHandle =
      prefix.length >= 2
        ? await ctx.db
            .query("profiles")
            .withIndex("by_handle", (q) => q.gte("handle", prefix).lt("handle", prefix + "\uffff"))
            .take(10)
        : [];
    for (const p of byHandle) await add(p);

    const byName = await ctx.db
      .query("profiles")
      .withSearchIndex("search_name", (q) => q.search("displayName", raw))
      .take(10);
    for (const p of byName) await add(p);

    return out.slice(0, 10);
  },
});

/// Change the name friends see. Handle stays put.
export const update = mutation({
  args: { displayName: v.string() },
  returns: profileValidator,
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx);
    const displayName = args.displayName.trim().slice(0, 60);
    if (displayName.length === 0) throw new ConvexError("Add a name.");
    await ctx.db.patch(me._id, { displayName });
    const next = await ctx.db.get(me._id);
    if (next === null) throw new ConvexError("Could not save the profile.");
    return await publicProfile(ctx, next);
  },
});

/// Short-lived URL the Mac app POSTs a JPEG/PNG to. Auth required.
export const generateUploadUrl = mutation({
  args: {},
  returns: v.string(),
  handler: async (ctx) => {
    await requireProfile(ctx);
    return await ctx.storage.generateUploadUrl();
  },
});

/// Point the profile at a photo already in Convex storage. Replaces any previous one.
export const setAvatar = mutation({
  args: { storageId: v.id("_storage") },
  returns: profileValidator,
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx);
    if ((await ctx.storage.getUrl(args.storageId)) === null) {
      throw new ConvexError("That photo didn't upload.");
    }
    const old = me.avatarStorageId;
    await ctx.db.patch(me._id, { avatarStorageId: args.storageId });
    if (old !== undefined) await ctx.storage.delete(old);
    const next = await ctx.db.get(me._id);
    if (next === null) throw new ConvexError("Could not save the profile.");
    return await publicProfile(ctx, next);
  },
});

/// Drop the photo. Friends see initials again.
export const clearAvatar = mutation({
  args: {},
  returns: profileValidator,
  handler: async (ctx) => {
    const me = await requireProfile(ctx);
    if (me.avatarStorageId !== undefined) {
      await ctx.storage.delete(me.avatarStorageId);
      await ctx.db.patch(me._id, { avatarStorageId: undefined });
    }
    const next = await ctx.db.get(me._id);
    if (next === null) throw new ConvexError("Could not save the profile.");
    return await publicProfile(ctx, next);
  },
});
