# Progress

Doorbell turns the Mac notch into a door. Friends knock, peek, or walk in.

Done: notch shell, hallway, follow requests, LiveKit rooms, private peephole, admission into an existing room.

Done: correlated visit queue, cancellation and logout teardown, Quiet Door, media errors, screen/window picker, device controls, Keychain sessions, server permission checks, private-beta installer, automated regression suite.

Done: Convex backend (`docs/convex.md`) — email login, handle, hallway, search, requests, close friends, knock / walk-in / answer / admit with LiveKit tokens in actions; Mac app on `ConvexMobile`. 23 convex-test tests. Settings → Profile (email, name, handle, upload/remove photo via Convex storage). Cabin-chime knock tone. `scripts/install.sh` for one-command `/Applications` install with `xattr -cr`.

Done: home tab is the Building (building.2 icon). First board-open plays a splash:
friends surface as peepholes through the doorstep dome into a plume while "Doorbell /
Knock, knock." focuses, then glide into their cards via shared-geometry handoff.
Click skips; Reduce Motion fades. Join is name + @handle, no email UI.

Done: park audit on this surface — 23 convex-test, 23 Swift tests (incl. Join-failure
copy), tsc + build clean; every failure string rendered and graded; one ghost-found
("spontaneous" mode jumps) traced to live user clicks via an input spy, then removed.

Done: top row is minimal — Doorbell home on the left, search + gear on the right.
Shelf lives as a diamond in the board's bottom-right corner (toggles what's inside
your door, with a crossfade). Close-friend ring is green; the walk-ins menu reads
"Friends knock. Close friends just get in." Glass setting previews the shapes.

Done: name changes capped at 2 per rolling 14 days (server + Settings hint). Selfie video mirrored on macOS. `convex-api-keys` component installed. LiveKit Cloud on Convex (`doorbell-t59irnxk.livekit.cloud`). `scripts/setup-local.sh` wires `.env` + `.env.secrets` → Convex; auth-gated `apiKeyMgmt`.

Done: a real app. App icon (the approved pinhole from `branding/macos-app-icon` → `Assets/AppIcon.icns`; Finder, the Dock during first launch, permission prompts). First launch is a window (`Onboarding/`): peephole plume → name + permanent @handle → camera/mic → Done; the notch never hosts the form. Board replays the splash each open; friends sort left→right by missed/recent knocks. Shelf + requests icons bottom-right; "by vagdev" footer. Live mode skips bundled demo portraits. `scripts/update.sh` pull + reinstall.

Done: occupied knock is Add to this call / End this call (`docs/bring-in-plan.md`).

Done: stickers in room chat — animated Noto emoji roll, your own stickers sent peer-to-peer, system emoji palette.

Now: Fresh Ring auto-updates on launch. Publish a new DMG so friends get the path-free binary.
Done: app loads Sounds/Portraits from the installed bundle (no SwiftPM /Users/…/.build path); strip Xcode rpaths at pack time.

Next: utilities, app window for settings (`docs/first-launch.md` §3), ship. Supabase stack is legacy beside Convex.

Details: `what this is.md`, `docs/how-it-works.md`, `docs/plan.md`, `docs/convex.md`.
