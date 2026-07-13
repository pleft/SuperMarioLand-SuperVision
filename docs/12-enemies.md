# Enemies / Objects Subsystem (Task #6)

Verified from code. The same framework drives enemies, projectiles, and some
interactive objects.

## Object slots
- **10 slots at `$D100`**, stride **`$10`** (16 bytes each): `$D100, $D110, … $D190`.
- Active flag = first byte; `$FF` ⇒ empty slot (the AI loop skips it).
- For processing, a slot's first **13 bytes** are copied to the working area
  **`$FFC0–$FFCC`** (`ObjectLoadSlot` $2CEB) and written back after (`ObjectSaveSlot` $2CFD).

### Working-field layout (`$FFC0..$FFCC`, mirrors slot bytes +0..+12)
| Off | Var | Meaning |
|-----|-----|---------|
| +0 | $FFC0 | **object type** (index into `$349E`/`$3375`) |
| +1 | $FFC1 | velocity |
| +2 | $FFC2 | Y position |
| +3 | $FFC3 | X position |
| +4 | $FFC4 | **AI-script program counter** |
| +7 | $FFC7 | accel/gravity flags (from `$3375`) |
| +8 | $FFC8 | movement state |
| … | | (others: sub-state, timers — refine per type) |

## Per-frame update — `EnemyUpdate_2491`
1. **`ObjectSpawnCheck` ($249B)** — walk the level spawn list (ptr `$D010/$D011`);
   when an entry's column ≤ current column `$C0AB`, create an object from it.
2. **`ObjectAIUpdate` ($2648)** — for each active slot: load → `ObjectPhysicsAndScript`
   → save. Dispatches the type's AI via the table below.
3. **`ObjectCollision_2568`** — object-vs-player interactions.

## Spawn-list entry (in level data; see `docs/10-level-format.md`)
3 bytes: **`[ column , position , type ]`**
- `column` = spawn column (vs `$C0AB`)
- `position` = byte with **Y** in bits 0–4 (`*8 + $10`) and **X screen offset** in bits 6–7
- `type` = object type id (→ `$349E`/`$3375`)
(Correction: an earlier note labeled byte2 "param"; it is the **type**, byte1 is position.)

## Type tables (indexed by `$FFC0` object type)
Types run past the `$00–$1B` enemies — ITEMS live higher [item map corrected 2026-07-02]:
**`$28`→`$29` Super Mushroom** (hop→walker), **`$2A`→`$2B` 1-UP heart** (identical physics +
scripts to the mushroom, sprite param `$17` = tile `$84`; pickup → `$c0a3` = +1 life),
**`$2C`→`$34` star** (rise → arc-bounce; pickup → `$c0d3`=`$f8` invincibility), **`$2D`→`$2E`
Superball Flower** (rise → sit). Block-content values (bank3 `$6536`) are spawned as these
object types (`Jump_000_1888` → `Call_000_254d`).
- **`AIScriptPtrTable` @ `$349E`** — per-type pointer to a **movement-script** (below).
- **`PhysicsParamTable` @ `$3375`** — **3 bytes/type** (`Call_000_2cbb` indexes `type*3`):
  byte0 → `$FFC7` (collision/accel flags; `&$0c==$04` = reverse-X-on-wall, `&$30`/`&$c0` =
  Y-collision response), byte1 → slot+10, byte2 → slot+12. (Earlier "2 bytes" was wrong.)
  Mushroom `$28` = `24 11 00`. Same ballistic engine as `ObjectPhysics_Integrate` ($2975) +
  horizontal mover (`$2879`): velocity `$FFC1` hi-nibble = Y speed, lo-nibble = X speed;
  `$FFC5` bit0/bit1 = X/Y direction.

## AI = a data-driven script bytecode
`ObjectPhysicsAndScript` ($2676) applies physics, then steps a **per-type script**:
- `HL` = `AIScriptPtrTable[type]`; **`$FFC4`** = script PC; current byte → `$D002`.
- byte `$FF` ⇒ reset PC (loop the script).
- high-nibble `$Fx` ⇒ control command; `$Ex` ⇒ set movement state (low nibble → `$FFC8`);
  other values ⇒ velocity/timing (`$FFC1`).
