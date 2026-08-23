# 3-1 rework — the closed-loop differential, and the slot leak it found

Task #27. The brief: "redo level 3-1 carefully / make it 100% GB original
accurate", after the user fell through a platform in the pit section.

## The instrument (built first, on purpose)

Two auto-players that run the SAME search on both sides:

* `tools/gbauto.py <level> [frames] [out.txt]` — drives the GB (PyBoy, the
  invincibility build) with a greedy save-state search: every 10-12 frames it
  rolls back, tries a fan of (pre, delay, hold, drift) jump timings, scores each
  by how far right Mario is at the horizon, and commits the winner's first
  frames. It writes the input script in svshot's letters (`R` right, `J`
  right+A, `A` A alone, `.` nothing).
* `tools/svauto.c` — the same search on the REAL Potator core via
  `supervision_save_state_buf`, reading the port's own RAM (`cam_x`, `spr_x`,
  `spr_y`, `respawn_req`, `death_anim`).
* `tools/sv_vs_gb.py <level> <script>` — replays one script on both and prints
  the first divergence. Useful only until the paths part; see law E23.

Two horizons, both needed (each was measured to be necessary):

* the LONG one (180 frames) sees the far side of a pit, so the jump can start
  before the lip;
* the SHORT one (60) is what crosses 3-1's sinking stone bridge, where NO
  candidate survives 180 frames and a long-only score makes "stand still" the
  best move — the search then never steps onto the bridge at all.

Rank: alive at the long horizon > alive at the short one > furthest corpse; and
"alive but not moving" is demoted to the bottom tier, or standing against a wall
outranks every move that gets somewhere. Ties go to the EARLIEST jump: a tie
usually means both timings clear the gap, and the later one walks to the lip
first.

## What the GB actually does here (measured, PyBoy)

* **Stepping stones ($36, six of them over the first pit, world x 384-424).**
  They are rideable and they SINK: stepping on one morphs it to $37 and it
  falls. Their slots are freed one by one as each scrolls off the left —
  slot 2 at cam 384, slots 3+4 at 416, slot 5 at 432, slots 6+7 at 464.
* **Vertical lift ($0A, first one in the big pit).** Spawn y = 72 = the TOP of
  its patrol; it heads DOWN 60px to 132 and back, 1px every 2 frames, so a
  half-cycle is 120 frames. The port's model (`upd_platv`: 60px, 1px/2f, spawns
  at the top heading down) matches exactly.
* **Riding geometry.** With Mario on a lift, RAM says `lift_y - mario_y = 10`
  and `mario_x - lift_x = 10`; OAM at the same frame says Mario's tiles occupy
  y 52..67 and the platform's three $EF tiles sit at y 68 — i.e. **Mario's feet
  land exactly on the platform's top pixel row**. The port: `plat_land` snaps
  `spr_y = o_y - 8`, the platform draws at `dy = o_y + 8`, and Mario's quads
  cover `spr_y .. spr_y+15`, so his feet are at `o_y + 8` = the platform's drawn
  top. Identical. The port's landing window (Mario's centre within ±16 of
  `o_x + 12`) is if anything more forgiving than the 24px platform.

So the platform's geometry was never the bug.

## The bug: object slots leak, and the spawner fails silently

`find_free_obj` scans for `o_type == 0`; `spawn_check` drops the entry if the
table is full. `upd_stone`, `upd_platv` and `upd_plath` had NO off-screen-left
cull — a stone that was never stepped on, and every lift already passed, held
its slot for the rest of the level. In 3-1 that is six stones plus two lifts out
of TEN slots. By the time the camera reaches the big pit (the $0A entries fire
at cam 640 and 736), the table can be full, the lift's spawn is dropped without
a trace, and the player walks into a pit where a platform should have been.

Fix: `cull_left` (the walker rule, `o_x + 20 < cam_x`, C=1 = culled) in CODE,
called at the top of `upd_stone`, `upd_platv` and `upd_plath`; `upd_chib`'s
inline copy now calls it too (that paid for most of the 25 bytes, and FIXED had
20 left afterwards). Gold gate: all nine levels byte-identical.

