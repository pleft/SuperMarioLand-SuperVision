# 2-3 rebuilt against the GB, by differential — no playtesting

User: *"I dont playtest anymore, do it 1-1 with GB original level."* So the
instrument had to come first. Every number below is measured, not reasoned.

> **CORRECTION (read this first).** Findings 1, 12 and 13 below were measured on
> `scratchpad/sml_iddqd3.gb`, which is an **INVINCIBILITY build**: five bytes
> differ from the clean rom and three of them turn death routines into `RET` --
> `$09f1` (hurt small Mario), `$09e0` (the big-Mario hurt) and `$515e` (the CRUSH
> death), all `-> $c9`. On that rom Mario cannot die, so every "the GB does not
> die here" result was an artifact of the patch.
>
> Re-measured on the CLEAN rom (warp per law F: `$ffe4=4`, `$ffb4=$22`,
> `$ffb3=$08`):
>
> - **Holding RIGHT in 2-3 DIES at f403** with `c202 = 241`, and again at f1014;
>   lives 2 -> 1 -> 0. `$515e` IS on the State_0D path. Finding 1 was wrong and
>   the crush death has been restored (`veh_crush`): the port now dies at f400
>   against the GB's f403.
> - **The scripted run DIES at f431** on the clean rom. The school fish is
>   lethal; the box IS the kill rule. Finding 13's "reports contact then declines
>   damage" was simply `$09f1` patched to RET.
> - That also vindicates the algebra y-window (`rel_y <= 4`) over the swept one
>   (`<= 6`), which is re-applied: the port's scripted death moved f422 -> f424
>   against the GB's f431.
>
> **Full re-audit on the clean rom.** Every measurement taken on the patched rom
> was re-run. The patch only turns three death routines into RET, so everything
> positional was expected to survive -- and it does, exactly:
>
> ```
> measurement                     patched rom        clean rom          verdict
> spawn obj x  $2f/$30/$10/$1d    192/190/196/192    192/190/196/192    same
> size bytes   $2f/$30/$10/$1d    $21/$21/$12/$22    $21/$21/$12/$22    same
> school activation y             108/104/100 vis    124/120/116 obj    same
> chase direction                 parent below -> up  parent 128,        same
>                                                     Mario 92 -> up
> honen arc                       -2 ~50f,-1,0,+1,+2 same shape + apex   same
> torion speed                    2px/3f world       -1.18px/f screen    same
> hull clamps                     top [25,126]       top [25,126]        same
>                                 left [-1,145]      left [-1,...]
> streaming frontier K            27                 27 (20 samples)     same
> ```
>
> Only the DEATH findings were wrong, and both are corrected above. Note the
> clean rom is brutal with crude input: no scripted pattern survived past ~500
> frames except "right, then up at the wall" (911), which is the window these
> re-measurements use. See [[iddqd-rom-trap]] in memory.

## The instrument

`tools/svshot.c` drives the **real Potator core** (not the py65 sim, which runs
neither NMI nor raster IRQ — law E9) into any level through the port's own
title-screen level select (N taps of SELECT = level N, then START). It dumps
sampled framebuffers, 8K of RAM per sample, and takes an **input script**
(`"R150,U80,D120"`). A PyBoy GB run is driven with the SAME script, so the two
can be compared frame for frame. `tools/svgold.sh` is the gold gate (law E1)
rebuilt on top of it — levels 0-8, hashed; the old one lived in `/tmp` and
evaporated.

