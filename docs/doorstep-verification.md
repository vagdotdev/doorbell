# Doorstep verification

- The ad-hoc beta uses a manual six-hour Quiet Door moon in the notch. The saved deadline survives restart/update and expires after sleep; explicit Accept remains available.
- The beta does not read macOS Focus. Other-app microphone/camera detection still pauses automatic behavior; provisioned builds additionally check Focus.

- Accept interrupts outgoing visits and ignores late admission responses.
- Quiet two-way preview uses independent audio gain; Listen changes playback only.
- Background microphone requires existing macOS microphone permission and readable activity status (plus Focus in provisioned builds). Automatic entry does not prompt for camera/mic access.
- Quiet Door, provisioned Focus, other active mic/camera use and an existing conversation suppress owner preview transmission. Use Quiet Door for meetings with both mic and camera off.
- Open Door Policy is the first settings card, off by default. It permits accepted friends only while available and only into your own room; strangers and pending requests receive no door access.
- Incoming chat has a soft two-note cue even with the chat open, honoring Sounds and burst throttling.
- Swift/Convex regressions and generated real duplex audio passed locally. Settings and call-window snapshots are in `.context/doorstep-qa`.
- Actual microphone input was MacBook Pro Microphone while output used EarPods. Settings now exposes the input choice. Denel-to-user hardware capture still needs a two-Mac check.
- Candidate backend deployment and app installation remain separate from these local results.


## Fresh Ring updater verification

- Fixed the always-nil second checksum check. Downloads require successful HTTPS responses and a valid matching SHA-256.
- Verified update metadata persists across app restarts; cached bytes are checked again before use. Offline checks retain a valid queued update; tampered cache is rejected.
- Only the default profile in `/Applications/Doorbell.app` can update. Preview, snapshot, test, and secondary-profile builds cannot replace the installed app.
- Manual checks work with automatic updates off. Both automatic and manual installation recheck call activity before preflight and immediately before quitting.
- The helper validates checksum, package, publisher identity, and backend compatibility before signalling readiness. It waits for the exact caller and refuses duplicate installed instances; it never kills unrelated apps.
- In-app updates require signed, notarized packages from the same publisher. An inherited unsigned-beta override cannot bypass these checks.
- Failed installation retains the download/log, uses the shared file rollback, and attempts to relaunch the restored app. Installer launch/preflight failure leaves the current app open.
- Removed the stale update trigger from `finishVisit`, which runs mid-accept before admission becomes active.
- `python3 scripts/test-update-helper.py`: 4 tests pass, including signature/identity/checksum/mount/timeout/duplicate faults, preview refusal, and transaction failure. All paths/commands are isolated stubs; no installed app was changed.
- `FreshRing.swift` passes standalone native Swift typechecking with configuration stubs. Focused Swift tests cover checksum/cache logic and injected helper handoff, including late busy, cancellation and quarantine; current suite evidence lives in `.park/`.
- Signed production upgrade, Gatekeeper, and promptless Keychain continuity still require a real Developer ID candidate. Ad-hoc-to-signed installation may ask for existing Keychain access; no auth data is intentionally reset.
