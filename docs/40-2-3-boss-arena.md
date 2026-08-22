# 2-3's boss arena: every sprite was drawn with the wrong tiles

The user's photo of the fight ("look at all this graphics mess") was four
separate defects, all of the same kind: the port had *guessed* which tiles each
arena sprite uses instead of reading them out of the GB's OAM. Reading OAM
settled all four in one capture.

## What the GB actually draws (OAM, cam 2720, iddqd rom, ~200 frames)

```
tile/attr        count   who
$AA 40/62/04/22   161    TAMAO frame A -- ONE tile, four quadrants, flipped
$AB 40/62/04/22   150    TAMAO frame B
$BA $BB $CA $CB   195    DRAGONZAMASU, REST frame (2 wide x 4 tall)
$DA $DB $CC $CD
$AE $AF $BE $BF   116    DRAGONZAMASU, MOUTH frame
$CE $CF $BC $BD
$E2 / $E3         254/255 his SHOT: ONE 8x8 ball, two frames
$FE                15    the shot while it is inside his mouth (a BLANK tile)
$70-$74                  the Marine Pop
```

The attrs are the giveaway on tamao: `04` (none), `22` (xflip), `40` (yflip),
`62` (both) at the four quadrants of one 16x16 -- so it is a single symmetric
tile flipped into a ball, not four different tiles.

## The four defects

**1. The shot was three rows of the dragon's own body.** The port drew a 2x3
stack of `$BE/$C0/$C2` -- port ids that resolve to the dragon's torso. That is
what the user saw as "arcs". It is one 8x8 ball.

**2. The ball's pixels are not in the sheet we extract.** `$E2/$E3` of the
common OBJ sheet are a striped BG pattern (the horizontal dashes in the same
photo). The arena runs a SECOND 256-tile OBJ sheet: **bank 2, file `0x8032` +
tile*16** -- exactly one bank above the common sheet at `0x4032`, and the same
sheet the x-3 rescue moth comes from. `extract_gfx.py` now emits `dshot23.svt`
from it.

**3. Tamao was two halves of two different tiles.** The slice shipped
`$AA, mirror($AA), $AB, mirror($AB)` as one quad; the GB uses four flips of
`$AA` (frame A) and four of `$AB` (frame B). The bottom row needs a VERTICAL
flip, which the packer could not express -- `_vfl()` and the `0x1_0000` /
`0x2_0000` tile flags were added for it.

**4. The dragon only ever had one frame.** The port shipped his MOUTH frame and
stood on it forever. His REST frame is eight further tiles.

## The cadences (measured, not assumed)

```
tamao    30 frames per frame, exactly
shot      4 frames per frame, in step across every ball on screen
dragon   MOUTH for the 15 frames after a shot and the 10 before the next,
         REST for the other 39  ->  25 : 39 of a 64-frame cycle
```

That 64 is the port's existing `o_tmr` shot cycle (`upd_dragon` fires at 64), so
his animation needed no new state at all -- just the second frame's tiles and a
compare.

## The trap inside the fix

`draw_16q` applies `foe_frame` -- a 16-frame wing flap -- and adds `frame*4` to
the base tile. Winding tamao's `o_tmr` to carry a 30-frame phase therefore made
his quad index 4 tiles further on, into the DRAGON's tiles: he turned into a
seahorse every other beat. Split into `draw_16q` (flap) and `draw_16q_f` (final
tile, no flap), 3 bytes, fallthrough preserved for every existing caller.

## Bank 5 ran out on the way

The 14 new tiles overflowed level 5's region into the rescue creature sheet
pinned at `$BF00`. The sheet moved to `$BF80` -- the bank's last 128 bytes -- so
the slice, which grows from below, can use everything under it. 58 bytes free.

## Verification

Not "it looks right": the dragon's two frames were rendered from the SHIPPED
ROM's own slice bytes and searched for in the port's framebuffer.

```
dragon renders checked:                             79
best-matching frame == the frame o_tmr predicts:    67/79
PIXEL-EXACT (diff 0 at offset 0,0):                 10
of the 10 cleanly-drawn frames, correct:            10/10
```

The 12 disagreements are frames caught mid-erase -- 2-3's known redraw flicker
(task 24), not a wrong frame. Tamao's ball and the shot's ball were byte-checked
against the GB's live VRAM instead.

Gold gate (`tools/svgold.sh`) is **identical on all nine levels**, which is the
expected result: nothing here exists outside the arena, and the arena is ~5400
frames past where the gate looks.

