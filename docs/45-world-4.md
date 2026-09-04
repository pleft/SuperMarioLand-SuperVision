# World 4 (levels 9-11 = 4-1, 4-2, 4-3) -- plan and RE inventory

Written 2026-08-29, before any code. Method as always: RE the GB first, then
port, then gate (battery31 + svgold + an auto-route that completes).

## What the levels actually contain

From `build/levels/level_09..11.json` (spawn lists, hard-mode bit 7 masked off)
cross-referenced with the W3 kit's `w3_typetab` and the engine's own roster:

| level | spawns | already ported | NEW types |
|---|---|---|---|
| 4-1 (9) | 82 | $00 $02 $04 $0A $0B $0C $36 $38 $39 $49 | **$55, $56** |
| 4-2 (10) | 70 | $00 $02 $04 $06 $09 $0B $36 $3A $3F $49 $4B | **$54, $55** |
| 4-3 (11) | 77 | $06 | **$4D $52 $53 $54 $59 $61** |

So 4-1 and 4-2 are mostly a LEVEL-DATA job: two new enemies each, everything
else is already running in W3. 4-3 is the boss level and brings six.

Every new type has a real AI-VM script ($349E table), so the W3 kit runs them
as data -- no new engine code, the same reason W3 went in as fast as it did.

### the new types, from the ROM

* **$55** -- 8x8, not standable, NOT stompable (contact $3186: stomp $00, side
  $FF = hurts, ball $00). Script $3BE0: bobs on the spot, alternating params
  $5F/$60, one 1px/tick step down and back. A pure hazard.
* **$56** -- 16x16, stompable -> morphs to **$57**, side hurts, Superball kill
  -> $15. phys0 $B4 (bit2 = reverse at walls): a wall-reversing walker.
* **$54** -- 8x8, not standable, not stompable, side hurts.
* 4-3's six ($4D $52 $53 $59 $61 + $54) include long scripted arcs ($53 is a
  60-step velocity program) and a spawner ($52 fires a child $50); $61 is the
  level's boss.

## The constraint that decides the shape of the work

The W3 sprite overlay has **68 tile slots** ($A0-$E3). Regenerating the kit's
data with the new types:

    + $55,$56            35 scripts, 1200B, 68 tiles   FITS
    + $54,$55,$56        36 scripts, 1227B, 68 tiles   FITS
    + all of World 4     9 out-of-range tile ids, 7 free slots   OVERFLOWS

So 4-1 and 4-2 go in under the existing single-blob design; **4-3 needs a
per-world tile slice** (or freed slots) before it can be built. That is the one
architectural decision World 4 carries, and it is deferred until 4-1/4-2 are
playable.

## Order of work

1. **4-1**: SEED += $55,$56; give level 9 a bank (MAGNUM pages 9-14 are free)
   and extend `lvl_bank_tab` + the three `cmp #9` level-count checks; build;
   auto-route; differential vs the GB; playtest.
2. **4-2**: SEED += $54; same loop.
3. **4-3**: solve the tile budget (per-world slice), then the boss.

Before writing a line of it, walk docs/35 (the port laws) -- A2/A3 (erase boxes
and the straddle row) and B1/B2 (contact rules) are the ones W3 paid for twice.

## The bank design (settled 2026-08-29, first two steps landed)

Measured facts that decide it:

* bank 1 (W3 resident) has **25 bytes** free; its tail runs to the far kit.
* bank 6's cold region ($8400-$A7C0, 9152B) holds W3's three maps + rooms +
  spawns in 8860B -- **292 bytes** free. Level 9 alone needs ~3.7KB more.
* MAGNUM pages 9-15 are entirely free in the 512K image.

So each WORLD gets a bank PAIR, exactly as World 3 has (1, 6):

| world | resident bank | cold bank |
|---|---|---|
| 3 (levels 6-8) | 1 | 6 |
| 4 (levels 9-11) | **9** | **10** |

*Resident* = the LEVELS prefix + the level headers (pinned at `W3HDR + (lvl-6)*24`,
so the engine's existing lookup works unchanged), pipes/blocks, the loader stub,
the world's BG charset, and the far kit at $BE50.
*Cold* = maps/rooms/spawns + the kit's pinned data (scripts $B200, display lists
$B540, tile slice $B740, the bank-resident walk $BC00) + the window image.

Two engine changes were needed and are **done and gated** (svgold 9/9,
battery31 10/10):

1. `cur_bank` -- load_level records the level's page; the kit's cold-bank
   detours (`w3_read`'s column fill, `w3_draw`'s tail) return to it instead of a
   hardcoded bank 1. Without this every W3-kit level was pinned to bank 1.
