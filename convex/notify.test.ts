import { afterEach, expect, test, vi } from "vitest";
import { backend, person } from "./test.setup";

afterEach(() => { vi.unstubAllEnvs(); vi.unstubAllGlobals(); vi.useRealTimers(); });

test("claiming a handle pings the ntfy topic", async () => {
  vi.stubEnv("NTFY_TOPIC", "doorbell-test-topic");
  const fetchMock = vi.fn(async (_url: string, _init: RequestInit) => new Response("ok", { status: 200 }));
  vi.stubGlobal("fetch", fetchMock);
  vi.useFakeTimers();

  const t = backend();
  await person(t, "dana", "Dana");
  await t.finishAllScheduledFunctions(vi.runAllTimers);

  expect(fetchMock).toHaveBeenCalledTimes(1);
  const [url, init] = fetchMock.mock.calls[0]!;
  expect(url).toBe("https://ntfy.sh/doorbell-test-topic");
  expect(init.method).toBe("POST");
  expect(init.body).toBe("Dana (@dana) just joined");
});

test("without NTFY_TOPIC the signup ping is a silent no-op", async () => {
  const fetchMock = vi.fn(async () => new Response("ok", { status: 200 }));
  vi.stubGlobal("fetch", fetchMock);
  vi.useFakeTimers();

  const t = backend();
  await person(t, "erin", "Erin");
  await t.finishAllScheduledFunctions(vi.runAllTimers);

  expect(fetchMock).not.toHaveBeenCalled();
});
