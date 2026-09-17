/// <reference types="vite/client" />
import { convexTest } from "convex-test";
import type { Id } from "./_generated/dataModel";
import schema from "./schema";

// Everything convex-test needs to run the functions in this directory.
export const modules = import.meta.glob("./**/*.*s");

export function backend() {
  return convexTest(schema, modules);
}

type T = ReturnType<typeof backend>;

/// A signed-in account, the way Convex Auth presents one: `subject` is `${userId}|${sessionId}`.
export async function signedIn(t: T, email: string) {
  const userId = await t.run(async (ctx) => await ctx.db.insert("users", { email }));
  return { userId, as: t.withIdentity({ subject: `${userId}|session` }) };
}

/// A signed-in account with a handle.
export async function person(t: T, handle: string, displayName = handle) {
  const { userId, as } = await signedIn(t, `${handle}@test.local`);
  const profileId = (await as.mutation((await import("./_generated/api")).api.profiles.claimHandle, {
    handle,
    displayName,
  })).id as Id<"profiles">;
  return { userId, profileId, handle, as };
}

export const livekitEnv = {
  LIVEKIT_URL: "ws://127.0.0.1:7880",
  LIVEKIT_PUBLIC_URL: "ws://livekit.test:7880",
  LIVEKIT_API_KEY: "devkey",
  LIVEKIT_API_SECRET: "secretsecretsecretsecretsecretsecret",
};
