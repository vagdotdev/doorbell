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

1. The visitor requests `visit`. The function verifies their accepted follow and returns a publish-only doorstep token. Their camera starts at the click, so it is lit by the time it publishes.
2. The visitor connects, publishes mic and camera together, grabs one small JPEG still, then requests `ring`. The server verifies they actually occupy that doorstep.
3. The server sends a private `knock` event to the owner, carrying the owner's preview seat (minted during `ring`, identical to a hidden `answer`) and the still (base64 JPEG, ≤ 16 KB, dropped if malformed). The event row is the only copy, deleted on receipt or after 45 s. Clients cannot broadcast to door channels.
4. The owner previews through a hidden, subscribe-only seat: no microphone, camera, or data publication permitted. The glass shows the still until the first live frame renders. Knocks from older servers carry no seat; the owner asks with `answer`. `door-timing:` log lines time each step.
5. **Open Door** connects the owner's visible seat first. **Let In** uses their existing room. The server verifies the guest's doorstep and the inviter's visible presence in the destination room.
6. The server sends an `admitted` token only to the guest's private channel. The guest checks both owner and visit ID before switching rooms.
7. Leave, logout, timeout, and window close invalidate pending work. Late admissions cannot revive the visit.

If the owner is in someone else's room, they can explicitly admit their visitor there. Other participants do not see the knock.

### Walk-in

The server returns `walk_in`, but still puts the visitor on their isolated doorstep. The owner's app auto-admits only when idle, with Quiet Door off. If the owner is already in a room, the visitor waits for **Let In** into that room. If the owner is away, quiet, or visiting someone else, no automatic owner capture occurs.

This intentionally replaces the old behavior where close friends could create an unattended room without the owner.

### Door status

A line the owner writes over their own door ("in a meeting till 4"), up to 40 characters, shown on their card in friends' hallways. `status:set` stores it in `doorStatus` with `expiresAt` six hours out and schedules `status:expire`; setting again replaces it and its expiry. Hover shows ×; empty text or × removes it. It is self-authored, so it says nothing about whether they are home.

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

- Screen share: explicit display/window picker using ScreenCaptureKit sources. The selected source becomes a large, uncropped tile. "Share sound" (on by default) captures the shared apps' audio, never Doorbell's own, at 30 fps instead of 15. LiveKit mixes that audio into the microphone track, so muting the mic mutes it too.
- Pointing: over someone's share, a viewer's mouse becomes a named pointer in their avatar colour — lossy `pointer` packets (`{"on":sharer,"x","y"}`, 0…1 from the picture's top-left, ≤ 30/s), a click is a reliable ping. Everyone watching sees them; the sharer sees them on their real screen through a click-through overlay that display capture excludes. Pointers fade after 4 s idle.
- Devices: microphone, output, and camera selection using LiveKit/AVFoundation.
- Chat: reliable LiveKit data messages, up to 4 KB each and 200 messages in memory. Failed sends retain the draft. Nothing persists after leaving.
- Stickers: topic `sticker` carries `{"emoji":…}` or `{"custom":<sha256>}`; older builds ignore it. Emoji stickers are Google's animated Noto set (CC BY 4.0), fetched from fonts.gstatic.com and cached in `~/Library/Caches/Doorbell/Stickers`. Custom stickers live in Application Support; the picture (≤ 2 MB) goes by LiveKit byte stream only to people in the room who lack it, and receivers keep it only if its SHA-256 matches, until the room ends.
- Audio: SDK echo cancellation, automatic gain, noise suppression, high-pass filtering; incoming volume changes for the doorstep.
- Notes: a button next to Chat records each person's audio, Sarvam romanizes it (`translit`), then writes English notes with a gloss in parentheses. The page lives at an unlisted `/n?t=` URL; Instinct can poll `/n/feed?t=`.

Permission-denied UI has been inspected. Actual camera, microphone, source capture, device switching, and OS-ended sharing still need permission-enabled two-Mac verification. Connection state is implemented; per-person network-quality indicators are not.

## Deployment and verification

Deploy both migrations, the v2 function, and the matching app together. Keep service-role and LiveKit signing secrets only on the server. Release bundling copies an allowlist of public client settings and rejects mock/localhost configuration.

See [reliable-doors.md](reliable-doors.md) for test evidence, install steps, and release gates. No cloud deployment was performed during this reliability pass.

## Still planned

Google/guest onboarding decision; automatic Focus/meeting detection; launch at login; signed updates; battery measurements; scratch shelf, Now Playing, mail slot, and shouts. These are separate from the working call path.