- Scripts live at **`$3564`…~`$3790`** (this is why they disassemble as data — they
  are bytecode, not CPU code).

## AI script VM — full opcode set (task #12, decoded + validated)
Interpreter `ObjectPhysicsAndScript` ($2676); PC = `$FFC4`; current byte → `$D002`,
operand → `$D003`. Decoder: `tools/decode_ai_scripts.py` (decodes all 28 scripts).

| Opcode | Operand | Effect |
|--------|---------|--------|
| `$00–$DF` | — | set **velocity** `$FFC1` = byte; mark active (`$FFC8=1`) |
| `$E0–$EF` | — | set **movement-state** `$FFC8` = low nibble (`$EF` = advance/next-frame) |
| `$F0 nn` | 1 | **facing / track player** (compare Mario Y `$C201` vs obj Y; set facing in `$FFC5`) |
| `$F1` | 0 | **spawn** a sub-object (init from physics tables) |
| `$F2 nn` | 1 | set **acceleration** `$FFC7` = nn |
| `$F3 nn` | 1 | **morph**: change object type `$FFC0`=nn → switch to that type's script; `$FF` = despawn |
| `$F4 nn` | 1 | set `$FFC9` = nn (sub-state/timer) |
| `$F5 nn` | 1 | conditional (variant of `$F0`) |
| `$F6 nn` | 1 | **jump**: set script PC `$FFC4` = nn (branch within script) |
| `$F8 nn` | 1 | set **param** `$FFC6` = nn (animation/sprite param) |
| `$FF` | — | **loop**: reset PC to 0 (script restarts) |

Scripts run each frame one "step" until they yield (set-state/velocity commands
advance the object a frame); `$F0–$F8` config commands execute then continue.

Example — type `$00` (simple looping object): `set_param 0; set_ffc9 2; velocity 1;
state 2; set_param 1; state 3; loop`. Type `$01` cycles `set_param`/`state` frames
with `face` + `jump_pc` (animated, player-facing enemy).

## Status
- ✅ Framework + **full AI script VM opcode set** decoded and validated against all
  28 type scripts (`tools/decode_ai_scripts.py`).
- ⏳ Remaining (light): label each of the 28 types to its named enemy (Goombo,
  Nokobon, fish, Bunbun, bosses, coins, fireball, superball…) by correlating script
  behavior + spawn usage + graphics. Mechanical now that the VM + decoder exist.

## For the port
Reproduce: the 10-slot table, the spawn-from-column-list mechanic, the shared
ballistic physics (already documented), and the script VM + per-type scripts
(extract the script bytes from the ROM at build time, rule 5). Behavior is fully
table/script-driven → ports cleanly to the 65C02 with the same data.

## PORT: spawn system + Chibibo — DONE, user-verified [2026-07-04]
**The spawn counter law (trace-calibrated, zero error): `$c0ab = 12 + camera/16`** — it ticks
every SIXTEEN pixels (every OTHER column), not per column. An entry (col `C`) fires when the
counter PASSES `C` → port fire_cam = `(C−12)*16` (STRICT compare: nothing spawns while idle).
Spawn X = camera+180 (original enters at OAM 188); o_y = GB y − 24. Extractor emits
`level_NN_spawns.bin` `[fire_cam16, o_y, type]`, skipping hard-mode (bit7) + platform entries.
Consequence re-derived: the DEATH CHECKPOINTS = `(C_seed−12)*16` = cameras **0/640/1280/1920**.
Verified fires vs the original: 2nd Chibibo 336 (orig spawned cam 346), the pair 448/464 —
entering above the r5 bricks (cols 79-81) and staircasing down brick→pipe-top→ledge, exactly
the original.

**Chibibo (type $00)**: walks left **1px per 3 frames** (trace: 24px/72f; fall 1px/frame),
wall-reverse, walks off ledges. Walk anim = **tile `$90` mirrored** (params $00/$01 = same
tile ± flip attr); **`$91` = the squash frame only** (using it as a walk frame looks like
hopping). Buried-spawn guard: feet+body rows both solid → rise 1 row/update until clear.

