# Progress

Doorbell turns the Mac notch into a door. Friends knock, peek, or walk in.

Done: notch shell, hallway, follow requests, LiveKit rooms, private peephole, admission into an existing room.

Done: correlated visit queue, cancellation and logout teardown, Quiet Door, media errors, screen/window picker, device controls, Keychain sessions, server permission checks, private-beta installer, automated regression suite.

Done: Convex backend (`docs/convex.md`) — email login, handle, hallway, search, requests, close friends, knock / walk-in / answer / admit with LiveKit tokens in actions; Mac app on `ConvexMobile`. 23 convex-test tests. Settings → Profile (email, name, handle, upload/remove photo via Convex storage). Cabin-chime knock tone. `scripts/install.sh` for one-command `/Applications` install with `xattr -cr`.

Now: keep `npm run dev` + `livekit-server --dev` running; friends Join with a name + @handle. Cloud: `npx convex login` + deploy when you want it off this Mac. See README → "Real backend, locally (Convex)".

Next: utilities, first-launch window (`docs/first-launch.md`), ship. Supabase stack is legacy beside Convex.

Details: `what this is.md`, `docs/how-it-works.md`, `docs/plan.md`, `docs/convex.md`.
