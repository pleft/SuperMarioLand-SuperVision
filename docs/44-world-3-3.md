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
