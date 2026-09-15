# Progress

This file tracks what is done and what is next. Full spec: `what this is.md`. System: `docs/how-it-works.md`. Plan: `docs/plan.md`.

Doorbell turns the Mac notch into a door. Friends knock, peek, or walk in. No links, no meetings.

Done: shell, real notch geometry, hover unfurl, spec, system design, build plan, backend migration, token function, audio fade, copy pass, atmosphere (pitch black with a faint starfield and one hairline of glass — see `docs/design-language.md`, "The atmosphere").

Done, on the local stack (README → "Real backend, locally"): sign in / create account / pick handle in the shell; hallway, search, requests from Supabase; knock rings the door through `door-token`; hidden peek seat; open the door → both sides in a LiveKit room with mic and camera. `scripts/bundle.sh` builds `build/Doorbell.app` so permissions stick. `scripts/seed-local.sh` makes alice and bob.

Now: room window on real tracks (screen share, device pickers, speaking ring); walk-in clicked through in the app; a cloud Supabase project. Denel — `Denel.md`.

Next: utilities, do not disturb, ship.
