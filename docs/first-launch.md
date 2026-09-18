# First launch, and the app window

Today Doorbell has no window of its own until someone is at a door. Sign-in and the
handle live in the notch board, which is fine for us and wrong for a stranger: the
first thing a new person sees should be a real app, once, that explains itself in
ten seconds and then gets out of the way. After that the notch is the product and
the window is where settings live.

Section 1 is built (`Sources/DoorbellApp/Onboarding/`): the window opens whenever there is
no account — first launch, sign-out, expired session — and the notch only offers a way back
to it. While it is up the app is a regular app (Dock icon, menu bar); on Done it goes back
to being the notch, and the board opens once on its own so the intro can play. The pitch
animation is still the placeholder described below. Sections 2–3 are not built.

## 1. First run

A normal window, black, centred, the room window's chrome (hidden titlebar, floating
traffic lights). Three beats, `Next` between them, no skipping needed because it is
short.

1. **What it is.** One animation: a notch at the top of the frame; a small character
   walks up and knocks; the notch unfurls into the peephole with their face; it opens
   into a two-tile call; someone else wanders in from the side and becomes a third
   tile. Loops. Under it, one line: *Friends knock on your notch. Close friends walk in.*
   The animation is the whole pitch and is worth commissioning or licensing rather
   than drawing in SwiftUI — a Lottie/Rive file dropped into the bundle. Placeholder
   until then: the real notch shell playing the mock knock and walk-in.
2. **Who you are.** Sign in (below), then pick a handle and a name. Same rules as the
   notch form today: lowercase handle, 3–20, unique, checked live.
3. **Permissions.** Camera and microphone, asked here with one sentence each, so the
   first knock does not interrupt itself with a system dialog. Then *Done*; the window
   closes and the notch takes over with the hallway open once.

The notch keeps its own sign-in form for the signed-out state after that (token
expired, signed out on purpose) — it is already there and quiet.

## 2. Sign-in

Supabase Auth stays the account system; the question is only which front door.

| Option | Feel on a Mac | Cost | Verdict |
|---|---|---|---|
| **Sign in with Apple** | Native sheet, Face ID/Touch ID, hides email if they want | Apple Developer account (needed for notarization anyway); Supabase `apple` provider is a config entry | **Default button.** The right answer on macOS. |
| Google | Browser round-trip, then back to the app via URL scheme | Google Cloud OAuth client; Supabase `google` provider | Second button. Plenty of people live in Google. |
| Email magic link | Type email, click link in mail, app opens | Nothing new | Fallback link under the buttons. No passwords anywhere. |
| Email + password | What we have now | Nothing | Keep for development and the local stack only. |

Implementation: `supabase-swift` already does all three (`signInWithApple` via
`ASAuthorizationController` credential, `signInWithOAuth(provider: .google)` with
`ASWebAuthenticationSession`, `signInWithOTP`). The bundle needs a URL scheme
(`doorbell://auth`) for the OAuth and magic-link returns. Profile creation (handle)
is unchanged: the `profiles` row is inserted after the first successful auth.

## 3. The app window

Reachable from the notch board's gear (replacing today's inline Settings) and from
the menu bar. Two columns, black, the same tokens as everything else. Left, a narrow
list; right, the page. Nothing else — no toolbar, no tabs, no search.

```
┌──────────────┬─────────────────────────────────┐
│ Privacy      │  Close Friends                  │
│ Audio        │  People who walk straight in.   │
│ Window       │  ○ Arjun Mehta          [on]    │
│ Settings     │  ○ Priya Nair           [on]    │
│              │  ○ Bob Menon            [off]   │
│              │  …everyone you follow…          │
│ @vagdev      │                                 │
│ Sign out     │                                 │
└──────────────┴─────────────────────────────────┘
```

**Privacy** — first item, first page.
- *Close Friends*: your friends, each with a switch. On = they walk in.
  This is `close_friends` today; it just gets a page instead of a context action.
- *Friends*: who may knock; removing someone removes access both ways.
- *Requests*: pending friend requests, accept/decline — moved out of the notch board
  where it currently crowds the top row.
- One sentence at the bottom, the only copy on the page: *Nobody can see whether
  you're home. Knocks aren't kept.*

**Audio**
- Microphone: the macOS mode (Standard / Voice Isolation / Wide Spectrum) and the
  picker, as in the notch settings today. Input and output device menus.
- Door volume: how loud someone at the door is through the peephole (today a constant,
  `DesignTokens.doorVolume`).
- Sounds: the knock and the creak, on/off; later a choice of knock.

**Window**
- Glass: Wide / Round (the peephole shape).
- Room window: open on the current screen vs. always the notch's screen; start in
  fullscreen off/on.
- Launch at login.

**Settings**
- Account: handle, name, avatar. Sign out. Delete account.
- About, version, updates.

## What moves out of the notch

Settings, Requests, and the sign-in form are in the board because there was no
window. Once this exists the board is the hallway and search, plus the door moments.
The gear becomes "open Doorbell". Fewer things at the top of the screen is the point.

## Order

1. App window with Privacy → Close Friends, Audio, Window, Settings on the current
   email+password auth. Move Requests and Settings out of the notch. (One or two days.)
2. Sign in with Apple + Google + magic link through Supabase; URL scheme. (One day
   plus the Apple/Google console work.)
3. First-run flow with a placeholder animation; permissions step. (One day.)
4. The animation itself, commissioned. Drop-in.
