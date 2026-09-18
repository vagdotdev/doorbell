import { ConvexError, v } from "convex/values";
import { AccessToken, RoomServiceClient, TrackSource } from "livekit-server-sdk";
import { internal } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import { action } from "./_generated/server";

const seatValidator = v.object({ mode: v.union(v.literal("knock"), v.literal("walk_in"), v.literal("answer")),
  url: v.string(), token: v.string(), room: v.string() });
type Who = { id: Id<"profiles">; handle: string; displayName: string };
type Seat = { mode: "knock" | "walk_in" | "answer"; url: string; token: string; room: string };
type Decision = { mode: "knock" | "walk_in"; me: Who; owner: Who };
type Visit = { me: Who; guest: Who; owner: Who };
const step = (owner: Who, visitId: string) => `doorstep:${owner.handle}:${visitId}`;
function livekit() {
  const raw = process.env.LIVEKIT_URL, key = process.env.LIVEKIT_API_KEY, secret = process.env.LIVEKIT_API_SECRET;
  if (!raw || !key || !secret) throw new ConvexError("LiveKit is not configured on this deployment.");
  const publicUrl = process.env.LIVEKIT_PUBLIC_URL ?? raw;
  const url = raw.replace(/^wss:\/\//, "https://").replace(/^ws:\/\//, "http://");
  return { url, publicUrl, key, secret };
}
async function seat(who: Who, room: string, via: string, subscribe: boolean, preview = false, data = true): Promise<string> {
  const lk = livekit();
  const at = new AccessToken(lk.key, lk.secret, { identity: who.handle, name: who.displayName || who.handle,
    ttl: "60s", metadata: JSON.stringify({ handle: who.handle, display_name: who.displayName, via, ...(preview ? { doorbellRole: "doorstep-preview" } : {}) }) });
  at.addGrant({ room, roomJoin: true, canPublish: true, canPublishData: data && subscribe && !preview,
    ...(preview ? { canPublishSources: [TrackSource.MICROPHONE] } : {}),
    canSubscribe: subscribe, hidden: false });
  return at.toJwt();
}
function isPreview(metadata: string | undefined): boolean {
  try { return JSON.parse(metadata ?? "{}").doorbellRole === "doorstep-preview"; }
  catch { return false; }
}
async function requireSeat(room: string, identity: string) {
  const lk = livekit();
  const people = await new RoomServiceClient(lk.url, lk.key, lk.secret).listParticipants(room);
  if (!people.some(p => p.identity === identity && !p.permission?.hidden && !isPreview(p.metadata))) throw new ConvexError("They are no longer in that room.");
}
export const visit = action({
  args: { door: v.string(), visitId: v.string() }, returns: seatValidator,
  handler: async (ctx, args): Promise<Seat> => {
    const lk = livekit();
    const d: Decision = await ctx.runMutation(internal.doors.decideVisit, args);
    const room = step(d.owner, args.visitId);
    // Close friends also wait for the owner app. Quiet Door may refuse automatic entry.
    return { mode: d.mode, url: lk.publicUrl, room, token: await seat(d.me, room, d.owner.handle, true, false, false) };
  },
});
export const announce = action({
  args: { door: v.string(), visitId: v.string() }, returns: v.null(),
  handler: async (ctx, args): Promise<null> => {
    const d: Visit = await ctx.runQuery(internal.doors.inspectVisit, { visitId: args.visitId, side: "guest" });
    if (d.owner.handle !== args.door) throw new ConvexError("Not your visit.");
    await requireSeat(step(d.owner, args.visitId), d.guest.handle);
    await ctx.runMutation(internal.doors.announce, { visitId: args.visitId });
    return null;
  },
});
export const leave = action({ args: { door: v.string(), visitId: v.string() }, returns: v.null(),
  handler: async (ctx, args): Promise<null> => { await ctx.runMutation(internal.doors.ringLeft, args); return null; } });
// The legacy `hidden` argument means camera-private doorstep preview. LiveKit
// hidden participants cannot advertise audio tracks, so this seat is visible to
// its one visitor, with server-enforced microphone-only publication.
export const answer = action({
  args: { hidden: v.boolean(), visitId: v.optional(v.string()) }, returns: seatValidator,
  handler: async (ctx, args): Promise<Seat> => {
    const lk = livekit();
    const me: Who = await ctx.runQuery(internal.doors.whoAmI, {});
    let room: string;
    if (args.hidden) {
      if (!args.visitId) throw new ConvexError("Choose an active visitor.");
      const d: Visit = await ctx.runQuery(internal.doors.inspectVisit, { visitId: args.visitId, side: "owner" });
      room = step(me, args.visitId);
      await requireSeat(room, d.guest.handle);
      // A policy or friendship can change while LiveKit answers.
      await ctx.runQuery(internal.doors.inspectVisit, { visitId: args.visitId, side: "owner" });
    } else {
      // Each conversation gets a fresh room: yesterday's guest token cannot enter it.
      room = `door:${me.handle}:${crypto.randomUUID()}`;
    }
    return { mode: "answer", url: lk.publicUrl, room, token: await seat(me, room, me.handle, true, args.hidden) };
  },
});
export const admit = action({
  args: { guest: v.string(), visitId: v.string(), room: v.string(), automatically: v.optional(v.boolean()) }, returns: v.null(),
  handler: async (ctx, args): Promise<null> => {
    const lk = livekit();
    const d: Visit = await ctx.runQuery(internal.doors.inspectVisit, { visitId: args.visitId, side: "owner" });
    if (d.guest.handle !== args.guest) throw new ConvexError("Not your visitor.");
    if (!/^door:[a-z0-9_]+:[0-9a-f-]{36}$/.test(args.room)) throw new ConvexError("Not a room. Update Doorbell.");
    // Check the owner even for their own room, and reject hidden seats as vouchers.
    await requireSeat(args.room, d.me.handle);
    await requireSeat(step(d.owner, args.visitId), d.guest.handle);
    const token = await seat(d.guest, args.room, d.me.handle, true);
    // Rechecks friendship, cancellation, expiry and exact visit after the network calls.
    await ctx.runMutation(internal.doors.deliverAdmit, { visitId: args.visitId, guestId: d.guest.id, automatically: args.automatically ?? false,
      grant: { url: lk.publicUrl, token, room: args.room } });
    return null;
  },
});