Measured after the fix, replaying the port's own route through 3-1: the stones
are all gone by frame 480 (9 free slots), both lifts spawn (frames ~880 and
~1000), and Mario rides one from world x 835 to 893.

## Where the searches stand

* GB search: world x 817 (the lip of the big pit) — it will not wait for a lift.
* Port search: world x 926 — it rides the first lift and dies transferring to
  the second.

Neither is a port defect; both are the greedy search's horizon. Riding a lift
means making no progress for ~100 frames, which every fixed horizon punishes.
The next step for the instrument is a progress metric that counts "riding" as
progress (the port has `ride` in RAM; the GB needs the equivalent flag found).

## Measured, NOT changed: the spawn trigger is ~8px of camera early

With the camera reconstructed exactly on both sides (GB: high bits from the
$C0AB block counter, low 8 from SCX; port: `cam_x` is already exact), each
spawn's first frame was logged on both engines for the same script:

| entry | GB fires at cam | port fires at cam | GB object x | port `o_x` |
|---|---|---|---|---|
| $36 stones col 24 (x2) | 200 | 193 | 391 / 399 | 384 / 392 |
| $36 stones col 25 (x2) | 216 | 209 | 407 / 415 | 400 / 408 |
| $36 stones col 26 (x2) | 232 | 225 | 423 / 431 | 416 / 424 |
| $0A lift col 52 | 648 | 640 | 847 | 840 |

The GB's rule, exactly: **trigger when `cam == col*16 - 184`** (independent of
`x_off` -- both members of a pair fire on the SAME frame), and the object lands
at **`col*16 + x_off*4 + 7`** in GB RAM coordinates.

The 7px of x is a coordinate convention, not an error: the GB draws this sprite
8px left of its RAM x (OAM: lift RAM x 71 -> tiles at 63/71/79), so its visual
left edge is world 839 against the port's 840. One pixel.

The trigger, though, really is ~8px of camera early in the port, which starts
each object's clock 8 frames sooner (visible as phase on anything that moves).
`spawn_check` already carries a measured lead rule, `fire + off*4 + 15`, but it
is GATED TO 2-3 because the same rule shifts 1-1/2-2/3-1 and those were verified
under the old timing. The 3-1 numbers above disagree with that formula's `off*4`
term (the GB fires a pair together), so the general rule wants re-deriving
against 2-3's capture before it replaces the gate. Deferred deliberately: it
touches every level the user has already signed off, and 8 frames of lead is not
what makes a platform unlandable.

## The corpse that rained down the screen (user-reported, 2026-08-22)

"Killing the first enemy makes its corpse respawn and fall from above... and it
does not drop only once, drops constantly."

`o_y` is a BYTE. W3 had **no vertical cull at all**: an object that left the play
area vertically ran its y past 255, wrapped, and re-entered from the other edge
-- forever. Captured on the shipped ROM (3-1, slot 2, GB type $3C): `o_y` 0 ->
255 at frame 822, then 255 -> 0 at frame 860. Round and round.

2-3 has had the guard since its anomaly sweep (`kit_sh1.inc`, gated `.ifdef
MAR23`); W3 was never given it. The W3 window segment has no room for it, so it
went into `w3_touch` (bank-resident W2FAR, +15 bytes):

```
    lda o_y,x
    cmp #168          ; GB-measured floor: the $3D corpse despawns at GB y 192,
    bcc :+            ; and port o_y = GB y - 24, so 192 -> 168
    cmp #232          ; 232..255 is a legal NEGATIVE y, not an escape
    bcs :+
    stz o_type,x
    rts
:
```

The 232 window matters and is measured, not slack. 3-1's high-ledge Batadon
(spawn col 49, GB ground y 48) hops 30px and peaks at GB y 18 -- which is port
`o_y` -6 = 250. On the GB it peaks there and comes straight back down; a naive
"anything >= 168 dies" would delete it mid-hop. After the fix the port's arc is
250 -> 254 -> 1 -> 11 -> 21 -> 36 -> 48: the same peak, the same landing.

