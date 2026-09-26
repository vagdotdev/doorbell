import { afterEach, expect, test, vi } from "vitest";
import { api } from "./_generated/api";
import { STATUS_TTL_MS } from "./status";
import { backend, person } from "./test.setup";

afterEach(() => { vi.useRealTimers(); });

async function friends() {
  const t = backend(), alice = await person(t, "alice"), bob = await person(t, "bob"), eve = await person(t, "eve");
  await alice.as.mutation(api.graph.request, { profileId: bob.profileId });
  await bob.as.mutation(api.graph.accept, { profileId: alice.profileId });
  return { t, alice, bob, eve };
}
const doorOf = async (viewer: Awaited<ReturnType<typeof person>>, handle: string) =>
  (await viewer.as.query(api.graph.hallway, {}))!.doors.find(d => d.profile.handle === handle);

test("a status is mine to write, short, and shown over my door to friends only", async () => {
  const { t, alice, bob, eve } = await friends();
  await expect(t.mutation(api.status.set, { text: "hi" })).rejects.toThrow(/Sign in/);
  await expect(bob.as.mutation(api.status.set, { text: "   " })).rejects.toThrow(/Write something/);
  await expect(bob.as.mutation(api.status.set, { text: "x".repeat(161) })).rejects.toThrow(/short/);

  const before = Date.now();
  const saved = await bob.as.mutation(api.status.set, { text: "  in a meeting \n till 4  " });
  expect(saved.text).toBe("in a meeting till 4");
  expect(saved.expiresAt - before).toBeGreaterThanOrEqual(STATUS_TTL_MS);
  expect(saved.expiresAt - Date.now()).toBeLessThanOrEqual(STATUS_TTL_MS);

  expect((await bob.as.query(api.graph.hallway, {}))!.myStatus).toEqual(saved);
  expect((await doorOf(alice, "bob"))!.status).toEqual(saved);
  expect((await alice.as.query(api.graph.hallway, {}))!.myStatus).toBeNull();
  expect(await eve.as.query(api.graph.hallway, {})).toMatchObject({ doors: [], myStatus: null });

  await bob.as.mutation(api.status.clear, {});
  expect((await doorOf(alice, "bob"))!.status).toBeNull();
  expect((await bob.as.query(api.graph.hallway, {}))!.myStatus).toBeNull();
});

test("statuses vanish after six hours, and an older timer never clears a newer status", async () => {
  vi.useFakeTimers();
  const { t, alice, bob } = await friends();
  await bob.as.mutation(api.status.set, { text: "exams" });
  vi.advanceTimersByTime(STATUS_TTL_MS / 2);
  const second = await bob.as.mutation(api.status.set, { text: "library till 9" });
  vi.advanceTimersByTime(STATUS_TTL_MS / 2 + 1);
  await t.finishInProgressScheduledFunctions();
  expect((await doorOf(alice, "bob"))!.status).toEqual(second);
  vi.advanceTimersByTime(STATUS_TTL_MS / 2);
  await t.finishAllScheduledFunctions(vi.runAllTimers);
  expect((await doorOf(alice, "bob"))!.status).toBeNull();
  expect(await t.run(ctx => ctx.db.query("doorStatus").collect())).toEqual([]);
});
