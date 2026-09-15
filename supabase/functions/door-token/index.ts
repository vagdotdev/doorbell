// door-token: mints a LiveKit join token for a door, according to the graph, and
// rings the door.
//
//   POST { door, intent: "visit" | "answer" | "admit" | "leave", hidden?, guest?, room? }
//   → { token, url, room, mode: "knock" | "walk_in" | "answer" }
//     leave → { mode: "left" }      admit → { mode: "admitted" }
//
// Two rooms per person. `door:{handle}` is their room. `doorstep:{handle}` is the step
// outside it: a knocker waits there (publish only, sees nothing), and the owner peeks
// from there (hidden). Nobody gets into a room without the owner's "admit", which
// mints the guest's seat and delivers it on the guest's own private channel.
//
// "visit" broadcasts knock / walk_in on the owner's channel door:{handle}; "leave"
// broadcasts left; "admit" broadcasts admitted (with the seat) on the guest's channel.
// Clients never write to these channels — only the owner reads their own, and only
// this function (service role) writes. The LiveKit API secret lives here and nowhere else.

import { createClient } from "npm:@supabase/supabase-js@2";
import { AccessToken, RoomServiceClient } from "npm:livekit-server-sdk@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const LIVEKIT_URL = Deno.env.get("LIVEKIT_URL")!;
// What the app connects to. Differs from LIVEKIT_URL only when the function runs in
// Docker against a livekit-server on the host (local development).
const LIVEKIT_PUBLIC_URL = Deno.env.get("LIVEKIT_PUBLIC_URL") ?? LIVEKIT_URL;
const LIVEKIT_API_KEY = Deno.env.get("LIVEKIT_API_KEY")!;
const LIVEKIT_API_SECRET = Deno.env.get("LIVEKIT_API_SECRET")!;

type Intent = "visit" | "answer" | "admit" | "leave";

/// One broadcast on a door's private channel, as the service role.
async function ring(door: string, event: string, payload: Record<string, string>) {
  const res = await fetch(`${SUPABASE_URL}/realtime/v1/api/broadcast`, {
    method: "POST",
    headers: {
      apikey: SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      messages: [{ topic: `door:${door}`, event, private: true, payload }],
    }),
  });
  if (!res.ok) console.error("ring failed", res.status, await res.text());
}

function seat(who: Profile, room: string, via: string,
              grant: { canSubscribe: boolean; hidden?: boolean }) {
  const at = new AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET, {
    identity: who.handle,
    name: who.display_name || who.handle,
    ttl: "10m",
    metadata: JSON.stringify({ handle: who.handle, display_name: who.display_name, via }),
  });
  at.addGrant({
    room,
    roomJoin: true,
    canPublish: true,
    canPublishData: grant.canSubscribe, // chat only once you're properly in the room
    canSubscribe: grant.canSubscribe,
    hidden: grant.hidden ?? false,
  });
  return at.toJwt();
}

interface Profile {
  id: string;
  handle: string;
  display_name: string;
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(405, { error: "POST only" });

  const authHeader = req.headers.get("Authorization") ?? "";
  const asUser = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user } } = await asUser.auth.getUser();
  if (!user) return json(401, { error: "sign in" });

  let body: { door?: string; intent?: Intent; hidden?: boolean; guest?: string; room?: string };
  try {
    body = await req.json();
  } catch {
    return json(400, { error: "bad json" });
  }
  const { door, intent } = body;
  if (!door || !intent) return json(400, { error: "door and intent required" });

  // Graph lookups bypass RLS: a visitor may not read the owner's close_friends,
  // but the function must, to decide knock vs walk-in.
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const profile = (column: "id" | "handle", value: string) =>
    admin.from("profiles").select("id, handle, display_name").eq(column, value).single<Profile>();

  const [{ data: me }, { data: owner }] = await Promise.all([profile("id", user.id), profile("handle", door)]);
  if (!me) return json(403, { error: "no profile yet" });
  if (!owner) return json(404, { error: "no such door" });

  const room = `door:${owner.handle}`;
  const doorstep = `doorstep:${owner.handle}`;

  const follows = async (follower: Profile, followee: Profile) => {
    const { data } = await admin
      .from("follows")
      .select("status")
      .eq("follower_id", follower.id)
      .eq("followee_id", followee.id)
      .eq("status", "accepted")
      .maybeSingle();
    return !!data;
  };

  switch (intent) {
    case "visit": {
      if (me.id === owner.id) return json(400, { error: "that's your own door" });
      const { data: close } = await admin
        .from("close_friends")
        .select("member_id")
        .eq("owner_id", owner.id)
        .eq("member_id", me.id)
        .maybeSingle();
      if (close) {
        await ring(owner.handle, "walk_in", { from: me.handle });
        return json(200, {
          token: await seat(me, room, owner.handle, { canSubscribe: true }),
          url: LIVEKIT_PUBLIC_URL, room, mode: "walk_in",
        });
      }
      if (!(await follows(me, owner))) return json(403, { error: "you don't follow this door" });
      // The knocker stands on the step: seen and heard by the owner, sees nothing.
      await ring(owner.handle, "knock", { from: me.handle });
      return json(200, {
        token: await seat(me, doorstep, owner.handle, { canSubscribe: false }),
        url: LIVEKIT_PUBLIC_URL, room: doorstep, mode: "knock",
      });
    }
    case "leave": {
      if (!(await follows(me, owner))) return json(403, { error: "you don't follow this door" });
      await ring(owner.handle, "left", { from: me.handle });
      return json(200, { mode: "left" });
    }
    case "answer": {
      if (me.id !== owner.id) return json(403, { error: "not your door" });
      // Hidden: peek from the doorstep. Otherwise: host my own room.
      const hidden = body.hidden ?? true;
      const where = hidden ? doorstep : room;
      return json(200, {
        token: await seat(me, where, owner.handle, { canSubscribe: true, hidden }),
        url: LIVEKIT_PUBLIC_URL, room: where, mode: "answer",
      });
    }
    case "admit": {
      // The owner lets a knocker in — to their own room, or to whichever room they
      // are a guest in right now. Serendipity: "someone's at my door, come meet them".
      if (me.id !== owner.id) return json(403, { error: "not your door" });
      if (!body.guest) return json(400, { error: "guest required" });
      const { data: guest } = await profile("handle", body.guest);
      if (!guest) return json(404, { error: "no such guest" });
      if (!(await follows(guest, me))) return json(403, { error: "they don't follow you" });

      const into = body.room ?? room;
      if (into !== room) {
        // Vouching for someone into another room needs the voucher to be in it, visibly.
        if (!into.startsWith("door:")) return json(400, { error: "not a room" });
        const svc = new RoomServiceClient(LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET);
        const participants = await svc.listParticipants(into).catch(() => []);
        if (!participants.some((p) => p.identity === me.handle)) {
          return json(403, { error: "you're not in that room" });
        }
      }
      const token = await seat(guest, into, me.handle, { canSubscribe: true });
      await ring(guest.handle, "admitted", { from: me.handle, room: into, url: LIVEKIT_PUBLIC_URL, token });
      return json(200, { mode: "admitted" });
    }
    default:
      return json(400, { error: "unknown intent" });
  }
});
