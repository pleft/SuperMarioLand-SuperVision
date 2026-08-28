# 44 -- World 3-3 (level 8): RE log

Reference: https://www.mariowiki.com/World_3-3_(Super_Mario_Land). Rule 0
throughout: nothing below is "verified" unless a GB capture (PyBoy,
tools/gbtrace.py / gbdeep.py / gbrun.py) and a port capture (real Potator core,
tools/svtrace.py / svrun.py) were compared frame by frame.

## Units and tooling (this round)

* `tools/gbtrace.py` camera is now PIXEL-exact: `cam = (c0ab*16-192)` refined
  with `$ffa4` (the fine scroll; `$ff43` is NOT what the game scrolls with).
  Before this fix a walking Mario looked "stuck at c202=81" -- that is just the
  camera pin (screen x 81 while the world scrolls).
* `c202` = Mario sprite-left + 10 (not 15: gold-verified port start x 40 =
  GB c202 50). Object `ffc3` = left + 7 (screenshot-checked on the lifts).
* Pad letters everywhere (svshot, svauto, gbtrace/gbshot/gbdeep/gbrun):
  `R L D U B A J(R+A) K(L+A) F(R+B) Q(R+A+B)`. svauto now searches run plans
  (Q/F) and finer DELAY/HOLD steps; `tools/dual.py LEVEL "script"` runs one
  script on both machines and prints (left, feet) + every object.
* `tools/gbdeep.py LEVEL SEG "script" out.json` = the `$ffe5` deep start.
  The c0ab column base can be 128px off there, so the camera integrates
  `$ffa4` deltas from frame 0 (absolute x may still carry that constant
  offset -- compare RELATIVE motion only).

## Mario physics: the air-momentum rule (port bug, FIXED)

GB bank 3 `$49ed` (jump start): `$c20c = $30`; a newly pressed Down seeds
`$c20c = $20` (`$49b5` PlayerJumpDown); B newly pressed with `$c20c == 6` and
no Superball zeroes it (`$49fd`). `$1dd8`/`$1e8b` increment `$c20c` every held
frame unless it is EXACTLY 6 (so the $30 seed keeps counting up in the air),
and the landing code (`$0b7f`, `$121a`) clamps `>= 7` back to 6. In the
no-input branch (`$1d5e`) the counter decays 1/frame and Mario keeps moving in
the remembered direction at speed index 0 (0.5px/f) while it lasts.

Effect: releasing the d-pad mid-jump on the GB leaves Mario GLIDING 0.5px/f
until he lands (up to ~48 frames); the port capped the counter at 6 and
stopped him within 2 frames. Measured (level 8, `R6,J10,.40`): GB x 48->62
after the release, port 53->56 (before) / 42->67 (after, = GB). Ported in
`move_player` (entry: landing clamp, Down seed, B rule) and `@startjump`
(`move_t = $30`, walk speed index 2 unless running). Gates: svgold IDENTICAL
(9/9), battery31 8/10 -- the two room tests failed only because their recorded
room prefix (3-1 pipe route) no longer replays; re-recorded via svauto.
docs/routes/level_07.txt (3-2) also stopped completing -> re-recorded.

## 3-3 object roster (spawn list, px = spawn col * 16)

`$0B` moving lift x5, `$36` stepping stone x4 (pairs at 624/1360),
`$38` diagonal lift x3 (down-left/up-right), `$39` x2 (up-left/down-right),
`$3A` vertical lift x2, `$3B` horizontal lift x3, `$0E` Kumo x2 (848/912),
`$04` Goombo x2, `$02` Pakkun (pipe 648), `$47` Ganchan x2, `$3C` Batadon x2,
`$31` Tokotoko (1840), `$32` Hiyoihoi (2336), hard-mode `$B1/$BC/$84`.

### GB-measured behaviours (all matched by the port unless noted)

* `$0B` (224): y 112, 0.5px/f, range 181..233 (period 200f). Port identical
  (spawn ~13px earlier on the port -> phase offset only).
