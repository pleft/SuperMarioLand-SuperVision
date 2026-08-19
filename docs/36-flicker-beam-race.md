# Why sprites flicker: the renderer races the beam with the sprite ERASED

User report: "2-3 flickers as hell". This is the analysis, the measurement, and
the fix. The mechanism is general -- it is NOT specific to 2-3 -- so this
document is a law, not a bug report.

## The mechanism

`render_all` runs in four passes (docs/27): classify, propagate, **erase every
dirty sprite**, **then draw every dirty sprite**. The two-pass split exists for
a good reason: if you erase-and-draw sprite by sprite, a later sprite's erase
box wipes an earlier sprite's freshly drawn pixels (the "paired-per-slot" bug
the comment in `render_all` warns about).

The cost of that split is that **a sprite is BLANK from its erase until pass 4
reaches it**. Measured in 2-3's fish school, before the fix:

```
475 erase->draw gaps: median 24932 cyc (97 scanlines), max 40480
```

The sprite is missing from the framebuffer for **97 scanlines' worth of time**,
i.e. more than half a screen.

That is invisible only while the whole render fits in vblank. It does not:

```
frame budget 65573 cyc (4 MHz / 61 Hz);  vblank = 24613 cyc = the first 38%
2-3 fish school: the frame takes 96-126% of the budget
```

So the render runs deep into the visible sweep, and the beam passes over
sprites while they are erased. Measured, same stretch:

```
BLANK WHEN THE BEAM PASSED: 138 events / 120 frames (1.1 per frame)
frames with at least one:   61/120  -- HALF THE FRAMES DROP A SPRITE
```

Half the frames losing a sprite at 61 Hz is exactly "flickers as hell".

## Why it shows up in 2-3 and not in 1-1

Nothing about 2-3 is special except its **object count**. A quiet frame renders
in under 38% of the budget and finishes inside vblank, so the blank window is
never on screen. Frame cost scales with the number of dirty sprites, and 2-3's
fish school puts 6 live objects on screen at once. The flicker threshold is not
a level property, it is `frame_cost > vblank`.

**A world that adds one more simultaneous enemy can cross this line.** Check
the frame cost of any new busy scene against 38%, not against 100%.

## The fix (implemented)

Draw each sprite **the instant it has been erased** (`p4_one`, called from pass
3), instead of leaving it blank until pass 4. To keep the paired-per-slot bug
from coming back, `@spread` now also records which sprites OVERLAP:

- Slots are erased+drawn in ascending slot order, so only the **lower** member
  of an overlapping pair can be damaged (the higher one is drawn after the
  lower one's erase). Bit 3 of `o_nfl` = "a later erase will run over you".
- A bit-3 slot stays dirty, so pass 4 redraws it after all the later erases
  (and Mario's) have run. Draw ORDER, and therefore layering, is unchanged --
  which is why the gold VRAM hashes still match bit for bit.
- Slots that overlap MARIO are marked too: his erase runs after every slot
  erase and his draw is last of all.

Result in the same stretch:

```
median erase->draw gap  24932 -> 4534 cyc   (97 -> 18 scanlines)
beam caught a blank      138 -> 31 events   (-78%)
frames with at least one  61 -> 26 of 120
```

## The cost, and what to do next

The redraw of overlapping sprites is a second full sprite blit. In 2-3 the
school fish genuinely overlap each other (303 of 360 fish draws are doubles),
so the busy stretch got slower:

```
whole-level soak   avg 49% -> 57%,  over budget 69 -> 208 of 2500 frames
fish school        96%  -> 121% of the frame budget
```

That trade was taken deliberately: a sprite vanishing in half the frames is far
worse than the game running ~15% slow in one stretch.

**The next step that removes the cost** (not implemented): process each overlap
CLUSTER with one erase of its UNION bounding box, then draw its members in slot
order. No member is ever damaged, so no redraw is needed, and the blank window
is the cluster's own size instead of the whole render. It needs cluster
identification (union-find over the overlap pairs) and a union box, which is
more code than the FIXED bank currently has spare (44 bytes at the time of
writing).

## The instruments

- `/tmp/gap23.py` -- the erase->draw gap distribution, in cycles and scanlines.
- `/tmp/beam23.py` -- counts sprites the beam swept while they were blank.
  Beam model: the NMI fires at the start of vblank, so
  `scanline(c) = (c - 24613) / 256` for a cycle offset `c` into the frame.
- `/tmp/soak23.py` -- whole-level frame cost, over-budget clusters by camera x.
- `/tmp/prof23.py`, `/tmp/blitprof.py` -- per-routine and per-blit-call cost.
