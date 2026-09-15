import { AccessToken } from "npm:livekit-server-sdk@2";
const room = `door:test_${crypto.randomUUID().slice(0,8)}`;
async function token(identity: string) {
  const t = new AccessToken("devkey", "secret", { identity, ttl: "10m" });
  t.addGrant({ room, roomJoin: true, canPublish: true, canSubscribe: true, canPublishData: true });
  return await t.toJwt();
}
await Deno.writeTextFile(Deno.args[0], JSON.stringify({ room, url: "ws://127.0.0.1:17900", first: await token("first"), second: await token("second") }));
