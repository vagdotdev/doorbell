# Hey Denel

This file is for you.

You already know what Doorbell looks like. This is the short version of how it works, how we keep score, and how to play with it on this Mac. Then you finish it and we ship.

## What this file is

`Denel.md` is a handoff. It is not the spec.

- Product (what it should feel like) → `what this is.md`
- System (how knocks, rooms, and tokens actually work) → `docs/how-it-works.md`
- Build order (phases, checks) → `docs/plan.md`
- What's done vs next, in a few lines → `progress.md`

Read `progress.md` first, every time. Then this file. Dive into the others only when you need the why or the how.

## What this is, in one breath

The Mac notch is a door. Friends follow you, knock, peek through a peephole, or — if they're close friends — walk straight in. No links. No calendar. No meetings.

Idle, it is a dark pill on the notch. Hover and it drops open into a hallway of doors. Click a door: that's a knock. Their notch bounces, they see your face small in the glass, your voice is quiet like you're outside. They hit the green button, or they don't. Silence is always deniable.

## How `progress.md` works

It is a tiny status board. Agents (and you) read it first.

Three lists only:

- **Done** — already real
- **Now** — what the current person is touching
- **Next** — after that

Rules, so it stays useful:

1. Move items between those three lists. Don't write essays in it.
2. A few words per change.
3. Never let it grow. Details live in the other markdown files, not here.
4. Update it when something actually moves (a phase finishes, the current job changes). Don't update it for typos.

When you pick up work, put it in **Now**. When it works, move it to **Done**. That's how we don't step on each other.

Right now: shell, hallway mock, knock/walk-in (simulated), backend schema + token function are done. Current leftover on the door is copy + audio fade. After that: real LiveKit media, real backend in the app, utilities, do not disturb, ship.

## Run this on the Mac (the demo)

From the repo root. First time will take a minute to compile.

```sh
cd /Users/vagdev/Documents/Git/Doorbell
swift build
```

Then run the tour. Each command replaces the last. Look at the notch at the top of the screen. There is no dock icon.

```sh
# 1. Idle door — just the notch pill
DOORBELL_MOCK_RESET=1 .build/debug/DoorbellApp

# 2. Hallway open (hover, scripted)
DOORBELL_MOCK_RESET=1 DOORBELL_START_EXPANDED=1 .build/debug/DoorbellApp

# 3. Search
DOORBELL_MOCK_RESET=1 DOORBELL_START_MODE=search .build/debug/DoorbellApp

# 4. Follow requests
DOORBELL_MOCK_RESET=1 DOORBELL_START_MODE=requests .build/debug/DoorbellApp

# 5. Settings (peephole glass, sounds)
DOORBELL_MOCK_RESET=1 DOORBELL_START_MODE=settings .build/debug/DoorbellApp

# 6. You at Priya's door (visiting / porch light)
DOORBELL_MOCK_RESET=1 DOORBELL_START_MODE=visit:priya .build/debug/DoorbellApp

# 7. Arjun knocks on you — bounce, peephole, green Open door
DOORBELL_MOCK_RESET=1 DOORBELL_SIMULATE=knock:arjun .build/debug/DoorbellApp

# 8. Arjun walks in (he's a close friend) — room window
DOORBELL_MOCK_RESET=1 DOORBELL_SIMULATE=walkin:arjun .build/debug/DoorbellApp
```

Stop a run with `Ctrl-C` in that terminal, or:

```sh
pkill -f DoorbellApp
```

Fake people: you are `vagdev`. You already follow Arjun, Priya, Rohan. Arjun is a close friend (walk-in). Ananya has a pending request on you. Kabir is a request you sent. Hover still needs a real mouse on the notch; the env vars above skip that.

One-shot tour (same thing, ~12s per beat, then leaves the hallway open):

```sh
./scripts/denel-demo.sh
```

That's what we ran on this Mac so you can see every state without hunting.

Dev extras: `DOORBELL_START_MODE=shelf` (utilities, empty for now). Right-click a door in a debug build to simulate a knock or walk-in by hand.

## What's upcoming (the rest of the project)

In order. Each phase in `docs/plan.md` has a check. Don't skip the check.

1. **Finish the door** — copy (the words on the peephole / visiting) and audio fade (voice through the door is quiet, *Listen* brings it up). Mock hallway stays until media is real.
2. **Real media (LiveKit)** — swap fake video for real rooms. Tiles, chat, screen share. Two people in a real room for 10 minutes is the check.
3. **Real backend in the app** — server is mostly there (Supabase graph + `door-token` function). Wire sign-in, follow, knock signals. Mock stays for solo work.
4. **Utilities** — scratch shelf, Now Playing, mail slot, shouts. So the app is useful with zero friends.
5. **Do not disturb** — Focus + "already in a meeting" → tiny silent pinhole. Visitor never knows.
6. **Ship** — design pass, real knock/creak sounds, signing, updates, idle battery like a menu-bar clock.

Not in scope: scheduling, recording, huge grids, mobile, Windows, enterprise.

## LiveKit — you already know this

This is the same LiveKit API as Jini.

You have already shipped video with it. Doorbell is not a new kind of calling. It is a door UI on top of rooms you already understand: join a room, publish cam/mic, subscribe, leave. The Swift SDK is already in `Package.swift`. `MediaSession.swift` already wraps `Room`.

The free Cloud tier is generous: no card, hard-capped, about 5,000 participant-minutes a month. That's roughly 40 hours of two-person rooms before anyone pays. Plenty to build and hang out.

What you do:

1. [livekit.cloud](https://cloud.livekit.io) → new project → Settings → Keys.
2. Copy `.env.example` to `.env` and fill `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`.
3. Same three go on the server: `supabase secrets set LIVEKIT_URL=... LIVEKIT_API_KEY=... LIVEKIT_API_SECRET=...`

That's enough to get a barebones video-calling app talking. Start there. One room, two people, camera on. Once that feels boring, put it behind the door.

The product work is the feel: hidden peek, door-volume audio, no presence, no receipts. LiveKit already carries the bits. You've done the hard part of "can I make video work" on Jini. This is you doing it on a Mac notch, which is cooler.

## How to work in here

```sh
swift build          # compile
swift run            # run (mock backend, no keys needed)
```

Need a second account on one Mac later: `DOORBELL_PROFILE=b`. Real graph: `DOORBELL_BACKEND=supabase` once `.env` is filled.

Code lives in `Sources/DoorbellApp/`. Social stuff goes through `DoorbellBackend`. `MockBackend` is the fake hallway. Don't break the privacy rules in `docs/how-it-works.md` (no online dots, no knock log, peek is invisible to the knocker).

When you start: put the job in `progress.md` **Now**. When it works: move it to **Done**. Keep that file small.

We're going to ship this.
