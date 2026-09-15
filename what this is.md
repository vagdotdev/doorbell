# What this is

Doorbell turns the Mac notch into a door.

Everyone has a door. It is always there. Friends walk over to it, knock on it, or walk straight in. There are no links. There is no scheduling. There are no meetings.

## Why

Video calls are appointments. You set them up, join them, leave them, and they die.

Friendship doesn't work like that. In a hostel, you walk down the corridor and see who's around. You knock. You barge in. Someone yells from the hallway. Nobody sends a calendar invite for maggi at 2am.

Doorbell is that corridor.

## The door

The notch is the door. It sits at the top edge of the screen — the boundary of your world. It is always there without being a window you manage.

Idle, it is almost nothing: a dark pill. It costs nothing to keep open. It asks for nothing.

Hover or swipe down and it drops open into a strip: the hallway, your friends' doors. Not who's home. Nobody knows who's home.

## Following

Doors are found the way people are found on Instagram. Search a handle. Send a request. They accept, and now you follow them — which means you can walk over to their door and knock. They can follow you back, or not.

No invite codes. No links. No "add by phone number". A name and a request.

Every door is private. Following is permission to knock. Nothing more.

## Knocking

You open the hallway and click a friend. That's the knock. Your camera and mic turn on. You are standing at their door, under the porch light, and you can start talking.

On their side the notch bounces once and unfurls into a peephole: your live face, small, in the notch. Your voice comes through — but low, as if through the door. Someone's outside, talking. They can turn you up and listen properly. Or not. You see nothing and hear nothing back.

It does not feel like a call. Nothing rings. There is no red button. There is one green one: open the door.

Open the door, and the room opens. You're in.

Nothing is a valid answer. When you step away from the door, the peephole quietly retracts. You learn one thing: let in, or silence. Silence is always deniable. It can always mean not there.

## The peephole

Two kinds of glass, chosen in settings:

- **Rectangle.** The notch grows a little and the video fills it. Clean, flat, engineered.
- **Realistic (eye hole).** A round lens, dark at the rim, the face slightly bowed in the middle, the way a real peephole bends the hallway.

Same door. Only the glass changes.

There are no read receipts. No "seen". No "delivered". No "peeked and didn't answer". No online dots. This rule is load-bearing. Break it and the product becomes surveillance.

The knocker is visible before the owner answers. The person outside stands under the porch light. The person inside stays hidden. The asymmetry is the point.

## Close friends

Close friends is a list you keep, like Instagram's. You add people to it. You remove people from it. They are not told either way.

Being on someone's close friends list means you don't knock. You walk in.

## Walking in

Close friends don't knock. They walk in.

You click their door, and the notch on their Mac swings wide into a full window — the room. Your voice is in their room immediately. Your video follows. Their mic and camera come on too; you're in the same room now. Joining takes one click and zero ceremony. Leaving takes closing the window.

Three or four close friends can be in your room at once. People show up at your house.

Walk-in is granted, not assumed. A small list. Four people, not forty. If your best friend can't take over your screen at 2am, something is wrong. If a stranger can, everything is wrong.

Close friends will be able to knock too, when they'd rather. First, they walk in.

## The room

The room is a window. Black, clean, quiet. Faces in tiles, names underneath, whoever's talking lit a little brighter. A thin strip along the bottom: mic, camera, share screen, chat, leave. A chat drawer on the right, like Meet's, for links and the thing you can't say out loud.

It has to be good enough that you stop opening Meet to call a friend. Sharp video. Screen sharing that just works. Audio that never crackles. The door is the charm. The room is the reason you stay.

Nothing in the room is recorded. Chat lives in the room and dies with it.

## Shouts

A shout is a five-second voice burst. Hold to talk, release to send.

Shout at a door: the owner hears it even if closed. Shout at the hallway: every open door hears it. That is the corridor yell — "who wants chai" — and it needs no one to be live.

Shouts left on closed doors stick like notes. Async hostel.

## The mail slot and the scratch

Two shelves. Opposite meanings.

Scratch is private. Park a screenshot, stash a link. Nobody can see it.

The mail slot is addressable. Friends drop files under your door through your handle. You come back to a small pile. It works when you're closed. It works when you're gone.

Friends only. An open mail slot is a spam vector on day one.

## Strangers in your room

Close friends who don't know each other will meet in your room. This has never existed in software. Group chats are curated. Calls are invited. Nobody has built the room where your school friend and your cousin start talking at 1am because they both wandered in.

A caption is enough introduction: "Arjun · friend of Vagdev". The context is the introduction. You're both here because you both know the same person.

## Presence

There is none. No green dots. No "active now". No last seen. Doorbell never tells anyone whether your app is running.

In a real hostel you don't check occupancy. You walk over and knock. If nobody answers, they're out, or asleep, or ignoring you, and you will never know which. That is the honest version.

## Do not disturb

If your Mac is in a Focus mode, so is your door. If you're in a meeting — Zoom, Meet, FaceTime, anything holding your camera or mic — your door notices and goes quiet on its own. No toggle to remember.

A quiet door still shows a knock, but barely: the notch grows by a few pixels into a tiny pinhole with the visitor's face in it. No sound. No voice through the speakers. No bounce. A walk-in gets the same pinhole. It should feel like something happening two rooms away.

The visitor sees nothing different. They never know you were busy.

## Utility

Doorbell ships utilities: scratch, mail slot, Now Playing, clipboard, timers. They are useful on day one with zero friends.

This is not a growth trick. It is life support. Every social app dies in an empty corridor. The utilities keep Doorbell installed, running, and warm until the first friend joins and the social layer turns on.

Utilities live in the same shell and obey the same rules. None of them may leak whether you're home.

## Look

The shell is black. Physics demands it — it must blend with the notch and the menu bar, or the illusion breaks.

The room is warm. Cream, amber, rounded, illustrated. The delight is the transition: a dark notch unfurling into a warm little world. That reveal is the screenshot.

Glass is used once: a top-light inner stroke on the shell, a deep shadow. Interior panels get material only where media plays. Glass everywhere is glass nowhere.

Two accents. Blue is utility. Amber is social. They never mix.

Empty states are illustrated, in one consistent language, used relentlessly: the empty hallway, the pile of letters, the knock. Boring Notch looks like a dev tool. Doorbell should look like a place.

## Feel

Everything moves on a spring. The notch bounces when knocked. The door creaks when opened. Panels unfurl; they never pop.

Sound is part of the interface. Knock. Creak. Chime. Muted by the system mute, always.

Battery is a feature. Idle Doorbell costs what a menu-bar clock costs: a heartbeat, no media, no camera. Audio and video spin up only when someone knocks or walks in. If Doorbell kills your laptop by 3pm, it gets uninstalled no matter how good it feels.

## Stack

Native Swift and SwiftUI. No Electron. Notch overlays need real control over window levels, spaces, and fullscreen behavior. LiveKit carries audio and video. Supabase carries accounts, the follow graph, and the knock itself. The transport is bought. The feel is built. Details in `docs/how-it-works.md`.

Mac-only. The notch was always Mac-only.

## Non-goals

No scheduling. No recordings. No breakout rooms. No forty-person grids. No enterprise anything. Two to five friends. That is the whole scope.
