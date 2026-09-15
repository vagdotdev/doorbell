# How it works

`what this is.md` says what Doorbell is. This says how it runs.

## Three pieces

| Piece | Owns | Why this one |
|---|---|---|
| **Mac app** (Swift, SwiftUI, AppKit) | The notch, the peephole, the room window, every animation and sound, scratch, Now Playing, DND detection | Notch overlays need window levels, spaces and fullscreen behavior that only native gives you |
| **LiveKit** (Cloud to start; self-host later if wanted) | Audio and video. Rooms, tracks, who can see whom | Open-source SFU with a mature Swift SDK for macOS. Raw WebRTC would mean building signaling + TURN + the Google WebRTC framework ourselves. FaceTime has no API |
| **Supabase** (Postgres, Auth, Realtime, Storage, Edge Functions) | Accounts, handles, the follow graph, close-friends lists, the knock signal, LiveKit token minting, mail-slot files, stored shouts | One service for everything that isn't media. Row-level security is the permission system |

Idle cost: one WebSocket to Supabase Realtime. No LiveKit connection, no camera, no mic. Media spins up only when a knock or walk-in happens and tears down when it ends.

## Accounts

Sign in with Apple through Supabase Auth. A `profiles` row holds `handle`, `display_name`, `avatar_url`. Handles are unique, lowercase, `[a-z0-9_]`, 3–20 chars.

Every account is private. There is no public profile page. Search returns handle + display name + avatar and nothing else.

## The graph

Two tables, both one-directional. Together they are the entire permission system.

**`follows`** — Instagram model. You request, they accept.

```
follower_id  followee_id  status                created_at
alice        vagdev       pending | accepted    ...
```

An accepted follow means: *alice may knock on vagdev's door*. That is all it means. It does not let vagdev knock on alice. It reveals nothing about whether either is online.

**`close_friends`** — a list the owner keeps.

```
owner_id  member_id  created_at
vagdev    arjun      ...
```

A row means: *arjun may walk into vagdev's room*. Constraint: `member_id` must have an accepted follow of `owner_id`. Adding or removing someone never notifies them.

Both tables are protected by RLS so a user can only read rows where they are a party, and can only write rows they own (you insert your own follow requests; only the followee can flip `pending → accepted`; only the owner writes `close_friends`).

## The hallway

The hallway is the list of doors you can knock on: everyone whose follow request from you is `accepted`. It is a static list. No dots, no sorting by activity, no "recently home". It is also where you manage your own close friends and pending requests.

Clicking a door does one of two things, decided by the token function (the visitor can't read the owner's `close_friends`):

- Not in the list → **knock**
- In the list → **walk in**

The visitor's app asks for a `visit` token and is told which one it got. The owner's list is what decides.

## Rooms

Every user owns two LiveKit rooms, named after their handle. `door:vagdev` is the room. `doorstep:vagdev` is the step outside it: a knocker waits there, and the owner peeks from there. Keeping the step separate means a knocker is never visible to whoever is already inside the room. LiveKit creates rooms on first join and destroys them when empty. Nobody is connected while idle.

Every join needs a token. Tokens are JWTs signed with the LiveKit API secret, which lives only in a Supabase Edge Function. The Mac app calls the function; the function checks the graph and returns a token — or refuses.

```
POST /functions/v1/door-token
  { door: "vagdev", intent: "visit" | "answer" | "admit" | "leave", hidden?, guest?, room? }
  → { token, url, room, mode: "knock" | "walk_in" | "answer" }

visit   → close_friends(door, caller) exists
            mode=walk_in, room=door:vagdev, grant: roomJoin, canPublish, canSubscribe
          else follows(caller → door).status = accepted
            mode=knock,   room=doorstep:vagdev, grant: roomJoin, canPublish, canSubscribe=false
          else 403
answer  → requires caller = door (you, at your own door)
            hidden (default): room=doorstep:vagdev, grant: … canSubscribe, hidden   — the peephole
            hidden=false:     room=door:vagdev,     grant: … canSubscribe            — hosting
admit   → requires caller = door, and follows(guest → door) accepted
          room = body.room ?? door:vagdev. Another room (one you're a guest in) is
          allowed only if you are a visible participant of it right now.
          Mints the guest's full seat in that room and broadcasts it to the guest's
          own channel as `admitted`. Returns { mode: "admitted" } — the caller never
          sees the guest's token.
leave   → broadcasts `left` on the door
```

Nobody enters a room without the owner's `admit`. There is no way for a knocker to upgrade their own seat.

Source: `supabase/functions/door-token/index.ts`. Schema and RLS: `supabase/migrations/`.

The knock signal rides on Supabase Realtime **private** broadcast channels, authorized by RLS on `realtime.messages`: only the owner may subscribe to `door:{handle}`; only accepted followers may send to it; presence is not permitted on any channel. Those three rules are in the migration, not the client.