* `$38` (288): diagonal, 1/3px/f, (289,89) <-> (253,125); `$39` (320):
  (321,88) <-> (284,51). Port ranges identical (its RAM y is 24 lower for
  engine lifts -- the drawn positions match).
* `$38`#2 (400): (408,81) <-> (371,118). `$3B` (464): horizontal y 56,
  414 <-> 465 at 0.5px/f. `$3A` (608): vertical y 96..154 at 0.5px/f.
* Ganchan `$47` (624): script F4 $02 = a velocity byte fires every 3rd frame;
  42,42,22,22,12,12,12,02 = 15px hop from rest (GB y 120 -> 105), dx 2 per
  fire (GB adds ~1px/4f of Mario-tracking drift). Port: same 15px / same
  cadence (per-frame compared). It hops over the 552 pipe and the pit and is
  culled off the left edge on both. The boss's thrown ones: 33px hops.
* Batadon `$3C`: hops in ~40px-wide, ~30px-high parabolas toward Mario,
  turning at each landing.
* Hiyoihoi `$32` (HP 9): 116-frame cycle -- lunge left 12px (vel 7,5), stand
  16f, step back 12px, three 30f poses (param $55/$54); at the pose change it
  spawns a `$33` at its feet which becomes a `$47` immediately (32px hop).

## Renderer: the third lift of a cluster was (nearly) invisible (FIXED)

3-3 runs three lifts at once (`$38/$39/$38#2`, later `$38/$39/$3A`). With
W3's 2-movers/frame budget and the pass-1 origin rotating ONE slot per frame,
the third mover in slot order got the budget only 2 frames in 10 (r=1,2 of
0..9): measured 51% of its moving frames with no redraw, and `$3A` at 1128
never visible while Mario approached it. Round-robin among movers (origin =
last served + 1) cures the starvation but churns the overlap propagation;
3-3 keeps the walker budget at 3 instead (`load_level`: level 8 exempt from
the W3 cut to 2). Redraw-miss rates after: 28/21/29% = the 1/3px-per-frame
lifts' legit "did not move a pixel" floor.

Logic-frame drops in the lift clusters (measured by counting `timer_sub`
changes per NMI frame): with 3 lifts on screen the main loop ran only 76-87%
of the frames (budget 3) / 88-94% (budget 2) -- Mario's jump off a lift
covered 32px where the GB's covers 48px, purely from the dropped frames. The
lift metasprites ($12 24x8, $22 16x8) were erased with the generic 40x24 box;
gen_w3data now gives them a 2-row box ($85/$84: 5/4 columns incl. the 8px
left shift -- 4 columns trailed). Result 87-96% of the frames run; no trails.

Replay fragility (E23) confirmed: ANY renderer-load change shifts the main
loop's phase against the pad sampling, so recorded routes diverge within a
few hundred frames even with zero missed NMIs (frame_count checked). Routes
are therefore re-recorded on the FINAL build only.

## Route (port): hand chunks past the lift puzzles, svauto in between

