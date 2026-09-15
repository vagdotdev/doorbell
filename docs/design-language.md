# NotchNook × DynamicLake Pro — design study

Source screenshots: `research/notch-apps/`. Reference while reading.

## NotchNook ($25) — the taste baseline

**Shell.** Pure-black panel, continuous corner radius ≈ 26, hangs off the
notch with a soft drop shadow. Top row is menu-bar height: pill tabs
(`Nook` / `Tray`, SF-symbol + label), gear icon pinned right. Nothing else
competes for attention.

**Expanded board.** 3-column widget grid (music | calendar | notes/mirror)
separated by 1px white/10 dividers, ~20px padding. SF type throughout:
semibold 15pt titles, regular 12–13pt secondary in white/50. One accent —
system blue — reserved for interactive elements (today's date, tray glyph,
formatting buttons). Album art is the only color allowed to shout.

**Tray (the shelf).** Dashed white/20 rounded container = drop zone. Parked
files show icon + truncated name. Drag-in gets a green `+` badge on the
cursor and the zone highlights blue. AirDrop sits beside it as a solid
dark-blue tile with a radar glyph — same row, visually heavier, reads as
"send" vs "park". This park-vs-send split is exactly Doorbell's
scratch-vs-mail-slot.

**Compact state.** Collapsed pill: album art left, scrolling track text
center, mini visualizer right. Grammar: `[glyph | text | meter]`.

**Motion.** Swipe/scroll between widgets with a springy settle. Expand feels
like unfurling, not like opening a window.

**Personality.** Contained playfulness: custom GIFs, Shortcuts widgets. The
shell never jokes; the contents are allowed to.

## DynamicLake Pro — the maximalist

**Compact island grammar.** Collapsed strip carries live state at all times:
album art left + red visualizer right; or notification bell + visualizer.
Lesson: the idle notch is never empty — it always whispers *something*.

**Expanded HUD.** Big music panel: large rounded art, ALL-CAPS title,
`Lossless` badge chip, scrub bar with elapsed/remaining times, five-icon
transport row (queue, prev, play, next, AirPlay). Heavy black, white type,
blue visualizer. More glow, more badges, more shine (Liquid Glass skin).

**Philosophy.** Named modules (DynaMusic, DynaKeys, DynaGlance…), longest
checklist in the category. iPhone-mimicry: looks impressive in screenshots,
generic in daily use. No point of view beyond "more".

## What Doorbell takes from each

From NotchNook: the shell (black, r=26, tab top-row), the column board, the
park-vs-send tray split, the `[glyph | text | meter]` compact grammar, the
springy unfurl, the discipline of one accent color.

From DynamicLake: the ambition that the notch is *always alive* (idle still
whispers), the badge-chip vocabulary, badge-able transport rows — but not
the generic shine.

## Doorbell's own moves (neither does these)

1. **Dark door, warm room.** Shell stays black (notch physics); the interior
   goes warm — cream, amber, illustrated — when friends are present. The
   reveal is the screenshot moment.
2. **Two accents, two worlds.** System blue = utility (tray, music, settings).
   Warm amber = social (knocks, presence, shouts). Never mixed.
3. **Glass, used once.** A single `white 14% → 3%` top-light inner stroke on
   the shell + deep shadow. Interior panels get `.hudWindow` material only
   where media plays. Glass everywhere = glass nowhere.
4. **Compact grammar extended.** `[avatar/art | text | meter]` where avatar can
   be a friend: idle door shows presence dots, knock shows peephole preview.

## The atmosphere: pitch black, and almost nothing else

The feeling we are after — the polish of a screen like Astra's welcome, where a
black sky and one piece of glass carry the whole thing — comes from restraint,
not from effects. We looked at that screen for its *mood*; nothing from it is
here. The rule: the shell is pitch black, and the few things drawn on it are
there to give the black depth, never to decorate it. If a layer can be removed
and the shell still reads as a space, remove it.

What is allowed, all in `Atmosphere.swift`:

- **Starfield.** Sparse, still, seeded. White only, most of it near invisible.
  This is what makes the black a space rather than a fill.
- **Doorstep.** Black glass whose crown sits `doorstepRise` above the floor;
  the controls stand on it. Drawn with two things: a 1 pt hairline where the
  light catches the rim, and a breath of the same light outside it, gone within
  a few points. It fades from the crown down so the arc dissolves before it
  meets the sides. `lit` (listening, a knock landing) lifts it a touch; that is
  the only thing that moves.
- **One light.** `horizon` is a barely-blue white, and it is the only colour
  the atmosphere has. Rims, halos, the doorstep — all the same light. The two
  accents (utility blue, social amber) stay on controls and never leak into the
  background.

What is not allowed: coloured glows, horizon washes, blurs, reflections,
anything that reads as a "theme". Gradients only, and few of them. Idle Doorbell
must cost nothing to draw.
