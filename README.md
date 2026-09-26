# Doorbell

Your Mac's notch is a door. Follow a friend, knock, or walk straight in if they've made you a close friend. No links, no scheduling, no meetings.

Search an @handle and send a request. Once they accept, a knock puts your face in their notch, quiet, like someone standing outside. They open the door, or they leave it shut. Close friends skip the knock. That list stays private.

The room is a call window: faces, mic, camera, screen share, and chat. Nothing in it is recorded.

## Install

Apple silicon, macOS 15 or later. This downloads the latest release, checks the checksum and signature, and installs to `/Applications`.

```sh
curl -fsSL https://doorbellnotch.vercel.app/install.sh | zsh
```

First launch is a window: your name, a permanent @handle, then camera and microphone. After that, Doorbell lives in the notch.

If macOS blocks a copy you already have:

```sh
xattr -cr /Applications/Doorbell.app && open /Applications/Doorbell.app
```

## Run from source

```sh
swift build
swift run
```

`swift run` is the notch only, with no Dock icon. With no `.env`, it uses a mock hallway: fake friends, fake knocks, no network.

To build a local app and install it:

```sh
DOORBELL_USE_LOCAL=1 DOORBELL_FROM_SOURCE=1 scripts/install.sh
```

Hover needs Accessibility permission. These variables open the panel for you:

| Variable | Effect |
|---|---|
| `DOORBELL_START_EXPANDED=1` | Open on launch |
| `DOORBELL_START_MODE=settings` | `search`, `requests`, `settings`, `shelf`, or `visit:priya` |
| `DOORBELL_SIMULATE=knock:arjun` | A knock, or `walkin:arjun`, two seconds after launch |
| `DOORBELL_MOCK_RESET=1` | A fresh fake friend graph |
| `DOORBELL_SNAPSHOT=/tmp/door.png` | Save the panel as a PNG after 3.5s, then quit |
| `DOORBELL_SIGNIN=name@doorbell.local:secret` | Sign in on launch |
| `DOORBELL_JOIN=Dave:dave` | Join with a name and @handle |
| `DOORBELL_AUTO_OPEN=5` | Answer the next knock after five seconds |

## Local backend

Friends join with a name and an @handle. Each account is `{handle}@doorbell.local` plus a shared secret, `DOORBELL_JOIN_SECRET`.

| Where | Holds |
|---|---|
| Mac `.env` (gitignored) | `DOORBELL_BACKEND=convex`, `CONVEX_URL`, optional `DOORBELL_JOIN_SECRET` |
| Convex deployment | LiveKit URL and keys, plus `JWT_PRIVATE_KEY`, `JWKS`, and `SITE_URL` |
| The app | No LiveKit secrets |

```sh
npm install
npm run dev
cp .env.secrets.example .env.secrets
scripts/setup-local.sh
open build/Doorbell.app
```

Leave `npm run dev` running. It writes `CONVEX_URL` into `.env.local`. Put LiveKit keys in `.env.secrets` before setup.

Without LiveKit Cloud, run `livekit-server --dev --bind 127.0.0.1` and use `ws://127.0.0.1:7880`, `devkey`, and `secret` in `.env.secrets`.

A second door on the same Mac:

```sh
open -n build/Doorbell.app --env DOORBELL_PROFILE=bob
```

Join that copy as `@priya`. The first account can knock on Priya. Launch with `open` so the camera is available.

Tests: `npx vitest run` and `npx tsc --noEmit`. `scripts/check.sh` runs the full suite on disposable local Convex and LiveKit processes, and leaves cloud data alone.

To reach friends on other Macs, run `scripts/deploy-cloud.sh`. It signs in once, deploys production, copies secrets from `.env.secrets`, and writes `.env.production`. Commit that file. Details are in [`docs/convex.md`](docs/convex.md).

To publish a release, run `scripts/ship.sh` in a real terminal. Convex opens a browser once. The script deploys the backend, publishes the DMG, and updates the site. Blockers are in [`docs/launch-audit.md`](docs/launch-audit.md).

## Supabase

Convex is the current backend. The Supabase stack still runs locally.

```sh
colima start
supabase start
livekit-server --dev --bind 127.0.0.1
cp supabase/.env.local.example supabase/.env.local
supabase functions serve door-token --env-file supabase/.env.local

cp .env.example .env   # paste ANON_KEY from `supabase status -o env`
scripts/seed-local.sh
scripts/bundle.sh debug
open build/Doorbell.app
```

Sign in as `alice@test.local` / `password123`. For the other side of the door:

```sh
open -n build/Doorbell.app --env DOORBELL_PROFILE=bob
```

For a hosted project: `supabase link`, `supabase db push`, `supabase functions deploy door-token`, then `supabase secrets set` for `LIVEKIT_URL`, `LIVEKIT_API_KEY`, and `LIVEKIT_API_SECRET`.

## Private beta

`scripts/package-beta.sh` writes `build/Doorbell-beta.zip` and its SHA-256 checksum. The zip contains the app and **Install Doorbell.command**, which copies Doorbell into `~/Applications` and clears quarantine on that copy only.

The beta is ad-hoc signed, so macOS may still ask for approval. Camera, microphone, and screen recording stay required. See [`docs/reliable-doors.md`](docs/reliable-doors.md).

## In the repo

- [`what this is.md`](what%20this%20is.md) — what it is, and how it should feel
- [`progress.md`](progress.md) — what's done, and what's next
- [`docs/how-it-works.md`](docs/how-it-works.md) — knock, walk-in, and privacy
- [`docs/convex.md`](docs/convex.md) — the Convex backend
- [`docs/plan.md`](docs/plan.md) — the build plan
- [`docs/design-language.md`](docs/design-language.md) — visual language
- `Sources/DoorbellApp/` — the SwiftUI and AppKit notch app
- `convex/` — accounts, the friend graph, and door events
