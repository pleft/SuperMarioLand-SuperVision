# 2-3 full-level comparison report (port vs GB, whole level)

> **RESOLVED — see "What the report found and what fixing it did" at the end.**
> The drift below traced to two constants, both now corrected: the camera ran
> 5.7% slow, and the spawn trigger fired a uniform 7px early.

First comparison that covers all of 2-3 rather than the first 8%. Method: give
BOTH sides the same invincibility (port `make GODMODE=1`, GB
`scratchpad/sml_iddqd3.gb`), drive them with identical input, and compare every
enemy over 6000 frames. Invincibility is only safe because nothing here asks
about damage -- see [[iddqd-rom-trap]].

## Headline: enemy PLACEMENT is right, enemy TIMING drifts

The spitter ($2F) spawns at exactly the same place every time -- `dx=0, dy=0`,
five instances across the level. What moves is WHEN:

```
spitter    GB f 432   port f 367    -65 frames
           GB f1072   port f1055    -17
           GB f2128   port f2167    +39
           GB f3312   port f3401    +89
           GB f3984   port f4147   +163
```

The port starts ahead and ends 163 frames behind. Cause, measured directly:

```
autoscroll rate, f1000-f5000:   GB 0.5000 px/frame
                                port 0.4715 px/frame   (5.7% slow)
```

It is **not** dropped frames -- the port's `frame_count` advances exactly 1.000
per emulator frame, so the game logic runs every frame. The camera itself moves
irregularly: over frames 1000-5000 only **1841 of 2000** eligible steps actually
scrolled (92%), and sampling individual frames shows the camera advancing by
**+2 on some frames and 0 on others** where the kit's autoscroll should give a
steady +1 every other frame. Something besides `veh_step` is writing `cam_x` in
2-3, or the autoscroll is being skipped. That is the next thing to find, and it
is worth more than any other open item: it desynchronises the whole level.

Everything downstream follows from it:

- **The first school latches the wrong direction.** The port spawns it 66 frames
  early, while Mario is still low, so it steps DOWN where the GB steps UP. The
  2nd and 3rd schools match the GB exactly (y 76/72/68 and 68/64/60), which
  confirms the chase rule itself is right -- only the timing is wrong.
- **The boss arrives 211 frames late** (Tamao and Dragonzamasu both).

## Per-type results

```
type                    GB   port   notes
honen (fishbone) $10     5      5   placement ok; BOB restored (see below)
torion           $1D     8      9   placement exact (dx=-1); one extra instance
gunion           $20     6      6   placement exact (dx=-1)
spitter          $2F     5      5   placement EXACT (dx=0, dy=0)
school fish      $30    13     15   y matches when Mario matches; 2 extra
tamao            $48     1      1   arrives +211 frames
DRAGONZAMASU     $1A     1      1   arrives +211 frames
dragon shot      $1F    11      6   COUNT AND POSITION WRONG -- the boss fight
```

**The dragon's shots are the one clear content defect**: the GB fires 11 in the
window, the port 6, and their positions differ by up to 71px. That matches the
"boss looks off" report and is unexplored -- the boss roster's collision sizes
($20/$22/$48/$1A/$1F) are still assumed 16x16 rather than measured, because
nothing could reach the boss until this god-mode build existed.

**A column in the raw report is my own artifact**: I converted GB obj y as
`o_y + 8N + 16`. The spitter matches exactly at `+24`, so the right constant is
`o_y + 24` for every type, and the `dy = +8/+9` readings for the 16px-tall types
are conversion error, not port error.

## The honen, and the lesson that keeps repeating

The GB's 2-3 honen DOES bob -- rise, fall, rest on a base line, rise again:

```
166 -> 54 (apex) -> 168 -> 168,168,168 (rest) -> 148 -> 55 -> 168 -> ...
```

An earlier pass measured a single 130-frame window, saw one leap, and rewrote it
as "one leap then falls off the bottom". That shipped a fish falling from the sky
forever, and the "fix" for that (culling it on the way down) made it worse, since
resting at the bottom is exactly what it is supposed to do. The original code was
right; it has been restored.

**Every wrong conclusion in this level came from the same mistake: a measurement
window too short to contain a full cycle.** "No crush death" (a window with no
crush, on a god-mode rom). "Honen doesn't bob" (130 frames of a ~320-frame
cycle). "School steps down" (one school, one Mario position). Before concluding
what a periodic thing does, measure at least two full periods, and check the
enemy's whole lifetime rather than the part that was changed.


## What the report found and what fixing it did

**1. The camera ran 5.7% slow (0.4715 vs 0.5000 px/frame).** The autoscroll
sampled `frame_count`'s PARITY once per call, which assumes the game loop runs
exactly once per frame. On the real core it does not: `cam_x` stepped +2 on 45
frames and 0 on 159 that should have moved. Replaced with a frame-delta
accumulator (`veh_scrolls`): elapsed frames go into `vacc`, every 2 of them
produce 1px, and any surplus is applied straight to the camera. Result:

```
before   0.4715 px/frame,  cam deltas 0x2158  1x1796  2x45
after    0.5000 px/frame,  cam deltas 0x2000  1x1999   (a clean alternation)
```

**2. The spawn trigger fired a uniform 7px early.** Only visible once spawns were
keyed on the CAMERA rather than the frame -- frame numbers are not comparable
across two harnesses with different level-entry latencies, and that had been
hiding the constant. Every enemy read `dcam = -7, dx = -1, dy = 0`: spitter,
torion, gunion, tamao, the dragon. One constant, `+8` -> `+15`.

Together:

```
spawn camera offset, whole level:   21 of 26 spawns now EXACTLY 0
                                    honen +4 (3 instances), 2 torion mis-paired
boss (tamao + Dragonzamasu):        arrives at the GB's camera, was +211 frames late
dragon shots:                       count 6 -> 11, matching the GB
```

**Still open:** the honen's +4px trigger; the port having one extra torion and
two extra school fish; and the dragon's shot POSITIONS (up to 63px out) even
though the count now matches -- the boss roster's collision sizes are still
assumed rather than measured.

**Method note.** Keying on the camera instead of the frame is what turned a
confusing set of per-enemy drifts into two constants. Frame numbers are a
property of the harness; the camera is a property of the level. Compare on the
thing the game actually keys off.