## The measurement lesson, again

An earlier pass in this same session read this same OAM and recorded `$aa`,
`$e3`, `$fe` -- every id one off from the truth (`$ab`, `$e2`, and `$fe` is
blank). One dump, parsed once, believed. The dump that settled it printed the
ATTRS too, and the attrs are what proved the four-flip layout. **When reading a
hardware table, print every field, not the one you came for** -- the fields you
did not ask for are what catch the parse error.


## Round 2: he was in the wrong place, and the shot flew the wrong path

The user played the fixed graphics and asked the right question -- "the movement
of the dragon is from very low to the middle, is this expected?" -- so both were
measured over the whole fight instead of a window.

**His patrol was half the size and half a screen too low.**

```
GB, screen top of his 32-tall sprite:  39 .. 104   (65px, turnarounds dead clean)
port, before:                          95 .. 128   (33px)
port, after:                           40 .. 103   (sampled every 10f)
speed: GB 65px per 116-frame leg = 0.560 px/f; port had 0.590 -> 143/256
```

The old code carried the comment "GB-measured patrol: y 103..136". That is what
you get from a SHORT window (his raw y only reached 112, not the true 144) run
through the `obj_y = o_y + 24` anchor rule -- which is right for the small types
and wrong for a 32-tall one. Two errors compounding. His visual top IS the port's
`o_y`, proven pixel-exact by the frame check above; no conversion needed.

**The shot does not rise.** Every shot of the fight, from OAM:

```
born at (his x, his y + 17)  ->  climbs to (his y + 6)  ->  flies LEVEL, 1px/f
```

and it is drawn with tile `$FE` -- a BLANK -- for exactly the 3 frames that climb
takes. So not one pixel of it is ever on screen: visually the ball appears 6px
below his top and flies straight. The port flew it up 32px over 16 VISIBLE
frames. The fix made `upd_dshot` simpler, not more complex: 3 frames of nothing,
then level flight. Verified on the port: **135 of 135 tracked shot samples drift
0px vertically**, and the shot spawns at his x (the `-4` nudge was invented).

Fire cadence confirmed at exactly 64 frames, which the port already had.

## A build trap that cost two captures

`make GODMODE=1` changes `ASFLAGS`, which the `.o` rules cannot see, so toggling
it left a stale `main.o` and shipped a MIXED build -- once diagnosed as "the boss
never spawns" and once as "the run dies at cam 232". The Makefile now stamps the
setting (`build/.godmode-on|off`) and deletes the objects when it flips. Both
rules must sit BELOW `all:` -- a target line above it silently becomes make's
default goal, which is its own half-hour. Verified: godmode and normal ROMs now
hash differently, and re-toggling reproduces the first hash exactly.


## Round 3: the torpedo flew one tile row too high

Reported as "I cannot go lower to break the block in order to advance", with the
sub sitting at the bottom of the arena and the floor blocks refusing to break.

The sub's own depth limit was NOT the problem -- it was checked first, by holding
DOWN across the whole level on the GB:

```
GB c201 with DOWN held: 148 on EVERY screen of 2-3  ->  hull top 126
port clamp:             126                          -> already exact
```

The torpedo was. GB OAM, tile `$7A`, measured at two different depths:

```
c201 134 -> torpedo y 116     hull top + 4
c201 148 -> torpedo y 130     hull top + 4
port:                          hull top - 2   (o_y = spr_y - 10)
```

Six pixels, but they straddle a tile boundary: at the floor limit the GB's
torpedo is at y 130, inside the block row 128..135, and the port's was at 124 --
the row ABOVE it. So the shot sailed over the wall you have to break to leave the
arena, at every depth, with no way to aim lower. `o_y = spr_y - 4` now.

Verified on the port: 188 of 229 torpedo samples read exactly +4 (the remainder
are samples taken after the sub sank further, which does not move a torpedo
already in flight). Gold gate identical.

The x was already right (`spr_x + 2`, GB-confirmed in the same capture).

**Not a bug:** the sub turning big at the boss. A torpedoed ?-block drops a
mushroom, and collecting it grows the Marine Pop -- the GB does the same. The
port never sets `mario_big` on its own; a scripted hold-RIGHT run through the
whole level leaves it 0 from start to finish.


## Round 4: the hull was drawn a tile too high, and Daisy's black square

Two more, both found from the user's GB screenshots.

