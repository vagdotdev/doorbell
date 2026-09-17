# App window and onboarding QA — 2026-09-15

## Implemented and checked locally

- One reusable window, reachable through the gear, own door, app menu and menu bar.
- Intro → account → handle → permissions → hallway; onboarding persists per account.
- Real local Supabase account creation, taken-handle detection, profile creation,
  Keychain session restoration and sign-out were exercised in the bundled app.
- Close Friends includes incoming-only followers. Accepting a local fixture's
  request, granting walk-in, and removing it were exercised through the window.
  Database readback confirmed both the follow and Close Friends rows were gone.
- Privacy, Audio, Window and Account pages were inspected. Mock name changes,
  request acceptance, Close Friends switches, removal confirmation and reopening
  were clicked through. Empty account/follower states were also inspected.
- Errors preserve loaded data, failed mutations stay visible, and repeated actions
  are guarded. Sign-out drains media work before dropping the session.
- Sessions use Keychain; legacy files migrate only after a protected write succeeds.
  Bundling copies only public backend configuration keys.
- The local database migration was applied. Regression SQL checks run inside a
  rolled-back transaction: immutable follow/profile identities, private Close
  Friends, and follower-side revocation. Search underscores are literal.

## Verification

`swift build`, `swift test`, `scripts/test-graph.sh`, `scripts/bundle.sh debug`.
Tests cover validation, offline recovery, duplicate mutation suppression, sign-out
ordering, onboarding persistence, callback routing and disconnected-room truth.
Native-window screenshots and action traces are in the workspace's `.context/`;
the review ledger is in `.park/` (both excluded from commits).

## Release blockers and remaining work

This is **locally verified, not a production release**.

- Only the local Supabase environment is configured. Apple/Google PKCE browser
  sign-in and email-link callback code exists, but cloud provider credentials,
  redirect allowlists and email delivery need target-environment verification.
- The bundle is ad-hoc signed with no Developer ID team. Signing, notarization and
  stable permissions across updates need a release identity and an installer test.
- A sustained two-Mac call, real device switching, screen sharing, packet loss and
  physical camera/microphone teardown still need media QA. Denied media no longer
  displays fake enabled tracks or fake remote participants.
- Native Apple authorization sheets, avatar editing, account deletion, automatic
  updates, the commissioned intro animation, utilities and DND remain in the plan.
- Stress/large-graph and production abuse/rate-limit testing were outside this pass.

No cloud deployment, push or commit was performed.