**Combat (RE `$08C7` + the `$3186` result table)**: stomp = Mario's y 4+ px above the enemy's
(position, not velocity) → squash (type+1 via the table: $00→$01, $04→$05 bomb, $0E→$0F) +
fixed bounce + 100 (+popup `$59/$58`); side contact → star kills / big **shrinks** (`$ff99=3`,
80f flash = grow mirrored, powers lost, mercy blink after) / small dies. Unstompable flag =
phys byte1 bit7. Superball kills (ball vanishes). Table byte4 = projectile-kill result types
($11/$12/$15 = the dead-flip variants).

**TODO next**: Nokobon $04 (tiles $96-$99; squash = BOMB type $05: blink $9A/$9B then explode)
+ fly $0E (params $28/$29 16px metasprites; spawn cab 83 @ x=199; death chain 0E→0F→15→0D
captured in the traces); death-hop animation; flashing-with-enemies check (perf).

## PORT: Nokobon + Fly — 1-1 ROSTER COMPLETE [2026-07-04]
**Nokobon $04** (one in normal 1-1 @col 59; hard mode adds 12): 8×16 walker (bottom `$97/$99`
+ shell `$96/$98` at dy−8, faces walk direction — tiles face LEFT natively), same 0.33px/f
engine, **TURNS AT LEDGES** (user-verified vs 1-2; phys `$07` bit0 = edge-turn — the Chibibo's
`$06` walks off). Stomp → **bomb** type $05: sits blinking `$9A/$9B`, harmless touch ($3186
row zeros), **fuse 63 frames** (trace-exact) → **explosion** type $46: 16px cloud = `$9D/$9E`
each + own X-mirror, **44 frames**, contact hurts ($3186 byte2=$FF). Ball/star kill → gone.
**Fly $0E** (3 in 1-1: cols 82/117/122; spawns at cam+191 not +188): 16×16 metasprite
(`$A0A1/B0B1` + `$A2A3/B2B3` buzz), sits ~55f → 48-frame hop toward Mario (tracked at launch):
15px arc via `fly_dy` per-frame table (rise 4,4,2,2,1,1,1 / hover / fall mirrored, one step
per 3 frames), drifts 1px/2f, ~24px/hop, ~103f period. Stomp → flattened pair `$A8+$A9`
(OBJ_SQUASH pair flag in o_st). Engine notes: shared `enemy_contact` proc (cull/overlap/star/
stomp-by-type/hurt); tall/wide erase via o_pw bit7 + width; bg_chardata → bank 0 (FIXED full).

## Enemy SCORES + popup tags + the stomp COMBO — RE'd exactly [2026-07-04]
(Was wrongly hardcoded 100-for-everything; the user caught the fly at 400.)
- **Base value** = phys byte2 bits 6-7 → class table `$0A29` = `01 04 08 50` (value CODES in
  BCD hundreds): class 0 = 100 (Chibibo `$00`, Nokobon `$00`), class 1 = 400 (Fly byte2 `$41`),
  class 2 = 800, class 3 = 5000.
- **Stomp combo** (`$ff9c` 50-frame window, `$ff9d` chain 0..3, code re-read fresh then
  `sla`×chain; codes ≥ $50 never double): 100→200→400→800; fly 400→800→1000→2000.
- **Code → points**: the code IS the score in BCD hundreds (second chain in the bank2 popup
  engine confirms: DE=$0100 stepping with the code). Port: `add_score(lo=0, hi=code)`.
- **Code → popup tiles** (bank2 `$5892` engine): left = `$59`+step ($01/$02/$04/$05/$08 →
  step 0-4), right = `$58` ("00"); codes ≥ $10 shift right glyph to `$57` ("000") with the
  same left progression; `$FE` = 1UP = `$5E/$5F`.
- Port procs: `award_stomp` (chains, combo_t/combo_n) / `award_kill` (base only — ball & star).
  py65: fly stomp = 400 ✓; chained chibibo right after = 200 (total 600) ✓.
