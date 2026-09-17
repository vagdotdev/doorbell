import { ConvexError, v } from "convex/values";
import { AccessToken, RoomServiceClient } from "livekit-server-sdk";
import { internal } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import { action } from "./_generated/server";

// Mints LiveKit seats according to the graph, and rings doors. The LiveKit API secret
// lives in this deployment's env and nowhere else.
//
// Two rooms per person. `door:{handle}` is their room. `doorstep:{handle}` is the step
// outside it: a knocker waits there (publish only, sees nothing), and the owner peeks
// from there (hidden). Nobody gets into a room without the owner's `admit`, which mints
// the guest's seat and delivers it on the guest's own door.

const seatValidator = v.object({
  mode: v.union(v.literal("knock"), v.literal("walk_in"), v.literal("answer")),
  url: v.string(),
  token: v.string(),
  room: v.string(),
});

type Who = { handle: string; displayName: string };
type Seat = { mode: "knock" | "walk_in" | "answer"; url: string; token: string; room: string };
// Explicit result types: an action that calls `internal.*` would otherwise infer
// itself through the api type.
type Decision = { mode: "knock" | "walk_in"; me: Who; owner: Who };
type Admission = { me: Who; guest: Who & { id: Id<"profiles"> } };

function livekit() {
  const url = process.env.LIVEKIT_URL;
  const key = process.env.LIVEKIT_API_KEY;
  const secret = process.env.LIVEKIT_API_SECRET;
  if (!url || !key || !secret) throw new ConvexError("LiveKit is not configured on this deployment.");
  return { url, publicUrl: process.env.LIVEKIT_PUBLIC_URL ?? url, key, secret };
}

async function seat(
  who: Who,
  room: string,
  via: string,
  grant: { canSubscribe: boolean; hidden?: boolean },
): Promise<string> {
  const lk = livekit();
  const at = new AccessToken(lk.key, lk.secret, {
    identity: who.handle,
    name: who.displayName || who.handle,
    ttl: "10m",
    metadata: JSON.stringify({ handle: who.handle, display_name: who.displayName, via }),
  });
  at.addGrant({
    room,
    roomJoin: true,
    canPublish: true,
    canPublishData: grant.canSubscribe, // chat only once you're properly in the room
    canSubscribe: grant.canSubscribe,
    hidden: grant.hidden ?? false,
  });
  return await at.toJwt();
}

/// Go to someone's door. Close friend → walk in. Accepted follower → knock from the
/// doorstep. Anyone else → refused. Rings the door either way.
export const visit = action({
  args: { door: v.string() },
  returns: seatValidator,
  handler: async (ctx, args): Promise<Seat> => {
    const lk = livekit(); // before the ring: a misconfigured server must not leave a ghost knock
    const d: Decision = await ctx.runMutation(internal.doors.decideVisit, { door: args.door });
    if (d.mode === "walk_in") {
      const room = `door:${d.owner.handle}`;
      return { mode: "walk_in" as const, url: lk.publicUrl, room, token: await seat(d.me, room, d.owner.handle, { canSubscribe: true }) };
    }
    const room = `doorstep:${d.owner.handle}`;
    return { mode: "knock" as const, url: lk.publicUrl, room, token: await seat(d.me, room, d.owner.handle, { canSubscribe: false }) };
  },
});

/// Step away from their door.
export const leave = action({
  args: { door: v.string() },
  returns: v.null(),
  handler: async (ctx, args): Promise<null> => {
    await ctx.runMutation(internal.doors.ringLeft, { door: args.door });
    return null;
  },
});

/// My own seat. Hidden: peek from the doorstep. Otherwise: host my own room.
export const answer = action({
  args: { hidden: v.boolean() },
  returns: seatValidator,
  handler: async (ctx, args): Promise<Seat> => {
    const lk = livekit();
    const me: Who = await ctx.runQuery(internal.doors.whoAmI, {});
    const room = args.hidden ? `doorstep:${me.handle}` : `door:${me.handle}`;
    return {
      mode: "answer" as const,
      url: lk.publicUrl,
      room,
      token: await seat(me, room, me.handle, { canSubscribe: true, hidden: args.hidden }),
    };
  },
});

/// Let a knocker in — to my own room, or to a room I'm a visible guest in right now.
/// Their seat goes to their door as `admitted`; I never see their token.
export const admit = action({
  args: { guest: v.string(), room: v.optional(v.string()) },
  returns: v.null(),
  handler: async (ctx, args): Promise<null> => {
    const lk = livekit();
    const { me, guest }: Admission = await ctx.runQuery(internal.doors.prepareAdmit, { guest: args.guest });
    const mine = `door:${me.handle}`;
    const into = args.room ?? mine;
    if (into !== mine) {
      if (!into.startsWith("door:")) throw new ConvexError("Not a room.");
      const svc = new RoomServiceClient(lk.url, lk.key, lk.secret);
      const participants = await svc.listParticipants(into).catch(() => []);
      if (!participants.some((p) => p.identity === me.handle)) {
        throw new ConvexError("You're not in that room.");
      }
    }
    const token = await seat(guest, into, me.handle, { canSubscribe: true });
    await ctx.runMutation(internal.doors.deliverAdmit, {
      guestId: guest.id,
      grant: { url: lk.publicUrl, token, room: into },
    });
    return null;
  },
});
