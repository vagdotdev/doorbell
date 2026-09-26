/// <reference types="vite/client" />
import { afterEach, expect, test, vi } from "vitest";
import { api, internal } from "./_generated/api";
import { SYSTEM, boardPage } from "./notes";
import { backend, person } from "./test.setup";

afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
});

test("the board is a white page of cards, and an empty one still says so", () => {
  const html = boardPage([]);
  expect(html).toContain("background: #fff");
  expect(html).toContain("ui-serif");
  expect(html).toContain("Nothing yet.");
  const full = boardPage([{ at: 1_700_000_000_000, people: ["Ada", "Bo"], notes: "Ada: telusa", url: "https://x/n?t=abc" }]);
  expect(full).toContain("Ada, Bo");
  expect(full).toContain('class="card"');
});

test("the notes prompt keeps romanized speech and asks for a gloss", () => {
  expect(SYSTEM).toMatch(/telusa, not /);
  expect(SYSTEM).toMatch(/parentheses/);
  expect(SYSTEM).toMatch(/No title/);
});

test("unsigned callers cannot transcribe or write notes", async () => {
  const t = backend();
  await expect(t.action(api.notes.transcribe, { wav: new ArrayBuffer(8), speaker: "Ada" })).rejects.toThrow(
    /Sign in/,
  );
  await expect(t.action(api.notes.write, { host: "ada", people: ["Ada"], transcript: "hi" })).rejects.toThrow(
    /Sign in/,
  );
});

test("a finished transcript becomes notes on a secret page and an inbox feed", async () => {
  vi.stubEnv("SARVAM_API_KEY", "test-key");
  vi.stubEnv("CONVEX_SITE_URL", "https://notes-test.convex.site");
  const fetchMock = vi.fn(async (url: string | URL, init?: RequestInit) => {
    const href = String(url);
    if (href.includes("/speech-to-text")) {
      return new Response(JSON.stringify({ transcript: "telusa" }), { status: 200 });
    }
    if (href.includes("/chat/completions")) {
      return new Response(
        JSON.stringify({
          choices: [{ message: { content: "With Ada\n\nAda: telusa (do you know?)" } }],
        }),
        { status: 200 },
      );
    }
    return new Response("no", { status: 404 });
  });
  vi.stubGlobal("fetch", fetchMock);

  const t = backend();
  const ada = await person(t, "ada", "Ada");
  const eve = await person(t, "eve", "Eve");

  const wav = new ArrayBuffer(64);
  const line = await ada.as.action(api.notes.transcribe, { wav, speaker: "Ada" });
  expect(line).toBe("Ada: telusa");
  const speech = fetchMock.mock.calls.find(([url]) => String(url).includes("/speech-to-text"));
  expect(speech).toBeTruthy();

  const saved = await ada.as.action(api.notes.write, {
    host: "ada",
    people: ["Ada"],
    transcript: "Ada: telusa",
  });
  expect(saved.notes).toBe("With Ada\n\nAda: telusa (do you know?)");
  expect(saved.url).toMatch(/^https:\/\/notes-test\.convex\.site\/n\?t=[0-9a-f]{64}$/);
  expect(saved.inboxUrl).toMatch(/^https:\/\/notes-test\.convex\.site\/n\/feed\?t=[0-9a-f]{64}$/);

  const chat = fetchMock.mock.calls.find(([url]) => String(url).includes("/chat/completions"));
  const body = JSON.parse(String((chat?.[1] as RequestInit | undefined)?.body));
  expect(body.reasoning_effort).toBeNull();
  expect(body.messages[0].content).toBe(SYSTEM);

  const token = new URL(saved.url).searchParams.get("t")!;
  const page = await t.query(internal.notes.page, { token });
  expect(page).toMatchObject({ host: "ada", notes: saved.notes });
  expect(await t.query(internal.notes.page, { token: "0".repeat(64) })).toBeNull();

  const inbox = new URL(saved.inboxUrl).searchParams.get("t")!;
  const feed = await t.query(internal.notes.feed, { token: inbox });
  expect(feed?.notes).toHaveLength(1);
  expect(feed?.notes[0]?.url).toBe(saved.url);
  expect(await t.query(internal.notes.feed, { token: inbox, after: page!.at })).toEqual({ notes: [] });
  expect(await eve.as.query(internal.notes.feed, { token: inbox })).toEqual(feed);
});

test("empty speech skips Sarvam and still hangs a page", async () => {
  const fetchMock = vi.fn(async () => new Response("no", { status: 500 }));
  vi.stubGlobal("fetch", fetchMock);
  vi.stubEnv("CONVEX_SITE_URL", "https://notes-test.convex.site");

  const t = backend();
  const ada = await person(t, "ada", "Ada");
  const saved = await ada.as.action(api.notes.write, { host: "ada", people: ["Ada"], transcript: "   " });
  expect(saved.notes).toBe("No speech was captured.");
  expect(fetchMock).not.toHaveBeenCalled();
});

test("the bulletin board opens with the env token and stays closed without it", async () => {
  const token = "ab".repeat(32);
  vi.stubEnv("NOTES_BOARD_TOKEN", token);
  vi.stubEnv("CONVEX_SITE_URL", "https://notes-test.convex.site");
  const t = backend();
  expect(await t.query(internal.notes.board, { token })).toEqual({ notes: [] });
  expect(await t.query(internal.notes.board, { token: "cd".repeat(32) })).toBeNull();
});
