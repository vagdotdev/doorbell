// door-token: mints a LiveKit join token for a door, according to the graph, and
// rings the door.
//
//   POST { door: "vagdev", intent: "visit" | "knock_answered" | "answer" | "leave", hidden?: boolean }
//   → { token, url, mode: "knock" | "walk_in" | "answer" }     (leave → { mode: "left" })
//
// "visit" also broadcasts knock / walk_in on the owner's private channel door:{handle};
// "leave" broadcasts left. Clients never write to that channel themselves — only the
// owner can read it, and only this function (service role) can write.
// The LiveKit API secret lives here and nowhere else.

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

type Intent = "visit" | "knock_answered" | "answer" | "leave";

/// One broadcast on a door's private channel, as the service role.
async function ring(door: string, event: string, from: string) {
  const res = await fetch(`${SUPABASE_URL}/realtime/v1/api/broadcast`, {
    method: "POST",
    headers: {
      apikey: SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      messages: [{ topic: `door:${door}`, event, private: true, payload: { from } }],
    }),
  });
  if (!res.ok) console.error("ring failed", res.status, await res.text());
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

  let body: { door?: string; intent?: Intent; hidden?: boolean };
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

  const [{ data: me }, { data: owner }] = await Promise.all([
    admin.from("profiles").select("id, handle, display_name").eq("id", user.id).single<Profile>(),
    admin.from("profiles").select("id, handle, display_name").eq("handle", door).single<Profile>(),
  ]);
  if (!me) return json(403, { error: "no profile yet" });
  if (!owner) return json(404, { error: "no such door" });

  const roomName = `door:${owner.handle}`;
  let mode: "knock" | "walk_in" | "answer";
  let canSubscribe: boolean;
  let hidden = false;

  const followsOwner = async () => {
    const { data } = await admin
      .from("follows")
      .select("status")
      .eq("follower_id", me.id)
      .eq("followee_id", owner.id)
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
        mode = "walk_in";
        canSubscribe = true;
      } else if (await followsOwner()) {
        mode = "knock";
        canSubscribe = false;
      } else {
        return json(403, { error: "you don't follow this door" });
      }
      await ring(owner.handle, mode, me.handle);
      break;
    }
    case "leave": {
      if (!(await followsOwner())) return json(403, { error: "you don't follow this door" });
      await ring(owner.handle, "left", me.handle);
      return json(200, { mode: "left" });
    }
    case "knock_answered": {
      if (!(await followsOwner())) return json(403, { error: "you don't follow this door" });
      // Only upgrade once the owner is visibly in the room. Hidden participants
      // are not listed, so "present in the list" means "opened the door".
      const svc = new RoomServiceClient(LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET);
      const participants = await svc.listParticipants(roomName).catch(() => []);
      const ownerVisible = participants.some((p) => p.identity === owner.handle);
      if (!ownerVisible) return json(403, { error: "door is not open" });
      mode = "knock";
      canSubscribe = true;
      break;
    }
    case "answer": {
      if (me.id !== owner.id) return json(403, { error: "not your door" });
      mode = "answer";
      canSubscribe = true;
      hidden = body.hidden ?? true;
      break;
    }
    default:
      return json(400, { error: "unknown intent" });
  }

  const at = new AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET, {
    identity: me.handle,
    name: me.display_name || me.handle,
    ttl: "10m",
    metadata: JSON.stringify({ handle: me.handle, display_name: me.display_name, via: owner.handle }),
  });
  at.addGrant({
    room: roomName,
    roomJoin: true,
    canPublish: true,
    canPublishData: canSubscribe, // chat only once you're properly in the room
    canSubscribe,
    hidden,
  });

  return json(200, { token: await at.toJwt(), url: LIVEKIT_PUBLIC_URL, mode });
});
