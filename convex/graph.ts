import { ConvexError, v } from "convex/values";
import type { Id } from "./_generated/dataModel";
import { mutation, query, type MutationCtx } from "./_generated/server";
import { closeFriendEdge, followEdge, follows, profileValidator, publicProfile, requireProfile } from "./lib";

/// Everything the hallway shows: doors I can knock on, requests to me, and who I'm
/// waiting on. Reactive — the app subscribes and the list updates by itself.
export const hallway = query({
  args: {},
  returns: v.union(
    v.null(),
    v.object({
      me: profileValidator,
      doors: v.array(
        v.object({ profile: profileValidator, followsMe: v.boolean(), isCloseFriend: v.boolean() }),
      ),
      requests: v.array(profileValidator),
      outgoing: v.array(v.id("profiles")),
    }),
  ),
  handler: async (ctx) => {
    const me = await requireProfile(ctx).catch(() => null);
    if (me === null) return null;

    const following = await ctx.db
      .query("follows")
      .withIndex("by_follower", (q) => q.eq("followerId", me._id))
      .take(500);
    const followers = await ctx.db
      .query("follows")
      .withIndex("by_followee", (q) => q.eq("followeeId", me._id))
      .take(500);
    const close = await ctx.db
      .query("closeFriends")
      .withIndex("by_owner", (q) => q.eq("ownerId", me._id))
      .take(500);

    const followsMe = new Set(followers.filter((f) => f.status === "accepted").map((f) => f.followerId));
    const closeSet = new Set(close.map((c) => c.memberId));

    const doors = [];
    for (const f of following) {
      if (f.status !== "accepted") continue;
      const p = await ctx.db.get(f.followeeId);
      if (p === null) continue;
      doors.push({
        profile: await publicProfile(ctx, p),
        followsMe: followsMe.has(p._id),
        isCloseFriend: closeSet.has(p._id),
      });
    }
    const requests = [];
    for (const f of followers) {
      if (f.status !== "pending") continue;
      const p = await ctx.db.get(f.followerId);
      if (p !== null) requests.push(await publicProfile(ctx, p));
    }
    const outgoing = following.filter((f) => f.status === "pending").map((f) => f.followeeId);
    return { me: await publicProfile(ctx, me), doors, requests, outgoing };
  },
});

/// Send a friend request. Idempotent; only the recipient can accept it.
export const request = mutation({
  args: { profileId: v.id("profiles") },
  returns: v.null(),
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx);
    if (args.profileId === me._id) throw new ConvexError("That's you.");
    const them = await ctx.db.get(args.profileId);
    if (them === null) throw new ConvexError("No such person.");
    if ((await followEdge(ctx, me._id, args.profileId)) !== null) return null;
    await ctx.db.insert("follows", { followerId: me._id, followeeId: args.profileId, status: "pending" });
    return null;
  },
});

/// One acceptance grants knocking in both directions, atomically. Walk-in access
/// stays on each person's separate close-friends list.
export const accept = mutation({
  args: { profileId: v.id("profiles") },
  returns: v.null(),
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx);
    const edge = await followEdge(ctx, args.profileId, me._id);
    if (edge === null) throw new ConvexError("No request from them.");
    if (edge.status !== "accepted") await ctx.db.patch(edge._id, { status: "accepted" });
    const reverse = await followEdge(ctx, me._id, args.profileId);
    if (reverse === null) {
      await ctx.db.insert("follows", {
        followerId: me._id, followeeId: args.profileId, status: "accepted",
      });
    } else if (reverse.status !== "accepted") {
      await ctx.db.patch(reverse._id, { status: "accepted" });
    }
    return null;
  },
});

/// Decline a pending request. A stale decline must not undo a friendship.
export const ignore = mutation({
  args: { profileId: v.id("profiles") },
  returns: v.null(),
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx);
    const edge = await followEdge(ctx, args.profileId, me._id);
    if (edge?.status === "pending") await ctx.db.delete(edge._id);
    return null;
  },
});

/// Remove the friendship and both people's walk-in permissions. The API name is
/// retained for existing clients.
export const unfollow = mutation({
  args: { profileId: v.id("profiles") },
  returns: v.null(),
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx);
    const edge = await followEdge(ctx, me._id, args.profileId);
    if (edge !== null) await removeFollow(ctx, edge._id, me._id, args.profileId);
    const reverse = await followEdge(ctx, args.profileId, me._id);
    if (reverse !== null) await removeFollow(ctx, reverse._id, args.profileId, me._id);
    return null;
  },
});

/// My close friends list. Only I write it; they are never told. A member must already
/// be an accepted follower of mine.
export const setCloseFriend = mutation({
  args: { profileId: v.id("profiles"), on: v.boolean() },
  returns: v.null(),
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx);
    if (args.profileId === me._id) throw new ConvexError("That's you.");
    const existing = await closeFriendEdge(ctx, me._id, args.profileId);
    if (args.on) {
      if (!(await follows(ctx, args.profileId, me._id))) {
        throw new ConvexError("They need to follow you first.");
      }
      if (existing === null) await ctx.db.insert("closeFriends", { ownerId: me._id, memberId: args.profileId });
    } else if (existing !== null) {
      await ctx.db.delete(existing._id);
    }
    return null;
  },
});

/// Removing follower→followee also removes the close-friend row followee keeps for
/// follower (the SQL trigger, restated).
async function removeFollow(
  ctx: MutationCtx,
  edgeId: Id<"follows">,
  followerId: Id<"profiles">,
  followeeId: Id<"profiles">,
) {
  await ctx.db.delete(edgeId);
  const close = await closeFriendEdge(ctx, followeeId, followerId);
  if (close !== null) await ctx.db.delete(close._id);
}