Recorded on the FROZEN build (god md5 770a9638...). Cluster 1 (288-464):
`R2,J8,R28,J6,R36,J6,R8,.40,F3,Q14,F4` (pipe, pillars, `$0B`), `.105,J6`
(`$38`), `.108,J8` (`$39`), `.290,Q14,F30` (`$38`#2, running), `.100,R8,J12,F20`
(`$3B`), `.40,F8,Q16,F16` (totem base 515). svauto then ran the pillars and
the cave to 913 by itself. Cluster 2 (1008-1296): the two diagonal lifts are
only half a period apart when their spawn triggers (cam 848 / cam 896) fire
within a few frames -- so WAIT at 885 (after `$0B` spawns, before `$38`'s
trigger) until `$0B` is about to reach 956, then run and board at once:
`F8,.58,F14,.2,Q10,F30`, `.80,J6` (`$38`), `.114,R6,Q10` (`$39`),
`.90,R4,Q14,F20` (`$3A`), `.48,F6,Q14,F30` (low `$0B` lane), `.104,R4,J10,F30`
(the 1296 block). Timings found with `tools/svsweep.py` (parallel sweeps).
Brick maze (1472-1583): the search wedged Mario into the 8px slot beside the
1544 block (it had no LEFT plans -- svauto now has them: letters L K G H).
The way is UP: from the low `$3B` lift (feet 136) onto the 1544 block (feet
104), a LEFT jump onto the 1528-1543 ledge (`K10,L2`, feet 72), a jump onto
the cap over the 1552 wall (`.16,R3,J14,R4`, feet 40), then walk off the cap
to the 1560 floor (`.10,R20,.40,F20`). svauto continues from there.

## Back half (port trace along the completing route vs the GB captures)

* Batadon `$3C` #2 (2192, open air): port arc 69->42->92 raw = the GB's
  ~30px hop; stomp -> `$3D` corpse falls. Batadon #1 (1776) restarts its hop
  loop when its head meets the 1744-1767 block while rising (kit rule: phys
  byte0 & $C0 = $C0 -> RESTART, the GB Suu rule) -- GB-unverified for this
  Batadon (no GB route reaches it; deep starts land past it).
* Tokotoko `$31` (1840): walks toward Mario, turns when passed (3-1 engine).
* Hiyoihoi `$32`: 116f cycle, lunge 2336->2324, throws `$33`->`$47` (33px
  hops) -- same numbers as the GB capture. Superball: 10 balls -> `$4F`,
  +1000 (port; GB points not reproduced -- the GB Superball state could not
  be poked from a deep start). The auto-route jumps over the boss to the
  sphere ledge (2371, feet 88): goal at frame 3828, tally, then the x-3
  rescue machine (goal_phase 5). The GB's post-sphere boss behaviour is
  NOT captured (the deep-start GB run fell into the 2312-2335 gap).

Route: docs/routes/level_08.txt (completes on the frozen god build).
Gates on the shipped build: battery31 10/10, svgold identical.

## User playtest round 1 (2026-08-26)

* "Cannot stand on the 3rd platform / falls like it does not exist" (then
  intermittent): `w3_stand` measured Mario's distance from o_x+4 -- an 8px
  object's centre -- for every width, so a 24px lift was standable 12px LEFT
  of its bar and not on its right third. Now Mario's x is biased by 4(w-1)
  around the shared `mario_dx` (window centred on o_x+4w, half-width 4w+2):
  measured standable span = the drawn bar +/-2px. `mario_dx` folded (+8/-4)
  to pay for it in the LEVELS prefix. Gates green.
* "Platforms flicker like hell": the 3-3 mover budget of 3 made the frame
  overrun -- o_pdr=0 (not drawn) 28-40% of frames vs 3-13% at budget 2.
  Reverted to 2; with the tight lift erase boxes three lifts on screen now
  draw 187/188 frames each (round-robin origin measured slightly worse).
* "Movement seems slippery": the GB air-momentum rule (above) -- releasing
  the d-pad mid-jump keeps Mario gliding at 0.5px/f until he lands; measured
  identical to the GB on 1-1 (ground release, run release, run-jump release).
* Boss "almost invisible" was reported on the budget-3 build; to re-check on
  the budget-2 build once a route reaches the arena again (all recorded
  routes/prefixes diverged with the landing-window change).
* "4th moving platform is choppy": measured on the drawn coordinates --
  `$38`#2 (the third mover in slot order) updated its image every ~7 frames
  in 8px steps (62 moves/432f) while the other two updated every 3rd frame
  (200 moves/600f): the 1-slot-per-frame origin rotation starves the third
  of three movers (2 frames in 10). Fixed: pass 1 records the last mover
  served (`stx rot1`) so the next frame's scan starts after it -- true
  round-robin. After: 149 moves, max step 2. Costs ~6% logic frames with
  three lifts (was measured "slightly worse" on not-drawn counts earlier,
  but not-drawn with the image kept is invisible; the 8px steps were not).
* Arena erase boxes: the boss's ($54/$55) row encoding gave 5 rows for a
  24px sprite (rows>=4 set both bits); now 4 ($A3). Ganchan poses $31/$47
  get a 4x3 box ($C4) instead of the 40x24 default. Arena logic-frame drop
  was 13% (213/246) before these.

## User playtest round 3: "boss barely visible" (2026-08-27)

Measured on the same per-scanline core commit as the user's RetroArch build
(c7e9419), via a WARP (svshot/svauto pokes: cam 2300 + a death -> the 1920
checkpoint, then a short svauto search to the platform, tools/svarena.py):
in the arena the frame overruns (logic 579/650 frames run) and the boss --
erased in pass 3a as slot 0, then waiting behind two Ganchan erases and
Mario's before pass 4 drew it -- showed as WIPED (BG restored through it) in
22 of 103 frames; every wiped frame was "dirty, erase done, draw not yet".
Fix: Mario's erase moved BEFORE the slot loop and the slots are erased
9..0 while pass 4 draws 0..9, so the lowest slot (the boss) has no foreign
work between its erase and its draw. Wiped frames 22 -> 5 of 103; the three
diagonal lifts all move in 2px steps now. (A pass-1 budget exemption for the
boss changed nothing -- the deferral was not the budget -- and was removed;
the Down/B momentum rules it had displaced are back.)

Respawn "in the gap next to the block" at the 640 checkpoint: the GB does
exactly the same (screenshot-matched), not a port bug.

Round 3b (strict metric: the boss's own 24x24 image box, full pose = 68-69
dark px): after the erase reorder the boss is intact in 73 of 105 arena
frames, partly wiped in 22, mostly gone in 10 -- still ~30% flicker frames.
The wiped stretches (2-7 frames) coincide with Mario or a Ganchan
overlapping the boss while the arena runs late (logic 578/650). A pass-1
"unmoved but not drawn last frame -> draw-only refresh" was added (paid with
the Down-seed rule) but measured NO change, as did a budget exemption: the
boss is not being deferred -- the whole render lands late against the beam
and the boss, the largest sprite, pays most. The arena is simply over the
software-sprite budget; the structural fix is the composed draw (CX_BUILD,
one protected object = the boss), parked after the 3-1 trial.
The refresh was then REVERTED (no gain, and it invalidated the just-recorded
route); the shipped 3-3 build is the round-3 one (Down/B rules present),
route docs/routes/level_08.txt completes on it (goal at frame 3597).

## Round 4: fewer boulders (user decision, 2026-08-27)

Elimination on the warp route (tools/svarena.py, strict boss-image metric,
105 arena frames): GB-faithful throws -> boss intact 73 / partly wiped 22 /
mostly gone 10; NO throws at all -> 106/2/0 (the boulders are the whole
cause: each throw's boulder is born inside the boss's box and hops out
through it). Hiyoihoi on 3-3 now throws every OTHER cycle (w3_child: level 8,
frame_count bit 7 -- ~one boulder alive at a time): intact 77/17/11. A wider
propagation window (dy<40), a boss redraw priority and a wiped-image refresh
all measured zero effect. The boss tiles are not in the behind-BG range.
This is a deliberate deviation from the GB for playability; the structural
fix stays the composer (docs/42).

## The boss walked into the pit (user playtest, 2026-08-28) -- FIXED

"the boss committed suicide by falling into the void". Reproduced by parking
Mario in the arena: Hiyoihoi drifted LEFT ~48px and kept going (x 2324 -> 2276
and further), because its script's two 12px steps per cycle both ran toward
Mario. The GB's own opcode handler ($2754) XORs the F0 argument's bits 3:2 into
ffc5 as `and $0C / rra / rra`: bit2 -> bit0 = X, bit3 -> bit1 = Y. The port had
them SWAPPED (bit2 -> Y, bit3 -> X) -- a workaround for a stomp corpse that
"flew upward", whose real cause was elsewhere. With the swap, the boss's
`F0 $04` (flip X) did nothing to its direction, so `F0 $40` (face Mario) won
every cycle and it marched off its platform.

Restored to the GB mapping. Measured after: the boss oscillates x 2336<->2348
(12px, the GB's own 2351<->2363) over 3000 frames with no drift. Gates:
battery31 10/10 (the stomp/corpse tests the swap was protecting still pass),
svgold identical, docs/routes/level_08.txt still completes. Affected kit types
are $0D, $1F and $32 only. 3-2's route needs re-recording (E23).

## Boss fight: NO boulders (user decision, 2026-08-28)

"lets try removing completely the boulders and have only the boss and mario as
sprites". w3_child now refuses the F1 spawn on level 8 outright. Measured on the
arena route (tools/svarena.py, the boss's own 24x24 image box):

    GB-faithful throws   intact 73 / 105   partly 21   gone 11
    every other cycle    intact 77 / 105   partly 17   gone 11
    NO boulders          intact 92 /  92   partly  0   gone  0

Logic frames 588/650 (was 556-580): the scene no longer overruns the way it did.
Gates: battery31 10/10, svgold identical, docs/routes/level_08.txt completes.
The fight is now the lunge + the Superball kill (HP 9); the GB's thrown Ganchan
is documented in this file and can be restored by deleting the level-8 gate.

## The boss left trails (user playtest, 2026-08-28) -- FIXED

"boss's animation sucks it leaves trails". Its erase box was ONE CELL too
narrow: gen_w3data sizes the exception box from the metasprite's display-list
extent (x 0..16 for $54/$55), but the drawn image reaches a cell further right
than the list predicts (the flipped form's quads), so a 12px lunge left one
column of the old image behind, permanently. The general exception now adds a
second column (cols = (maxx-minx)/8 + 2). Rendered lunges are clean.

Also corrected on the way: the y origin. The engine's tall-erase path already
subtracts 8 (erase_slot), so w3_excy must be -miny-8 PIXELS -- the generator had
been emitting ROWS through a `*8` in the writer, which happened to agree for the
old shapes; it now emits pixels directly and the boss's 24px-tall metasprite is
covered exactly. Gates: battery31 10/10, svgold identical, route completes.

## Boulders restored (2026-08-28, after the drift + trail fixes)

The boulders were never the real cost: the boss's DRIFT was. With the F0 flip
fix (it now stands still) and the erase-box fix, measured over 1971 arena
frames with the boulders thrown every cycle (GB-faithful):

    boss   intact 1879 (95%)   partly 31   wiped 61 (3%)
    boulder  visible 2629 / 2629 frames
    logic 1700/1971 frames (14% overrun, was ~30%)

So w3_child's level-8 gate is gone and 3-3's fight is the GB's again. (Smaller
boulder art would cut per-sprite cost roughly with area -- erase+draw are both
box-sized -- but the measurement says it is not needed.)

## ONE boulder at a time (user decision, 2026-08-28)

"its nearly impossible to beat the boss with such flickering. can you make it
shoot one boulder only". w3_child now refuses Hiyoihoi's $33 child while a $47
is still alive (it scans the 10 slots; the child morphs to $47 on spawn, so a
live $33 never exists). Measured over 1971 arena frames:

    unlimited (GB)   boss intact 95%   logic 86%   up to 2 boulders
    ONE at a time    boss intact 100%  logic 97%   max 1 boulder (mean 0.97)

The boulder is on screen 65% of the time, so the threat stays. Window space for
the scan came from moving w3_read's column fill into the bank-6 pin (w6_col) --
that shifts W3 timing very slightly, so level 6's gold capture drifts by a few
pixels of Mario travel (verified frame by frame: same scene, no artefacts);
docs/gold_ref.txt is the refreshed reference.

## The lifts sank 2px per tick (regression, found + fixed 2026-08-28)

User, on the ROM shipped with the boulder cap (md5 61c4b1fc): *"you fucked up
something in timing and at start mario cant jump from the pre-last moving
platform to the last one!"* -- with a screenshot of Mario on the diagonal lift
and the horizontal one far above him.

They were right, and the cause was the line the previous section calls a
"very slight" timing shift. `w6_col` (the bank-6 column fill) was handed its
destination in **tmpL3/tmpH3**, and `w3_read` staged it there on every cache
MISS. But `w3_move` keeps *this tick's dy* in tmpH3 across its floor/ceiling
probe:

    @ystep: lda o_vx,x / lsr x4 / sta tmpH3      ; dy = velocity hi nibble
    @fall:  jsr w3_floor                         ; <-- probes the map: on a MISS
                                                 ;     w3_read overwrote tmpH3
    @fmove: lda o_y,x / clc / adc tmpH3          ;     with >W3CDATA = 2

So **every W3 object moved 2px per tick in Y instead of its own velocity
whenever its floor probe touched an uncached column** -- which is exactly when
it is moving into new terrain. Measured on the same replay (frame:x,y):

    prev build   349:408,56  351:407,57  354:406,58  357:405,59   (45 deg, GB)
    61c4b1fc     346:408,56  349:407,58  351:406,60  354:405,62   (2px per 1px)

The GB is unambiguous (gbtrace, same lift): `156:297,64 158:296,65 161:295,66`
-- 1:1. The 3-3 lifts therefore sank up to 14px below their GB line during the
approach (first cycle 56..107 instead of 56..93) and the whole diagonal chain
was mis-shaped.

Fix: `w6_col` fills through **tmpL2/tmpH2** -- the slot pointer `@slotptr` has
already set -- and `w3_read` no longer stages anything in tmpL3/tmpH3.

Gates: battery31 10/10; `svgold` on the fixed build is **byte-identical on all
nine levels to the pre-regression build** (/tmp/prev_ref.sv, md5 e4792ef2), so
the clobber is fully undone and the boulder cap itself changes nothing there.
docs/gold_ref.txt is back to those hashes.

### and the jump itself is GB-faithful

Everything the jump depends on was then re-verified against the GB:

| | GB | port |
|---|---|---|
| $38 / $39 diagonal step | 1px x, 1px y per tick | same |
| tick divider ($F4 $02 / $01) | 3 / 2 frames per tick | same |
| velocity byte costs a tick | yes ($26EB sets ffc8=1) | same |
| $38 patrol / $3B patrol | 37 ticks / 52 ticks per leg | same |
| standable width ($38/$3B) | 3 / 2 tiles ($3375 table) | same |
| spawn triggers, whole cluster | 199,191,191,199,191 px ahead of cam | identical |
| walking jump (R+A, 30f hold) | rise 33px, dx 47, airtime 47 | rise 33, dx 48, 48 |

The crossing is genuinely tight: it is made **mid-climb**, not from the top --
jump while the diagonal lift is still rising and the horizontal one is at the
LEFT end of its patrol, holding A long. A sweep of 360 timings from a fixed
ride state lands cleanly at delay ~90 (hold 26); jumping at the lift's apex is
always short, because by then the target has moved 26-44px right.

### state after both fixes (2026-08-28)

* shipped ~/sml33.sv md5 cdf9df2e (god: sml33-god.sv) -- tmpH3 fix + the GB run
  jump (docs/08) + the one-boulder cap.
* arena re-measured on the warp route after both fixes: boss frames 89,
  **mostly-wiped 0**, not-drawn 13/89, ganchan not-drawn 47/121, logic 484/560.
  The fight is where the one-boulder measurement left it.
* battery31 10/10, svgold 9/9 unchanged.
* docs/routes/level_07,08 are REPLAYS and both died on the new physics (E23);
  they are being re-recorded (tools + the repair loop: cut back 130 frames from
  the death, re-search from that prefix with svauto, splice, repeat).