2. `w3_cold` -- a byte in the kit's window image holding the world's COLD page
   (6 for W3). pack_banks patches it in each world's copy, so one kit image can
   serve several worlds.

### what is left for 4-1

* `gen_w3data.py` per world (SEED, tile order, overlay source) -- World 4's
  sprite overlay is `w4_ovl_8A00.svt`, not W3's, so the slice must be built from
  it; this is also what gives 4-3 its own 68 slots later.
* the kit assembled per world (its tables live in the window image).
* `pack_banks.pack_w3` generalised to (levels, resident page, cold page).
* `NUM_LEVELS` 9 -> 10 and `lvl_bank_tab` += page 9.

## Pionpi ($56/$57) -- stomp behaviour (user report, fixed 2026-08-29)

GB rule: a stomp knocks a Pionpi FLAT ($57) for ~3 s, then it gets up ($56).
Stomps never kill it; only a Superball (or a star) does.

The port killed it after a few stomps. Two independent bugs, both fixed:

1. `w3_hp` and `w3_fcv` shared `$0128` (law E33). The gravity floor-probe
   verdict overwrote the Superball hit counter, so a knocked-down Pionpi
   incremented its own kill count once per knockdown. `w3_hp` moved to `$0132`.
2. `w3_ffc7`'s `@fall` re-keyed the probe cache to the new y (law E32), so an
   airborne object never re-probed and fell through the floor until the y>=168
   cull freed the slot. A Pionpi stomped MID-HOP therefore vanished ("died")
   on the second stomp; one stomped while grounded survived. This was a
   cross-world bug: any W3 object that left the ground was affected.

Verified after the fix (god build, Mario dropped on the first Pionpi at
x448 y112 every 110 frames): 6 knockdowns over 12 stomps, ~184 frames flat
each, still alive at f1399. Gates: battery31 10/10, svgold 9/9 identical.

## 4-1 level data verified against the GB's live VRAM (2026-08-29)

The extracted map is not just plausible, it is the GB's: walking the GB (PyBoy,
run-jump pattern) and reading the BG tilemap at $9800 row by row gives columns
identical to `build/levels/level_09.json` for every column checked (56-87,
byte-for-byte). So the four big gaps are real level design, not a decode bug:

    pits (cols with no solid tile at ANY row):
      60-81 (176px), 200-219, 280-321, 360-363, 365-383, 399-401, 420-423

**The pits are crossed on lifts, and the lifts come from spawners.** The level's
`$0A`/`$0B` spawn entries sit just before each pit (cols 31/36 -> pit 60-81;
142/157/180 -> pit 200-219; 255 -> pit 280-321). On the GB those entries appear
as live `$38`/`$3A`/`$3B` lifts over the gap; the port keeps them as native
`$0A`/`$0B` platform objects. Input-matched check at the same camera position:
GB `$0A` anchored x512, y 90..120 (vertical); port x504, y 83..114 -- the same
lift within 8px. Riding sets `ride` (main.s:6292), so svauto's stall exemption
applies to them.

Consequence for routing: 4-1 needs hand chunks for the lift crossings exactly
like 3-3 (docs/44) -- a plain svauto search dies in the first pit (world x 605,
backtrack budget spent). Do NOT read that as a broken level.

Also verified: both pipes (entry cols 2 and 387) enter room 2 (the 44-coin
room) AND exit it through the `$74` mouth on the top-right ledge, resuming at
the saved surface camera; all 17 distinct spawn types in the level are covered
(bit 7 is the hard-mode/spawn flag: `$D6`=`$56`, `$C9`=`$49`, `$84`=`$04`, ...);
kit types `$38/$39/$49/$55/$56` are all in the World-4 table.

Known deviation (all levels, not just 4-1): the port starts Mario at spr_x 40,
the GB at 50.

## 4-1 route: how to resume (partial, x1568 / 3680)

`docs/routes/level_09_partial.txt` replays to world x 1568 (43% of the level,
past the FIRST lift pit) and leaves Mario safe at frame 3064. It is a partial
route, not a gate -- level 9 has no completing route yet.