**The sub was drawn 8px above where the GB draws it.** `sub_ensure` set the
vehicle object's `o_y = spr_y - 8`, following the engine's "visual = o_y + 8"
law -- but `draw_subv` paints its quad at `o_y + 0` (its `sq_dy` is `0,0,8,8`,
and unlike `draw_dshot` it never adds the 8). So the hull floated a whole tile
high: at the floor limit the GB's hull spans 126..141 and the port's spanned
118..133.

```
GB  hull tile top = c201 - 22 = spr_y           (OAM: tiles at 119 and 127 with c201 141)
port, before      = spr_y - 8
port, after       = spr_y      (pixel-exact: the ROM's own $70-$73 quad matched
                                the framebuffer at dy=0, dx=0, diff 0)
```

`o_ndy`/`o_pvy` derive from `o_y`, so the erase box followed the shift by itself
-- verified by eye over a 600-frame up/down sweep with no trails. This is also
why the GB-correct torpedo (hull top + 4) looked like it came out below the hull:
the torpedo was right and the hull was wrong.

**The x-3 rescue's fake Daisy became a solid BLACK SQUARE.** Reported as
"working many many builds back", and it was: the copy that swaps the 2-3
creature tiles over the moth selects its source bank with the PRE-MAGNUM
encoding.

```
creature copy:  lda #(5 << 5) | (NMI|TIMER|LCD)   -> $AB
$2021 under MAGNUM: bits 3:0 ARE the page (docs/37) -> page $B = 11
256K image has 8 banks -> reads return $FF -> an all-bits-set tile = BLACK
set_bank:       "A = bank 0..14 ... the page number IS the bank number"
3-3's arm:      lda #6    (plain -- which is why only 2-3 broke)
```

So it broke at the 256K MAGNUM conversion (task 22) and nothing since touched
that path. Fix: `lda #5`. Proven by A/B on the two ROMs, reading the RAM the
copy fills (`moth_tiles`, $1725, inside the L13E overlay window):

```
pre-fix build:  creature loaded  0 samples, all-$FF (black) 36 samples
fixed build:    creature loaded 36 samples, all-$FF          0 samples
```

Reaching that scene needed a new tool: `svshot` now takes RAM pokes
(`addr:val@frame,...`) so a scene 6000 frames and a boss fight deep can be
driven directly -- here `ending13=2`, `e_cap`, `goal_phase=5`.

Audited the rest: only three sites write `$2021`, and the other two (`set_bank`,
the restore to bank 1) already pass a plain bank number.

**Gold gate:** level 5 changes (the hull moved 8px on frame 1, and the gate looks
at the first 900 frames); all eight other levels identical.


## Round 5: the mushroom froze the game and the camera cashed in the freeze

Reported as "after the sub got bigger the collision map shifted left" -- the
background drawn correctly, but the sub stopping against a boulder that is
several tiles to the RIGHT of anything visible.

This one was mine, from round 1 of this session. The camera fix replaced a
frame-parity gate with an elapsed-frame accumulator (`veh_scrolls`), and it had
two faults that only a FREEZE exposes:

1. It banked every elapsed frame. `mario_grow` is 80 frames with the whole
   action frozen (main.s: "counts 80->0, game frozen"), and the GB does not
   scroll one pixel through it -- so 80 frames sat in `vacc`.
2. It spent the surplus by poking `cam_x` DIRECTLY, in a loop. The caller's
   scroll step is the GB's whole protocol (`cam_x`, the `spr_x` give-back at
   $4fdb, and the background column the engine feeds off that move), so a direct
   poke moves the MAP without drawing the BACKGROUND.

Together: the instant the grow finished, the camera jumped ~40px with nothing
drawn for it, and the collision map ran 5 tiles ahead of the picture.

```
                        max single-frame cam_x jump    (cam_x>>3) - fb_col0
pre-fix,  grow at f900        41 px  (deltas 0,1,41)        up to 8 columns
fixed,    grow at f900         1 px  (deltas 0,1)           up to 4 = the BASELINE
                                                            (a no-grow run also
                                                             reaches 4)
```

Fix: clamp the elapsed delta to 2 (a genuine dropped frame still compensates, a
freeze cannot bank), and return ONE step per call -- surplus waits in `vacc` for
the next call instead of being poked into `cam_x`. The rate this was all built
for is unchanged: **0.5000 px/frame**, measured over f1000-f4500.

`mario_shrink` (hit while big) is "a mirror of mario_grow" and freezes the same
way, so it is covered by the same clamp; so is any future freeze.

**Lesson:** an accumulator that integrates wall-clock time must be told about
every state in which the thing it drives is supposed to STOP. The bug was
invisible for the whole session because no scripted run ever grew, shrank, or
paused -- the user had to pick up a mushroom to find it.


