# World 3 (Easton) enemies: the RE ledger (2026-08-19)

Sources, in order of authority: (1) live GB slot traces with the CAMERA logged
(tools/w3behav-style captures; screen x drifts when the camera moves -- always
compensate), (2) the AI-VM scripts (tools/decode_ai_scripts.py), (3) the
metasprite display lists (tools/dump_metasprites.py: $2FE2 right / $30B4 left,
param*2 -> control/tile byte stream), (4) PhysicsParamTable $3375 + the contact
table $3186. Nothing goes in the port on (2)-(4) alone: a live trace confirms.

## GB warp recipe (this world)

State_08 increments BOTH `$ffe4` (linear level id) and `$ffb4` (the BCD
world-stage shown in the HUD, with a stage-4 roll). Poke `ffe4 = target-1`
AND `ffb4` = the target's predecessor BCD, then `ffb3 = $08`:
3-1 -> ffe4 5 / ffb4 $23, 3-2 -> 6 / $31, 3-3 -> 7 / $32. Poking ffe4 alone
lands in the wrong world (my first sweep captured World 4 by accident).

## Already ENGINE-shared (no new port work)

`spawn_check` maps these globally: $00 Chibibo, $04 Nokobon, $0E Fly,
$42 Bunbun, **$36 stone**, $0A platform-vertical, $0B platform-horizontal.
W3's lists are full of $04/$0A/$0B/$0E/$36 -- they come for free. ($02 Suu
and $0C spiky ball exist in the 1-3 kit; W3's EAS3 kit must re-provide them
since kits are per-bank.)

## 3-1

| GB | what | model (measured) |
|----|------|------------------|
| $3C | **BATADON** (winged moai head) | 24x16. Params $23/$24/$25 = 3 wing frames: top row [$AA|$AB|$AA x-flip] ($24 -> $BA, $25 -> $AC), bottom [$BB] centred. Script `face/track $60` = track Mario's X. TRACE (Mario left, camera still): hop cycle **92f**, x moves toward Mario ~1px/f throughout, y arc 136 -> 106 -> 136 (30px up), fast at the start (1px/f), easing to 0.5px/f near the apex, ~6f hang, mirrored descent. Phys `301282`, contact `0000ff27` (stompable -> $27 cloud). |
| $3E | Batadon's spawn/landing burst | params $27 (a 24x8 [$AC|$AD|$AC-flip] band) then $2A/$2B (16x16 quads $A4-$A7/$B4-$B7); script: SFX $dff8=$03, **morph_type $0D** (the falling-corpse type), spawn_child $23. |
| $49 | **rising moai pillar** (moai head on a column, drawn BEHIND the BG: OAM attr $80) | param $51 = 8x16 [$87 top, $88 bottom]. TRACE (camera-compensated): drifts left ~0.5px/f for 32f, then PARKS at its column and bobs: up 16px over ~16f, dwells ~108f at the top, down 16px over ~14f, dwells ~64f, repeat. Spawns child $4A. |
| $4A/$4B | the pillar's projectile chain | $4A params $52/$53 (8x16 pairs $F9/$FB and $F9/$FA), velocities $30/$70 (vertical, fast), morphs to $4B; $4B keeps $52/$53 with vel $01 (1px/f horizontal). |
| $31 | 16x16 quad, params $2A/$2B ($A4-$A7/$B4-$B7), vel $06 | shares the $3E art; script is 6 lines = a simple mover. Needs its own trace. |
| $3A | params $22 = TWO $EF tiles (16x8), vel $10, face/track $22/$20 | |
| $3B | param $22 as well, vel $01, face/track $10/$11 | contact `00ff2727` |
| $03 | param $1F (single $FE), spawn_child $47 | a generator |
| $05 | params $08/$0E/$65, morph $46 | |

## 3-2 / 3-3 (recon only; traces pending)

- 3-2 is dominated by **$25** (48 sightings): params $32/$33 (16x16 quads
  $C4-$C7/$D4-$D7), `face/track $22/$20`, vel $00/$10, phys `e02241`.
  Plus Suu $02 and $35 (param $20 = single $DF, vel $10).
