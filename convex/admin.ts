import { internalMutation } from "./_generated/server";

// Reset the deployment to zero users. Internal: only the CLI or dashboard can run it.
//   npx convex run --prod admin:wipeAll
export const wipeAll = internalMutation({
  args: {},
  handler: async (ctx) => {
    const tables = [
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
