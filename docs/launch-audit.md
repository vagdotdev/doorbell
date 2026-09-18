# Launch audit — September 18, 2026

**Private-beta audit.** The user chose handle-only login and xattr/ad-hoc distribution. Local checks do not prove every user's hardware or macOS version. No app/backend code was published by this audit; the authorized production media configuration repair is recorded below.

## Fixed locally

- Convex now preserves the same visit UUID through knock, departure and admission.
- Every visitor waits in a separate room. Close friends receive room access only after the owner app approves. Automatic admission rechecks close-friend permission.
- Admission checks both participants, friendship, cancellation and expiry after external requests. New conversations use new room names.
- Convex chat uses the transport; disconnected calls do not display fake participants.
- Convex credentials move to Keychain. A late refresh cannot restore a logged-out session. Local logout does not wait for network revocation.
- Logging out during a visit no longer waits for the remote cancellation request. A regression test holds that request open until after local logout.
- Avatar uploads establish ownership; attaching another person's storage ID and revoking another person's API key are refused.
- Installer validates and stages before replacement, restores the previous app after failure, verifies checksums, and checks the actual installed executable.
- Official beta installer verifies signatures/checksums and clears quarantine on the staged ad-hoc app. Signed upgrades retain same-publisher and Gatekeeper checks. Web installer is generated from the tested helper.
- Publishing requires a clean source tree and verified bundle integrity; the signed distribution additionally requires Gatekeeper approval. The user chose the private-beta distribution.
- Signing includes the camera and microphone resource entitlements required for hardened runtime. See [Apple’s audio-input documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input).
- Repeat packaging works. Bundles exclude `.env.local` and server secrets. Release URLs require public HTTPS. Installed apps ignore working-directory `.env` files.
- Dock reopen, an already-restored account during onboarding, permission-status refresh and visible graph-operation errors are handled.

## Release blockers

- **Deferred identity:** the user explicitly kept handle-only Join for this beta. Its shared password does not prove account ownership. Personal passwords and existing-account migration are planned in `passwordlogin.md`, not implemented now.
- **Chosen distribution:** xattr/ad-hoc beta is intentional. The public site currently also re-signs downloaded apps; the local installer repair preserves signatures and adds checksum/rollback checks. Developer ID enrollment is not a beta gate.
- **Oldest OS:** advertised minimum is Apple silicon macOS 15. The Convex 0.8.1 static library emits linker warnings that its objects were built for macOS 26.2. A successful build/boot on this Mac does not prove macOS 15 support. Test on a clean macOS 15 Mac or rebuild/fix the dependency before claiming compatibility.
- **Two actual Macs:** verify remote camera/mic, screen sharing, denied permissions, Bluetooth devices, sleep/wake, network switching, missed knocks, logout and update/relaunch. Loopback data transport is insufficient proof of camera capture or NAT traversal.
- **Production rollout:** the new app requires the new visit protocol and avatar functions. Deploy and verify the reviewed backend and matching app together, with an upgrade path for older clients. Production capacity/quotas and a 100-user cloud load test remain unverified.
- **Visual QA:** native automation failed with `Sky Computer Use native pipe startup failed`. Process boot is checked separately; onboarding clicks and Dock reopen still need real UI verification.

## Evidence

- Initial unit suites were green despite broken Convex admissions and impersonation. Green counts alone are not launch approval.
- Downloaded release: `v2026.09.18-2149-a3f259a`; SHA-256 `6b6edffb8414ed9749e3d2d7b00bf095ee93598ee9253e0aa8dd62db059cd268` matched GitHub's asset digest.
- Read-only production queries for account, graph and events returned signed-out/empty responses to an anonymous caller.
- `scripts/check.sh` covers Swift, Convex/Vitest, TypeScript, configuration, script syntax, installer fault injection, legacy Supabase validation/RLS, local LiveKit and a disposable local Convex/Swift/LiveKit round trip.
- `scripts/test-convex-live.py` uses its own loopback-only database and media server. Real Swift clients sign up, become friends, knock, preview, admit, send chat, cancel and sign out. No production accounts are used.
- Backend tests include a 100-account fixture (99 visitors), UUID isolation and scheduled cleanup. This is a correctness test, **not a production capacity benchmark**.
- `scripts/test-bundle.py <candidate.dmg>` checks archive checksum, bundle signature/resources, temporary installation and an eight-second fresh signed-out profile launch. The bundled cloud configuration is retained.
- `.park/` contains fingerprinted baseline, prediction and probe records. Intermediate failures remain recorded: wrong interpreter used for a Python `.sh` file; Deno module-resolution setup; source edits during build; concurrent auth-policy changes. Final results below supersede only the corresponding repaired checks.

## Finish release

- Keep the agreed handle-only beta; preserve the deferred password migration plan.
- Freeze/commit the reviewed source; rerun `scripts/check.sh` and package the exact candidate.
- Verify the xattr/ad-hoc upgrade on a clean Mac, including existing login and microphone access.
- Complete the two-Mac and macOS 15 checklist above.
- Approve the specific production deployment and release publication only after those gates pass.

## Final verification

- Full `scripts/check.sh`: passed, including disposable Convex and real Swift/LiveKit call transport.
- Repeated DMG packaging: passed. Candidate: `.context/launch-audit/release/Doorbell.dmg` (local ad-hoc beta only).
- Candidate checksum, signatures, camera/microphone entitlements, isolated installation and eight-second fresh-profile process boot: passed.
- Installer/release fault injection: eleven checks passed, including replacement/launch failure, rollback and rejected public publishing.
- These results do not clear the release blockers above. Independent review and fingerprinted command results live in `.park/`.

## Follow-up: production media repaired

- The reported knock failure came from rejected LiveKit credentials; production visit actions succeeded, but media authentication returned `invalid token`.
- With user approval, replaced only `LIVEKIT_API_KEY` and `LIVEKIT_API_SECRET` on `fastidious-starling-768` using verified credentials from the authenticated Doorbell LiveKit project. Synced private `.env.secrets`.
- Production readback matches. Two real cloud clients connected and exchanged data. All three Swift `LiveKitIntegrationTests` passed using tokens generated with the current production keys.
- Temporary rooms and tokens removed. Existing apps use the repaired server credentials on their next attempt; no app rebuild required for this fix.
- This fixes the media authentication incident; physical camera/mic and two-Mac launch gates remain separate.
