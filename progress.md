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

Now: keep `npm run dev` + `livekit-server --dev` running; friends Join with a name + @handle. Cloud: `npx convex login` + deploy when you want it off this Mac. See README → "Real backend, locally (Convex)".

Next: utilities, first-launch window (`docs/first-launch.md`), ship. Supabase stack is legacy beside Convex.

Details: `what this is.md`, `docs/how-it-works.md`, `docs/plan.md`, `docs/convex.md`.