Hop timing was verified against the GB on the same enemy with Mario standing
still. GB: ground 136, peaks 106 / 106 / 82, turning at frames 42, 86, 136, 154,
204, 260. Port: ground 112, peaks 82 / 82 / 58, turning at 127, 171, 221, 239,
289, 345. Every y is exactly 24 lower (the coordinate origin) and every interval
matches beat for beat -- 44, 50, 18, 50, 56 on both. The hop itself was never
wrong; only the missing cull was.

Gold gate: all nine levels byte-identical.

## The standable-top flag — one missing bit, four user-visible bugs

User, after playing the fixed build: the rising pipe cannon hurts Mario instead
of carrying him; he still cannot land on the little moai ledges; a stomped
missile turns into a winged moai head; and "the cannon is not hiding in the
pipe".

**The GB marks "Mario can stand on this" as bit 7 of PhysicsParamTable byte 1,
and the rest of that byte IS the collision box** — `(hi nibble - 8) * 8` = width,
`(lo nibble) * 8` = height. Cross-checked against every W3 metasprite's display
list, and it matches all of them:

| phys1 | box | types |
|---|---|---|
| `$91` | 8x8 | `$35`, `$36` (the stepping stones) |
| `$A1` | 16x8 | `$3A`, `$3B` (the moai ledges) |
| `$B1` | 24x8 | `$0A`, `$0B` (the moving lifts) |
| `$92` | 8x16 | `$49` (the pipe cannon) |
| `$A2` | 16x16 | `$33`, `$47` |

Across the whole table the bit is set for `$07 $0A $0B $0C $13 $14 $33 $35 $36
$37 $38 $39 $3A $3B $47 $49 $4C $4D $4E`. The port hard-coded the four it knew
about — `OBJ_PLATV`, `OBJ_PLATH`, `OBJ_STONE`, `OBJ_GIFT` — and W3's entire set
was thin air. That single omission is bug 3 (the cannon), bug 4 (the ledges),
AND the reason both auto-players failed to cross 3-1's big pit: the crossing is
lift -> `$3A` ledge -> lift, and the middle step did not exist.

`w3_stand` (kit window) implements it from that byte:

* top = `o_y + 16 - h`, Mario's feet are `spr_y + 16`, so standing means
  **`spr_y = o_y - h`**;
* x window `|mario centre - (o_x+4)| <= w/2 + 2`, which reproduces the
  GB-measured support range on the `$49` cannon (supported while `mario_x -
  obj_x` is in `[-2, +10]`; he falls at -3 and at +11);
* landing beats every contact rule, exactly as on the GB — `$33/$35/$47` hurt at
  the SIDES but carry Mario on top;
