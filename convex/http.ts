import { httpRouter } from "convex/server";
import { WebhookReceiver } from "livekit-server-sdk";
import { internal } from "./_generated/api";
import { httpAction } from "./_generated/server";
import { auth } from "./auth";
import { boardPage, notePage } from "./notes";

function tokenOf(url: URL): string {
  return url.searchParams.get("t") ?? "";
}

function afterOf(url: URL): number | undefined {
  const raw = url.searchParams.get("after");
  if (!raw) return undefined;
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? n : undefined;
}


const http = httpRouter();

// /.well-known/openid-configuration and /.well-known/jwks.json, so the deployment
// can verify the tokens it issued.
auth.addHttpRoutes(http);

// LiveKit Cloud posts room/participant events here (Settings → Webhooks), signed
// with the same API key the deployment already holds. Verified events feed the
// /admin analytics via calls:record; everything else is a 401.
http.route({
  path: "/livekit/webhook",
  method: "POST",
  handler: httpAction(async (ctx, req) => {
    const key = process.env.LIVEKIT_API_KEY;
    const secret = process.env.LIVEKIT_API_SECRET;
    if (!key || !secret) return new Response("LiveKit is not configured.", { status: 500 });

    const body = await req.text();
    const auth = req.headers.get("Authorization") ?? undefined;
    let event;
    try {
      event = await new WebhookReceiver(key, secret).receive(body, auth);
    } catch {
      return new Response("unauthorized", { status: 401 });
    }

    if (
      event.event === "participant_joined" ||
      event.event === "participant_left" ||
      event.event === "room_finished"
    ) {
      await ctx.runMutation(internal.calls.record, {
        event: event.event,
        roomName: event.room?.name ?? "",
        roomSid: event.room?.sid ?? "",
        identity: event.participant?.identity,
        metadata: event.participant?.metadata,
        at: event.createdAt ? Number(event.createdAt) * 1000 : Date.now(),
      });
    }
    return new Response("ok", { status: 200 });
  }),
});

// Unlisted notes page. The 64-character token is the only credential.
http.route({
  path: "/n",
  method: "GET",
  handler: httpAction(async (ctx, req) => {
    const page: { host: string; people: string[]; notes: string; at: number } | null =
      await ctx.runQuery(internal.notes.page, { token: tokenOf(new URL(req.url)) });
    if (!page) return new Response("Not found.", { status: 404 });
    return new Response(notePage(page), {
      headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store", "X-Robots-Tag": "noindex" },
    });
  }),
});

// Unlisted bulletin board. Opens even when nothing has been recorded yet.
http.route({
  path: "/b",
  method: "GET",
  handler: httpAction(async (ctx, req) => {
    const url = new URL(req.url);
    const board: { notes: { at: number; host: string; people: string[]; notes: string; url: string }[] } | null =
      await ctx.runQuery(internal.notes.board, { token: tokenOf(url) });
    if (!board) return new Response("Not found.", { status: 404 });
    if (url.searchParams.get("json") === "1") {
      return new Response(JSON.stringify(board), {
        headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
      });
    }
    return new Response(boardPage(board.notes), {
      headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store", "X-Robots-Tag": "noindex" },
    });
  }),
});

// Instinct polls this. Same token rule. `after` is a millisecond timestamp.
http.route({
  path: "/n/feed",
  method: "GET",
  handler: httpAction(async (ctx, req) => {
    const url = new URL(req.url);
    const feed: { notes: { at: number; host: string; people: string[]; notes: string; url: string }[] } | null =
      await ctx.runQuery(internal.notes.feed, { token: tokenOf(url), after: afterOf(url) });
    if (!feed) return new Response("Not found.", { status: 404 });
    return new Response(JSON.stringify(feed), {
      headers: {
        "Content-Type": "application/json; charset=utf-8",
        "Cache-Control": "no-store",
        "Access-Control-Allow-Origin": "*",
      },
    });
  }),
});

export default http;
