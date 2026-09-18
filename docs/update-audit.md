# Update audit

## Verdict

- User chose the existing xattr/ad-hoc private beta. Apple Developer enrollment is not required for that chosen distribution.
- Current public release: `v2026.09.18-2213-a3f259a`; app reports `0.1`, is ad-hoc signed, has no updater helper, and fails Gatekeeper assessment.
- Existing public clients have no updater helper and need one manual installation of the new beta before automatic updates can work.
- No production deployment, publication, or replacement of the running app was performed.
- The user confirmed the latest source, including shared-password Join, is intentional. Verification uses that implementation; the earlier overlapping-edit pause is resolved.

## Fixed

- Valid downloads no longer fail a second, empty checksum comparison.
- Only the installed main-profile app can update; preview/test copies cannot replace it.
- Calls, knocks, previews, Accept, media teardown, sign-out and policy saves block replacement.
- Checksum, exact bundle release tag and unchanged account database are checked before quitting. Official ad-hoc beta updates preserve their distribution mode; signed installations retain same-publisher and Gatekeeper checks.
- Apple bundle versions remain numeric; `DoorbellReleaseTag` stores the update identity. See [Apple version format](https://developer.apple.com/help/glossary/version-number/) and [build format](https://developer.apple.com/help/glossary/build-string/).
- Verified downloads survive restart; corrupt cache and unsuccessful HTTP responses are rejected.
- Installer waits for the exact caller. No global process kill. Beta quarantine removal is limited to the staged app; installers preserve its existing signature instead of re-signing it.
- Native atomic bundle exchange keeps a complete app at its path; kernel locks release after crashes.
- Failed launch restores the old bundle and attempts to reopen it. Failed candidate tag/digest is quarantined across launches until explicit retry or a different release.
- Legacy session migration preserves missing-marker and same-deployment sessions; updates leave Keychain, preferences and backend friend data in place.
- Settings shows update state, retry, version, location/profile restrictions and signing recovery instructions.
- Packaged startup exposed an Apple entitlement rejection that unit tests missed. Ad-hoc builds omit restricted Focus access and use the six-hour manual Quiet Door moon; signed builds require a valid provisioning profile.

## Verification

- `.park/` records current fingerprinted checks and independent review; earlier broad audit is archived in `.context/launch-audit/park-before-updater`.
- Swift suite: update download/cache/version/handoff/cancellation/quarantine; legacy session migration; media and Accept regressions.
- Installer faults: copy, validation, exchange, launch, wrong publisher, wrong backend, beta source restrictions, signed-to-ad-hoc downgrade and SIGKILL.
- Disposable Convex/LiveKit: two-way decoded audio, admission/revocation, account and friend graph preservation.
- Separate seed/restore test processes verify passwordless saved-session recovery and identical profile, friends, close friends and Open Door Policy.
- Release candidate: `build/doorstep-candidate/Doorbell.dmg`; bundle metadata, signatures, isolated install and fresh-profile boot checks.
- These are local checks. Stubbed installer faults do not prove Apple signing, physical media devices or remote user upgrades.

## Remaining beta checks

- Verify the real old-beta → new-beta upgrade on supported Macs: existing login/friends, Keychain access, camera/mic permissions, successful restart and rollback.
- Verify macOS 15: current Convex library objects warn they were built for macOS 26.2.
- Complete two-Mac media checks from `docs/launch-audit.md`; Denel's hardware-specific microphone report has not been reproduced.
- Deploy the matching backend and publish the reviewed beta only as a coordinated release.
- Personal-password login is deferred by the user; migration plan is in `passwordlogin.md`.

## Scope of guarantees

- SIGKILL testing proves a complete app remains at the destination and the old bundle is retained in staging. It does not prove automatic recovery after power loss or a successful first boot of arbitrary code.
- A same-backend update preserves account data. Ad-hoc binary changes can still prompt for Keychain or microphone access; xattr clears quarantine, not privacy permissions. Deliberate sign-out, revoked credentials and backend migrations are separate cases.
- Public clients without an updater cannot fetch this fix themselves.
- Ad-hoc builds cannot use Apple's restricted Focus entitlement. The notch moon pauses automatic doorstep audio/walk-ins for six hours, persisted across updates; manual Accept works. The beta still checks other-app mic/camera use. A future provisioned build can add automatic system Focus checks. [Apple capability requirements](https://developer.apple.com/documentation/UserNotifications/handling-communication-notifications-and-focus-status-updates).
