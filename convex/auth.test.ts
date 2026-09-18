import { afterEach, beforeAll, expect, test, vi } from "vitest";
import { exportPKCS8, generateKeyPair } from "jose";
import { api } from "./_generated/api";
import { backend } from "./test.setup";
let privateKey: string;
beforeAll(async () => { privateKey = await exportPKCS8((await generateKeyPair("RS256", { extractable: true })).privateKey); });
afterEach(() => vi.unstubAllEnvs());
function authBackend() {
  vi.stubEnv("JWT_PRIVATE_KEY", privateKey);
  vi.stubEnv("CONVEX_SITE_URL", "https://auth-test.convex.site");
  return backend();
}
test("group join signup/signin use the password provider", async () => {
  const t = authBackend();
  const params = { email: "alice@doorbell.local", password: "doorbell", flow: "signUp" };
  const first = await t.action(api.auth.signIn, { provider: "password", params });
  expect(first.tokens?.token).toEqual(expect.any(String));
  const again = await t.action(api.auth.signIn, { provider: "password", params: { ...params, flow: "signIn" } });
  expect(again.tokens?.token).toEqual(expect.any(String));
  await expect(
    t.action(api.auth.signIn, { provider: "password", params: { ...params, password: "wrong-secret", flow: "signIn" } }),
  ).rejects.toThrow();
  expect(await t.run(ctx => ctx.db.query("users").collect())).toHaveLength(1);
});