The method (3-3's, docs/44): a plain svauto run dies in the first pit because
one 150-backtrack budget is not enough for a multi-lift crossing. Chain instead:

    python3 tools/svchain.py <route.txt> <prefix.txt>     # cut at the furthest
                                                          # SAFE frame (grounded
                                                          # or riding, pre-death)
    /tmp/svauto build/super-mario-land.sv 9 12000 <out.txt> <prefix.txt>

Each iteration starts a fresh backtrack budget at the far side of the last
crossing, so progress accumulates: 459 -> 651 -> 910 -> 1242 -> 1568 so far.
Repeat until the log prints GOAL, then move the result to
`docs/routes/level_09.txt`. Remember E23: any engine-speed change invalidates
the whole chain and it must be re-searched from the start.

Remaining pits to cross: cols 200-219, 280-321, 360-383, 399-401, 420-423.

## BUG (user-found, confirmed 2026-09-03): breakable bricks past world-col 360 don't stay broken

Symptom (user, big Mario, ~x3264 in 4-1): bonking a $82 brick plays the break
animation + scores, but the brick REAPPEARS and can be re-bonked for score again,
indefinitely.

Root cause: `tile_mod` (the broken/used/collected bitmap, main.s) is 720 bytes =
360 world-columns x 2 (16 rows). 4-1 is **460 columns** -- the first level past
360. `mod_ptr` = tile_mod + col*2 + (row>=8). For col 408 (x3264, the 3rd $82
trio) that is tile_mod+817, which is 97 bytes PAST the array, landing in the
object SoA (o_pdr region, ~$103C). The object pass rewrites it every frame, so
the mod bit never survives -> `map_transform` keeps returning $82 -> the brick is
re-solid and re-breakable. PROVEN: at col408 two bonks scored +50 each
(008300->008350->008400) with the block never removed. Bricks at col <=359
(x<=2872) are fine (verified: col129 breaks and persists until death).

Also latent from the same undersizing: the ROOM region keys at bytes 640-679
(= surface cols 320-339); 4-1 has 460 surface cols AND rooms, so cols 320-339
collide with room cells. The old design assumed surface <= 320 cols (comment at
tile_mod).

Fix requires enlarging tile_mod to the widest W4 level (4-3 = 480 cols -> 960 B
surface + 40 B room = ~1000 B, vs 720 today) and moving the room region off the
surface range. BLOCKER: BSS is exactly full (4096/4096); ZP/RCODE/kit-window/
HUDSHADOW/kit-cache fill $0000-$1FFF; revpix (256B) and HUDSHADOW (640B) are both
hot/fully-used. So this needs a deliberate RAM-budget pass -- natural to do with
the 4-2/4-3 kit-roster RAM work (they need bank/RAM changes anyway). Interim: the
affected bricks are OPTIONAL (not on the completing route); small Mario and level
completability are unaffected.

## 4-2 objects vs the GB (2026-09-04)

Method: closed-loop routes on BOTH engines (svauto / gbauto -- an open-loop
replay of the port's letters dies in the first gap: the port starts Mario at
spr_x 40, the GB at 50), then per-frame object timelines compared at matched
camera positions (tools/gbtrace + the svshot RAM dump). GB y = port y + 24.

**$3F Gao (x768) -- VERIFIED.** Same spawn point (port x768, GB x776: the 8px
systematic offset seen on every W4 object, docs/45 4-1). Stationary; spits a
$23 fireball 92 frames after spawning on both engines (port 91), at the same
angle and speed (-1 px/frame x, +0.5 px/frame y, aimed down-left at Mario),
repeating every ~137 frames. Stomp -> $40 -> $41 -> $0D corpse floating off
up-left, the W3 chain. Contact rules decode as expected: stompable, side hurts,
the fireball hurts on every side.

Measured deviation, NOT fixed (ship discipline): the timed part of the death
chain runs ~1.35x slower on the port when many objects are live -- $40 lasted
62 frames vs the GB's 46, the $0D arc 30 vs 19 -- with 7-8 objects resident
(two Piranhas, $4B, the second fireball, natives $08/$0E). Cause: the mover
budget (bud_base = 2 for levels >= 6, main.s load_level) defers a mover's MOVE
together with its redraw, so VM waits stretch under load; 3-1's battery (one
mover live) measures the same $40 at the GB's 45. Raising the budget to 3 was
measured to overrun the frame on 3-3 (docs/44), so this stays.

## BUG (found verifying 4-2, fixed 2026-09-04): the spawner jammed at entry 52

spawn_check indexes the RAM spawn table with an 8-bit Y = idx*5 -- and every
spawn handler takes that Y (overlay ABI) -- which caps the LIVE table at 51
entries. World-4 lists are 58-68 entries (4-1 68, 4-2 58, 4-3 63; 4-1 even
exceeds the 384-byte RAM copy). On 4-2 the $3A lift is entry 52: its offset
wrapped to 4, spawn_check read garbage, never fired, never advanced -- no lift,
and nothing spawned for the rest of the level (the $36 stones after it). 4-1's
late entries were silently dropping too.

