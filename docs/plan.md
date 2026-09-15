# Build plan

Goal: a notch app two to five friends use instead of Meet. Each phase ends in something that runs and can be screenshotted or exercised. Nothing moves to the next phase until the check passes.

Legend: ✅ done · 🔨 in progress · ⬜ not started

Current reliability status and release gates: [reliable-doors.md](reliable-doors.md). Earlier checks below describe their original phase, not proof of the current cloud release.

## Phase 0 — Shell ✅

Black shell hugging the real notch. Hover unfurls it on a spring; window resizes so menu-bar clicks work when closed.

Check: `swift run`, hover the notch. Window bounds match notch ± bleed when closed, 560×220 when open.

## Phase 1 — Hallway on a mock backend ✅

The social layer's UI, with no network.

- `DoorbellBackend` protocol: hallway snapshot, search, request, accept, ignore, unfollow, close-friend toggle, visit, events. `MockBackend` implements it in memory with ten fake people; persists to `UserDefaults`; fake people accept requests after 3 s.
- Expanded shell = the hallway: a row of doors (avatar + first name), yours first with a request badge, a dashed *Find* door last. Top row: `Hallway` / `Shelf` pill tabs left of the physical notch, search + gear right of it.
- Search: `@handle` field, prefix results, *Request* / Requested / Following.
- Requests: *Let them* / *Ignore*.
- Per-door context menu: *Close friend* toggle (only if they follow you), *Unfollow*, and in debug builds *Simulate: they knock / walk in*.
- Settings: peephole style (Rectangle / Realistic), sounds. Launch-at-login waits for the .app bundle.

Check: every screen screenshotted (`DOORBELL_START_EXPANDED=1`, `DOORBELL_START_MODE=…`). Still to do by hand: hover in/out, type in search, right-click a door.

## Phase 2 — Knock and walk-in, simulated ✅ (audio pending)

The door moments, still no network. The local camera stands in for the visitor.

- Knock → dip-and-settle bounce + placeholder knock sound → door shell (372×164 eyehole / 436×164 rectangle). Visitor video in the glass, name, *Listen* chip, one green *Open door*, small ×.
- Open door → room window.
- Walk-in → room window directly (the "notch swings wide" moment is Phase 7 motion work).
- Visiting → own camera in the glass, "At Priya's door", *Leave*, breathing amber dots, 30 s timeout.
- Room window: black, floating traffic lights, adaptive tile grid capped at 16:9, name chips, mic/cam/share/chat/leave strip, chat drawer.
- Dev hooks: `DOORBELL_SIMULATE=knock:arjun|walkin:arjun`, `DOORBELL_START_MODE=visit:priya`.

Check: screenshots of both glass styles, visiting, and the room — done. Not yet: door-volume audio (needs a real remote track, Phase 3), real knock sound (Phase 7).

Learned: an `NSHostingView` used directly as a window's `contentView` takes over window sizing and loops against our own `setFrame` until AppKit throws. Always nest it (`fillingContainer()`).

## Phase 3 — Real media (LiveKit) 🔨 core done

Swap the mock's fake video for LiveKit. Tokens come from `door-token`; nothing is minted on the client.

- ✅ `client-sdk-swift` via SPM. `MediaSession` wraps `Room`: connect, publish mic/cam, remote tracks, speaking, data messages, per-track volume driven by `IncomingAudio` (door volume → full).
- ✅ Two seats per person: `media` (the room I'm in) and `peep` (my hidden seat behind my own door while someone knocks — no mic, no camera, invisible to the knocker).
- ✅ Real tracks in the peephole, the visiting glass, and the room tiles. The mock's `CameraPreview` steps aside when LiveKit owns the camera.
- ✅ Device pickers, screen/window selection, connection/error states, active-speaker ring implemented. Actual capture and device switching still need two-Mac verification; per-person connection quality remains planned.

Check: two accounts on one Mac (`DOORBELL_PROFILE=alice` / `bob`) against the local stack: knock → hidden peek → open → both publish mic + camera in `door:bob` — passes. Still to do: 10 minutes on two Macs with screen share and chat.

Learned: launched from an agent's sandboxed shell, the camera silently never delivers frames (LiveKit reports "Timed out" on publish). `open build/Doorbell.app` — a real launch — is fine. Test media through `open`, not a child process.

## Phase 4 — Real backend (Supabase) 🔨 working locally

Replace the mock with the network.

- ✅ Migration `20260915000000_graph.sql`: `profiles`, `follows`, `close_friends`, triggers, RLS, `search_profiles` RPC, private door channels on `realtime.messages`. Only the door's owner may read their channel; nobody but the server writes to it.
- ✅ Edge Function `door-token`: mints seats (`visit` / `answer` / `admit` / `leave`) and rings the door itself with the service role after checking the graph. Clients never broadcast — a follower policy on `realtime.messages` would have let followers *read* the channel too.
- ✅ `SupabaseBackend` implements `DoorbellBackend`: email + password auth, per-profile Keychain session, hallway from `follows` with embedded profiles, search RPC, one private channel per door. Mock stays for development (`DOORBELL_BACKEND` unset).
- ✅ Onboarding in the shell: sign in → pick handle → hallway. Sign out from Settings.
- ⬜ Sign in with Apple. ⬜ A cloud project (the first one was removed; everything runs locally for now — see README).

Check: two accounts, follow, accept, knock, open door — passes on the local stack. Walk-in (close friend) minted correctly by the function; not yet clicked through in the app. Grep the schema and function for anything that could record presence or a knock — there must be nothing.

## Phase 5 — Utilities ⬜

Scratch shelf (drag in / park / drag out, local). Now Playing (verify the current macOS media API story first). Mail slot and shouts over Storage.

Check: app is useful with zero friends for a day.

## Phase 6 — Do not disturb 🔨 manual Quiet Door implemented

Focus detection, camera/mic-in-use detection, pinhole mode. Nothing published.

Check: start a Meet in the browser, get knocked — pinhole only, silent. Turn on Focus — same.

## Phase 6½ — First launch and the app window ⬜

A real window for the first ten seconds (animation, sign in, handle, permissions) and, after that, the one place settings live: two columns — Privacy (Close Friends first), Audio, Window, Settings. Sign in with Apple as the default, Google second, magic link under them. Requests and Settings move out of the notch board. Spec: `docs/first-launch.md`.

Check: a stranger opens the DMG, understands the app from the animation, signs in with Apple, picks a handle, grants camera and mic, and is at the hallway — without reading anything longer than a sentence.

## Phase 7 — Ship-quality ⬜

Design pass on every surface: illustration for empty states, sound design (knock, creak, chime), warm room accents, motion tuning. Developer ID signing + notarization, Sparkle updates, launch at login, crash reporting. Battery: idle draw measured and equal to a menu-bar clock.

Check: someone who isn't us installs it from a DMG and gets to a working knock without help.

## Not in the plan

Scheduling. Recordings. Breakout rooms. Grids beyond five. Mobile. Windows. Anything enterprise.
