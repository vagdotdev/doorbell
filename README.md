# Doorbell

Your Mac's notch is a door. Friends knock, peek through the peephole, or —
if they're close — walk straight in. No links, no scheduling, no meetings.
A hostel hallway for your laptop.

Utility layer (scratch shelf, mail slot, Now Playing) keeps the app alive
solo; the social layer (knocks, walk-ins, shouts) turns on when friends join.

## Layout

- `Sources/DoorbellApp/` — native SwiftUI + AppKit notch app (macOS 15+)
- `docs/design-language.md` — NotchNook × DynamicLake design study + tokens rationale
- `research/notch-apps/` — 39 competitor screenshots + `SOURCES.md`

## Build & run

```sh
swift build   # verify compile
swift run     # run the shell (agent app: notch panel only, no dock icon)
```

Or open the folder in Xcode and Run (`⌘R`). For a distributable `.app`
bundle + notch-geometry work, we'll migrate to an Xcode project once the
shell proves out.

## Milestones

1. ✅ Static black shell hanging top-center (this commit)
2. Compact ↔ expanded states with springy unfurl
3. Scratch shelf (drag in, park, drag out)
4. Now Playing module
5. Knock + peephole (local simulation first)