Fix (main.s): the RAM copy is a WINDOW onto the ROM list. `spawn_base` ($1FF0)
= the ROM entry at spawn_tab[0]; `spawn_shift` slides it 51 entries when
spawn_idx reaches 51 (consumed entries are never needed again); `spawn_seek`
rebuilds the window from ROM at every respawn/level start and fast-forwards
past the checkpoint (replacing the two FIXED fast-forward loops, so FIXED got
smaller). Kit levels keep their list in the COLD page (the W3/W4 header's +16
is only the resident $FFFF sentinel): the stub saves the cold list address at
$1FF1/2 and `cold_copy` (FIXED, because the prefix is not mapped under the cold
page) does the page dance inline. Prefix room came from moving build_shtab /
build_row48 into BOOT6; the far kit moved $BE50 -> $BE58 for the stub's 6 bytes.

Two traps hit on the way (laws E36/E37 in docs/35): set_bank lives in the
prefix, so a FIXED routine must not call it to map the cold page (3-1 froze at
its first respawn); and the kit stub RELOCATES ITS LOADER TO $1F80 and runs it
there -- $1F80..~$1FE9 is live code during a level load, so RAM chosen from
"the free bytes above W3CTAG" ($1FE0-$1FE6, first try) was the loader's own
tail (its jmp $1500 operand) and the stub's stores self-modified it: 4-2 froze
at start. The composer's CX_* ($1FE0-$1FE3) and stash B ($1FA0-$1FDB, = himod,
harmless only while CX_BUILD=0) sit in the same transient region and are
re-cleared by the kit init, which runs after the loader.

