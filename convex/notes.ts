import { ConvexError, v } from "convex/values";
import { internal } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import { action, env, internalMutation, internalQuery } from "./_generated/server";

const WAV_LIMIT = 800_000;
const TRANSCRIPT_LIMIT = 80_000;
const NOTE_LIMIT = 12_000;

export const SYSTEM = [
  "You write notes from a romanized call transcript.",
  "Indic words are already in English letters. Keep them that way: telusa, not తెలుసా.",
  "",
  "Write only this, in this order:",
  "With <names>",
  "",
  "Then one line per spoken turn:",
  "Name: romanized words (short English gloss)",
  "",
  "Then, only if someone agreed to do something:",
  "Next",
  "Name: the thing",
  "",
  "Rules:",
  "- English glosses. Romanized speech stays romanized.",
  "- The gloss is the meaning, in parentheses, on that same line.",
  "- No title, no greeting, no emoji, no markdown.",
  "- Skip filler and repeats.",
  "- If nothing was said, write: No speech was captured.",
].join("\n");

const saved = v.object({
  notes: v.string(),
  url: v.string(),
  inboxUrl: v.string(),
});

type Who = { id: Id<"profiles">; handle: string; displayName: string };
type Saved = { notes: string; url: string; inboxUrl: string };

function secret(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

function site(): string {
  return env.CONVEX_SITE_URL.replace(/\/$/, "");
}

function key(): string {
  const value = process.env.SARVAM_API_KEY;
  if (!value) throw new ConvexError("Sarvam is not configured on this deployment.");
  return value;
}

async function sarvam(path: string, init: RequestInit): Promise<Response> {
  const res = await fetch(`https://api.sarvam.ai${path}`, {
    ...init,
    headers: { "api-subscription-key": key(), ...(init.headers ?? {}) },
  });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new ConvexError(res.status === 403 ? "Sarvam key was refused." : `Sarvam failed (${res.status}). ${body.slice(0, 120)}`);
  }
  return res;
}

/// One person's speech, already in English letters. Audio is not stored.
export const transcribe = action({
  args: { wav: v.bytes(), speaker: v.string() },
  returns: v.string(),
  handler: async (ctx, args): Promise<string> => {
    await ctx.runQuery(internal.doors.whoAmI, {});
    if (args.wav.byteLength === 0 || args.wav.byteLength > WAV_LIMIT) {
      throw new ConvexError("That audio clip is the wrong size.");
    }
    const speaker = args.speaker.trim().slice(0, 60);
    if (!speaker) throw new ConvexError("Missing speaker.");
    const form = new FormData();
    form.append("file", new Blob([args.wav], { type: "audio/wav" }), "chunk.wav");
    form.append("model", "saaras:v3");
    form.append("mode", "translit");
    form.append("language_code", "unknown");
    const res = await sarvam("/speech-to-text", { method: "POST", body: form });
    const body: unknown = await res.json();
    const text =
      typeof body === "object" && body !== null && "transcript" in body && typeof body.transcript === "string"
        ? body.transcript.trim()
        : "";
    return text ? `${speaker}: ${text}` : "";
  },
});

/// Turn the romanized transcript into notes and hang them on a secret URL.
export const write = action({
  args: { host: v.string(), people: v.array(v.string()), transcript: v.string() },
  returns: saved,
  handler: async (ctx, args): Promise<Saved> => {
    const me: Who = await ctx.runQuery(internal.doors.whoAmI, {});
    const host = args.host.trim().slice(0, 40);
    const people = args.people.map((n) => n.trim().slice(0, 60)).filter(Boolean).slice(0, 8);
    const transcript = args.transcript.trim().slice(0, TRANSCRIPT_LIMIT);
    const notes = transcript.length === 0 ? "No speech was captured." : await compose(host, people, transcript);
    return await ctx.runMutation(internal.notes.save, {
      ownerId: me.id,
      host,
      people,
      transcript,
      notes: notes.slice(0, NOTE_LIMIT),
    });
  },
});

