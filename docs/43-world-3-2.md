# 43 -- World 3-2 (level 7): RE first, then code

Ship discipline (memory `ship-discipline`): RE the GB FIRST, build the battery
BEFORE code, implement only what the GB does, gate after every change, ship
only when the auto-player completes the level AND the gates are green.

## Map + roster (verified)

* `build/levels/level_07.json`: 320 cols, 63 spawns, 3 rooms, 2 pipes, 6
  blocks, bank 3. Byte-correct against the GB column stream (57/57 columns,
  death-aware capture, `world col = (ffe5-3)*20 + ffe6-1`, start_seg 3).
* UNITS (cost me an evening): the JSON map columns are 8 px wide (one GB
  tile column; the streamer's `ffe6` steps 2 per 16 px, `ffe5` every 10
  spawn columns = 20 json columns). Spawn-list / camera columns (`c0ab`) are
  16 px. So level 7 = 320 json cols = 2560 px = 160 spawn cols, and the spawn
  list's last entry (spawn col 158, `$36`) IS the level end -- there is no
  objectless tail. The GB spawn walker compares only `c0ab`'s low byte and the
  list ends in a single `$FF` (never fires); the decoder's "col 255 `$8C`" is
  an artefact of that byte, skipped.
* Cross-check with mariowiki (World 3-2), px = spawn col * 16: Suu x11 = 11
  `$25`; Pipe Cannon x2 = `$49` at px 1296/1968; Piranha Plant 2 normal =
  `$02` (3rd hard-flagged); Kumo 5 normal `$35` (+ `$B5` hard-flagged); the
  two Ganchan spawn points = `$03` spawners at px 1680/1840 (`F1 $47`) over
  the `$ED` spike bed (json cols 203-214 = px 1624-1712) and the pit after it;
  "crossing lifts" = `$0A` at px 2112 + `$3A` at px 2192 (the GB shows it on
  the ledge at json 270-273); "dropping lifts" = the 13 `$36` stones at px
  2240-2528 over the 20-json-col waterfall (json 280-299); the two doors at
  json 318-319 (rows 0-1 high, 13-14 low).
* Bit7 on a spawn type = hard-mode only: `$FF9A` != 0 makes the spawner take
  them (ObjectPhysics_Init_24EF); `HARD=1 tools/gbtrace.py` pokes it.
* Hard fact for GB captures: `$ffe5` pokes at level load round down to a
  multiple of 4 and re-seed `c0ab = 12 + (ffe5-4)*10`; the stream pointer is
  separate, so a later re-poke does NOT redirect the map. Mario x pokes
  (`c202`) do not scroll the camera. Both were useful only for screenshots.

## AI-VM gaps found by tracing (docs/34 interpreter)

Instrument: `tools/gbtrace.py` (PyBoy replay of a pad script, per-frame
`$D100` object rows: type, screen x, y, pc, param, vel, dir) and its twin
`tools/svtrace.py` (real Potator core via `tools/svshot` RAM dumps, same row
shape, W3 slots mapped back to GB type ids). Same script alphabet as svshot.

### `F6 nn` -- WAIT FOR MARIO (GB $27F4)

    a = objX(ffc3) - marioX(c202) + $14 ; C = a < $20
    nn == 1 : proceed when C (Mario inside (objX-12, objX+20])
    nn != 1 : proceed when !C
    else    : ffc4 -= 2 (re-run F6 next tick), RET (velocity untouched)

The port skipped it (fell to the `bra @loop` default), so the Suu (`$25`)
and Kumo (`$35`) dropped on a fixed timer. Now `w3_f6` (kit_w3.inc): GB and
port both trigger at Mario dx -10/-11 and drop at 1 px/frame with the same
pc/param cadence (`/tmp/gb_near.json` vs `/tmp/sv_near.json`).

### `F9` / `FA` end the tick