**$4B (moai missile) never culled off-screen right -- FIXED 2026-09-04.** On the 4-2 route
capture a $4B (the $49 pillar's missile, F3 from $4A) flew right at 1px/frame
from x3320 to x4712+ (slot 9, ~1400 frames) without ever being freed: the port
culls kit objects only when they fall below y 168. A horizontally escaping
object keeps a slot and its per-frame cost for the rest of the level. Check the
GB's off-screen rule (it frees slots that leave the 176px window) and add the
same to w3_ffc7/w3_step before 4-3 (which has more shooters).
Fix: w3_step frees any VM slot whose x is >= 2 pages ahead of the camera
(257..511px; spawns land at +192..204), every frame; l3_cull got the same bound
for the 1-3/2-2 kits (not 2-3: its bank is 10 bytes from full; not W3/W4: the
window is full and w3_step covers them). GB reference: its rightward $4Bs lived
~700 frames and vanished ~220px past the screen edge (gb10s trace); the port now
bounds them at <= 511px instead of never. Gate: svgold 9/9, battery31 10/10.

**$54 (x1328.., 15 spawns) -- VERIFIED.** A 48x48 orbit around its spawn point:
from (x0, y0) up-left to (x0-24, y0-24), down-left to (x0-48, y0), down-right
to (x0-24, y0+24), back -- period 144 frames, identical on both engines (GB
deep-start at cam 1280: spawn (1496,136), x 1448-1496, y 112-160; port instance
at (1328,112): x 1280-1328, y 88-136, f2412 -> f2556). Two lanes (o_y 48 / 112)
and both hurt from every side; the script's velocity ladder decodes to exactly
this loop.

**$3A lift (x2928) -- VERIFIED on the port after the spawner fix.** Spawns from
entry 52 through the window shift (spawn_base 51 at f4414 on the route), rises
and falls at 0.5px/frame between y40 and y100 with a 240-frame period at a fixed
x -- the W3 $3A script already GB-measured on 3-3 (docs/44). Boarded from the
x2918 ledge with a short hop (J9) timed to the low phase; run-jumps overshoot it.

## Per-type tables relocated to the resident bank (2026-09-04, for 4-3)

gen_w3data now emits w3_typetab/scrlo/scrhi/phys0-2/stomp/side and the three
exception tables into segment W3TAB (cfg/w3code.cfg: W3TABM $B000..$B51F, listed
LAST so the bytes end the kit .bin); pack_banks pastes them at $B000 in bank 1,
pack_w4 at $B000 in page 9 (over bank 1's inherited copy). Every reader already
runs with the resident bank mapped, so no code changed. The $1500 windows fell
from 2010/1977 B to 1784 B for both worlds -- room for 4-3's 43-type closure
(+~217 B) with ~50 B to spare. Gate: svgold 9/9, battery31 10/10, 4-1/4-2 boot.
Trap: pack_w4 runs after make_512k has already written the image, so a pack_w4
failure left a fresh-looking half-built .sv and `make` then said "Nothing to be
done" -- Makefile now has .DELETE_ON_ERROR.

## 4-3 packs: World 4's own page-10 layout (2026-09-04)

Three levels' maps (9823 B dedup'd) plus the 43-type kit no longer fit around
the bank-6 pins, so World 4's cold page is laid out edge to edge, every pin
asserted by pack_w4 (cfg/w4code.cfg, kit_w3.inc / w3stub.s `.ifdef W4KIT`):

    $8000 window image 1784 B  (PAGE-ALIGNED: the stub copies from >W3WIN only)
    $86F8 W3X2 stash head 967 B   $8ABF maps+rooms+spawns 9823 B   $B11E spt
    $B124 scripts 1527 B   $B71B display lists 545 B   $B93C tile slice 1216 B
    (76 slots: draw_quad's band top is per world, quad_top $1FF3 = $EC here,
    $E4 for W3; ids inside the band keep their own slot, only ids >= the top
    are parked)   $BE00 W3X walk 476 B   -> 4 bytes spare.

Resident page 9: per-type tables at $B000 (362 B), then a HOLE to $B51F that
takes the header-pointed pieces (pipes/blocks/sentinel/stub), so the tail at
W3HDR is headers + charset only (2192 B, was 31 B over the far kit).

**4-3 is the Sky Pop aeroplane level** (a vehicle stage like 2-3: no walkable
floor -- its "ground" tiles $53/$55/$57 are below the solid threshold; the
render is sky and clouds and Mario falls from the spawn). It needs the vehicle
player path (veh_vec, as kit_mar23's veh_init installs for 2-3) in the World-4
kit plus its VM enemies ($4D $52 $53 $59, boss $61) -- the next phase.

## 4-3 Sky Pop kit: first light (2026-09-04)

Built as `w43code` (EAS3 + W4KIT + SKY43, `cfg/w43code.cfg`: the W4 layout plus
`SKYFARM` $A680 size $0980, segment `SKYFAR`) with its own page pair (11
resident, 12 cold; `pack_w4.py PAIRS`, the SKYFAR slice pasted at $A680 of
page 11). `src/kit_sky43.inc` = the 2-3 vehicle player copied verbatim
(veh_init..draw_one, sub_off, sub_step, torp_qblock, veh_clear) plus VM-side
`torp_scan`/`torp_hit` (missile vs OBJ_W3: HP in w3_hp, morph from w3_torpt,
clink for $61). Level 11 now loads, the plane holds y 112 at spr_x 42, the
autoscroll runs 0.5 px/frame, and $53s spawn.

Four bugs between "links" and "flies", each a RULE-0 lesson about copying a
kit that lived in RAM into one that lives in ROM:

1. **The stub mapped page 9 before jumping to the kit init** (`lda #9` under
   W4KIT). 4-1/4-2's init is RAM code so it never mattered; 4-3's init ends in
   `jmp veh_init` = SKYFAR in page 11, and with page 9 mapped that address is
   $FF fill. Blank screen, frame counter ticking, CPU spinning. `w3stub.s` now
   maps 11 under SKY43.
2. **The vehicle's blob-local state was `.byte` in SKYFAR** -- ROM. `vacc`
   never accumulated, so the autoscroll never started. In 2-3 the same lines
   sat in the $1500 window (RAM). They are kit-RAM equates now ($1FE7-$1FEB,
   law E38).
3. **`w3_cold` was 10** (the W4KIT default): 4-3 read 4-1's columns through
   the cache, every sky tile came back >= $60 = solid, and the scroll crushed
   the plane against a wall that was not there. 12 under SKY43.
4. **The stub's spawn-list index subtracted 9**: 4-3's pair holds one level,
   so its list is entry 0. Nothing spawned for 900 frames. 11 under SKY43.

Still to do, in order: spawn timing/positions against the GB trace (port
frame 0 is ~66 frames after the GB's; the first $53 differs), the plane's
own drawing (draw_subv still has the sub's blade), missiles (torp_fire x
offset), the six foes + Tatanga + the col+4 morphs, the ending (veh_clear no
longer arms 2-3's rope rescue; 4-3's clear is the game ending), then the gate
and the three World-4 routes re-recorded (E34).

## 4-1 playtest, round 2 (2026-09-04): the Superball vs Pionpi

User: "here I am shooting the enemy continuously and it doesnt get killed".
Two defects, one of them the whole story:

* **w3_hp was aliased AGAIN.** The per-slot Superball hit counter moved from
  $0128 (on top of w3_fcv, docs/45 above) to $0132 -- which is `do_yflip`
  (draw_quad clears it on every quad) and `mus_seen` at $0133 (the audio's
  frame stamp). Slot 0's count was wiped every frame, so an HP-1 Pionpi
  absorbed every ball forever. Measured with a poked ball on the real core:
  hit -> hp 1 -> hp 0 on the next frame. w3_hp now lives at $1FF4-$1FFD
  (kit RAM); the same test shows hp 1 held, and the second ball morphs the
  Pionpi to $15 (the corpse flies off, 800). The stack page is FULL -- the
  equate list is in law E39; it was never "clear at $0132".
* **The ball box was the engine's generic |dx|<10, |dy|<10** around the
  slot's top-left. The GB (docs/12, docs/38 s12) tests the ball's 4x3 box
  against the foe's size-byte box: in port coordinates dx in [4-8W, 0], dy in
  [-3, 8N-1]. A ball at a 16x16 foe's feet (dy 10..15) hit on the GB and
  passed here; a ball to its right (dx 1..9) hit here and passed on the GB.
  `w3_ballbox` (kit_w3.inc) is the GB test, FIRST in the W3TAB paste so FIXED
  can `jsr $B000` (W3BOX) from ball_hits for type 36 in worlds >= 3; 2-2's
  Mekabon (id 36 too) keeps the generic box. Unit-tested in py65 on the page-9
  image (9 dx/dy cases at the box edges).

Not reproduced (need the spot): the plant losing its left half as Mario
approaches, and the "barely playable" flicker/slowdown scene with several
Pionpi/hazards. Presence sweeps on the col-17 plant (Mario adjacent, jumping,
scrolling it off the left edge) showed both halves drawn; a warp to the
1920 checkpoint with 3-4 objects on screen ran 60 logic frames per 60.

Also found while re-homing w3_hp: **himod (the cols>=360 overlay) sat on the
composer's stash CS_B ($1FA0-$1FDB, object slots 7-9)**. Moved to $1C00-$1C3F
above the EAS3 kits' window code; the three kit cfgs now cap W2WIN at $1BFF so
the linker refuses a kit that grows into it.

### The plant "erased partially" (2026-09-04, user: every pipe plant, both sides)

Reproduced on the real core with a per-frame metric (non-sky pixels in each
4px byte-half of the plant's 8x16 sprite above the pipe rim): on the shipped
build 80 of 520 plant-up frames along the 4-1 route had one byte-half empty.
Not an erase at all: `draw_quad`'s OBJ-behind-BG rule sampled the quad's two
bytes on rows 0/5/7 of the BACKGROUND and skipped the whole quad when any of
them was non-white -- so a ladder pole behind the plant (4-1 has one behind
almost every pipe) took the plant's cell away whenever the sample hit a pole
line. The GB's OAM priority (attr bit7, OAM-checked on tiles $92-$95) is per
PIXEL: the sprite shows through every colour-0 background pixel and the pole's
lines draw over it. The blit's aligned fast path now applies exactly that
(`bmerge`: allow = pixels whose background is 0; dst = (dst & ~(M & allow)) |
(src & allow)), and the whole-quad sample is gone; the plant also emerges 1px
at a time now instead of 8. FIXED is full to the byte (CODE ends $EFF9): the
helper works in the shifted path's idle zero-page masks. Every behind object
(plant, pillar, cannon) is spawned 4px-aligned and never moves in x, so the
shifted path carries no behind case. Like-for-like on the same scripts: 80 -> 0
and 80 -> 15 byte-half frames, the 15 being the metric splitting a sprite that
sits 3px into its byte (pixel dumps show it intact). svgold 9/9 identical,
battery31 all pass.

### "Barely playable, heavy flickering and slowdown" (2026-09-04, the pillar stretch x 1900-2200)

Reproduced by warping to the 1920 checkpoint and fighting through the $55
pillars with the Superball (up to 9 live objects: hazards, debris, stones, a
platform, the ball). Two metrics on the real core, on-screen unfrozen frames
only: logic stalls (timer_sub unchanged across a display frame -- the 8-9%
baseline is the 61 Hz display against the NMI, it is flat from 0 to 9 objects)
and mover deferrals (dirty_bud wrapped below zero = a moving sprite kept last
frame's image). With World 3's budget of 2 movers a frame the scene deferred in
34% of frames (the judder the user calls flicker); 4 -> 2.7%, 6 -> 0.6%, with no
stall increase at any of them. The 4-1 route replay agrees (63 -> 54 -> 2
deferral frames, stalls 2% flat). load_level now gives World 4 (levels 9+) a
budget of 6; World 3 keeps 2 (its 40x24 lifts overran at 3, docs/44). svgold
9/9 identical, battery31 all pass. The lever's ceiling is the frame: re-measure
if a later 4-x scene shows stalls above the baseline.

### Congestion, measured and thinned (2026-09-04, user: "nothing fixed ... find those areas, solve the problem")

The user's call: compromise ONLY in congested areas -- half the pipe plants,
drop projectile shooters. Two new tools made that a measurement instead of a
guess:

* `tools/svprof.c` -- the real core with a PC sampler in `Loop6502` (every
  256 cycles; gated on death_anim == 0 and Mario on screen; PROF_FROM/TO/OUT/
  ALIVE env). Build like svshot but compile watara.c with
  `-DLoop6502=orig_Loop6502`.
* `tools/svcongest.py LEVEL` -- warps to every checkpoint, plays a fixed
  run/jump/fire script, and reports per 128px camera bin the logic-stall rate
  (timer_sub unchanged across a display frame with Mario on screen and
  unfrozen = the main loop overran), the mean live objects and the types.

4-1 before: x 2048-2175 (the $55 pillars) 14.5% of frames overrun with 4.7
objects live; x 256-383 (the first Pionpi fight) 7.0%; x 2176+ 8.4%. Removing
every $55 by poke took the pillars to 1.3%, so the hazards are the cost. The
profile there: ~50% of the CPU in the render pipeline (sprite_blit 15%,
blit_tile 8%, render_all 7%, restore_bg 6%, blit_blank 5%), ~13% in map reads
(w3_read 5.5%, mod_ptr 4.4%, map_transform, mod_test), the VM fetch itself
under 0.5% (its two page dances per script byte are NOT the problem).

Engine side: a pass-through mover (phys0 & $C0 / & $30 == 0) no longer runs
the ceiling/floor probe whose verdict it ignores (w3_move; the probes moved
to the resident W3TAB area because the $1500 window is pinned by the cold
layout). Semantics identical (svgold 9/9, battery31); the stall rate did not
move, so the probes were not the bottleneck either -- the sprites are.

Data side (`tools/pack_w4.py THIN`, entries by (fire_cam, type, o_y), the
build fails if one is missing): 4-1 drops the plant on the first Pionpi
fight's pipe (x 400), three of the six pillar hazards ($55 at fire_cam 1648/
1808/1968), the middle pillar plant (1840) and two of the three stone-droppers
after the pillars ($36 at 2208/2240). After: pillars 4.6%, Pionpi fight 4.3%,
1920-2047 3.7%; 2176+ stays 8.3% (platform + $38 + its stones; the survey's
script dies there, so that stretch is measured on 192 frames only).
`tools/pack_w4.py` is now a Makefile dependency of the ROM (it was not, and a
THIN edit built nothing -- E35's cousin).

4-2 surveyed the same way: one hot stretch, x 1408-1535 at 13.5% (eight $54
orbiters spawn between fire_cam 1136 and 1536, three or four alive at once).
THIN drops every other one (1184, 1296, 1392, 1536): 2.2% after. The rest of
4-2 sits at the 0.5-2% baseline. Shipped as ~/Desktop/sml_0904e.sv.

### The congestion algorithm (user, 2026-09-04) and its result on 4-1 / 4-2

User: "a) first start dropping STATIC enemies, e.g. pipe plants and cannons
(with their missiles) one at a time and remeasure; b) if the congestion is not
solved from a) then drop MOVING enemies again one at a time and remeasure" --
"if the plan works on 4-1 then we should document it and apply it in all
congested areas in all levels". Implemented as `tools/svthin.py LEVEL SCENE`
(law E42):

* a SCENE is a reproducible placement on the real core (a camera + Mario poke
  so every entry up to the camera is alive, as it would be when walked in; a
  checkpoint WARP is not usable -- the respawn seek skips every entry fired
  before it, so a warped scene is emptier than the user's) plus a fixed
  fight/run/jump script and a camera window; Mario is kept invulnerable
  (hurt_inv topped up) so 1000-3000 frames get measured -- a 127-frame
  baseline once accepted a drop on noise;
* the metric is the logic-stall rate (main loop overran a display frame:
  timer_sub unchanged, Mario on screen and unfrozen); baseline 2-4%;
* candidates are the spawn entries whose world x lies within the window
  (+/-160), lifts excluded, STATIC first ($02 plant, $49 cannon, $55 hazard,
  $36 stone-dropper, $0C), then moving; each is dropped alone, the ROM
  rebuilt, the scene re-measured; the drop stays only if the rate fell by a
  full point; the search stops at 4%;
* the accepted drops are `tools/thin.json` (read by pack_w4.py, a build
  dependency; a missing entry fails the build).

From an EMPTY table (the earlier hand-picked drops were discarded):

| scene | before | after | dropped (fire_cam type) |
|---|---|---|---|
| 4-1 pillars (walked in at x 1748) | 20.7% | 6.7% | cannons 1744 $49, 1904 $49; hazards 1776, 1808, 1936 $55 |
| 4-1 cannon after the 640 pit | 12.0% | 2.7% | cannon 528 $49 |
| 4-1 start | 5.2% | 4.0% | hazard 48 $55 |
| 4-2 orbiters (walked in at x 1150) | 13.7% | 3.2% | orbiters 1136, 1184, 1296, 1344 $54 |

The pillars stop at 6.7%: no remaining single drop gains a point there (the
three plants, the last hazards, the stone-droppers and the walkers were each
tried and reverted). Every plant in both levels survived the algorithm --
dropping one never bought a point. Shipped ~/Desktop/sml_0904f.sv; svgold
9/9 identical, battery31 all pass.

World 3 under the same algorithm (2026-09-04, "apply it in all congested
areas in all levels"): `svcongest` found 3-2's first stretch (x 128-511) at
13-19% -- five Tokotokos ($25) with two Nokobons and a plant -- and nothing
else above baseline in 3-1/3-3 (3-3's arena is docs/44's own story).
`svthin 7 start`: the two plants were tried first and bought nothing
(reverted); dropping three of the five Tokotokos (fire_cam 112, 208, 224)
took it from 12.5% to 1.9%. pack_banks.py now applies tools/thin.json to the
World 1-3 lists too (tools/thin.py is the shared reader). Consequence: 3-2's
svgold hash changes on purpose, and its recorded route must be re-checked
(log: docs/routes/thin_log_w3_2026-09-04.txt).

### 4-3 against the GB, round 1 (2026-09-05)

* **Spawner**: GB slot activations (D100 table) fire at `c0ab*16 = fire_cam +
  208` for every entry; port frames of the same activations are a constant 111
  frames apart from the GB trace's (its warp begins ~190 frames into the
  level), so the spawn timing is right as is.
* **$53's flight**: the GB flies straight at 1.5 px/f (screen) until it is
  within 32 px of the plane, then dives and climbs back; the port dived after
  14 frames. Cause: opcode `FB nn` (restart the script unless objx - c202 < nn)
  was one of the "unused" ops the VM skipped. Implemented from the interpreter
  ($2839), with `FC nn` (teleport, $62) -- docs/34 has the table. Re-traced:
  the dive now starts at the GB's x within 2-4 px.
* **The plane**: GB OAM quad $63 $64 / $65 $66|$67, the BR tile alternating
  every 4 frames (6667777666677776666...); drawn so. Its BIG form is not
  captured yet (needs the level's mushroom): small tiles until then.
* **The missile**: GB OAM tile $6E appears at (hull left + 9, hull top + 4)
  and moves 2 px/f ON SCREEN while the level scrolls under it; the port's
  copy of the sub's torpedo moved 2 px/f in world space (1.5 on screen) from
  hull + 16. Now screen-space (+2 + this frame's camera step, `vstep`) from
  hull + 9: 44,46,48.. in the same frames as the GB. (2-3's torpedo has the
  same world-space motion; left as accepted.)

### 4-3 against the GB, round 2 (2026-09-05)

* **Horizontal wall probe** (GB $2879/$28f0, probes $2b84/$2b9a): the VM
  mover never probed walls when stepping in x, so every walker went through
  them and Tatanga flew out of its arena (culled at screen -21). Now: before
  each x step the tile at the leading edge (left: o_x; right: o_x + W*8 - 8;
  row (o_y+8)/8 - 2) is read; $5F <= tile < $F0 is solid (one below the
  floor rule's $60 -- the arena's left wall IS a column of $5F); the response
  is phys0 & $0C: $00 walk on, $04 flip the x direction, $0C restart the
  script. Tatanga (phys0 $54) now bounces inside the arena (x 7..195 vs the
  GB's 16..192, y 47..136 vs 56..136 -- its turning points still differ by
  up to 9 px, open). battery31 caught my first version reading the floor
  row (HUD offset) and turned the boulder into a statue; fixed.
* **4-3 has its own data set** ("world 43" in gen_w3data, build/w43*.bin,
  w43data.inc, pack_w4 PAIRS tag): the shared W4 set had put every 4-3 type
  into 4-1/4-2's cold page (4 bytes left); the two $06 hazards before the
  arena did not fit. 4-1/4-2's roster is back to its 24 types.
* **Type $06** (two bobbing 16x16 hazards before the arena): added; motion
  matches the GB (dx -4 / dy +-4 per 8 frames).
* **The $1500 window**: w3_fetch/w3_cue/w3_morph/w3_child/w3_face moved to
  the resident W3TAB area (pure logic; every page dance restores the resident
  page before returning to them). W2C is at $627 of $6F8 now.
* **Spawn timing** verified for the whole level: every GB slot activation
  is a constant 111 frames from the port's (trace start offset), including
  $54/$06/$61 at the end once the window reload read page 12.
* Overrun: with three missiles in flight the port skips about every third
  logic frame (profile: sprite blit 22%, margin blank 10%, restore_bg 10%,
  map reads 19%). 4-3 gets the congestion survey once its objects are done.
