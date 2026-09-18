import { getAuthUserId } from "@convex-dev/auth/server";
import { ConvexError, v, type Infer } from "convex/values";
import { action, internalMutation, mutation, query, type MutationCtx } from "./_generated/server";
import {
  HANDLE,
  NAME_CHANGE_LIMIT,
  currentProfile,
  nameChangeQuota,
  profileValidator,
  publicProfile,
  recentNameChanges,
  requireProfile,
} from "./lib";

import { internal } from "./_generated/api";
import type { Doc } from "./_generated/dataModel";

const nameQuotaValidator = v.object({
  remaining: v.number(),
  resetsAt: v.union(v.number(), v.null()),
});

/// Where the account stands. The Mac app subscribes to this.
export const account = query({
  args: {},
  returns: v.object({
    state: v.union(v.literal("signedOut"), v.literal("needsHandle"), v.literal("ready")),
    me: v.union(profileValidator, v.null()),
    email: v.union(v.string(), v.null()),
    nameQuota: nameQuotaValidator,
  }),
  handler: async (ctx) => {
    const userId = await getAuthUserId(ctx);
    if (userId === null) {
      return {
        state: "signedOut" as const,
        me: null,
        email: null,
        nameQuota: { remaining: NAME_CHANGE_LIMIT, resetsAt: null },
      };
    }
    const user = await ctx.db.get(userId);
    const email = user?.email ?? null;
    const me = await currentProfile(ctx);
    if (me === null) {
      return {
        state: "needsHandle" as const,
        me: null,
        email,
        nameQuota: { remaining: NAME_CHANGE_LIMIT, resetsAt: null },
      };
    }
    return {
      state: "ready" as const,
      me: await publicProfile(ctx, me),
      email,
      nameQuota: nameChangeQuota(me.displayNameChangedAt),
    };
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

/// Change the name friends see. Handle stays put. Two changes per rolling 14 days.
export const update = mutation({
  args: { displayName: v.string() },
  returns: profileValidator,
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx);
    const displayName = args.displayName.trim().slice(0, 60);
    if (displayName.length === 0) throw new ConvexError("Add a name.");
    if (displayName === me.displayName) {
      return await publicProfile(ctx, me);
    }
    const recent = recentNameChanges(me.displayNameChangedAt);
    if (recent.length >= NAME_CHANGE_LIMIT) {
      throw new ConvexError("You can change your name twice every 14 days.");
    }
    await ctx.db.patch(me._id, {
      displayName,
      displayNameChangedAt: [...recent, Date.now()],
    });
    const next = await ctx.db.get(me._id);
    if (next === null) throw new ConvexError("Could not save the profile.");
    return await publicProfile(ctx, next);
  },
});

// Upload and commit under the same authenticated caller. Clients cannot claim an
// arbitrary storage ID (including one copied from somebody else's avatar URL).
export const uploadAvatar = action({
  args: { bytes: v.bytes(), contentType: v.string() }, returns: profileValidator,
  handler: async (ctx, args): Promise<Infer<typeof profileValidator>> => {
    await ctx.runQuery(internal.doors.whoAmI, {});
    const bytes = new Uint8Array(args.bytes);
    const jpeg = bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
    const png = [137,80,78,71,13,10,26,10].every((n, i) => bytes[i] === n);
    if (bytes.length > 512 * 1024 || !(args.contentType === "image/jpeg" && jpeg || args.contentType === "image/png" && png)) {
      throw new ConvexError("Choose a JPEG or PNG smaller than 512 KB.");
    }
    const storageId = await ctx.storage.store(new Blob([args.bytes], { type: args.contentType }));
    return ctx.runMutation(internal.profiles.commitAvatar, { storageId });
  },
});
export const commitAvatar = internalMutation({
  args: { storageId: v.id("_storage") }, returns: profileValidator,
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx);
    await ctx.db.insert("avatarUploads", { storageId: args.storageId, ownerId: me._id });
    await removeOwnedAvatar(ctx, me);
    await ctx.db.patch(me._id, { avatarStorageId: args.storageId });
    return publicProfile(ctx, { ...me, avatarStorageId: args.storageId });
  },
});
// Old versions receive an explicit upgrade error rather than a dangerous upload URL.
export const generateUploadUrl = mutation({ args: {}, returns: v.string(), handler: async ctx => {
  await requireProfile(ctx);
  throw new ConvexError("Update Doorbell to change your photo.");
} });
export const setAvatar = mutation({
  args: { storageId: v.id("_storage") }, returns: profileValidator,
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx);
    const owned = await ctx.db.query("avatarUploads").withIndex("by_storageId", q => q.eq("storageId", args.storageId)).unique();
    if (!owned || owned.ownerId !== me._id) throw new ConvexError("That photo is not yours. Update Doorbell and upload again.");
    if (me.avatarStorageId === args.storageId) return publicProfile(ctx, me);
    // A formerly replaced image must not be resurrected.
    throw new ConvexError("Upload your photo again.");
  },
});
async function removeOwnedAvatar(ctx: MutationCtx, me: Doc<"profiles">) {
  if (!me.avatarStorageId) return;
  const owned = await ctx.db.query("avatarUploads").withIndex("by_storageId", q => q.eq("storageId", me.avatarStorageId!)).unique();
  // Legacy files have no ownership proof. Clear the pointer without deleting them.
  if (owned?.ownerId === me._id) {
    await ctx.storage.delete(owned.storageId);
    await ctx.db.delete(owned._id);
  }
}

/// Drop the photo. Friends see initials again.
export const clearAvatar = mutation({
  args: {},
  returns: profileValidator,
  handler: async (ctx) => {
    const me = await requireProfile(ctx);
    if (me.avatarStorageId !== undefined) {
      await removeOwnedAvatar(ctx, me);
      await ctx.db.patch(me._id, { avatarStorageId: undefined });
    }
    const next = await ctx.db.get(me._id);
    if (next === null) throw new ConvexError("Could not save the profile.");
    return await publicProfile(ctx, next);
  },
});

/// Only the caller can open their own door. Omitted legacy field means closed.
export const setOpenDoorPolicy = mutation({
  args: { enabled: v.boolean() }, returns: profileValidator,
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx);
    await ctx.db.patch(me._id, { openDoorPolicy: args.enabled });
    await ctx.runMutation(internal.doors.cancelNonfriendVisits, {});
    return publicProfile(ctx, { ...me, openDoorPolicy: args.enabled });
  },
});