Two habits made the difference (laws E11/E12): compare the **drawn sprite**
(GB OAM at $FE00 vs the port's `o_x - cam_x` / `o_y + 8`), and align on
**static scenery**, checking the residual — the seabed is periodic, so a
correlator happily reports a confident −48px that is pure aliasing.

## What was wrong

### 1. A death the GB does not have  ("mario dies unexpectedly")

The kit pushed the sub left when a wall met the autoscroll and, at the left
clamp, ran `stz mario_big / sub_off / hurt_mario`, citing GB `$515e`.

`$515e` is real (`c202 == 0 || c202 >= $ED` → state 1) but **is not on the
State_0D path**. Measured four ways: 1500 no-input frames against the wall,
the same without the star assist, and poking `$c202` to `$f0/$ed/$00/$01`
directly — the GB never leaves state `$0D` and never loses a life.

What the GB actually does (`$4fcb`, byte for byte) is subtler: it drops the
screen x FIRST (so the sub keeps its world position and the probe re-reads the
same column), wraps `$c202` to `$f0` if it hits 0, probes, and gives the pixel
back only if the way is clear. "Blocked" is signalled by `$50cc` ending in
`pop hl / ret` — it **discards its caller's return address**, skipping the
`inc [hl]` at `$4fea`. So a wall costs one screen pixel per scroll step and
nothing else; you slide off the left edge, stay alive, and can steer back.

### 2. Every probe read one tile row too high

The kit transcribed the GB's probe offsets (`c201+5`, `c201-3`, `c201+$0a`)
straight onto `spr_y`. But the GB resolves the row as `($ffad - 16) >> 3`, and
OAM says `c201 = hull top + 22`, so the screen y it tests is `spr_y + d + 6`.
All three probes (h / up / down) were a whole tile row high for the entire
level. The vertical clamps were converted with the same bad constant: the port's
box was hull-top [34,134] against the GB's OAM-measured [25,126] — the sub could
sink 6px into the seabed and could not reach the ceiling.

Also: the GB's left step decrements twice while the autoscroll runs and only the
FIRST dec is clamped (`$5008` vs `$5012`), so the reachable minimum is `$0E`,
two below the stated `$10`.

### 3. The sub sat 2px left, all level long

`do_respawn` hands every level the walking start (`spr_x` 40); the GB puts the
Marine Pop at `c202 = 50`. Because the hull is CARRIED by the autoscroll the
error never washes out. `veh_home` sets 42 (drawn at `spr_x-7` = 35 = the GB's
OAM x). It has to be applied on the first `veh_step`, not in `veh_init` —
`ovl_bind` runs BEFORE `load_level` writes the shared spawn.

### 4. The renderer dropped sprites at the right edge — every level

Pass 1 culls with

```
tmpL = screen_x - cam + scroll_s        ; the RING pixel column
cmp #168 ; bcs -> not visible
```

`scroll_s` runs **0..31** (the ring row is 192px = the 160px window + 32px of
scroll slack), so the cut slides up to 31px LEFT of the screen's right edge and
swallows sprites that are *fully visible*. Measured on the real core: the Marine
Pop parked at its right clamp (screen x 144) **vanished for runs of 17 and 12
frames** while the GB drew it throughout — 29 frames of a 441-frame run.

168 was `192 - 24`, a blanket guard so the widest sprite's blit could not run off
the 48-byte row into the next scanline. `restore_bg` has always guarded its erase
that way (`cmp #24 / bcs @skip`); the DRAW never did. Giving `blit_tile` and
`blit_blank` the same row-end guard lets the cut sit at 176, which covers every
fully-visible position (144 + 31). The clipped-off part is beyond ring column
191, which is off-screen by construction, so nothing visible is lost.

**This affects every level, not just 2-3.** All nine gold hashes are unchanged.

### 5. The school — a fix I made and then had to REVERT

I read a scripted capture (GB OAM: the three fish activate at y 108, 104, 100,
stepping UP) as the rule, and flipped the kit's `+4` to `-4`. Then I ran the
same school under a DIFFERENT input and got y 116, 120, 124 — same frames, same
x to the pixel, stepping the other way. The school's y **tracks Mario**; the
scripted run had driven him upward first.

The original `+4` reproduces the no-input case exactly (port 116/120/124 = GB
116/120/124), so it is restored. The real gap is that the port models a constant
stair where the GB adapts — unmodelled, and now on the open list.

**One capture is not a rule.** The mistake was generalising a single input
condition; the cost was a 24px error in the common case, shipped behind the word
"measured". Vary the input before calling a behaviour characterised.

### 6. The GB's probe reads a 32-column ring

`$3ee6` resolves the probe column as `($ffae - 8) >> 3` where `$ffae` is a
**byte** indexing a 32-column BG tilemap — so a probe beyond the streamed window
wraps 32 columns back and reads STALE map. This is reachable in ordinary play:
hold right into the wall, the autoscroll parks you off the left edge, and from
there the probe sits ~30 columns ahead. `veh_fold` reproduces it (fold when the
column exceeds `fb_col0 + 24`, the newest streamed column). On screen the probe
never exceeds `fb_col0 + 20`, so it never fires during normal movement.

### 7. Torion ($1D) was drawn 8px right of where the GB draws it

Found the GB's **enemy object table at $D100** (stride 16, type at +0, y at +2,
x at +3) by diffing two frames for a byte that moved with the sprite -- the
`$C050` hits were the OAM shadow, not the table. That makes object-to-object
comparison possible for every remaining type.