## Round 6: the death hop's black column, and a GODMODE ROM that wasn't

**The trail.** 2-3's crush death happens when the autoscroll squeezes the sub off
the LEFT edge -- the GB's `c202 >= $ED` is a WRAPPED negative, so the port's
`spr_x` is 240 there, and `mario_vx` with it. Then:

```
restore_bg  clips at tile col 24 (the 48-byte framebuffer row): 240/8 = 30 -> SKIPPED
draw_player does not clip: 240px folds mod 48 bytes -> paints at x 48, IN VIEW
```

Every frame of the hop stamped a copy that nothing could erase, so the death drew
itself a solid column up the middle of the screen. A death at a normal x erases
perfectly -- which is why no capture ever caught it. Fix: skip the player draw
when `mario_vx >= 192`, the same limit the erase clips at.

```
dark pixels in the trail band, across the hop
before:  64 -> 156 -> 228 -> 288 -> 300 ... 226 left behind
after:   44 constant (the background blocks that live there)
```

Legitimate positions stay clear of the threshold: `mario_vx` peaks at 95/81/90/95
in 1-1/1-2/1-3/3-1 and 183 in 2-3, against a cull at 192.

**The GODMODE ROM was a copy of the normal one.** `GODMODE=1` changes `ASFLAGS`,
which the `.o` rules cannot see, so an incremental build relinked stale objects;
worse, `make godmode` had been writing the SHARED rom name, so afterwards a plain
`make` saw it up to date and left godmode content in the normal file. Both
directions shipped the wrong flavour, and the user lost a life to a "godmode"
build.

Fixed by making the two settings share NOTHING:

```
OBJDIR = build$(if $(GODMODE),/god)
ROM    = build/super-mario-land$(if $(GODMODE),-god).sv
```

Both stay incremental and neither can ever be the other. Verified from a clean
slate (7560 bytes differ, and a godmode build leaves the normal ROM untouched),
and behaviourally, on the one path that actually goes through `hurt_mario`:

```
2-3 crush death forced by poke:  normal  lives 2->0, death_anim 142 frames
                                 godmode lives 2->2, death_anim never runs
```

Note 1-1 cannot test this: holding RIGHT there dies in a PIT, and pit death does
not go through `hurt_mario`, so both flavours lose lives identically. A test that
cannot fail on the broken build is not a test.

## Round 7: the flicker, measured -- and an interleave experiment that did not pay

The remaining nuisance after the level played clean. Mechanism, measured rather
than assumed: `render_all` erases EVERY dirty sprite and then draws every dirty
sprite, so a sprite erased early is blank for the whole render. In a busy 2-3
stretch a sprite is erased-but-not-yet-redrawn in 12.2% of frames.

Two candidate causes ruled out by experiment (RAM pokes, no rebuild):

```
redraw budget: 5 -> 10   blink frames 12.2% -> 12.2%   (saturated; dirty/frame 2.36 either way)
               5 ->  3   blink frames  6.8% ->  4.6%   BUT the honen draws >2px stale in
                                                       17% of its frames (worst 20px), and
                                                       kit_mar23 records that a 3-cap was
                                                       "the user's flashing" before -> rejected
stream/shift frames      37.2% / 31.2% blink vs 10.5% on ordinary frames -- but they are
                         only 6% of frames, so fixing them removes ~19% of the flicker
```

So the bulk is the ordinary erase-then-draw gap. The one lever with no extra
drawing is ORDER: sprites that overlap nothing can erase and draw back to back.
Implemented as pass 2b (mark the entangled set) + pass 3b (isolated sprites,
after pass 4 so the entangled group keeps its exact old timing).

Two real bugs surfaced while building it, both caught by the gate:

- The isolation box started at 36x40. `o_pw` reaches 4 columns (32px) and TALL
  adds 8px, so a wide pair slipped through and 15 pixels of 1-1 changed. 48x48.
- `mark_slot_y` can mark a sprite REFRESH-ONLY (bit2, no bit0). Pass 3b tests
  bit0 and the new pass 4 tested bit3, so such a sprite was drawn by NEITHER.
  Forced refresh-only into the entangled set.

With both fixed the gold gate is **byte-identical on all nine levels**, which is
the correctness proof for a pure reordering. But the benefit did not survive the
fixes:

```
                        blink frames        renders/1000 frames
approved build          12.20%              982
interleave (correct)    13.72%              970
```