- **AI VM opcode `$F9 nn` decoded** (was missing from the table): writes nn to `$dff8` =
  SOUND trigger (the `$FA nn` below it writes `$dfe0`). The explosion's `F9 01` = its bang —
  audio phase, not visual.

## PORT: the 1-2 kit — Bunbun + arrow + falling stone [2026-07-13, commit 7f62148]

Identified from the FULL type tables (99 entries: PhysicsParamTable $3375..$349E = 99×3,
AIScriptPtrTable $349E..$3564 = 99×2 — decode_ai_scripts.py now decodes all of them) +
the enemy metasprite display lists ($2fe2 right / $30b4 left, param*2 → list of
[control bytes: bit3/2 y∓8, bit1/0 x∓8, upper bits → OAM attr] + tile bytes (bit7 set),
$FF end) + PyBoy slot captures of a forced 1-2 (`$ffe4` poked at the title, or better:
State_08 with `$ffe4 = target−1`).

- **Bunbun (type $42 → OBJ_BUNBUN 19)**: 16×16 bee, tiles $C0/$C1/$D0/$D1 (+2 = frame B),
  left-native like the fly. Phys `00 22 80` → score class 2 = **800**. Slot capture:
  spawns at the right edge, flies at its SPAWN HEIGHT (no y tracking) 1px/frame toward
  Mario for 40f (script steps = 8f each; wing flap per step), hovers 33f, **drops the
  arrow 17f into the hover** (cycle tick 57), loops — `F0 $10` re-faces Mario every cycle.
  Stomp → type $43: param $34 = flat pair $C8+$C9 (~24f) → $44 (pop −7/+3) → $0D falling
  corpse (param $35). Port: OBJ_SQUASH pair (32f, the fly convention) on stomp; star/ball
  → corpse kind 3 (dead-flip 16×16). Ball kills in ONE hit (no fly-style 2-ball rule).
- **Arrow (type $45 → OBJ_ARROW 20)**: 8×16, tiles $BC over $AC. Phys `00 12 00`, script:
  velocity $10 = 1px/frame straight DOWN, x frozen, NO terrain collision — captured
  falling through the floor to y≈191, culled off-screen. Contact table row `$3186+$45*5 =
  00 00 ff 00 00`: **no stomp morph** — any contact falls through to hurt (captured: arrow
  on small Mario = death state $03). Port: shared-geometry overlap (`mario_dx`) → hurt;
  star just deletes it (+100 class 0).
- **Stepping stone (type $36 → OBJ_STONE 21)**: single 8×8 tile $EE, phys `00 91 00`
  (byte1 bit7 = rideable, like the platforms' $B1). Contact row `37 00 00 00 00`: LANDING
  morphs it to $37 = same sprite, one script-step beat, then velocity $10 = falls 1px/f
  (still carrying). Port: plat_land/ride_support accept OBJ_STONE (8px window), landing
  sets an 8f beat then a 1px/f drop via carry_y_dn; culled off the bottom. py65: land
  f+5, beat 8f, stone+Mario descend in lockstep ✓.
- **Moving platforms are now TABLE-DRIVEN** (spawn entries carry x_off; $0A/$0B emitted):
  world x = fire+192+x_off*4 ($249B rule), V patrols spawn-y DOWN 60px, H patrols spawn-x
  LEFT 53px, 0.5px/f ping-pong (o_st = offset from origin, o_vy = returning). Six 1-2
  platforms slot-captured (all = spawn_y..+60); the rule reproduces 1-1's dedicated-trace
  bounds EXACTLY (V x=2280 y 64..124, H y=40 x 2291..2344 — py65-verified), so the 1-1
  hardcoded end-area spawner (PLATS_AT/plats_on) is deleted.

**1-3 roster still to port** (spawn types from its list): $02 (walker w/ pauses+turns,
params $04/$05), $08 (big winged thing, params $48/$49, drops type $1B), $0C (low wide
rock, param $13), $3F (Gao the sphinx: static, params $2A/$2B, spawns fireball $23),
plus 5× $36 stones (done) — AND the $d014 animated water tiles + music track $03.
