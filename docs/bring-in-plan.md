# Bring-in

When you are already in a room and someone knocks, Accept is the wrong control. It hides a real choice: add them to this hang, or leave this hang and take the knock in a new room.

Idle knocks stay as they are: one green Accept.

## Now

`DoorController.openDoor()` already branches:

- No live room → `answer` mints `door:<you>:<uuid>`, then `admit` into that room.
- Room already active → skip `answer`, `admit` the guest into the current `roomName`.

The server already allows that second path. `convex/doorActions.ts` `admit` requires you to hold a visible seat in the destination room (`door:<handle>:<uuid>`). That room can be yours or someone else’s. Other people in the hang do not see the knock.

The UI does not expose the branch. Peephole and the in-room `AtTheDoor` chip both say **Accept** and always call `openDoor()`. If you are in a call, Accept means add. There is no way to hang up first and then let them in.

Walk-ins already wait when a room is live (`walkInDuringExistingRoomWaitsForAdmission`). They should get the same menu as a knock, not auto-join the hang.

## Choice

Replace Accept with a menu only while `room.isActive`.

| Action | What happens |
|---|---|
| **Add to this call** | Today’s Accept. Admit the visitor into the current LiveKit room. You stay. Everyone already in stays. |
| **End this call** | You leave the current room. Then the idle Accept path: mint your own room, admit the knocker there. |

Do not kick the other people. “End this call” means you hang up, not that the hang is destroyed. If you were the last person besides the doorstep, the old room dies on its own.

Labels, not “Accept”:

- Add to this call
- End this call

“Join” is the visitor’s verb. You are already in.

Keep **Not Now** beside the menu. Dismiss still does not tell the knocker anything.

## Where

Same two surfaces that already show Accept during a live hang:

1. Notch peephole (`PeepholeView`) — if the knock stole the shell while a room window is open.
2. In-room chip (`RoomView.AtTheDoor`) — the one you actually see while talking.

Idle peephole (no `room.isActive`): still a single Accept. No menu.

Pinhole / Quiet Door: opening the peephole first, then the menu if a room is live. Walk-in + Quiet still must not auto-admit into a hang.

Disabled while `isAdmitting`. Opening… on the control that was chosen.

## Add to this call

`openDoor()` as it is when `room.isActive`.

If the room is at five visible seats, do not admit. Disable **Add to this call** and say the room is full. **End this call** stays available.

If `admit` fails (they left, friendship ended, you dropped out of the room), keep the hang. Same error as today: “Couldn’t let them in. They may have left. Try again.”

The knocker still does not learn that a hang was already on. They see admission into a room, same as any other open-door.

## End this call

Order, so a failed leave cannot admit them into the old room:

1. Snapshot the arrival (`profile`, `visitID`). If that visit is no longer first, stop.
2. Leave the current room the same way the window-close / Leave path does: disconnect media, `room.end()`, clear `roomName`. Best-effort `leaveVisit` only if you were yourself a visitor in that room.
3. Confirm the same visit is still first and still announced.
4. Run the idle open-door path: `answer(hidden: false)` → connect your visible seat → `admit` into the new `roomName` → open the room window with the knocker.

If step 2 succeeds and step 4 fails, you are out of the old hang and the knocker is still on the doorstep. Show the peephole again. Do not silently rejoin the old room.

Cancel an in-flight End if the knocker leaves, you pick Not Now, or a newer Accept/End starts. Existing generation / `isAdmitting` tickets already serialize this; End is a new `openDoor` mode, not a second admission pipeline.

Leaving someone else’s room does not need a new Convex function. You already disconnect. The old hang continues for whoever stayed.

## Who can add

Same rule as today’s admit: you must be a visible participant in the destination room. You can add a knocker on *your* door into a hang you are sitting in, even if you are not the host.

Do not add a new “invite to this room” for people who did not knock on you. This plan is only the occupied-door menu.

Automatic walk-in stays off while a room is live. Close friends wait and get this menu.

## UI

Menu, not a second green button. One control where Accept was.

In-room chip is tight (38pt capsule). Use a split control if a full menu will clip: the prominent action is **Add to this call**; a chevron opens **End this call**. That is still the choice, not a new object on the door.

Notch peephole has more room: a menu under the current Accept slot is fine.

Copy stays short. No “meeting,” no “kitchen.” Call is the word already on Leave.

## Tests

Controller, not screenshots:

- Occupied + knock → `openDoor(bringIn: .add)` admits into existing `roomName`, does not call `answer`, room host unchanged.
- Occupied + knock → `openDoor(bringIn: .end)` disconnects current media, then `answer` + `admit` into a new room. Old `roomName` is not passed to `admit`.
- Occupied + walk-in does not auto-admit; both menu actions still work.
- Full room (5) → add refused, end still works.
- Knocker leaves after End started but before `admit` → no phantom room, no admit.
- Duplicate End/Add while `isAdmitting` → one admit.
- You are a guest in `door:priya:…` and add → `admit` `into:` that room; Priya is not notified of the knock (already true).
- Failed `admit` after End → you are not still in the old room; peephole returns.

Keep the existing Accept-always-wins tests for the idle path.

## Out of scope

- Showing anyone that a hang is occupied (the “what’s going on” building view).
- Starting a hang and pulling several people at once.
- Ending the hang for everyone else.
- Changing LiveKit token shape, visit IDs, or `admit` authz.
- Mail slot, fridge, shouts.

## Ship order

1. Split `openDoor` into add vs end. Default idle path unchanged. Tests above.
2. Occupied UI on `AtTheDoor`, then peephole.
3. Full-room disable on add.
4. Two-Mac: A+B in a room, C knocks A — add (C appears, A+B stay) and end (A+C in a new room, B stays in the old one).
