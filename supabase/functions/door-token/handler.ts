export interface Profile { id: string; handle: string; display_name: string }
export interface Participant { identity: string; hidden?: boolean; metadata?: string }
export interface SeatGrant { publish: boolean; subscribe: boolean; hidden: boolean }
export interface Dependencies {
  user(authorization: string): Promise<string | null>;
  profile(column: "id" | "handle", value: string): Promise<Profile | null>;
  follows(follower: string, owner: string): Promise<boolean>;
  close(follower: string, owner: string): Promise<boolean>;
  allow(user: string): Promise<boolean>;
  participants(room: string): Promise<Participant[]>;
  ensureRoom(room: string): Promise<void>;
  ring(handle: string, event: string, payload: Record<string, string>): Promise<void>;
  seat(who: Profile, room: string, via: string, visit: string, grant: SeatGrant): Promise<string>;
  revoke(owner: Profile, follower: Profile): Promise<void>;
  url: string;
}
const json = (status: number, body: unknown) => new Response(JSON.stringify(body), {
  status, headers: { "content-type": "application/json", "cache-control": "no-store" },
});
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const handle = /^[a-z0-9_]{3,20}$/;
const full: SeatGrant = { publish: true, subscribe: true, hidden: false };
const waiting: SeatGrant = { publish: true, subscribe: false, hidden: false };
const observer: SeatGrant = { publish: false, subscribe: true, hidden: true };

export function createHandler(d: Dependencies) {
  return async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return json(405, { error: "POST only" });
    try {
      const uid = await d.user(req.headers.get("authorization") ?? "");
      if (!uid) return json(401, { error: "Sign in first" });
      if (Number(req.headers.get("content-length") ?? 0) > 4096) return json(413, { error: "Request too large" });
      // Bound streamed requests too; Content-Length is optional and untrusted.
      const reader = req.body?.getReader();
      if (!reader) return json(400, { error: "Missing body" });
      let bytes = 0; const chunks: Uint8Array[] = [];
      while (true) {
        const next = await reader.read();
        if (next.done) break;
        bytes += next.value.length;
        if (bytes > 4096) { await reader.cancel(); return json(413, { error: "Request too large" }); }
        chunks.push(next.value);
      }
      const raw = new Uint8Array(bytes); let offset = 0;
      for (const chunk of chunks) { raw.set(chunk, offset); offset += chunk.length; }
      let body: Record<string, unknown>;
      try { body = JSON.parse(new TextDecoder().decode(raw)); } catch { return json(400, { error: "Invalid JSON" }); }
      if (!body || Array.isArray(body) || typeof body !== "object") return json(400, { error: "Invalid request" });
      if (body.version !== 2) return json(409, { error: "Update Doorbell to continue" });
      if (typeof body.door !== "string" || !handle.test(body.door)) return json(400, { error: "Invalid door" });
      if (typeof body.intent !== "string" || !["visit", "ring", "leave", "answer", "admit", "revoke"].includes(body.intent)) {
        return json(400, { error: "Invalid intent" });
      }
      const { door, intent } = body;
      if (body.hidden !== undefined && typeof body.hidden !== "boolean") return json(400, { error: "Invalid hidden flag" });
      const hidden = body.hidden !== false;
      const needsVisit = !((intent === "answer" && !hidden) || intent === "revoke");
      if (needsVisit && (typeof body.visit !== "string" || !uuid.test(body.visit))) return json(400, { error: "Invalid visit" });
      const visit = typeof body.visit === "string" ? body.visit.toLowerCase() : "";
      const [me, owner] = await Promise.all([d.profile("id", uid), d.profile("handle", door)]);
      if (!me) return json(403, { error: "Choose a handle first" });
      if (!owner) return json(404, { error: "No such door" });
      // Local leave never depends on signaling; expiry clears a missed notification.
      if (!(await d.allow(uid))) {
        if (intent === "leave") return json(200, { mode: "left" });
        return json(429, { error: "A moment, please. Try again shortly." });
      }
      const room = `door:${owner.handle}`;
      const doorstep = `doorstep:${owner.id}:${visit}`;
      const output = async (who: Profile, where: string, mode: string, grant: SeatGrant) => json(200, {
        token: await d.seat(who, where, owner.handle, visit, grant), url: d.url, room: where, mode,
      });
      if (["visit", "ring"].includes(intent)) {
        if (me.id === owner.id || !(await d.follows(me.id, owner.id))) return json(403, { error: "You can’t visit this door" });
        const walkIn = await d.close(me.id, owner.id);
        if (intent === "visit") return await output(me, doorstep, walkIn ? "walk_in" : "knock", waiting);
        const peers = await d.participants(doorstep);
        if (!peers.some(p => p.identity === me.handle)) return json(409, { error: "Connect before knocking" });
        await d.ring(owner.handle, walkIn ? "walk_in" : "knock", { from: me.handle, visit });
        return json(200, { mode: "rang" });
      }
      if (intent === "leave") {
        // A caller may only clear their own identified visit. Payload identity is server-owned.
        if (await d.follows(me.id, owner.id)) await d.ring(owner.handle, "left", { from: me.handle, visit });
        return json(200, { mode: "left" });
      }
      if (me.id !== owner.id) return json(403, { error: "Not your door" });
      if (intent === "answer") {
        if (!hidden) await d.ensureRoom(room);
        return await output(me, hidden ? doorstep : room, "answer", hidden ? observer : full);
      }
      if (typeof body.guest !== "string" || !handle.test(body.guest)) return json(400, { error: "Invalid guest" });
      const guest = await d.profile("handle", body.guest);
      if (!guest || guest.id === me.id) return json(404, { error: "No such guest" });
      if (intent === "revoke") {
        await d.revoke(me, guest);
        return json(200, { mode: "revoked" });
      }
      if (!(await d.follows(guest.id, me.id))) return json(403, { error: "They can’t visit this door" });
      if (!(await d.participants(doorstep)).some(p => p.identity === guest.handle)) {
        return json(409, { error: "They have left the doorstep" });
      }
      const into = body.room ?? room;
      if (typeof into !== "string" || !/^door:[a-z0-9_]{3,20}$/.test(into)) return json(400, { error: "Invalid room" });
      if (!(await d.participants(into)).some(p => p.identity === me.handle && !p.hidden)) {
        return json(403, { error: "Join the room before admitting someone" });
      }
      const token = await d.seat(guest, into, me.handle, visit, full);
      await d.ring(guest.handle, "admitted", { from: me.handle, visit, room: into, url: d.url, token });
      return json(200, { mode: "admitted" });
    } catch {
      // Never log request bodies, credentials, peer identities or room tokens.
      return json(503, { error: "Doorbell couldn’t connect. Try again." });
    }
  };
}
