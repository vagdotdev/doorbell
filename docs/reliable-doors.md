# Reliable doors — release check

**Status: local reliability fixes implemented. Production qualification blocked on target testing.**

## What changed

- Every visit has a unique doorstep and correlated admission. Concurrent knocks queue; stale arrivals expire.
- Leaving, window close, and logout cancel pending entry and tear down media. Double acceptance cannot admit twice.
- Walk-ins respect the owner's current room and manual Quiet Door. Quiet prevents automatic owner capture.
- Server authorization checks accepted follows, exact doorstep occupancy, and the inviter's visible room seat. Hidden seats cannot publish.
- Sessions migrate from development files to Keychain. Outages show retry; they do not send existing users to handle creation.
- Actual media state drives controls. Screen/window selection, device controls, connection errors, reconnect state, and failed chat drafts are implemented.
- Public client settings are allowlisted. Release packaging rejects mock/local backends and server keys. The private-beta installer removes quarantine only from its staged Doorbell app.

## Evidence on this Mac

Run `scripts/check.sh` from the repo. It fails on the first failed check.

| Check | Result and limits |
|---|---|
| Swift build | Pass on Apple Silicon / macOS; existing AppKit deprecation warnings remain |
| Swift regressions | 17 non-media tests: visit/admission races, queue identity, expiry, Quiet Door, failed admission, window close, stale account refresh after logout, generation checks, actual Keychain migration/CRUD, enabling Quiet mid-entry, delayed old-account response using real Supabase Auth/PostgREST with stubbed HTTP |
| Actual LiveKit | 3 tests: two real SDK seats exchange data and disconnect; connect/disconnect cancellation; refused connection produces failure state. No hardware capture enabled |
| Function | Type-check plus 16 tests for hostile actors, isolation, occupancy, admission, bounds, version rejection, rate limits and revocation |
| PostgreSQL | All migrations applied in a disposable database; real authenticated-role RLS probes for hidden graph/list, immutable endpoints/handles, no self-accept, private limiter, follower-side cleanup and 30-request cap |
| Client config | 6 tests: exclude secrets, reject local/mock release, accept public keys and explicit local debug |
| Bundle | Debug app builds and has a valid ad-hoc signature. Installer/package shell syntax checked |
| Native UI | Room controls, device sheet, and screen permission-denied/retry UI inspected. UI run uses mock participants; it does not prove media capture |

Raw logs, screenshots, predictions and fingerprinted test runs are under gitignored `.park/`. The tests and this summary are tracked. Earlier failed probes are retained: too-short LiveKit membership timeout, missing Deno environment permission, the Keychain missing-item bug, and a blank default-device selector. Their causes were corrected; no failing test was relabeled as a pass.

Independent review found two additional races: enabling Quiet during automatic entry, and an old account response poisoning a newer session. Both were fixed and received passing regressions; the Quiet regression was observed failing before the fix. The reviewer found no remaining local P0/P1 issues on recheck. This does not replace the target checks below.

## Required before friends rely on it

1. **Cloud:** provision Supabase and LiveKit. Apply both migrations, deploy the v2 function, configure LiveKit server secrets, and bundle the matching client with public cloud settings. Old clients fail with an update-required response.
2. **Two Macs:** create accounts, follow/accept, knock, peek, admit, walk in, join an existing room, cancel, sign out mid-connect, revoke access. Repeat across separate networks.
3. **Capture:** grant mic/camera/screen permissions. Confirm the selected window alone appears remotely; stop via app and macOS; switch devices; deny permissions; unplug a device; disconnect/reconnect networking; verify capture ends on leave/logout.
4. **Install:** package with `scripts/package-beta.sh`. Download the ZIP on a fresh Mac, approve the installer if required, install, launch, grant permissions, relaunch, and replace with a newer build. This has not been exercised on another Mac.

The current workspace has local service configuration, not a deployed cloud release. Doorbell's Screen Recording permission was unavailable in the UI probe. No second physical Mac was available to this session. These are explicit unverified conditions, not passing tests.

## Login and install decisions

Current onboarding remains email/password plus a chosen handle. A random Supabase UUID is internal; changing to Convex would not improve the visible name. Supabase can create [anonymous accounts](https://supabase.com/docs/guides/auth/auth-anonymous), so a handle-only first run is possible, with Google linking later for recovery. That flow is not implemented here.

The installer follows the requested private-beta approach: copy the app, verify its ad-hoc signature, remove the copied app's quarantine, launch. This does not guarantee a frictionless download: [macOS can still require approval for unnotarized software](https://support.apple.com/en-gb/102445). Developer ID is optional for this beta path; trusted distribution and automatic updates remain later work.

No cloud deployment, migration of the existing app database, commit, push, or release publication was performed.
