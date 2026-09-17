import { v } from "convex/values";
import { internalMutation } from "./_generated/server";

// Development only: scripts/seed-convex.sh signs three accounts up through
// `auth:signIn`, then calls this to give them handles and a small graph.
//
//   alice  follows bob (accepted, both ways)
//   bob    follows carol (accepted); on carol's close list
//   carol  does not know alice
//
// Internal — never callable from the app. Safe to rerun.
export const graph = internalMutation({
  args: {},
  returns: v.array(v.string()),
  handler: async (ctx) => {
    const people = [
      { email: "alice@test.local", handle: "alice", displayName: "Alice Rao" },
      { email: "bob@test.local", handle: "bob", displayName: "Bob Menon" },
      { email: "carol@test.local", handle: "carol", displayName: "Carol Iyer" },
    ];
    const ids: Record<string, string> = {};
    const done: string[] = [];
    for (const p of people) {
      const user = await ctx.db
        .query("users")
        .withIndex("email", (q) => q.eq("email", p.email))
        .first();
      if (user === null) {
        done.push(`${p.handle}: no account yet (sign up first)`);
        continue;
      }
      let profile = await ctx.db
        .query("profiles")
        .withIndex("by_user", (q) => q.eq("userId", user._id))
        .unique();
      if (profile === null) {
        const id = await ctx.db.insert("profiles", { userId: user._id, handle: p.handle, displayName: p.displayName });
        profile = await ctx.db.get(id);
      }
      if (profile !== null) {
        ids[p.handle] = profile._id;
        done.push(`${p.handle}: ${profile._id}`);
      }
    }

    const follow = async (a: string, b: string) => {
      if (!ids[a] || !ids[b]) return;
      const existing = await ctx.db
        .query("follows")
        .withIndex("by_pair", (q) =>
          q.eq("followerId", ids[a] as never).eq("followeeId", ids[b] as never),
        )
        .unique();
      if (existing === null) {
        await ctx.db.insert("follows", { followerId: ids[a] as never, followeeId: ids[b] as never, status: "accepted" });
      } else if (existing.status !== "accepted") {
        await ctx.db.patch(existing._id, { status: "accepted" });
      }
    };
    await follow("alice", "bob");
    await follow("bob", "alice");
    await follow("bob", "carol");
    if (ids.carol && ids.bob) {
      const close = await ctx.db
        .query("closeFriends")
        .withIndex("by_pair", (q) => q.eq("ownerId", ids.carol as never).eq("memberId", ids.bob as never))
        .unique();
      if (close === null) await ctx.db.insert("closeFriends", { ownerId: ids.carol as never, memberId: ids.bob as never });
    }
    return done;
  },
});