With it, at f750: GB object x = **192** while its OAM quad is drawn at **184**.
The GB draws this type 8px LEFT of its object; the port drew at the object.
Motion was never wrong -- both run 2px/3f world and +1px/3f in y, and both
objects sit within 2px in absolute world coordinates.

So the fix moves the SPRITE, not the object: `draw_torion` subtracts 2 byte
columns (8px, sub-pixel untouched) before falling into the shared quad draw, and
`w2_width23` moves the erase ORIGIN by the same 8px -- `ovl_width` is the hook
that runs after `o_pvx` is stored (law A2), and `p4_one` draws BEFORE storing it,
so the correction cannot live in the draw. Leaving the object where it is keeps
contact resolving on the GB's own box, which IS the object.

Verified: port drawn-vs-object dx = -7/-8 on the frames where the template
matches cleanly (the GB template is one flap frame, so the other frames
mis-match and must be discarded, not averaged).

**It did not change the deaths** -- the hold-right soak still dies at exactly
f850/1950/3075, because those are downstream of the un-park divergence below.
Two false starts on the way, both from assuming a draw offset instead of
measuring it: a "+8px y on every 2-3 spawn" (the port draws this type at
`o_y+1`, not `o_y+8` -- there is no y error) and a "Torion speed error" (a
10-frame window; over its full 48-frame life the speeds match exactly).

### 8. The school chases Mario — and latches the direction at SPAWN

The `+4`/`-4` argument (finding 5) is settled, from the GB's own object table
under three different inputs:

```
input           parent y   Mario y   the three fish        direction
hold right        132        134      132 / 136 / 140      DOWN
hold down         132        134      132 / 136 / 140      DOWN   (identical)
up, then right    124         94      124 / 120 / 116      UP
```

The parent steps 4px **toward Mario** before each spit. Crucially the direction
is **latched at spawn, not re-evaluated**: in the up-first run Mario is back at
134 by the second spit, yet every fish keeps rising. Re-deciding per spit
reverses the third one and does not match. So `mar_spawn` now latches the step
into `o_vy` (merged with the Torion's existing spawn-time aim, which does the
same comparison and paid for the bytes), and the stair is just `o_y += o_vy`.

Verified against both inputs: port 116/120/124 and 108/104/100, exactly the GB.
(GB obj y = `o_y + 16` for this type -- the fish is 8px tall, so its metasprite
offset is not the Torion's 24. Per-type, always.)

### 9. Honen ($10): 2-3's does not bob

The port models this type as a repeating bob -- up, hang, down, clamp to a base
line (`o_vy`, the spawn y), rest 36 frames, repeat. That is the 2-1/2-2 shape.
2-3's does something else, measured per frame off the GB's object table:

```
from spawn:  -2px/f for 53 frames -> -1 for 8 -> 0 for 8 -> +1 for 8 -> +2 forever
```

One leap from below the screen to the top and back, then it falls off the bottom
and is culled -- no rest, no base-line clamp. Its world x never changes (its
screen x drops at exactly the camera rate). The port's base-line clamp is what
made it flatten at the hull's height and kill Mario. Both the phase durations
(52/7/3 against 53/8/8) and the clamp are now `.ifdef MAR23`, so 2-1 and 2-2 keep
the bob they were verified with -- and their gold hashes confirm it.

Result: the arc now matches in shape and amplitude (both peak at exactly y 54)
and falls off properly. Normal play's death moved f516 -> f636.

### 10. The spawner fired early — fixed, and GATED to 2-3

`spawn_check` triggered when the camera passed `fire_cam`, while `spawn_tabx`
places the object at `fire + 192 + off*4`. The GB fires when the object is a
fixed distance ahead, so the port fired early by `off*4`.

Measured with the GB's OWN camera (recovered exactly from `$ffa4`, which the
h-probe trace proved is the camera low byte), the GB fires when the object's
VISUAL x is 184-188px ahead:

```
          GB cam at spawn   obj x   visual world   port o_x
$2F           216            192        400           401
$10           248            196        436           436
$1D           408            192        592           592
```

Two things fall out of that table. First the port's `o_x` IS the GB's visual x,
to the pixel. Second the trigger wants `fire + off*4 + 8`, which now fires at a
lead of 183-184 against the GB's 184-188.

**It is gated on `cur_level == 5`.** The rule is the GB's own spawner and is very
probably right everywhere, but a discriminating gold run shows it also moves 1-1,
2-2 and 3-1, and it has only been measured in 2-3. Twice in this session a rule
measured in one context did not generalise (findings 5 and 11), so the other
levels keep the old timing until each is measured. Ungating it is a small,
well-defined job: verify one spawn per world against the GB, then delete the
`cmp #5`.

**The gold gate was blind to this.** Its 240-frame no-input runs park the camera,
so no spawn entry ever fires and no enemy is ever on screen. Even 420 frames was
too short — entries fire with the object ~184px off-screen. `tools/svgold.sh`
now holds RIGHT for 900 frames, which is verified to separate builds whose spawn
timing differs. Any conclusion drawn from the old gate about enemy behaviour was
worth nothing.

### 11. A correction: the Torion draw offset was mine, and wrong

Finding 7 said the GB draws `$1D` 8px left of its object and shifted the port's
sprite and erase origin to match. That was wrong. I compared a GB object x
against a camera value read from the PORT's run (398) when the GB's own camera at
that frame was 408. With the right camera the GB's visual world x is 592 —
exactly the port's `o_x`. Drawing at `o_x` was correct all along; the shift has
been reverted.

The lesson is narrow and worth keeping: two runs of "the same" input are not
frame-aligned, so never mix a coordinate from one with a camera from the other.
Recover each side's camera from its own state.

### 12. The GB's contact box, reverse-engineered ($0aaf) -- ready to implement

The port's `l3_box` (|dx| < 10, |dy| < 14 with mixed conventions) is far more
generous than the GB's, which is why 2-3 kills on grazes. The GB's actual test
is at **$0aaf**, with Mario's box built at **$088e**:

```
Mario's box     x [c202-3, c202+2]            (6px)
                y [c201,   c201+6]            (7px; c201-2 when big, unless c203 = $18)

enemy's box     size byte at its struct +$0a:  N = size & $0F   (height, 8px units)
                                               W = (size >> 4) & 7 (width, 8px units)
                x [obj_x - 8*(W-1), obj_x]
                y [obj_y - 8*(N-1), obj_y + 8)
```

Overlap on both axes = contact. In 2-3 the stomp/hurt discrimination is skipped
($08b9: state $0D jumps straight to the hurt path at $094b), which is law B1
arriving from the other direction.

Verified against the disputed frame. At f421 the GB reads:

```
mario c201=115 c202=160  ->  box x[157,162] y[115,121]
$30 fish obj(159,124) size=$21 (N=1, W=2) -> box x[151,159] y[124,132)
```

x overlaps ([157,159]) but y does NOT (121 < 124), so no contact -- exactly what
the GB does and the port does not.

**Translating to port coordinates** (`spr_x = c202-8`, `c201 = spr_y+22`, and the
GB's `obj_y` is the sprite BOTTOM + 8, so `obj_y = o_y + height + 16` while
`obj_x = o_x + 8`):

```
Mario   x [spr_x+5, spr_x+10]      y [spr_y+22, spr_y+28]
enemy   x [o_x + 16 - 8W, o_x+8]   y [o_y+24, o_y+24+height)
```

Both boxes sit ~16-22px below their own sprites, so the offset cancels between
them -- what matters is that Mario's box is SEVEN pixels tall against the
enemy's full height. That is the whole difference.

