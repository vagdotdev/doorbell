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
- `research/notch-apps/` — 39 competitor screenshots + `SOURCES.md`

## Build & run

```sh
swift build   # verify compile
swift run     # run the shell (agent app: notch panel only, no dock icon)
```

Dev hooks (hover can't be scripted without Accessibility rights):

```sh
DOORBELL_START_EXPANDED=1 swift run            # launch already unfurled
DOORBELL_START_MODE=settings swift run         # search | requests | settings | shelf | visit:priya
DOORBELL_SIMULATE=knock:arjun swift run        # or walkin:arjun — fires 2 s after launch
DOORBELL_MOCK_RESET=1 swift run                # fresh fake graph
DOORBELL_SNAPSHOT=/tmp/door.png swift run      # write the panel to PNG after 3.5 s and quit (DOORBELL_SNAPSHOT_DELAY)
DOORBELL_SIGNIN=alice@test.local:password123   # real backend: sign in on launch
DOORBELL_AUTO_OPEN=5                           # real backend: answer the next knock after 5 s
```

Without a `.env` the app runs on the mock hallway: fake friends, fake knocks, no network.

### Real backend, locally

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
4. 🔨 Real backend — Supabase auth, follow graph, token function, realtime knocks; end to end on the local stack
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
