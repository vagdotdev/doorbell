import { ConvexError, v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { apiKeys } from "./apiKeys.js";
import { requireProfile } from "./lib";

/// Create an API key for the signed-in user. Plaintext token is returned once.
export const create = mutation({
  args: { name: v.string() },
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx);
    const name = args.name.trim().slice(0, 80);
    if (name.length === 0) throw new ConvexError("Name the key.");
    const key = await apiKeys.create(ctx, { name, namespace: me._id });
    return { ...key, expiresAt: key.expiresAt ?? null };
  },
});

/// Keys owned by the signed-in account (via namespace = profile id).
export const list = query({
  args: {},
  handler: async (ctx) => {
    const me = await requireProfile(ctx);
    const page = await apiKeys.listKeys(ctx, {
      namespace: me._id,
      paginationOpts: { numItems: 20, cursor: null },
    });
    return page.page;
  },
});

/// Revoke one of your keys.
export const revoke = mutation({
  args: { keyId: v.string() },
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx);
    const key = await apiKeys.getKey(ctx, { keyId: args.keyId });
    if (!key.ok || key.namespace !== me._id) throw new ConvexError("That key is not yours.");
    return await apiKeys.invalidate(ctx, { keyId: args.keyId, reason: "revoked by owner" });
  },
});
