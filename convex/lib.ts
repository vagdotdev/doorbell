import { getAuthUserId } from "@convex-dev/auth/server";
import { ConvexError, v } from "convex/values";
import type { Doc, Id } from "./_generated/dataModel";
import type { MutationCtx, QueryCtx } from "./_generated/server";

export const HANDLE = /^[a-z0-9_]{3,20}$/;

/// What a search result or a hallway entry shows. Nothing else about a person leaves
/// the server.
export const profileValidator = v.object({
  id: v.id("profiles"),
  handle: v.string(),
  displayName: v.string(),
  avatarUrl: v.union(v.string(), v.null()),
});
export type PublicProfile = {
  id: Id<"profiles">;
  handle: string;
  displayName: string;
  avatarUrl: string | null;
};

export async function publicProfile(
  ctx: QueryCtx | MutationCtx,
  p: Doc<"profiles">,
): Promise<PublicProfile> {
  return {
    id: p._id,
    handle: p.handle,
    displayName: p.displayName,
    avatarUrl: p.avatarStorageId ? await ctx.storage.getUrl(p.avatarStorageId) : null,
  };
}

/// The caller's profile, or null when signed out / no handle yet.
export async function currentProfile(ctx: QueryCtx | MutationCtx): Promise<Doc<"profiles"> | null> {
  const userId = await getAuthUserId(ctx);
  if (userId === null) return null;
  return await ctx.db
    .query("profiles")
    .withIndex("by_user", (q) => q.eq("userId", userId))
    .unique();
}

/// The caller's profile, or a ConvexError the app can show.
export async function requireProfile(ctx: QueryCtx | MutationCtx): Promise<Doc<"profiles">> {
  const me = await currentProfile(ctx);
  if (me === null) throw new ConvexError("Sign in and pick a handle first.");
  return me;
}

export async function followEdge(
  ctx: QueryCtx | MutationCtx,
  followerId: Id<"profiles">,
  followeeId: Id<"profiles">,
): Promise<Doc<"follows"> | null> {
  return await ctx.db
    .query("follows")
    .withIndex("by_pair", (q) => q.eq("followerId", followerId).eq("followeeId", followeeId))
    .unique();
}

/// follower may knock on followee's door.
export async function follows(
  ctx: QueryCtx | MutationCtx,
  followerId: Id<"profiles">,
  followeeId: Id<"profiles">,
): Promise<boolean> {
  const edge = await followEdge(ctx, followerId, followeeId);
  return edge?.status === "accepted";
}

export async function closeFriendEdge(
  ctx: QueryCtx | MutationCtx,
  ownerId: Id<"profiles">,
  memberId: Id<"profiles">,
): Promise<Doc<"closeFriends"> | null> {
  return await ctx.db
    .query("closeFriends")
    .withIndex("by_pair", (q) => q.eq("ownerId", ownerId).eq("memberId", memberId))
    .unique();
}
