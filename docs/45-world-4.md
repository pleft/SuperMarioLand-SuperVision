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
