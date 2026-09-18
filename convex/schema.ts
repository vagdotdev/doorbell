import { authTables } from "@convex-dev/auth/server";
import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

// The graph from docs/how-it-works.md. There is no RLS here: every public function
// checks the caller first (see lib.ts). Nothing records presence. A knock is a row in
// doorEvents only for as long as it takes the owner's app to see it.
export default defineSchema({
  ...authTables,

  profiles: defineTable({
    userId: v.id("users"),
    handle: v.string(),
    displayName: v.string(),
    openDoorPolicy: v.optional(v.boolean()),
    avatarStorageId: v.optional(v.id("_storage")),
    /// Milliseconds since epoch. Rolling 14-day window; at most two renames.
    displayNameChangedAt: v.optional(v.array(v.number())),
  })
    .index("by_user", ["userId"])
    .index("by_handle", ["handle"])
    .searchIndex("search_name", { searchField: "displayName" }),

  // A request is one directed edge. Acceptance creates both accepted edges, so
  // friends can knock in either direction. Close-friend permission stays separate.
  follows: defineTable({
    followerId: v.id("profiles"),
    followeeId: v.id("profiles"),
    status: v.union(v.literal("pending"), v.literal("accepted")),
  })
    .index("by_follower", ["followerId"])
    .index("by_followee", ["followeeId"])
    .index("by_pair", ["followerId", "followeeId"]),

  // owner's list. Member may walk into owner's room. Members are never told.
  closeFriends: defineTable({
    ownerId: v.id("profiles"),
    memberId: v.id("profiles"),
  })
    .index("by_owner", ["ownerId"])
    .index("by_pair", ["ownerId", "memberId"]),

  avatarUploads: defineTable({ storageId: v.id("_storage"), ownerId: v.id("profiles") })
    .index("by_storageId", ["storageId"]),

  // Ephemeral call handoff, never online presence. Expired by scheduled mutation.
  visits: defineTable({
    visitId: v.string(),
    ownerId: v.id("profiles"),
    guestId: v.id("profiles"),
    mode: v.union(v.literal("knock"), v.literal("walk_in")),
    status: v.union(v.literal("prepared"), v.literal("announced"), v.literal("admitted"), v.literal("canceled")),
    expiresAt: v.number(),
  }).index("by_visitId", ["visitId"]).index("by_guestId", ["guestId"])
    .index("by_ownerId", ["ownerId"])
    .index("by_ownerId_and_status", ["ownerId", "status"]),

  // The knock signal. Written only by door actions, read only by `to`, deleted on
  // receipt or by the sweep. `admitted` carries the guest's seat; nothing else does.
  doorEvents: defineTable({
    visitId: v.optional(v.string()), // absent only on pre-upgrade events; never delivered
    toProfileId: v.id("profiles"),
    fromProfileId: v.id("profiles"),
    kind: v.union(
      v.literal("knock"),
      v.literal("walk_in"),
      v.literal("left"),
      v.literal("admitted"),
    ),
    grant: v.optional(
      v.object({ url: v.string(), token: v.string(), room: v.string() }),
    ),
  })
    .index("by_to", ["toProfileId"])
    .index("by_pair", ["toProfileId", "fromProfileId"]),
});