async function compose(host: string, people: string[], transcript: string): Promise<string> {
  const res = await sarvam("/v1/chat/completions", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      model: "sarvam-105b",
      temperature: 0.2,
      max_tokens: 2048,
      reasoning_effort: null,
      messages: [
        { role: "system", content: SYSTEM },
        {
          role: "user",
          content: `Host: ${host || "unknown"}\nPeople: ${people.join(", ") || "unknown"}\n\n${transcript}`,
        },
      ],
    }),
  });
  const body: unknown = await res.json();
  const text = pickContent(body);
  if (!text) throw new ConvexError("Sarvam returned empty notes.");
  return text;
}

function pickContent(body: unknown): string {
  if (typeof body !== "object" || body === null || !("choices" in body)) return "";
  const choices = body.choices;
  if (!Array.isArray(choices) || choices.length === 0) return "";
  const first = choices[0];
  if (typeof first !== "object" || first === null || !("message" in first)) return "";
  const message = first.message;
  if (typeof message !== "object" || message === null || !("content" in message)) return "";
  return typeof message.content === "string" ? message.content.trim() : "";
}

export const save = internalMutation({
  args: {
    ownerId: v.id("profiles"),
    host: v.string(),
    people: v.array(v.string()),
    transcript: v.string(),
    notes: v.string(),
  },
  returns: saved,
  handler: async (ctx, args) => {
    const token = secret();
    await ctx.db.insert("meetingNotes", {
      ownerId: args.ownerId,
      token,
      host: args.host,
      people: args.people,
      transcript: args.transcript,
      notes: args.notes,
      at: Date.now(),
    });
    const existing = await ctx.db
      .query("meetingInboxes")
      .withIndex("by_ownerId", (q) => q.eq("ownerId", args.ownerId))
      .unique();
    const inbox = existing?.token ?? secret();
    if (!existing) await ctx.db.insert("meetingInboxes", { ownerId: args.ownerId, token: inbox });
    const root = site();
    const board = process.env.NOTES_BOARD_TOKEN;
    return {
      notes: args.notes,
      url: `${root}/n?t=${token}`,
      inboxUrl: board ? `${root}/b?t=${board}` : `${root}/n/feed?t=${inbox}`,
    };
  },
});

const pageValidator = v.object({
  host: v.string(),
  people: v.array(v.string()),
  notes: v.string(),
  at: v.number(),
});

export const page = internalQuery({
  args: { token: v.string() },
  returns: v.union(pageValidator, v.null()),
  handler: async (ctx, args) => {
    if (!/^[0-9a-f]{64}$/.test(args.token)) return null;
    const row = await ctx.db
      .query("meetingNotes")
      .withIndex("by_token", (q) => q.eq("token", args.token))
      .unique();
    if (!row) return null;
    return { host: row.host, people: row.people, notes: row.notes, at: row.at };
  },
});

const feedItem = v.object({
  at: v.number(),
  host: v.string(),
  people: v.array(v.string()),
  notes: v.string(),
  url: v.string(),
});

export const feed = internalQuery({
  args: { token: v.string(), after: v.optional(v.number()) },
  returns: v.union(v.object({ notes: v.array(feedItem) }), v.null()),
  handler: async (ctx, args) => {
    if (!/^[0-9a-f]{64}$/.test(args.token)) return null;
    const inbox = await ctx.db
      .query("meetingInboxes")
      .withIndex("by_token", (q) => q.eq("token", args.token))
      .unique();
    if (!inbox) return null;
    const after = args.after ?? 0;
    const rows = await ctx.db
      .query("meetingNotes")
      .withIndex("by_ownerId", (q) => q.eq("ownerId", inbox.ownerId))
      .order("desc")
      .take(20);
    const root = site();
    return {
      notes: rows
        .filter((row) => row.at > after)
        .map((row) => ({
          at: row.at,
          host: row.host,
          people: row.people,
          notes: row.notes,
          url: `${root}/n?t=${row.token}`,
        })),
    };
  },
});

