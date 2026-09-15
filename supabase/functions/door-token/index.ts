import { createClient } from "npm:@supabase/supabase-js@2";
import { AccessToken, RoomServiceClient } from "npm:livekit-server-sdk@2";
import { createHandler, type Profile } from "./handler.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const livekitURL = Deno.env.get("LIVEKIT_URL")!;
const apiKey = Deno.env.get("LIVEKIT_API_KEY")!;
const secret = Deno.env.get("LIVEKIT_API_SECRET")!;
const admin = createClient(url, service);
const rooms = new RoomServiceClient(livekitURL, apiKey, secret);

Deno.serve(createHandler({
  url: Deno.env.get("LIVEKIT_PUBLIC_URL") ?? livekitURL,
  async user(authorization) {
    const client = createClient(url, anon, { global: { headers: { Authorization: authorization } } });
    const { data, error } = await client.auth.getUser();
    return error ? null : data.user?.id ?? null;
  },
  async profile(column, value) {
    const { data, error } = await admin.from("profiles").select("id, handle, display_name").eq(column, value).maybeSingle<Profile>();
    if (error) throw error;
    return data;
  },
  async follows(follower, owner) {
    const { data, error } = await admin.from("follows").select("status")
      .eq("follower_id", follower).eq("followee_id", owner).eq("status", "accepted").maybeSingle();
    if (error) throw error;
    return !!data;
  },
  async close(follower, owner) {
    const { data, error } = await admin.from("close_friends").select("member_id")
      .eq("member_id", follower).eq("owner_id", owner).maybeSingle();
    if (error) throw error;
    return !!data;
  },
  async allow(user) {
    const { data, error } = await admin.rpc("consume_door_request", { caller: user });
    if (error) throw error;
    return data === true;
  },
  async participants(room) {
    // A missing/failed room lookup fails closed; never assume presence.
    try { return (await rooms.listParticipants(room)).map(p => ({ identity: p.identity, hidden: p.permission?.hidden })); }
    catch { return []; }
  },
  async ensureRoom(name) { await rooms.createRoom({ name, maxParticipants: 5, emptyTimeout: 60, departureTimeout: 20 }); },
  async ring(door, event, payload) {
    const response = await fetch(`${url}/realtime/v1/api/broadcast`, {
      method: "POST", headers: { apikey: service, Authorization: `Bearer ${service}`, "content-type": "application/json" },
      body: JSON.stringify({ messages: [{ topic: `door:${door}`, event, private: true, payload }] }),
    });
    if (!response.ok) throw new Error("Broadcast failed");
  },
  async seat(who, room, via, visit, grant) {
    const token = new AccessToken(apiKey, secret, {
      identity: who.handle, name: who.display_name || who.handle, ttl: "45s",
      metadata: JSON.stringify({ handle: who.handle, display_name: who.display_name, via, visit }),
    });
    token.addGrant({ room, roomJoin: true, canPublish: grant.publish, canSubscribe: grant.subscribe,
      canPublishData: grant.publish && grant.subscribe, hidden: grant.hidden, canUpdateOwnMetadata: false });
    return await token.toJwt();
  },
  async revoke(owner, follower) {
    const { error } = await admin.from("follows").delete().eq("follower_id", follower.id).eq("followee_id", owner.id);
    if (error) throw error;
    const all = await rooms.listRooms();
    for (const room of all.filter(r => r.name === `door:${owner.handle}` || r.name.startsWith(`doorstep:${owner.id}:`))) {
      const present = await rooms.listParticipants(room.name);
      if (present.some(p => p.identity === follower.handle)) await rooms.removeParticipant(room.name, follower.handle);
    }
  },
}));