The GB stores the operand ($dff8 sfx / $dfe0 music cue) and RETs: the next
opcode runs on the following tick. The port fell through and fired `$49`'s
missile a tick early. Now both set `o_tmr = 1` and `w3_cue` plays the sound:
F9 nn -> SFX_DFF8_nn (01 bang, 02 smash, 03/04 the death chains), FA nn ->
SFX_DFE0_nn. The cannon's `FA $09` was never extracted (extract_sfx's list
skipped 9): added. The LEVELS prefix could not take 56 more bytes (bank 5 is
the tightest: 2-3's far kit sits at a fixed W2FARM), so `FAR_SFX` streams go
to FIXED's tail (`sfx_aux` after sfx_play; the offsets table carries a
link-time `sfx_aux - sfx_data` entry, the player's 16-bit add needs nothing).
The one extra table entry (4 B) still moved W2FARM $A600 -> $A610 (cfg +
pack_banks asserts; bank 5: 186 free). Verified on the real core (route 7d
RAM dump): at the FA tick `sfx_p` = $CC17 = sfx_aux, the missile spawns the
next frame; svgold identical, battery31 ALL PASS.

### Ceiling probe + `$40`/`$C0` response (GB Call_000_2c21, jr_000_29a1)

A rising object probes the tile at `ffc2 - (h-1)*8` in the floor probe's
column BEFORE moving; blocked -> `phys0 & $C0`: `$00` move anyway, `$40` turn
to falling, `$C0` restart the script (ffc4 = ffc8 = 0). The Suu's climb is
scripted for 96 px (12 x E8 at F4 $01 = 0.5 px/frame) but it rests where it
started because its ceiling tile restarts the script at GB y55 -- the port
climbed the full 96 px and hung 16-40 px above its tile. Now `w3_ceil` ->
`w3_probe` (row delta -(h-1): the port's feet row is one row under the GB's
probe row -- with -h it fired a row early, y63; measured y55 == GB).

Suu cycle, GB vs port (`gb_past.json` / `sv_near.json`, restart at pc 0):
GB y55 f392, port y55 -- identical pc:y ladder 47:136 ... 77:56, then 0:55.

### Composer compiled out of the hot segments

`CX_BUILD` (kit_w3.inc, `.define`, 0): the parked composer's window/far
pieces (cs_composed, cs_entry, the w3_step hook, w3_width's composed branch,
w3_draw's dispatch) no longer assemble; the bank-6/page-8 halves stay. The
window limit is back to $800 (pack_banks); re-enabling needs it under $1C70.

## Auto-players (closed-loop rule)

Both `tools/svauto.c` and `tools/gbauto.py` now carry a CHECKPOINT STACK
(death/stall pops back 1, 2, 3... windows and takes the next-best untried
candidate; MAXBACK bounds it) and long-wait candidates (delay 48/64/90) so a
Ganchan can be waited for. Before this both died in the same place -- the
pit right after the spike bed (px ~1730). With it svauto mounts a Ganchan
and rides (route 7e ended mid-ride at its 4000-frame budget). gbauto with
the bigger fan is too slow on PyBoy to be useful (35 min for 240 frames):
the GB is for targeted probes, the port's auto-player is the completion gate.

## Gates on this build (F6 + F9/FA + ceiling + cue)

* battery31: ALL PASS. svgold: identical to the 3-1 reference on all 9 levels.
* COMPLETION (god build, real core): `docs/routes/level_07.txt` reaches the
  bottom door -- goal_phase set at frame 4439, x 2544 (`tools/svgoal.py 7
  docs/routes/level_07.txt`). The route = svauto to the ledge before the
  spike bed (route 7d, 2600 frames) + a hand-searched Ganchan mount (wait
  28, right-jump 22: the Ganchans spawn at px ~1684, land at ~1640 and bounce
  RIGHT past the ledge every ~250 frames; Mario must come down on one near
  his apex) + dismount onto the pillar at 1761 (ride 144, right-jump 26 --
  a jump does not release the ride until then) + svauto from the pillar
  (second bed, lift, ledge, the 13 dropping stones) + R200 into the arch.
  svauto learned three things here: a `prefix` argument (replay a known-good
  script, search from its end), partial-route dumps at every progress print,
  and `goal_phase` ($5A) as SUCCESS (before, the arch freeze read as a stall).
* Shipped ~/Desktop/sml32.sv = build/super-mario-land.sv 8f74860c.
* Caveat: the route was searched on the GOD build (as every level before);
  replayed on the normal ROM it dies to the first Fly at frame 221. A
  normal-ROM search (7n, real deaths) got to px 978 -- past the first Suus,
  the platform pit and the col-59 Kumo -- and spent its backtrack budget at
  the small waterfall pit right after the Kumo (json 120-121). Not a port
  bug (the god route crosses it; the Kumo descends 0.5 px/frame, a human
  runs under it): the greedy search dislikes "jump a pit while something
  drops on you". Left as the next auto-player improvement.

## Open

* Kumo `$35`: trigger (F6, dx -9..-11) and 0.5 px/frame descent captured on
  the GB (hard Kumo, HARD=1) == port. phys `00 91 00`: no land response, so
  the GB's Integrate moves it THROUGH the floor (jr_29c6) -- the port does the
  same (sinks to o_y 168, culled). The hard Kumo's window lies over a pit and
  the col-59 one needs a GB run past the pits, so the floor pass-through is
  disasm-verified, not captured.
* `$49` cannon fires `$4A`->`$4B` on route 7d (battery31's missile tests cover
  the mechanics); `$03` spawner / Ganchan ride = 3-1's (battery31); lifts
  `$0A`, `$3A`, the `$36` dropping stones and the two doors: to be exercised
  by the completing route.
* GB culls at screen x -1 (wrap to 255); the port keeps objects ~30 px
  further -- harmless so far (memory #28).

## Play-test round 1 (2026-08-25, user) -- four findings, all fixed

1. **Suu drops "too late".** GB OAM vs RAM: `c202` is Mario's sprite-left
   +15 and `ffc3` the object's left +7, so the GB's `ffc3-c202 < 12` opens the
   window with Mario's left 20 px short of the Suu's; the port compares draw-
   left to draw-left and opened it 4 px later. `w3_f6` now adds $10 instead
   of $14 (onset RAM dx -15, was -11; measured on the real core). Note the
   GB itself does NOT drop for a Mario standing at the pipe 22 px away --
   the window is (suuLeft-20, suuLeft+12].
2. **Kumo drew as garbage.** Its metasprite is the single tile `$DF` (GB OAM
   confirms; the resting Kumo IS an 8x8 spider on a thread). `$DF` is a W1
   base-sheet tile, but the port's chardata is a dedup'd sheet with its own
   indices, and `draw_quad` sent `$DD+` there raw. Now gen_w3data routes EVERY
   kit tile id >= $A0 through the W3 slice (pack_banks sources the pixels
   from w1_obj_8000.svt for ids outside the $A0-$DC overlay), draw_quad's
   overlay window is $A0-$DF (64 slots; no engine constant lives there).
   The "fly" death sprite was the same garbage tile flipped.
3. **Hidden block $07 = the LIFT.** The W3 kit's gift vector only marked the
   cell used (the W2 `$F0` rule). `w2_gift` under EAS3 now spawns 1-3's
   `l3_gift` for `$07` (kit_sh4/kit_sh6 included; upd_gift/draw_gift in the
   kit tables). Window: $7E5/$800; `w3_f6` moved to FIXED for the room.
4. **"Falling barrels" missing.** The 13 `$36` stones were spawned but
   `w3_behind` listed `$EE` as a priority tile and the whole-quad skip hid
   them inside the waterfall (every cell non-zero). A per-pixel priority blit
   was written and measured: ~5% of a sprite-heavy frame -- the missile
   scene lagged one frame and battery31's fixed-frame stomp missed. Reverted;
   `$EE` is simply not behind (the GB shows the barrels over the mostly-white
   water; the cannon keeps its pipe skip).

Two traps met on the way, both invisible to the linker: BSS ends at $11FE
and `$1200` is RCODE (`calc_view`) -- two more `.res` bytes shifted every
level's view by 4 px; and `$1FA0` is the kit's column cache (W3CTAG_E at
$1F80), not a free gap -- scratch there corrupted map reads (spikes/bricks/
stomps failed in battery31). The composer's `CS_B` at $1FA0 was the same
mistake, parked. Also: `w2code`'s init cleared "stash A" at $1C70, which
now holds kit CODE (window > $770) -- guarded by CX_BUILD.

Gates after the round: battery31 ALL PASS, svgold identical on 9 levels.

Route re-searched on this build (svauto 7q, no prefix, goal detection): GOAL
at frame 5480, x 2544 -- `docs/routes/level_07.txt` replaced. Frame checks on
the way: Kumo = the 8x8 spider under the rock pillar (f1679), stones drawn
over the waterfall (f5039). The user's RetroArch still shows the old glyph
Kumo after a cold start -- md5/core check pending.

## Play-test round 2 (2026-08-25, user): "Kumo still garbled"

The garbled sprite was never the `$35`: World 3's **`$0E` object IS the
Kumo** -- the same engine object as W1's Fly, drawn with the World-3 overlay
tiles `$A0-$A3/$B0-$B3` (the wiki's hopping Kumo; the `$35` is the small
drop-from-the-ceiling variant). Two faults stacked:

1. The W3 tile slice was COMPACT (ids renumbered from $A0 in first-use
   order), so the engine's raw `$A0..` ids hit the wrong slots. The slice is
   now ID-PRESERVING: slot $A0..$DC = overlay tile $A0..$DC; the kit's
   out-of-range ids ($DF, $E2, $E3, $EF, $FE, $F9-$FB) are parked in slots no
   W3 list and no engine object uses (gen_w3data `ENGINE_IDS`).
2. The slice is bank-6 data and the engine draws with bank 1 mapped. New
   FIXED helper `draw_16w3` (2x2 quads, x-flip per quad as before, y-flip for
   the corpse) wraps the draw in a bank-6 switch in W3 levels -- INLINE, not
   via `set_bank`: set_bank lives in the LEVELS prefix and bank 6 has none,
   so calling it hung the game on the first Kumo (frame 920 of the route).
   The corpse (was `draw_tile_yflip` from chardata = a W1 fly) now uses the
   same helper with `do_yflip`.

Verified on the real core: frame 1112 of the route shows the Kumo sprite.
battery31 ALL PASS, svgold identical. Shipped as ~/Desktop/sml32.sv.

### Round 2b: facing right + gravity (user)

* Facing right drew the Kumo wrong: the GB's right-facing display list SWAPS
  the two halves as well as x-flipping them; the port flipped each half in
  place (invisible on W1's near-symmetric fly). `draw_16w3` (now a 4-quad
  loop, FIXED) swaps when `do_flip`.
* "Lacks gravity": 3-2's `$0E` entries spawn mid-air (pos $0B -> y 104). On
  the GB the object sits in the air (script velocity 0), hops, and the
  script's tail velocity `$41` (y 4/tick, F4 $02) held through 5xEF carries
  it down until the floor probe restarts the script (land response $30):
  the wiki's "drops from midair". The port's fixed 48-frame arc landed at
  its spawn line. `fly_fall` (FIXED): after the arc, probe the feet row;
  fall 4 px every 3rd frame until solid, snap, then sit. Grounded spawns
  (1-1) land on the same frame as before. Not ported: the GB's x drift of
  1/tick during the fall (~10 px; FIXED is full to the last 6 bytes).
* Verified on the real core: the `$0E` at px ~1100 sits at o_y 88, hops,
  lands at 112 (the floor); a forced right-facing hop renders the swapped
  halves. battery31 ALL PASS, svgold identical. Shipped.

### Round 2c: "Kumo always falls in the void" (user)

GB trace (gbtrace_7deep, the px-680 Kumo): sits at y 112 (16 px above the
floor), hop = 16 ticks x (x 2, y arc) = ~32 px sideways, then the `$41` fall
drifts 1 px/tick and it lands on the floor at y 128, x ~645 -- the 16-px
strip between two pits. The port's hop moved 1 px/2 frames (24 px) and the
fall had no drift, so it came down ~18 px short: in the pit. Now: x 2 px on
every hop tick (frame%3, `upd_fly`), x 1 px per fall tick (`fly_fall`).
Port trace: 672 -> 640 (hop) -> lands 635 at y 128, sits, hops on. (The first
cut of the tick test read `cmp #3`'s flags instead of the remainder and never
moved x -- caught by the same trace.)
Room: `w3_f6` moved to the LEVELS prefix; the 2-3 creature sheet moved from
bank 5's tail to bank 6 $BF00 (pack_banks + the L13E copy's source bank) so
bank 5 could give the prefix 128 bytes (W2FARM $A680).

### Round 2d: the stomped Kumo (user)

Stomping gives OBJ_SQUASH with the flattened pair `$A8/$A9` (GB param $2C) --
overlay ids, so (a) the draw needs the bank-6 wrap (the squash branch now
switches through the shared `bank_set` when the level is W3 and the tile is
>= $A0) and (b) the slice must keep those slots: they were not in
`ENGINE_IDS`, so the out-of-range parking had put the lift ($EF) and the
missile ($F9) there -- the corpse drew as an oval + a blob. `ENGINE_IDS`
now includes $A8/$A9 and the slice has 68 slots ($A0-$E3; parking $DD-$E3,
ending exactly at creature33's $BB80). Verified: the squash at f1031 of the
route is the overlay pair pixel for pixel. battery31 ALL PASS, svgold
identical. Room: fly_fall back in the LEVELS prefix, w3_f6 in FIXED, W2FARM
$A6C0 (bank 5: 10 free).

Route re-searched on the shipped build (5476db38): GOAL at frame 5710 --
`docs/routes/level_07.txt` replaced.

## Open after round 2 (user question): Superball vs W3 kit enemies

GB ($2A68): HP = phys byte2 & $3F, absorbed while HP > 0 (ball vanishes, no
score; $32/$08 play $dff0), then the contact row's byte 3 = the morph type
(Suu $19, boulder $41, Hiyoihoi $4F with HP 9, $3C -> $3E; 00 = the ball
passes). The port has NO ball handling for OBJ_W3 (since 3-1). Needs ~100
bytes (FIXED logic, a 28-byte table, a 10-byte HP array at $0128 in the
stack page, a kit vector for w3_morph) -- every segment is at its ceiling
(window 5 B, FIXED 46 B, prefix 10 B, BSS 1 B), so a space reclaim comes
first. Same mechanism Hiyoihoi (3-3) needs.

### Naming, settled with the user (2026-08-25)

* `$0E` (engine "Fly" object with the World-3 overlay tiles) = the **Kumo**.
* `$25` = the **Suu** (the 16x16 spider hanging on a thread).
* `$35` = a **stalactite**: one 8x8 tile ($DF) tucked into the rock of a tall
  thin pillar, invisible at rest, drops straight down when Mario comes within
  its F6 window and falls through the floor. NOT a Kumo (earlier notes call
  it "drop-Kumo" -- read "stalactite").

## Superball vs W3 kit enemies -- WIRED (2026-08-25, user request)

GB ($2A68): HP = phys byte2 & $3F; while hits < HP the ball is absorbed
(expires, no score); at HP the contact row's byte 3 is the morph type (00 =
the ball passes) and the score is byte2's class. Port:
* `w3_ball` (FIXED, main.s): `w3_hp` = per-slot hits at $0128 (stack-page
  scratch beside w3_fcc/w3_fcy, cleared by find_free_obj); the table is
  `build/w3ball.inc` from gen_w3data -- sparse (type index, morph, byte2)
  triples: Suu $25 -> $19 (HP 1), Tokotoko $31 -> $41, Hiyoihoi $32 -> $4F
  (HP 9), $3C -> $3E (HP 2); everything else passes (Ganchan, Batadon, the
  stalactite, pillar, missile...). ball_hits dispatches OBJ_W3 (36) to it and
  awards through award_kill_at (popup at the victim).
* The morph runs in the kit through the GIFT vector overloaded with A=$FE
  (`w2_gift` -> `w3_morph`, tmpL3 = type): FIXED cannot name kit code and
  ovl_vec cannot grow (BSS is full).
* Room: fly_dy compressed to per-tick entries (upd_fly counts phase/3 in
  tmpL3), the (o_x+4)>>3 feet probe factored into `obj_feet` (LEVELS prefix;
  4 inline copies replaced), w3_cue's `beq` dropped (nn=0 fails the cmp).
* Verified on the real core (sv_near prefix, Mario poked big+superball at
  x 45 under the Suu, facing left, B every 30 frames): f662 hit 1 absorbed
  (w3_hp 1), f685 hit 2 -> w3_ti 6 -> 2 ($19), score +400, then the $0D
  corpse. battery31 ALL PASS, svgold identical. Shipped ~/Desktop/sml32.sv.

### Round 3 (user): the raining mushroom

A mushroom (or heart) that fell into a pit kept falling: `o_y` is a byte, it
wrapped past 255 and re-entered from the top for ever. `upd_mush`'s drop
now culls at o_y >= 168 like the corpses. battery31 ALL PASS, svgold identical.

## route re-recorded (2026-08-29)

The 2026-08-28 fixes (the tmpH3 lift regression, the GB run jump, the atomic
renderer) all move engine timing, so the old replay died at x664 (E23).
`docs/routes/level_07.txt` re-recorded by the cut-and-re-search repair loop on
the shipped build (md5 26b12496): **goal reached at frame 3617, x 2544,
goal_phase 1** -- the same goal the 5480-frame route reached, 1863 frames
quicker. God build, like every svauto route.