* no `ride` bookkeeping: `update_objects` runs after `move_player`/`jump_player`
  (the GB's order too — platform landing comes after FloorCheck), so re-snapping
  each frame IS the carry, and walking off the edge simply stops it.

Measured after the fix, port vs GB on the same cannon: Mario lands at
`spr_y = pillar_y - 16`, is carried 112 -> 96 and back, and jumps off cleanly —
the GB's arc to the pixel.

Space for it came from the W3 build itself: **no W3 level spawns `$0C`** (checked
all three spawn lists), so the rock's update/draw are compiled out, and the
Yurarin-Boo aimed ball (only reachable from `upd_leap`, already `.ifndef EAS3`)
went with it. The W3 window had 5 bytes free before that.

### The corpse's costume is the corpse's business

`w3_touch` forced param `$27` on every stomp. GB truth: `$3C` stomps into `$3D`,
whose script opens `F8 26`; `$4B` (the missile) stomps into `$0D`, whose script
has **no `F8` at all**, so the missile's own param carries and the corpse is a
falling missile. Forcing `$27` painted the Batadon's squash on everything — the
"winged moai head" floating over the pipe in the user's screenshot was a stomped
missile wearing it, which also explains "the cannon is not hiding": the cannon
was hidden, that was the corpse. Removed; the port's corpse now carries `$52`,
the missile's own art.

## The underground-room batch (2026-08-23): six bugs, all measured, all battery-verified

User reports, verbatim class: the missile's death sprite is the Batadon's; the
cannon is still visible over its pipe; the freshly fired missile gets stomped by
STANDING Mario; Mario stands on spikes unhurt; the pipe descent leaves an
unerased trail; the room's block pays one coin and turns solid where the GB's
"just disappears".

1. **Spikes ($ED).** GB FloorCheck `$181E`, RE'd byte-for-byte: landing tile ==
   `$ED` -> star immune, else hurt (small `$09F1` = death, big `$09E0` = shrink,
   transitional sizes skip), and STILL falls through to LandSnap -- spikes are
   solid ground that bites. Port: `read_solid` now records `feet_tile`; the
   grounded-support path calls `spike_check` (LEVELS). Battery: small dies on
   landing, big shrinks and stands.

2. **The unlisted-$80 block.** GB dispatch `$19C4/$19CD/$19D1`: `$81` with no
   content entry pays the single coin + used block (the port's old default --
   correct for `$81`, and every one of 1-1's 24 unlisted blocks is an `$81`);
   but `$80` with no content is `jp $19E1` -- **it IS a brick**. Small hop, big
   smash (+50, shards, cell gone), never a coin. Confirmed three ways: the
   disassembly, a PyBoy room-2 capture (the bonk re-stamps the cell as `$82`,
   score/coins untouched through five bonks), and the user's own mGBA
   screenshots (+50, shards, block gone). Port: the ceiling dispatch pre-checks
   `find_block` for `$80` and routes unlisted ones to the existing brick path;
   `map_modded` maps a modded UNLISTED `$80` to blank (smashed), a listed one
   stays the used block. `hit_qblock` moved to LEVELS to pay for it (FIXED was
   full). Known 1-tile cosmetic gap: after a small-Mario hop the GB re-stamps
   the cell as brick art; the port's 1-bit mod map cannot represent that state,
   so the cell keeps the block art (mechanics identical).

3. **Missile stomped by standing Mario.** The contact y-window compared sprite
   TOPS with a fixed 14 -- exact for 16-tall types, 8px too generous for the
   8-tall missile whose art sits in the cell's bottom half. GB-measured: the
   `$4B` passing 8px under standing Mario's feet does nothing. `l3_box` (EAS3)
   now takes the height from phys1's low nibble: touch iff `3-h <= spr_y-o_y <=
   13` (collapses to the old |dy|<14 when h=16). Battery: the missile fires
   from under standing Mario and flies 100px untouched (it died at spawn+4
   before).

4. **The Batadon-squash corpse on a stomped missile** -- fixed earlier today
   (the forced param `$27`); the battery run confirms the corpse now carries
   the missile's own `$52`.

5. **Pipe-descent trail.** `pipe_animate` called `restore_bg` bare, but
   restore_bg reads `rb_*`, which only render_all loads -- the erase repainted
   whatever rectangle the last render left there, so the sinking Mario stacked
   unerased copies up the pipe. It now loads `rb_*` from `prev_*` exactly as
   render_all's pass 3 does. Verified: the frame before room entry has zero
   sprite residue above the rim.

6. **Cannon visible over the pipe.** `draw_quad`'s behind-test sampled ONE BYTE
   (4px) of two rows; the pipe art is vertical stripes, so some camera sub-byte
   phases landed the sliver on a white stripe and the "background here?" test
   read 0. Now samples the quad's full 8px width on both rows. Verified across
   4 camera phases: during the straddle only the above-rim rows draw.

Gold gate after the batch: all nine levels byte-identical.

### The strobing landing (follow-up to w3_stand)

Landing on a standable W3 object strobed jump/stand poses and flickered
(user-reported): `jump_player` runs BEFORE `update_objects` each frame, its tile
probe found AIR under Mario's feet (the ledge is an object, not map tiles),
flipped him airborne, and w3_stand snapped him back 4 calls later -- a
grounded/falling flip every frame. The engine's own platforms prevent exactly
this with `ride`, which w3_stand had skipped. Now: w3_touch sets `ride =
slot+1` while w3_stand holds him and clears it only if it was his own slot;
`ride_support` accepts OBJ_W3 unconditionally (w3_stand owns the geometry).
Verified: 194 frames on the sinking ledge with ZERO jump_state transitions
(was ~2/frame), pose stable, spr_y tracking the ledge both directions; the
cannon ride unchanged; walking off the edge clears ride and drops him on the
next frame.

### The two regressions of 2026-08-23 morning, and the real cannon bug

**Stomp became a hurt.** The height-correct touch window was right; the
stomp/side split (`l3_above`, "+4 above") was calibrated on 16-tall types and
sat INSIDE the missile's touch window: falling contact landed stomp or hurt on
alternate phases. The GB's $08C7 constant through the measured +2 anchor shift
puts the split at dy <= -2. w3_touch now divides with the box height l3_box
leaves in tmpH3 (`stomp iff dy+h-3 <= h-5`); for 16-tall types every falling
contact still reaches the stomp region first, so nothing else moves. Battery:
5/5 landing phases stomp cleanly; the standing pass-through still passes.

**The cannon was never properly hidden -- the gate tested the WRONG REGISTER.**
`draw_quad` called `set_dst` (which does `ldx dy`) BEFORE `w3_behind`, whose
whole job is `cpx <tile>`. It had been comparing the ROW NUMBER against
$87/$92/$EE since the priority feature was born; blit_behind armed at random,
which is why the artifact came and went with camera phase and o_y, and why
three spot checks "passed". One line -- call w3_behind before set_dst -- and
the below-rim band is byte-identical to the hidden reference through the whole
rise, 0/150 frames at four camera phases. The widened row sampling (0/5/7,
full 8px width) stays: with the gate armed, it is what skips a straddling
quad whole. E28 below is the law.

## The Tokotoko ($31) — the stompable roller (MISNAMED Ganchan below; see E30)

User: "the whole boulder hopping is implemented wrong... study the mechanics
and fix it... the last half of the level depends on it."

**GB truth, measured + disassembled.** The $31 script is trivial (divider 4,
params $2A/$2B alternating, dx 6/tick = 1.5px/f, no F0: default direction).
Everything else is ENGINE physics keyed on PhysicsParam byte 0 (= ffc7),
disassembled at $267B/$28CE/$2958:

| ffc7 bit | meaning |
|---|---|
| $02 | GRAVITY: 1px per FRAME while unsupported; on landing `and $F8` (snap) |
| $04 | REVERSE at walls (`set/res 0,ffc5`) |
| $30 | landing response: $10 stop, $30 restart script (already in w3_move) |
| $C0 | ledge response (not yet needed by any spawned W3 type) |

$31 = $06 = gravity + wall-reverse: a ping-pong roller. GB-measured: rolls at
1.5px/f, reverses at the block towers (x 38 <-> 200), falls 1px/f off ledges.

**The ride is a STOMP, not a stand.** phys1($31) = $22 -- bit7 CLEAR, so the
$0AEA platform path ignores it (that path `bit 7,(hl)`-gates on slot byte +10,
which is phys1 -- the same bit as w3_stand's). Landing on a rolling boulder
takes the $08C7 stomp path: contact col+0 = $40 -> **the boulder morphs to $40
and STOPS DEAD, pays 400 (class 1), and Mario takes the stomp bounce**
(GB-captured: x froze mid-roll the frame Mario's feet arrived, score +400,
c207 -> 1). $40's own script = param $2E, wait ~45 ticks, then $41 (sound) ->
$0D (the falling corpse) -> gone ~50 frames later. GB frame log: $31 -> $40 at
f56, -> $41/$0D at f103/104, freed at f155. Crossing the spike stretch =
bounce boulder to boulder, each one stopping ~0.8s under you before it
crumbles.

**Port.** The stomp chain already ran through the VM (col+0 morph, class
score, bounce); what was missing was BOTH ffc7 engine bits -- the boulder
glided forever ("no gravity at all") and never ping-ponged. Implemented as
`w3_ffc7`, run per FRAME before the tick gate. It lives in the LEVELS common
prefix, not the kit window: the window is full to the byte and its ceiling is
hard -- $1D00 is HUDSHADOW (growing the window let the HUD overwrite kit code
every frame; found by the window-vs-file byte compare). The kit mirrors phys
bytes 0/1 into per-slot RAM at spawn/morph (`w3_ph0/w3_ph1` -- in the BOTTOM
of the stack page, because BSS ends flush against RCRAM at $1200 and even 20
more bytes broke all nine levels at once; gold caught that twice). w3_stand
moved to LEVELS the same way and reads the phys1 mirror.

**Verified** (tools/battery31.py, all PASS): rolls + grounded + 5 wall
reversals; stomp -> $40 + exactly +400 + crumble -> $0D; the six other
regression tests unchanged. Gold gate: all nine levels byte-identical.

Two honest deviations, both load-related, same family as the parked composite
renderer (#24): under object load the update stagger stretches VM ticks (the
boulder can roll ~1.0px/f where the GB holds 1.5, and the stopped-boulder
window runs ~72 frames vs the GB's ~47 -- SAFER for the player), and heavy
frames still tear sprites (the "split boulder" -- 45 of 319 composed frames in
the battery scene; the game frame occasionally spans two display frames).

## The map extraction is byte-exact (and how the instrument lied)

Chasing a "photographic pit" that our map didn't have, the GB's own stream
buffer ($C0B0) was captured for every column the level streams, labeled by the
GB's own counters (ffe5/ffe6): **434 columns, 0 mismatches** against
build/levels/level_06.json with `world col = (ffe5-3)*20 + ffe6-1`. The
extraction was never wrong; the "pit" screenshots were taken during post-death
replays where my computed camera was stale. Lesson recorded: a runner that can
die mid-capture poisons every downstream label -- validate captures against
the subject's OWN counters, not reconstructed ones.

## The Tokotoko art was corrupted at the SLICE level (user-reported three times)

The user kept reporting broken boulder animation; it was triaged as tearing
twice. Byte-level truth: in the previous shipped image, EVERY overlay-sourced
entry of the bank-6 W3 tile slice differed from its source sheet -- both
boulder frames were built from wrong tiles (frame A merely happened to look
rounder). The current image's slice is byte-identical to
build/gfx/w3_ovl_8A00.svt for all 56 overlay entries, and composing A4|A5 /
B4|B5 from that sheet yields the GB's round boulder exactly. The fix shipped
implicitly with the bank-6 re-pin (W3SCRB $B200 / W3DLB $B540 / W3TILB $B740)
that made room for the grown kit -- the old pin layout had let something
tread on the slice. Verified: slice==sheet byte-for-byte in the shipped ROM.

## The ride question, settled twice

A second, fully NATURAL measurement (buttons only, no state pokes: walk, wait
for the rolling boulder, jump, land on it): $31 -> $40 the frame Mario's feet
arrive, +400, Mario bounces (c207=1). Same result as the forced-drop capture.
There is no carried-ride in the GB engine: the crossing is the stomp relay --
each touched boulder stops for ~45 ticks (the cracking platform), then
crumbles. What screenshots show as "riding" is the contact/bounce instant.

## The slowdown, quantified (task #30, in progress)

Metric: the level timer decrements once per 40 LOGIC frames, so timer ticks
per 600 DISPLAY frames measure the logic rate directly (15 = full speed).
Measured on the real core, godmode build:

| scene | ticks/15 |
|---|---|
| 1-1 walking | 15 |
| 3-1 start, walking | 15 |
| 3-1 first cannon, standing | 15 |
| 3-1 two-cannon pair (cam 1160), standing, 8 objects | 14 |
| 3-1 pair zone, walking | 12 |
| 3-1 Tokotoko zone, walking, 10 objects | 12-13 |

So ~20% logic loss in the busy zones -- and the music sequencer ticks once
per LOGIC frame, so the music drags by the same 20% (the user's report).
W3's banked map reader is NOT the walking overhead (3-1's start walks at
full speed); the cost is scene-local. The py65 play-in profiler run will
name the routine. Also learned: the py65 harness CANNOT be teleported --
camera pokes without the NMI's resync run the renderer into a BRK loop
(the real core tolerates the same pokes); enter scenes by simulated play.

## NAMING CORRECTION (2026-08-23) + the Ganchan, done right

Everything above that says "boulder (Ganchan, $31)" measured the **TOKOTOKO**
($31). The rideable boulder the level's spike pits are crossed on is the
**GANCHAN, type $47**, spawned forever by the six $03 sky spawners (cols
155/165/175/185/195/215, y 56 -- mariowiki's "six points" exactly). The user's
wiki links exposed the swap; every measurement was tagged with its type id, so
all numbers survived under corrected names (law E30).

**The Ganchan ride (user: "mario can stand on it but does not ride with it").**
phys1($47) = $A2: bit7 SET -> w3_stand's platform path, not the stomp path.
What was missing was the CARRY: the GB moves the rider's x with the object's
every step. Port: w3_move's x-step now calls `w3_carry_rt/lf` (LEVELS) when
`ride == oi+1`; right goes through `carry_x1_rt`, the SAME pin/cam-push helper
upd_plath uses (dedup, so the camera rules match the 2-1/2-2 platform rides).
Real-core proof (battery test 10): drop onto a hopping Ganchan -> ride holds
376 frames, boulder dx == Mario dx exactly (75==75, 73==73, 57==57). Before
the fix the same drop rode for ~30f and slid off (the boulder moved out from
under him) -- which is precisely what the user reported.

**The tumble frame (user: "the 2nd boulder animation frame is corrupted...
I told you this before").** Param $47's display list carries bit5 in its
control bytes = Y-FLIP: the second frame is the same C2/C3/D2/D3 quad rotated
180 degrees. The port's control decode implemented bits 0-4 and silently
ignored bit5, drawing the tumble frame un-flipped = the user's halves-wrong
screenshot. Now: w3_draw decodes bit5 -> `do_yflip`; draw_quad reverses the
tile through `flip_to_buf` (shared with the corpse y-flip) before the blit.
Pixel proof off the real core's framebuffer: composite(param $47) ==
rot180(composite(param $31)) with 8/256 differing pixels, all background
bleed at the rect edges, zero on the boulder body.

**The freeze that almost shipped instead.** First implementation placed
flip_to_buf in the banked common prefix; called inside w3_draw's bank-6
window, the jsr executed TILE DATA and the Ganchan froze mid-hop, whole slot
pinned. Bisected in three steps (kit decode reverted -> unfroze; decode back +
engine path stubbed -> stayed unfrozen; therefore the engine call), then
rom.lbl showed flip_to_buf at $98E9 = bank territory. Law E29. FIXED paid for
it by evicting carry_x1_rt (only ever called under the normal mapping) to the
common prefix.

Gate state: battery 10/10 (new test 10 = ride-carry + rot180 pixel check),
svgold 9/9 byte-identical vs the shipped reference.

## The music no longer drags (task #30, first half)

The GB runs its audio sequencer in the VBLANK INTERRUPT: when game logic lags
(and original SML lags plenty), the music keeps perfect time. The port ticked
sfx_tick/mus_tick once per LOGIC frame at the top of main_loop, so every
dropped logic frame dragged the tune -- the user's "slowdown in music too!".
Fix: `audio_catchup` (low common prefix, $8205) ticks audio once per elapsed
DISPLAY frame (mus_seen vs the NMI's frame_count), clamped so a long stall
(level load, pause exit) resyncs with ONE tick instead of bursting the
backlog; mus_seen self-heals from garbage via the same clamp. NMI-side audio
was rejected deliberately: mus_tick + the music data live in the banked
common prefix ($82xx/$8D80+), and an NMI landing inside w3_draw's bank-6
window would execute tile data (law E29).

Real-core proof (mus_wait tick-decrements per 600 display frames, walking):
start 595, tokotoko zone 578 (logic 425!), ganchan 587 (logic 483) -- audio
at display rate everywhere while logic still drops. Battery 10/10, gold 9/9
byte-identical.

Logic-rate ground truth for the remaining work (timer_sub decrements per 600
display frames, real core, R900 walks): start 585, two-cannon 503, tokotoko
375, ganchan 449. A/B attribution: per-mover render ~4.4k cycles (bud_base
3->2 gains ~39 logicf in the tokotoko zone), W3 logic the rest; the cannon
zone's own deficit is ~6 NOKOBONS alive at once, not the cannons.

## The logic slowdown cut to GB parity (task #30, second half)

Profile (py65, route-driven): a busy frame is ~73% renderer -- the sprite blit,
the erase, and their addressing. Three cuts, each measured on the real core
(logic frames per 600 display frames, camera parked in the zone, Mario pinned
clear of contact; full speed = 585, and the REAL GB measured on the same
metric lags 9-13% while scrolling, so parity is ~520):

| cut | tokotoko | ganchan | two-cannon |
|---|---|---|---|
| (before) | 424 | 484 | 549 |
| W3 mover budget 3->2 + unrolled blit_blank | 475 | 503 | 552 |
| tight erase boxes | 501 | 543 | 565 |

1. **W3 mover budget 2** (load_level, cur_level >= 6): the GB itself staggers
   OAM under load; a mover redrawn a frame late is invisible next to a 62%
   logic rate.
2. **blit_blank unrolled** (~160 vs ~280 cycles): the hottest primitive -- a
   busy frame zero-fills ~25 cells (sprite erases over sky + stream blanks).
   Lives in the LOW common prefix; FIXED is full.
3. **Tight erase boxes**: w3_width's default was $C5 = 40x24px -- sized for
   the Batadon's [wing|head|wing] band and paid by EVERY W3 metasprite: a
   16x16 Tokotoko erased 15-20 cells where 8-12 suffice. gen_w3data now
   emits the default as $84 (one quad) and EXACT exceptions for the seven
   bigger params (the four legacy boss entries keep byte-identical values).
   w3_cinval moved to the prefix to pay for the table growth (far kit full).

**Verified**: battery 10/10 (tests 9/10 now scout the boulder's own trajectory
and drop Mario onto it -- fixed drop frames went stale at every speed change);
stray-pixel sweep CLEAN in all three zones (frame-diff outside live object
rects, 46 pairs each -- no smears from the tighter erases); svgold 9/9
byte-identical. One real bug found by the wrap check: w3_carry_lf could carry
Mario past the left screen edge and wrap spr_x to 255 -- now clamps at 8 and
Mario drops off the ride, like the GB's own screen-edge stop.

Left for later: the last ~20 logic frames to exact GB parity in the Tokotoko
zone belong to #24's composite renderer (erase+draw in one pass).

## The kill-trail orphan (user-reported on the parity build)

User: "trails especially after killing enemies and in some times artifacts
would spawn out of nowhere." The hole: when an enemy dies ON SCREEN, its
image waits one render for the dead-slot leftover erase -- but the spawner
runs in the SAME logic phase, and the kit's allocate path stamped `stz
o_pdr` on the reused slot ("fresh slot: nothing to erase"), orphaning the
corpse's pixels on screen forever. Fix (w2_go + spawn_wball + mek_fire): a
slot whose previous occupant is still drawn is REFUSED for one frame -- the
render erases the leftover, the spawner retries next frame (spawns fire
~184px off-screen; the delay is invisible). The engine-side spawns never had
the hole: they keep o_pdr/o_pvx, so the new occupant's first dirty pass
erases the old image.

Verification limits, stated honestly: the hole is code-proven, and the fixed
build shows ZERO persistent world-space strays across a 2,300-frame scrolled
route replay plus tight-mask parked sweeps in three zones -- but the exact
kill+same-frame-spawn collision did not occur under any scripted replay, so
the user's sighting could not be reproduced pre-fix either. If trails
reappear on this build, the next suspect is the eviction path (POPUP/SQUASH/
CORPSE victims), which reads as self-healing but is untested under pool
pressure.
