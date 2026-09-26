import { v } from "convex/values";
import { internalMutation } from "./_generated/server";

// The analytics ledger behind /admin. LiveKit Cloud posts signed webhooks to
// /livekit/webhook (convex/http.ts), which forwards join/leave/finish events
// here. Room names encode the owner — `door:{handle}:{uuid}` for calls,
// `doorstep:{handle}:{visitId}` for knocks — and participant identity is the
// handle, so no Mac app change is needed. Anything else is ignored.

const ROOM = /^(door|doorstep):([a-z0-9_]+):/;

function isPreview(metadata: string | undefined): boolean {
  try { return JSON.parse(metadata ?? "{}").doorbellRole === "doorstep-preview"; }
  catch { return false; }
}

export const record = internalMutation({
  args: {
    event: v.union(
      v.literal("participant_joined"),
      v.literal("participant_left"),
      v.literal("room_finished"),
    ),
    roomName: v.string(),
    roomSid: v.string(),
    identity: v.optional(v.string()),
    metadata: v.optional(v.string()),
    /// Milliseconds since epoch, from the webhook's createdAt.
    at: v.number(),
  },
  returns: v.null(),
  handler: async (ctx, args) => {
    const match = ROOM.exec(args.roomName);
    if (!match) return null;
    const kind = match[1] as "door" | "doorstep";
    const ownerHandle = match[2]!;

    if (args.event === "room_finished") {
      const rows = await ctx.db
        .query("callSessions")
        .withIndex("by_room_and_identity", (q) => q.eq("roomName", args.roomName))
        .take(100);
      for (const row of rows) {
        if (row.leftAt === undefined) await ctx.db.patch(row._id, { leftAt: args.at });
      }
      return null;
    }

    if (!args.identity) return null;
    const mine = await ctx.db
      .query("callSessions")
      .withIndex("by_room_and_identity", (q) =>
        q.eq("roomName", args.roomName).eq("identity", args.identity!))
      .take(100);

    if (args.event === "participant_joined") {
      // LiveKit retries deliveries; the same join must not count twice.
      if (mine.some((row) => row.joinedAt === args.at)) return null;
      await ctx.db.insert("callSessions", {
        roomName: args.roomName,
        roomSid: args.roomSid,
        kind,
        ownerHandle,
        identity: args.identity,
        preview: isPreview(args.metadata),
        joinedAt: args.at,
      });
      return null;
    }

    // participant_left: close the oldest still-open session for this seat.
    const open = mine
      .filter((row) => row.leftAt === undefined)
      .sort((a, b) => a.joinedAt - b.joinedAt)[0];
    if (open) await ctx.db.patch(open._id, { leftAt: args.at });
    return null;
  },
});
