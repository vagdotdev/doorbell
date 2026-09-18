import { expect, test } from "vitest";
import { api } from "./_generated/api";
import { backend, person } from "./test.setup";

test("another person's avatar cannot be attached and then deleted", async () => {
  const t = backend(), alice = await person(t, "alice"), bob = await person(t, "bob");
  await alice.as.action(api.profiles.uploadAvatar, { bytes: new Uint8Array([0xff,0xd8,0xff,1]).buffer, contentType: "image/jpeg" });
  const id = (await t.run(ctx => ctx.db.get(alice.profileId)))!.avatarStorageId!;
  await expect(bob.as.mutation(api.profiles.setAvatar, { storageId: id })).rejects.toThrow();
  await bob.as.mutation(api.profiles.clearAvatar, {});
  expect(await t.run(ctx => ctx.storage.getUrl(id))).not.toBeNull();
});


test("another person's API key cannot be revoked", async () => {
  const t = backend(), alice = await person(t, "alice"), bob = await person(t, "bob");
  const key = await alice.as.mutation(api.apiKeyMgmt.create, { name: "Alice only" });
  await expect(bob.as.mutation(api.apiKeyMgmt.revoke, { keyId: key.keyId })).rejects.toThrow();
  expect((await alice.as.query(api.apiKeyMgmt.list, {}))[0].status).toBe("active");
});
