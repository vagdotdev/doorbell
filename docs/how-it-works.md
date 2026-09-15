# How it works

Doorbell is a native Mac app. Supabase owns accounts and permissions. LiveKit carries calls.

## Accounts

Implemented: email/password → choose a handle → stay signed in. Supabase stores the account UUID; `profiles` stores the chosen handle and display name. Friends see names, never database IDs. Sessions live in macOS Keychain; legacy development session files migrate after a successful Keychain write.

A network outage shows retry, not a new-account screen. Signing out tears down both media seats before clearing the account. Profile results, room-channel subscriptions, and incoming events are bound to the current account and session version, so a delayed response cannot restore a previous account.

Google sign-in and handle-only guest onboarding are **not implemented**. Either can use Supabase. Anonymous auth removes the visible login step, not identity: the device still receives an authenticated account. Recovery needs a linked provider. Convex does not inherently improve names or remove this requirement.

## Permissions

- `follows`: Alice requests Bob; Bob accepts. Alice can now knock on Bob's door. The permission is one-directional.
- `close_friends`: Bob enables **Allow Walk-ins** for Alice. This permits automatic room entry and Bob's mic/camera when his app is idle and Quiet Door is off.
- Only the owner reads their close list. Only parties read their follow edge. Handles and follow endpoints cannot be edited after creation.
- Removing a follower also removes their walk-in permission. The server removes their current seats from the owner's room and doorsteps. A previously issued token can remain usable until its short expiry; revocation is not instantaneous token invalidation.

## One visit, one doorstep

Visible room: `door:<owner handle>`, capped at five participants.
Waiting room: `doorstep:<owner UUID>:<visit UUID>`.

Every visit gets its own random ID. A second knock cannot replace the first person's face, audio, or admission. Each app keeps at most five arrivals and expires them after 30 seconds.

### Knock

1. The visitor requests `visit`. The function verifies their accepted follow and returns a publish-only doorstep token.
2. The visitor connects, attempts mic/camera publication, then requests `ring`. The server verifies they actually occupy that doorstep.
3. The server sends a private `knock` event to the owner. Clients cannot broadcast to door channels.
4. The owner previews through a hidden, subscribe-only seat: no microphone, camera, or data publication permitted.
5. **Open Door** connects the owner's visible seat first. **Let In** uses their existing room. The server verifies the guest's doorstep and the inviter's visible presence in the destination room.
6. The server sends an `admitted` token only to the guest's private channel. The guest checks both owner and visit ID before switching rooms.
7. Leave, logout, timeout, and window close invalidate pending work. Late admissions cannot revive the visit.

If the owner is in someone else's room, they can explicitly admit their visitor there. Other participants do not see the knock.

### Walk-in

The server returns `walk_in`, but still puts the visitor on their isolated doorstep. The owner's app auto-admits only when idle, with Quiet Door off. If the owner is already in a room, the visitor waits for **Let In** into that room. If the owner is away, quiet, or visiting someone else, no automatic owner capture occurs.

This intentionally replaces the old behavior where close friends could create an unattended room without the owner.

### Quiet Door

Manual switch in Settings. Enabling it also cancels an unfinished automatic walk-in; explicit acceptance remains available. No bounce, sound, hidden preview connection, or automatic owner mic/camera. The owner can explicitly listen or answer. Quiet status is never sent to visitors. Automatic Focus/meeting detection remains future work.

## Protocol v2

Authenticated `POST /functions/v1/door-token`:

```json
{"version":2,"door":"bob","intent":"visit","visit":"<UUID>"}
```

Intents: `visit`, `ring`, `leave`, `answer`, `admit`, `revoke`. Hidden `answer` requires a visit ID; visible `answer` does not. Admission includes `guest` and optionally the existing `room`. Revocation includes `guest`.

Events: `knock`, `walk_in`, `left` carry `{from,visit}`. `admitted` also carries `{room,url,token}`. The server derives `from`; only the intended account reads its channel.

Old clients receive 409. Payloads are capped at 4 KB. Each account gets 30 requests per minute. Rate-limited leave still succeeds locally but skips the notification; the arrival expires. Invalid or unavailable dependencies fail closed.

The rate bucket stores an account ID, request count, and time window, with opportunistic stale cleanup. It stores no door target or knock history. It is operational metadata, not a presence feature.

## Media and room UI

Two serialized seats: `media` for the room/visitor, `peep` for the hidden preview. The app uses actual SDK publication state for mic, camera, and share controls. Errors appear in the interface; reconnecting and terminal disconnection have distinct states.

- Screen share: explicit display/window picker using ScreenCaptureKit sources. The selected source becomes a large, uncropped tile. App audio is excluded.
- Devices: microphone, output, and camera selection using LiveKit/AVFoundation.
- Chat: reliable LiveKit data messages, up to 4 KB each and 200 messages in memory. Failed sends retain the draft. Nothing persists after leaving.
- Audio: SDK echo cancellation, automatic gain, noise suppression, high-pass filtering; incoming volume changes for the doorstep.

Permission-denied UI has been inspected. Actual camera, microphone, source capture, device switching, and OS-ended sharing still need permission-enabled two-Mac verification. Connection state is implemented; per-person network-quality indicators are not.

## Deployment and verification

Deploy both migrations, the v2 function, and the matching app together. Keep service-role and LiveKit signing secrets only on the server. Release bundling copies an allowlist of public client settings and rejects mock/localhost configuration.

See [reliable-doors.md](reliable-doors.md) for test evidence, install steps, and release gates. No cloud deployment was performed during this reliability pass.

## Still planned

Google/guest onboarding decision; automatic Focus/meeting detection; launch at login; signed updates; battery measurements; scratch shelf, Now Playing, mail slot, and shouts. These are separate from the working call path.