Implementing it needs a per-type size byte (the GB's `+$0a`) in the kit, which
both kit segments are currently too full to hold -- so it is the next session's
first job, not a squeeze. Everything needed is above; no more GB captures are
required to write it.


### 13. The contact box is NOT the kill rule (and the kit was already right)

I freed space (W2FARM $600 -> $700, bank 5 had 616 spare) and implemented the
`$0aaf` box from finding 12 -- and it changed nothing, because the vehicle's
contact never goes through `l3_box` at all. 2-3's enemies resolve in the kit's
own `veh_touch`, which ALREADY carries a GB kill window measured by PyBoy slot
sweeps in an earlier session, with the same per-type size table this session
re-derived from the GB ($12 / $22 / $21 / $21 for honen / torion / spitter /
school). Both the implementation and the segment growth were reverted.

Then the box model itself broke. Hooking the GB's own overlap routine shows it
**reports contact on frames where the GB then does no damage**:

```
$0aaf returned HIT at f425, 426, 427, 429, 430, 431, 433
across all of which: state stays $0D, lives stay 5, Mario is never hurt
```

Reading `hl` at the hook identifies the reporter exactly: all nine hits are
`$d113` -- slot 1's x byte, the school fish, tracking 154 down to 142. So the
fish really does report contact nine times and Mario is really never hurt.

**Why the "damage path" walk was worthless, and the tooling lesson.** I traced
that path with hooks and concluded the obvious gates were all open: `$ff99` = 0
(so the `cp $03` skip at $0953 never applies), `$2a44` reads `$3186+type*5+2`
which is `$FF` = HURT for every 2-3 type, and `$09f1`'s gate `[$d007]` = 0. Then
probing every instruction inside `$09f1` showed its ENTRY firing 9 times and
`$09f4`, `$09f5`, `$09f6`, `$09f8`, `$09fa`, `$0a04`, `$0a09`, `$0a0f` -- with no
branch between them -- firing ZERO. **PyBoy hooks only fire at call/jump
targets** (now law E13). Every "the path runs" claim above rests on hooks that
cannot see inside a routine, so the gate is still unknown.

The next instrument is a real debugger: a watchpoint on `$FFB3` writes through
f425-433 answers in one run whether the death state is ever entered.

**So the paper box is a necessary condition, not the kill rule**, and the earlier
session's note -- "the $0aaf paper model was 12px too generous" -- was right for
a reason I can now state: the GB tests a wider box than it acts on. A y-window
derived from the algebra was tried here (`rel_y in [-(8N+1), +4]` instead of the
swept `[-8, +6]`) and moved the death by 2 frames before being reverted; the
sweep is the measurement, the algebra is a hypothesis.

What IS solid from this round: the GB's box algebra ($0aaf/$088e), the per-type
size bytes, and the fact that `$3186` column +2 is `$FF`/`$00`/morph rather than
extents. The next step is the slot-tagged hit log.

## Where it stands

Driven by the same input script, 460 frames:

```
hull vs GB (state) dx mean -0.37px (max 2)   dy mean +0.05px (max 1), 422 frames
hull not drawn     0 frames        (was 29)
seabed mismatch    0.00%           (terrain + scroll phase pixel-identical)
gold levels        0-4, 6-8 unchanged; only 2-3 moves
```

**Read the first line narrowly.** It compares the port's `o_y + 8` / `o_x - cam`
against the GB's `c201 - 22` / `c202 - 15` -- STATE against STATE, which is
exactly the trap law E12 warns about. Spot-checking the PIXELS gives a mixed
answer: at f40 the hull is identical to the GB row for row over its own columns,
but at f388 the port's hull ink sits at rows 67..79 against the GB's 75..87 --
8px high -- while both sides' state agrees the top is y=72. Two different
automated detectors (a row-threshold and a box correlator) then disagreed with
each other about how often this happens, which means the detectors are
unreliable here, not that the frequency is known. One confirmed instance, cause
and frequency unmeasured. See the open list.

**Still open.** Holding RIGHT for 3600 frames, the GB never dies; the port dies
around f850/1950/3075. The two now track to ~1px through the wall push AND the
off-screen park (before the ring fold they parted immediately), but the port
un-parks later than the GB, and from there the sub meets enemies the GB's does
not. Two measured leads:

- the school's parent spawns **8px right and 16 frames early** (port fish
  activate at screen x 191 vs the GB's 183) — its own spawn placement, since the
  fish inherit the parent's position;
- the un-park point itself. **This is the one that matters** -- the two subs are +1px identical through f400 (35/34, 134/133,
  84/83, 34/33, 226/225), part at f500-600 (port 190 vs GB 200) and never
  re-converge, so every later collision is against a different scene. Fix this
  before measuring any more enemy geometry.

- the school's y tracks Mario on the GB; the port uses a constant +4 stair.
  Needs the GB's $2F/$30 spit code RE'd rather than more captures.
- the drawn-vs-state 8px discrepancy above: needs a detector that isolates the
  hull from the bubbles and propeller tiles near it (mask by the hull's own
  tile art rather than by an ink threshold) before any conclusion is drawn.

### The un-park: found and fixed, by tracing the probe at its call

Post-frame snapshots were useless here (several probes per frame, each
overwriting the shared scratch), so both sides were instrumented AT THE CALL:

- **port** — the py65 harness (no NMI/IRQ, but the probe is pure computation)
  driven through the title level select, single-stepped to every `vh_read`, then
  run to its RTS to capture `(feet_col, mrow, carry)`. 1.26M steps/sec, so the
  whole park costs about a minute.
- **GB** — a PyBoy hook at bank 1 `$50E8`, immediately after `$50cc` stores
  `$ffae`. That isolates the horizontal probe (1050 calls / 700 frames = 1.5 per
  frame: the autoscroll's every other frame, plus the right-move step). Hooking
  the shared tile lookup `$0153` instead does NOT work -- many things call it,
  and filtering by row still mixes in torpedo and coin probes.

What that showed, in order:

1. `ffae == (c202 + ffa4 + 8) & 255` on **481/481** records, so `$ffa4` is the
   camera low byte and the port's column arithmetic is the right quantity.
2. The port's column **mod 32 matched the GB's ring column 481/481** -- the
   selection was never wrong.
3. The GB's tilemap slot 29 read `$82` (solid) up to cam 268 and `$2c` (open)
   from cam 273. **The slot's content changed**: the streaming had rewritten it
   with column 61. So at cam 273 the GB probes column 61, and the port's fold
   turned 61 into 29 and read a wall that the GB could no longer see.

The frontier is `(cam_x >> 3) + 27`. Every slot rewrite in the trace (slots 5,
29, 30, 31) gives **exactly 27, no scatter**. Two traps: `$c0ab` understates it
by 3 columns (it is 192px ahead of the view, not the frontier), and the
comparison must be against `cam_x >> 3` and NOT `fb_col0` -- `fb_col0` advances
4 columns per 32px shift, so it lags by 0..3 and no constant threshold against it
can be right. That is why a first attempt (24, then 28, against `fb_col0`) only
moved the un-park part-way.

Result, holding RIGHT:

```
hull screen x /100 frames   port  35 134 84 34 226 202 202 157 112
                            GB    34 133 83 33 225 200 200 153 103
probe verdict, matched (cam, c202) states:  149/151 agree
```

Before the fix the port un-parked ~100 frames late and ended 47px adrift
(190/153 against the GB's 200/200). The 2 remaining verdict disagreements are a
one-pixel boundary -- the GB rewrote the slot at cam 273, the port treats it as
resident at cam 272 -- which is the granularity of a per-column model against
per-pixel streaming.

**The deaths remain** (f825/1950/3050). The killer is still the Torion, but now
by way of the residual drift: +1px through f500, +2 at f600, +4 at f700, +9 at
f800, which is enough to change the encounter. That residual is the next thread,
and it is a much smaller one than the 47px it replaced.

### One more `veh_fold` bug found while reading it back

`lda feet_col+1 / bne @fold` folds unconditionally whenever the column number
exceeds 255. 2-3 runs to column 360, so from column 256 onward EVERY probe folds
-32, whether or not it is past the streamed window. Not reached in the captures
above (they stay under column 100), but it will corrupt the second half of the
level. Fix with the fold check, not before it.