/// The unlisted bulletin board. The env token is the only credential, and an empty board is still a page.
export const board = internalQuery({
  args: { token: v.string() },
  returns: v.union(v.object({ notes: v.array(feedItem) }), v.null()),
  handler: async (ctx, args) => {
    const expected = process.env.NOTES_BOARD_TOKEN;
    if (!expected || args.token !== expected || !/^[0-9a-f]{64}$/.test(args.token)) return null;
    const handle = process.env.NOTES_BOARD_HANDLE;
    const owner = handle
      ? await ctx.db.query("profiles").withIndex("by_handle", (q) => q.eq("handle", handle)).unique()
      : null;
    if (handle && !owner) return { notes: [] };
    const rows = owner
      ? await ctx.db.query("meetingNotes").withIndex("by_ownerId", (q) => q.eq("ownerId", owner._id)).order("desc").take(30)
      : await ctx.db.query("meetingNotes").order("desc").take(30);
    const root = site();
    return {
      notes: rows.map((row) => ({
        at: row.at,
        host: row.host,
        people: row.people,
        notes: row.notes,
        url: `${root}/n?t=${row.token}`,
      })),
    };
  },
});

export function boardPage(notes: { at: number; people: string[]; notes: string; url: string }[]): string {
  const cards = notes.length === 0
    ? `<p class="empty">Nothing yet.</p>`
    : notes.map((note) => {
        const who = note.people.length > 0 ? note.people.join(", ") : "Untitled";
        const when = new Date(note.at).toISOString().replace("T", " ").slice(0, 16);
        const preview = note.notes.split("\n").filter((line) => line.trim()).slice(0, 4).join("\n");
        return `<a class="card" href="${escapeAttr(note.url)}">
          <h2>${escapeHtml(who)}</h2>
          <p class="when">${escapeHtml(when)} UTC</p>
          <pre>${escapeHtml(preview)}</pre>
        </a>`;
      }).join("\n");
  return pageShell("Notes", `<h1>Notes</h1>\n${cards}`);
}

export function notePage(note: { people: string[]; host: string; notes: string; at: number }): string {
  const who = note.people.length > 0 ? note.people.join(", ") : note.host || "Notes";
  const when = new Date(note.at).toISOString().replace("T", " ").slice(0, 16);
  return pageShell(who, `<p class="back"><a href="javascript:history.back()">Notes</a></p>
    <h1>${escapeHtml(who)}</h1>
    <p class="when">${escapeHtml(when)} UTC</p>
    <pre>${escapeHtml(note.notes)}</pre>`);
}

function pageShell(title: string, body: string): string {
  return `<!doctype html>
<meta charset="utf-8">
<meta name="robots" content="noindex">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(title)}</title>
<style>
  :root { color-scheme: light; }
  body { margin: 0; background: #fff; color: #111; font: 16px/1.5 ui-sans-serif, system-ui, sans-serif; }
  main { max-width: 40rem; margin: 0 auto; padding: 3.5rem 1.5rem 5rem; }
  h1, h2 { font-family: ui-serif, Georgia, "Iowan Old Style", Palatino, serif; font-weight: 500; letter-spacing: -0.02em; }
  h1 { font-size: 2.4rem; margin: 0 0 1.75rem; }
  a.card { display: block; color: inherit; text-decoration: none; border: 1px solid #111; padding: 1.15rem 1.25rem 1.2rem; margin: 0 0 0.85rem; }
  a.card:hover { background: #111; color: #fff; }
  h2 { font-size: 1.35rem; margin: 0; }
  .when, .back { color: #444; font-size: 13px; margin: 0.35rem 0 0.8rem; }
  .back a { color: inherit; }
  pre { white-space: pre-wrap; font: 15px/1.55 ui-sans-serif, system-ui, sans-serif; margin: 0; }
  .empty { margin: 0; }
</style>
<main>
${body}
</main>`;
}

function escapeHtml(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function escapeAttr(text: string): string {
  return escapeHtml(text).replace(/"/g, "&quot;");
}
