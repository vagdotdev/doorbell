# Convex

Doorbell's backend is Convex. The Mac app and LiveKit stay. Supabase stays in the
repo as the old local stack; nothing new goes there.

## What is installed

| Piece | What it is |
|---|---|
| **`convex/`** | The backend. Schema, queries, mutations, actions. Pushed by `npm run dev`. |
| **`@convex-dev/auth` Password** | Email + password on the Convex deployment. The Mac app calls its HTTP `auth:signIn` action through `ConvexPasswordAuth` (`Sources/DoorbellApp/ConvexAuth.swift`), which stores the refresh token on disk and serializes refreshes. |
| **`ConvexMobile`** | Official Swift client. `ConvexBackend` (`Sources/DoorbellApp/ConvexBackend.swift`) subscribes to `profiles:account`, `graph:hallway`, `doors:events`. |
| **`livekit-server-sdk`** | Runs inside Convex actions (`convex/doorActions.ts`) to mint LiveKit tokens. Secrets live only on the deployment. |
| **`convex-test` + Vitest** | `npx vitest run`. 22 tests over auth, graph rules and door events. No deployment needed. |

Not added: Convex Presence (we never publish online), a second database, Stripe, hosting,
OAuth. Sign in with Apple waits for the first-launch spec and would go through Clerk or Auth0.

## How the pieces sit

```
Mac app (Swift)
  → Convex Auth HTTP   (email + password → JWT + refresh token)
  → Convex WebSocket   (profiles, follows, close friends, door events)
  → Convex actions     (visit / leave / answer / admit → LiveKit token)
  → LiveKit            (camera and mic)
```

## Files

- `schema.ts` — `profiles`, `follows`, `closeFriends`, `doorEvents`, plus Convex Auth's tables.
- `auth.ts`, `auth.config.ts`, `http.ts` — Convex Auth, Password provider, JWKS routes.
- `lib.ts` — `requireProfile`, `follows`, `closeFriendEdge`. Every rule from
  `docs/how-it-works.md` is checked here, in functions, instead of RLS.
- `profiles.ts` — `account`, `claimHandle`, `search`, `update`, `generateUploadUrl`, `setAvatar`, `clearAvatar`.
- `graph.ts` — `hallway`, `request`, `accept`, `ignore`, `unfollow`, `setCloseFriend`.
- `doors.ts` — `events` (the owner's subscription), `ack`, and the internal ring / sweep.
- `doorActions.ts` — `visit`, `leave`, `answer`, `admit`. LiveKit config is checked before
  anything is written, so a misconfigured deployment never rings a door it can't seat.
- `seed.ts` + `scripts/seed-convex.sh` — alice, bob, carol.

## A knock

`visit` decides knock vs walk-in from the graph, inserts one `doorEvents` row for the owner,
schedules a sweep 90 s out, and mints the knocker's doorstep seat. The owner's app is
subscribed to `doors:events`; on delivery it rings and calls `doors:ack`, which deletes the
row. Acks are retried for any row still present, so a restart cannot re-ring an old knock.
`answer` and `admit` put both sides in the room; `admit` delivers the guest's grant as an
`admitted` row the same way.

## Sessions

Convex Auth JWTs are short-lived; the refresh token is the session. `ConvexPasswordAuth`
keeps one refresh in flight at a time (a second concurrent refresh would burn the same
token) and signals the client to drop its token when the server rejects a refresh, so a dead
session lands on the sign-in screen instead of an error loop. Both paths were probed live;
see "Evidence".

## Commands

```sh
npm run dev                          # local anonymous deployment; writes .env.local
npm run dashboard                    # data + logs UI
node scripts/convex-auth-keys.mjs    # JWT_PRIVATE_KEY, JWKS, SITE_URL (skips if present)
npx convex env set LIVEKIT_URL=… LIVEKIT_API_KEY=… LIVEKIT_API_SECRET=…
scripts/seed-convex.sh
npx vitest run && npx tsc --noEmit
```

Production: `npx convex login` (a real terminal, opens the browser), `npx convex deploy`,
then the two env steps above with `--prod`. The Mac app reads `CONVEX_URL` from `.env` or
`.env.local`; `scripts/bundle.sh` copies both into the bundle.

## Evidence

Checked on the local deployment with two app instances and HTTP-driven knocks:

- Misconfigured LiveKit → `visit` fails, `doorEvents` stays empty (was a ghost knock; fixed).
- A knock is acked over the authenticated WebSocket within 5 s; no row survives to the sweep.
- A leftover row inside the sweep window does not re-ring after an app restart (fixed).
- A bogus refresh token on disk → signed out, session file removed, no error loop (fixed).
- With the JWT lifetime forced to 20 s, an app running 70 s received three knocks across two
  token refreshes with no errors (refresh serialization; fixed).

## Agent setup

From https://www.convex.dev/agent-setup.md: Convex skills under `~/.agents/skills/` and this
repo's `.agents/`, plus the `convex` MCP server in `~/.cursor/mcp.json`. Project AI files live
in `AGENTS.md` and `convex/_generated/ai/guidelines.md`.