The metric samples one instant per frame, so moving work later in the render
biases it -- it cannot say what the SCAN sees, and the earlier "9.97%" was
measured on the version with the refresh-only bug. With no instrument that can
demonstrate a win, and a real 1.2% loop-rate cost, the change was REVERTED: the
tree rebuilds the approved ROM byte-for-byte (d6e9d0a2d482, godmode
614e683c79ae). The experiment is kept as `sml23-interleave.sv` for an eye test,
and the source at `$CLAUDE_JOB_DIR/tmp/main_interleave.s`.

**What would settle it:** an instrument that knows where the scan is when each
blit lands -- i.e. cycle-stamping the erase and draw of each sprite against the
raster position, not sampling RAM once per frame. Until then this stays open
(task 24), because "it should help in principle" is exactly the reasoning that
produced the two reverted attempts before it.

## Round 8: what the flicker actually IS, and two more failed cures

The user retested the interleave and found it no better, then asked for the two
worst spots: the fish school and the boss fight. Measuring those forced the
mechanism out into the open.

**The core composes the display at the END of the frame.** `watara.c` runs all
256 CPU slices first and only then calls `gpu_render_scanline` over the
framebuffer as it stands. So a sprite is seen blank in exactly one case: its
ERASE and its DRAW fall on opposite sides of a frame boundary. Nothing is raced
against a beam -- there is no beam to race.

That makes the once-per-frame `o_pdr` sample GROUND TRUTH, not a proxy, and it
was checked in pixels: when `o_pdr` goes 1->0 the sprite's own box loses **68
pixels of ink** on average, against +9 when it stays drawn.

Two consequences, both measured:

```
sprite y band     24-47  48-71  72-95  96-119 120-143
blink rate         7.0%   6.2%   8.2%   4.0%   4.3%     <- NO y gradient:
                                                           nothing is racing a
                                                           scan, so ordering
                                                           sprites by y (250
                                                           lines of asm) would
                                                           have bought nothing
```

**Failed cure 1: component-atomic rendering.** Partition the dirty set into
overlap components and erase+draw each as a unit, so a boundary can only catch
one component. It works -- the worst frame dropped from 6 blanked sprites to 5 --
but the classification lengthens the render, so MORE renders straddle:

```
                     blink frames    worst frame
approved                 12.20%       6 sprites
component-atomic         18.40%       5 sprites
```

Three real bugs surfaced on the way (each caught by an instrument, not by eye):
`restore_bg`/`draw_player` clobber X, which is harmless outside a loop and fatal
as a loop index; a find/retire driver that could spin forever (replaced with a
bounded scan by naming each component after its lowest member); and 12 bytes of
new RAM declared mid-block, which shifted every variable after it and offset the
whole picture -- new RAM goes at the END.

**Failed cure 2 (partial): a shorter render via the redraw budget.** 5 -> 3:

```
                   whole level   CROWDED (>=6 sprites)   BOSS ARENA
approved              19.06%            46.21%             63.25%
bud_base = 3          15.50%            38.35%             60.09%
sprites >2px stale     0.6%  ->  3.4%
```

It helps the crowded stretches (the fish school lives there, -17%) and barely
touches the arena. The arena is 63% of frames because the overlap SPREAD forces
every sprite dirty regardless of the budget -- the dragon is two glued objects,
his shots sit on top of him, and the deferral cannot apply to any of them.

**So the arena needs a cheaper PIPELINE, which is what docs/36 said in the first
place.** The remaining candidate is the parked composite draw: blit background
and sprite in one pass per tile, so a sprite is never blank at any instant and
the boundary stops mattering. Everything short of that has now been measured and
rejected: budget up (saturated), budget down (helps the school, not the boss),
isolated interleave (user: no better), component-atomic (worse), y-ordering (no
gradient to exploit).

Shipped for an eye test as `sml23-lowbud.sv`; the tree stays on the approved
build (d6e9d0a2d482 / godmode 614e683c79ae).

**Verdict (user, eye test):** the `bud_base = 3` variant is "no significant win"
either. Every cure short of a cheaper pipeline is now rejected by the only
instrument that counts:

```
budget up (5->10)        saturated, no change            (measured)
budget down (5->3)       -17% in crowded frames          user: no significant win
isolated interleave      gold-clean, cheap               user: no better
component-atomic         worst frame 6->5 sprites        MEASURED WORSE overall (18.4%)
y-ordering               no y gradient exists            not attempted, would buy nothing
```

Task 24 stays open with exactly one candidate left: composite draw.