- 3-3: $31/$32/$38/$39/$3A/$3B/$47/$56 + the boss. $32 (params $54/$55 =
  16x24 stacks, spawn_child $33) is the **Hiyoihoi** shape (three 16x8 rows);
  $56 (params $28/$29 = 16x16 quads $A0-$A3/$B0-$B3, many velocities) is the
  other big one. $47 params $31/$47 (the same $C2/$C3/$D2/$D3 quad, flipped).

## THE AI-VM (read out of the disasm at $2676 + $2879 + ObjectPhysics_Integrate)

The GB runs ONE interpreter for every scripted enemy. Ported faithfully it
covers all of W3 (and W4 later) instead of a dozen hand-written movers.
Semantics, now exact (disasm-read AND probe-confirmed against live slots --
the slot's 16 bytes are the saved VM context: +1 velocity, +2/+3 y/x,
+4 script PC, +6 param, +8 wait counter, +9 tick counter):

- `$ffc9` = (counter << 4) | divider. Each frame counter++; when counter ==
  divider a TICK happens (counter resets). `F4 nn` sets the divider, so
  `F4 $01` = a tick every 2 frames (Batadon's cadence, probe-confirmed).
- On a tick: `ffc8`-- (the wait counter), then movement is applied.
- When `ffc8` hits 0 the next opcode is fetched from the script:
  `$FF` -> PC = 0 (restart, NOT "end"); `$E0-$EF` -> wait (opcode & $0F)
  ticks (so `$EF` = wait 15 -- my first decode read these as "set_state",
  which mis-modelled every idle); `$F0-$FE` -> 2-byte extended; anything
  else -> the VELOCITY byte (and wait 1).
- Velocity byte: **low nibble = X px per tick, high nibble = Y px per tick**
  (`ffc3 -= vx` / `ffc2 -/+= vy`). Direction comes from `ffc5`: bit0 = X
  flipped, bit1 = Y falling. NOT from the nibble.
- `F8 nn` = set metasprite param. `F0 nn` = direction control: bit7 track
  Mario's Y, bit6 track Mario's X, bit5/4 force, bits3-2 XOR-flip.
  `F3 nn` = morph type, `F1 nn` = spawn child, `F9 nn` = SFX, `FA nn` = ?
- Collisions gate the movement: wall/floor/ceiling probe calls decide
  whether the step applies, whether Y flips to falling, or whether the
  script restarts (`ffc7 & $c0 == $c0` -> PC = 0).

Example, fully cross-checked: `$3A` = `F8 22 | F4 01 | F0 22 | 10 | EE |
EF EF EF | F0 20 | EF EF EF EF | FF` = set param $22, tick every 2f, face
one way, X speed 1, patrol ~59 ticks, face back, ~60 ticks, loop -- a plain
patroller. Batadon's 92-frame hop is the same machinery with Y velocities.

## THE PORT (shipped)

kit_w3.inc runs the VM; gen_w3data.py extracts 36 scripts (1285B), 44
metasprite display lists and a compact 58-tile slice into bank 6; the hot code
lives in the $1500 window and the cold half in a bank-RESIDENT far segment in
bank 1 (W3's own bank, so no bank juggling).

**Per-type gate** (tools-side: /tmp/w3verify.py): force the GB and the port to
the same script offset, then compare TICK EVENTS (pc, velocity, param, dy,
|dx|). Results so far:
- `$3C` Batadon: 21 events, **0 mismatches**
- `$49` rising moai pillar: 20 events, **0 mismatches**
Types deeper in the levels ($3A/$3B/$31/$25/$35) could not be reached by the
GB autoplay bot (it dies or stalls before their spawn columns) -- they run the
same interpreter and appear correct in play, but they are NOT individually
gated. Say so rather than implying they are.

**Contact** comes from the ROM's contact table ($3186, FIVE bytes per type):
column +0 is the stomp result, reached from the GB's stomp test at $08C7.
$00 there means "not stompable" (the shared l3_hurt behaviour: side contact
hurts, landing does nothing). Non-zero morphs the slot into that type, and
since kill chains are just more VM types the whole chain runs for free
(Batadon -> $3D squashed -> $3E puff -> $0D falling corpse).

**Level soaks**: 3-1/3-2/3-3 each run 4000 frames across the whole level with
enemies live -- no wedge, no corruption, canaries clean. 3-3's ending (sphere
gate -> rope -> room -> the World-3 creature -> bonus) verifies end to end
with the creature tiles byte-asserted.

## What is NOT done in W3  (user asked 2026-08-20: "are we done in W3?" -- NO)

- **Hiyoihoi ($32) is not a boss yet**: it spawns and the VM runs its script
  (it throws its child $33), but there is no HP/defeat handling, so it cannot
  be killed -- the level is finished by reaching the sphere, which works.
- Ball column of the contact table: WIRED 2026-08-25 (docs/43 `w3_ball`:
  HP + morph + score). The star column is still not wired.
- $36's engine-side stone and the shared types are inherited, not re-verified
  against W3 specifically.

## Hardware playtest round 1 (user-reported, 2026-08-19)

Three reports; two had confirmable mechanisms, found by measurement:

1. **HUD unstable while scrolling, W3 only.** MEASURED: W1/W2 levels perform
   ZERO SYS_CTRL writes per frame during play; W3 was doing **22 on average
   and up to 54**, because its map data lives in bank 6 and the reader mapped
   the bank per tile read. Every SYS_CTRL write restarts the LCD scan
   (docs/27: doing it once per frame already produced unplayable banding).
   FIX: a 4-slot map-COLUMN cache in the RAM tail the retired 2-3 loader stub
   used to occupy ($1F80), invalidated when map_base changes (rooms reuse low
   column numbers). Result: **1.0 writes/frame** (max 14). Not zero -- new
   columns must still be fetched -- so if a residual wobble remains, batch the
   refills to a fixed point in the frame.
2. **Background not erased around new enemies.** MEASURED: four metasprites
   exceed the erase box that was sized from Batadon alone -- $54/$55
   (Hiyoihoi, 3-3) and $4E/$4F, which appear when 3-2's dominant enemy $25 is
   stomped ($25 -> $1C -> $19). FIX: a generated exception table gives those
   params their own erase origin and row count, and the engine's width byte
   gained bit5 = two extra rows (max 5 rows = 40px) for the 32px cases.
3. **Garbled level-select text**: NOT diagnosed. Ruled out the obvious cause
   by measurement -- 3-1's live GB font tiles ($00-$2B) match the port's
   shared charset 44/44, so the character set is intact. (Note w3_bg_9000 and
   w3_obj_8000 are extraction red herrings: the GB loads W1's base sheets plus
   the per-world overlay, confirmed 68/128 + the $31-$6F overlay.) Needs a
   screenshot.

Space after the fixes: W3 window 2030/2048, W3 far 398/448, FIXED ~1 byte.

## 2-3's boss, re-measured against the GB (2026-08-20)

The user asked whether Dragonzamasu ($1A) was really implemented per the
original. Captured him on the GB rather than trusting the comments:

```
                    GB (measured)              port (was)          verdict
HP                  19 (slot+$0C & $3F)        19                  OK
shot cadence        every 64 frames            64                  OK
patrol range        y 103..136 GB = 87..120    63..124              WRONG (2x)
patrol speed        1px / 1.70 frames          1px / 2 frames      WRONG
his shot            a METASPRITE               ONE 8x8 tile        WRONG
```

**The shot was the user-visible one** ("big fireballs but they are half
rendered"). GB OAM at the shot's position:

- `$1F` rising: 4 sprites, 2x2 = 16x16 -- `$CE $CF` over `$BC $BD`
- `$58` flying: 6 sprites, 2x3 = 16x24 -- `$BE $BF` / `$CE $CF` / `$BC $BD`

`draw_dshot` was `jmp draw_ghalf`: one 8x8 tile, and the wrong art (the
gunion-split blob `$E2`). It now draws the real metasprite per phase, and
`ovl_width` gives it a 3-col box that is 16px tall rising / 24px flying
instead of the 2-col box that left half of it on the floor.

Tiles: the port's quad ids ARE the GB's ($BC = DRG_TA), and the W2 region
carries the full 61-tile $A0-$DC overlay, so $CE/$CF were already shipping --
nothing new had to be extracted.

LESSON (law E-class): "it was capture-verified" in a comment is not the same as
"I verified it". The HP and cadence were right; the geometry never was.
