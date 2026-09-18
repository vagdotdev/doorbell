#!/usr/bin/env node
/** Prove LiveKit credentials work before pushing them to Convex. */
import { readFileSync, existsSync } from "node:fs";
import { LiveKitAPI, AccessToken } from "livekit-server-sdk";
import { Room, RoomEvent } from "@livekit/rtc-node";

function loadSecrets() {
  const path = new URL("../.env.secrets", import.meta.url);
  if (!existsSync(path)) throw new Error("Missing .env.secrets — copy from .env.secrets.example");
  const env = {};
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#") || !trimmed.includes("=")) continue;
    const i = trimmed.indexOf("=");
    env[trimmed.slice(0, i).trim()] = trimmed.slice(i + 1).trim();
  }
  return env;
}

const env = { ...process.env, ...loadSecrets() };
const host = env.LIVEKIT_URL;
const publicUrl = env.LIVEKIT_PUBLIC_URL ?? host;
const apiKey = env.LIVEKIT_API_KEY;
const secret = env.LIVEKIT_API_SECRET;
for (const [k, v] of Object.entries({ LIVEKIT_URL: host, LIVEKIT_API_KEY: apiKey, LIVEKIT_API_SECRET: secret })) {
  if (!v) throw new Error(`Missing ${k} in .env.secrets`);
}

const api = new LiveKitAPI({ host, apiKey, secret });
try {
  await api.room.listRooms();
} catch (e) {
  const msg = e?.message ?? String(e);
  console.error(`LiveKit rejected these credentials (${msg}).`);
  console.error("Create a fresh key at https://cloud.livekit.io → your project → Settings → Keys.");
  console.error("Paste into .env.secrets, then run: scripts/sync-livekit-prod.sh");
  process.exit(1);
}
console.log("→ LiveKit server API ok", host);

const jwt = await new AccessToken(apiKey, secret, { identity: "doorbell-verify", ttl: "60s" })
  .addGrant({ roomJoin: true, room: "doorbell-verify" })
  .toJwt();
const room = new Room();
await new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error("LiveKit connect timed out")), 15000);
  room.once(RoomEvent.Connected, () => { clearTimeout(timer); resolve(); });
  room.connect(publicUrl, jwt).catch(reject);
});
await room.disconnect();
console.log("→ LiveKit media connect ok", publicUrl);