Participant metadata carries `{ handle, display_name, via: "vagdev" }` so the room can caption strangers as "Arjun · friend of Vagdev".

## The knock signal

Each running app holds one Supabase Realtime channel for its own door, `door:{handle}`. It is receive-only for the owner. Knockers broadcast into it. Presence tracking on this channel is **off** — nobody can see who is subscribed.

Messages:

```
knock     { from: "arjun" }
walk_in   { from: "arjun" }
left      { from: "arjun" }
admitted  { from: "vagdev", room, url, token }   ← to the knocker's own channel
```

That is the whole protocol. No acks. No delivery status. If the owner's app is not running, the message is dropped. From the knocker's side that is indistinguishable from being ignored, which is exactly the rule.

## Knock, end to end

Arjun clicks Vagdev's door. Arjun is an accepted follower, not a close friend.

1. Arjun's app → Edge Function: `{ door: "vagdev", intent: "visit" }`. Returns a publish-only token for `doorstep:vagdev`, and the function broadcasts `knock { from: "arjun" }` on Vagdev's channel.
2. Arjun's app connects to the doorstep, publishes camera + mic. His local preview shows him at the door. He can start talking.
3. Vagdev's app receives the knock. Notch bounces once, knock sound plays (unless DND — see below).
4. Vagdev's app → Edge Function: `{ door: "vagdev", intent: "answer" }`. Returns a **hidden** token for the doorstep.
5. Vagdev's app joins the doorstep as a hidden participant, subscribes to Arjun's tracks, and renders his face in the peephole (rectangle or eye-hole, per Vagdev's setting). Arjun's audio plays at **door volume** — about a quarter — so it reads as "someone's outside talking". A *listen* toggle brings it to full. His microphone is cleaned the same way it would be in a room (noise suppression, echo cancellation, high-pass; see `docs/audio.md`), so what comes through the door is his voice, not his fan. Arjun's client cannot see that anyone joined; his token has `canSubscribe=false`, so even if Vagdev published by accident Arjun would receive nothing.
6. One of two things happens:
   - **Open.** Vagdev clicks the green button. His app takes a visible `answer` seat in `door:vagdev`, publishes mic + camera, opens the room window, then calls `admit { guest: "arjun" }`. The function mints Arjun's full seat and delivers it on Arjun's own channel as `admitted`. Arjun's app trades the doorstep for the room. They are in the room. Nothing about Arjun's follow or close-friend status changes.
   - **Nothing.** The peephole stays while Arjun is at the door and retracts a moment after he leaves. Vagdev can also dismiss it early. Vagdev's app disconnects from LiveKit. Nothing is written anywhere.
7. Arjun's side: the porch light stays on for up to 30 s or until he closes it. Then his app disconnects. He learned one thing: let in, or not.

### Knock while a room is already going

Vagdev is mid-conversation — in his own room, or a guest in Priya's — and Arjun knocks. Same peephole in the notch; the same choice appears as a small bar inside the room window too, the way Meet asks "someone wants to join". The green button reads **Let In**. The doorstep seat stays silent (the room keeps its level) until Vagdev chooses *listen*.

Let In calls `admit { guest: "arjun", room: <the room Vagdev is in> }`. For a room that isn't Vagdev's, the function first checks that Vagdev is a visible participant of it — he can vouch someone into a room only from inside it. Arjun's seat lands in that room, captioned "Arjun · friend of Vagdev" to whoever doesn't know him. Someone new walked in and said hello; nobody exchanged a link.

No `knocks` table exists. Knocks are never logged, counted, or shown later.

Peephole style (`rectangle` | `eyehole`) is a local `UserDefaults` value. It never leaves the machine.

## Walk-in, end to end

Arjun is now in Vagdev's close friends.

1. Arjun's app → Edge Function: `{ door: "vagdev", intent: "walk_in" }`. Full token.
2. Arjun's app connects, publishes mic first (fast), camera a beat later.
3. Broadcast `walk_in { from: "arjun" }`.
4. Vagdev's app: notch swings wide into the room window. Requests an `answer` token (not hidden), joins, subscribes, publishes mic + camera. Arjun's voice is on Vagdev's speakers within a second or two; Vagdev's mic is live to Arjun.
5. Priya (also close) clicks Vagdev's door. Same flow. She lands in the same room. Arjun and Priya see each other, captioned "· friend of Vagdev".
6. Anyone closes their window → their app disconnects. When the room empties, LiveKit deletes it.

If Vagdev's app is not running, Arjun and Priya still get the room. Vagdev's absence looks like any other absence.

## The room window

A normal `NSWindow` (resizable, fullscreen-capable), opened by the app when a door is opened or someone walks in. It is the only conventional window Doorbell has, and it has to stand next to Meet.

| Feature | How |
|---|---|
| Tiles | One per visible participant, laid out in a grid that adapts 1→5; self-view as a small tile bottom-right. `SwiftUIVideoView` from the LiveKit SDK renders each track |
| Names | Participant metadata: `display_name`, plus `· friend of {door}` when they aren't following each other |
| Active speaker | `Room.activeSpeakers` from the SDK drives a soft ring on the tile |
| Mic / camera | `localParticipant.setMicrophone(enabled:)` / `setCamera(enabled:)`, with device pickers from `AVCaptureDevice` |
| Screen share | `localParticipant.setScreenShare(enabled:)` — the SDK uses ScreenCaptureKit on macOS, so the system picker handles window/display choice. A shared screen becomes the large tile |
| Chat | LiveKit data messages on a `chat` topic, reliable delivery. Lives in memory for the life of the room. Nothing is stored server-side |
| Connection quality | `participant.connectionQuality` shown as a small indicator; auto-adaptive simulcast is on by default |
| Leave | Close the window → `room.disconnect()`. Last one out and LiveKit deletes the room |

Audio device handling, echo cancellation and noise suppression come from the SDK's WebRTC audio pipeline. Don't build custom audio.

## Do not disturb

Detected locally, never published.

- **Focus mode.** macOS exposes no public API. Read `~/Library/DoNotDisturb/DB/Assertions.json` (the file every menu-bar DND indicator reads). Verify against the current macOS before shipping.
- **In a meeting.** Ask the system whether any other process is using the camera or mic: CoreMediaIO `kCMIODevicePropertyDeviceIsRunningSomewhere` and CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere`. This is how notetakers know a call is on, and it is app-agnostic — Zoom, Meet in a browser, FaceTime, all look the same.

When DND is on, steps 4–6 of a knock or walk-in change: no bounce, no sound, no speaker audio. The notch grows a few points into a pinhole and shows the visitor's video, muted. The owner can still click through to answer. The visitor's app does nothing different and is told nothing.

## Shouts and the mail slot

Both ride on Supabase Storage + a table row + Realtime insert notifications. One mechanism handles "live" and "left on the door":

- Record a 5-second clip, or pick up a dragged file.
- Upload to Storage: `shouts/{to}/{uuid}.m4a` or `mailslot/{to}/{uuid}/{filename}`.
- Insert a row: `shouts(from, to, path)` / `drops(from, to, path, filename, bytes)`.
- Recipient's app, if running, gets the insert over Realtime and plays / shows it. If not, it sees the rows on next launch.

Storage policies: only accepted followers of `to` may write; only `to` may read. Hallway shout = one row per accepted follower.

Scratch is local disk only. It never touches the network.

## Privacy invariants

These are checked, not hoped for:

1. Nothing in the schema records whether a user is online, was online, or saw anything.
2. Realtime presence tracking is disabled on every channel.
3. An owner answering their own door joins hidden. A knocker's token cannot subscribe.
4. Knocks are not persisted. Ever.
5. Close-friend adds and removes produce no notification to the other party.
6. DND state exists only in the local process.

## Data model

```sql
profiles       (id uuid pk → auth.users, handle text unique, display_name text, avatar_url text)
follows        (follower_id, followee_id, status text check in ('pending','accepted'), created_at,
                pk (follower_id, followee_id))
close_friends  (owner_id, member_id, created_at, pk (owner_id, member_id))
shouts         (id uuid pk, from_id, to_id, path text, created_at)
drops          (id uuid pk, from_id, to_id, path text, filename text, bytes int, created_at)
```

## Cost

LiveKit Cloud Build tier (free, no card, hard-capped): 5,000 participant-minutes/month, 50 GB transfer, 100 concurrent participants. Roughly 40 hours of two-person rooms a month before anything costs money. Supabase free tier covers the rest. Apple Developer Program ($99/yr) is required to sign and notarize a camera/mic app distributed outside the App Store.

## Local development

Everything social goes through one protocol, `DoorbellBackend`. Two implementations:

- `MockBackend` — in-memory graph, fake friends, a "simulate knock" button. Runs on one Mac with no accounts.
- `SupabaseLiveKitBackend` — the real thing.

Build the whole flow against the mock first. Swap in the real backend once the Supabase project and LiveKit project exist.

## Open decisions

- **Knock camera preview.** Does the knocker see their own camera while at the door, or just a "you're at Vagdev's door" state? Preview is more honest about what's being sent.
- **Knock duration.** 30 s at the door before the knocker's app gives up. Tune by feel.
- **Door volume.** Starting at 25% for a friend's knock. Might want a low-pass filter too so it sounds muffled, not just quiet. Try both.
- **Close friends knocking.** Not yet. They walk in. Add a long-press or modifier-click to knock instead once the walk-in feels right.
- **Walk-in while owner is in DND.** Pinhole, muted, no auto-join. The walker is in the room alone (or with other close friends) until the owner clicks in.
