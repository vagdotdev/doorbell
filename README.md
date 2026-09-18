# Doorbell

Your Mac's notch is a door. Follow friends, knock on their door, or — if
they've made you a close friend — walk straight in. No links, no scheduling,
no meetings. A hostel hallway for your laptop.

Utility layer (scratch shelf, mail slot, Now Playing) keeps the app alive
solo; the social layer (knocks, walk-ins, shouts) turns on when friends join.

## Layout

- `what this is.md` — the product: what, why, how it should feel
- `docs/how-it-works.md` — the system: stack, knock/walk-in sequences, data model, privacy rules
- `docs/plan.md` — phased build plan with a check per phase
- `docs/design-language.md` — NotchNook × DynamicLake design study + tokens rationale
- `Sources/DoorbellApp/` — native SwiftUI + AppKit notch app (macOS 15+)
- `convex/` — Convex backend (accounts, graph, door events). See `docs/convex.md`.
- `research/notch-apps/` — 39 competitor screenshots + `SOURCES.md`

## Build & run

```sh
swift build   # verify compile
swift run     # run the shell (agent app: notch panel only, no dock icon)
```

### Install (one command)

Downloads the latest release, checks its checksum and signature, stages it safely, and installs to `/Applications`. A public release must be signed and notarized. See `docs/launch-audit.md` for current release blockers.
No Xcode, no clone, no compile — same idea as [Megaphone](https://github.com/Kuberwastaken/megaphone).

First launch is a window: your name and @handle, camera and mic. Then the notch takes over.

```sh
  curl -fsSL https://doorbellnotch.vercel.app/install.sh | zsh
```

Requires macOS 15+. The app bundle carries the cloud Convex URL; only the join phrase
travels in the install command.

**Owner, first ship:** in a real terminal, `scripts/deploy-cloud.sh` (Convex browser login once),
then `scripts/release.sh --publish`, then `scripts/deploy-site.sh` — or all at once: `scripts/ship.sh`.

Build from source (dev on your Mac):

```sh
DOORBELL_USE_LOCAL=1 DOORBELL_FROM_SOURCE=1 scripts/install.sh
```

```sh
xattr -cr /Applications/Doorbell.app && open /Applications/Doorbell.app
```

Dev hooks (hover can't be scripted without Accessibility rights):

```sh
DOORBELL_START_EXPANDED=1 swift run            # launch already unfurled
DOORBELL_START_MODE=settings swift run         # search | requests | settings | shelf | visit:priya
DOORBELL_SIMULATE=knock:arjun swift run        # or walkin:arjun — fires 2 s after launch
DOORBELL_MOCK_RESET=1 swift run                # fresh fake graph
DOORBELL_SNAPSHOT=/tmp/door.png swift run      # write the panel to PNG after 3.5 s and quit (DOORBELL_SNAPSHOT_DELAY)
DOORBELL_SIGNIN=vagdev@doorbell.local:doorbell   # real backend: sign in on launch (join credentials)
DOORBELL_JOIN=Dave:dave                        # name-yourself join on launch (friend-group path)
DOORBELL_AUTO_OPEN=5                           # real backend: answer the next knock after 5 s
```

Without a `.env` the app runs on the mock hallway: fake friends, fake knocks, no network.

### Real backend, locally (Convex)

For ~10–18 friends: everyone opens the app, types a name + `@handle`, and joins.
No email UI. Under the hood each person is `{handle}@doorbell.local` plus a shared
secret (`DOORBELL_JOIN_SECRET`).

**What goes where**

| Where | What |
|---|---|
| Mac `.env` (this repo, gitignored) | `DOORBELL_BACKEND=convex`, `CONVEX_URL`, optional `DOORBELL_JOIN_SECRET` |
| Convex deployment env (`npx convex env set`) | `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`, auth keys (`JWT_PRIVATE_KEY`, `JWKS`, `SITE_URL`) |
| Never in the app | LiveKit secrets — only on Convex |

```sh
npm install
npm run dev                                    # local Convex; writes CONVEX_URL to .env.local; keep it running
cp .env.secrets.example .env.secrets           # LiveKit Cloud keys + the join phrase (gitignored)
scripts/setup-local.sh                         # .env, Convex secrets, auth keys, seed, tests, bundle
open build/Doorbell.app                        # first launch: the window; join as @vagdev (or any new handle)
```

Without LiveKit Cloud, `livekit-server --dev --bind 127.0.0.1` and `ws://127.0.0.1:7880` /
`devkey` / `secret` in `.env.secrets` work the same.

Second door on the same Mac:

```sh
open -n build/Doorbell.app --env DOORBELL_PROFILE=bob
```

Join as `@priya`. Vagdev can knock on Priya.

Backend tests: `npx vitest run` and `npx tsc --noEmit`. Full audit checks: `scripts/check.sh` (includes disposable local Convex/LiveKit services).

**Cloud (when you want friends off this Mac):** in a real terminal, `scripts/deploy-cloud.sh`.
It signs in (browser, once), creates the project, deploys production, sets its secrets from
`.env.secrets`, and writes `.env.production` — commit that, and the install command above
requires Apple silicon and macOS 15 or later; oldest-OS verification is still pending. Details: `docs/convex.md`.

### Old backend, locally (Supabase — still works)

Everything runs on this Mac: Supabase in Docker (via Colima), LiveKit's dev server, and the
`door-token` function.

```sh
colima start                                   # Docker
supabase start                                 # Postgres, auth, realtime, applies supabase/migrations
livekit-server --dev --bind 127.0.0.1          # media; keep it running
cp supabase/.env.local.example supabase/.env.local
supabase functions serve door-token --env-file supabase/.env.local   # keep it running

cp .env.example .env                           # then paste ANON_KEY from `supabase status -o env`
scripts/seed-local.sh                          # alice + bob (mutual follow), carol (bob is on her close list)
scripts/bundle.sh debug                        # → build/Doorbell.app (a bundle keeps camera/mic permission)
open build/Doorbell.app
```

Sign in as `alice@test.local` / `password123`. For the other side of the door on the same Mac:

```sh
open -n build/Doorbell.app --env DOORBELL_PROFILE=bob   # separate session; sign in as bob@test.local
```

Launch through `open`, not from a shell running inside an agent or sandbox — those can't reach
the camera and LiveKit will time out publishing video.

Handing the bundle to someone: it is ad-hoc signed, not notarized, so Gatekeeper will refuse it
once downloaded. They clear the quarantine flag and it opens:

```sh
xattr -cr /Applications/Doorbell.app
```

Cloud: `supabase link` + `supabase db push` + `supabase functions deploy door-token`, then
`supabase secrets set LIVEKIT_URL=… LIVEKIT_API_KEY=… LIVEKIT_API_SECRET=…` and point `.env`
at the project.

Or open the folder in Xcode and Run (`⌘R`).

## Plan

See `docs/plan.md`. Short version:

0. ✅ Shell — real notch geometry, hover unfurl
1. ✅ Hallway on a mock backend — doors, search, requests, close friends, settings
2. ✅ Knock + peephole (both glass styles), visiting, walk-in → room, simulated locally
3. 🔨 Real media — LiveKit seats, real tracks in peephole and room (screen/window picker, devices and error states implemented; two-Mac proof pending)
4. ✅ Real backend — Convex auth, follow graph, token action, live knocks; end to end on the local deployment (Supabase stack still in repo)
5. Utilities — scratch, Now Playing, mail slot, shouts
6. Do not disturb — Focus + meeting detection, pinhole mode
7. Ship — design pass, sound, signing, updates, battery

## Reliability checks

```sh
scripts/check.sh
```

Requires Swift, Node, Docker with the local Supabase database running, and `livekit-server`.
Database tests create and drop an isolated test database. Media tests start and stop their own
loopback server on ports 17900–17902. No cloud data is changed. Hardware capture is a separate check.

## Share a private beta

Put your cloud Supabase URL and public anon/publishable key in `.env`, with
`DOORBELL_BACKEND=supabase`. Deploy both migrations and the v2 token function first.
Then run `scripts/package-beta.sh` to create `build/Doorbell-beta.zip` and its SHA-256 checksum.
The package contains the app and **Install Doorbell.command**, which copies it into
`~/Applications` and removes quarantine only from that copy.

This is an ad-hoc signed private beta. macOS may still ask your friend to approve the installer.
Camera, microphone, and screen recording permission remain required. A cloud-ready release
package and a fresh-Mac install have **not** been verified yet.

See [release evidence and remaining checks](docs/reliable-doors.md).
