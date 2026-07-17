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
  spawns at the right edge, flies at its SPAWN HEIGHT (no y tracking) 1px/frame for 40f
  (script steps = 8f each; wing flap per step), hovers 33f, **drops the arrow 17f into
  the hover** (cycle tick 57), loops. **It NEVER turns** (user-verified vs GB): the
  direction is fixed at spawn (toward Mario = left) and it exits the screen. [An earlier
  build re-faced Mario each cycle off the script's loop-start `F0 $10` — a disasm
  inference the capture never confirmed (the observed bee died to star contact before a
  second cycle could show it). RULE 0: same failure mode as the skid pose.]
  Stomp → type $43: param $34 = flat pair $C8+$C9 (~24f) → $44 (pop −7/+3) → $0D falling
  corpse (param $35). Port: OBJ_SQUASH pair (32f, the fly convention) on stomp; star/ball
  → corpse kind 3 (dead-flip 16×16). Ball kills in ONE hit (no fly-style 2-ball rule).
- **Arrow (type $45 → OBJ_ARROW 20)**: 8×16 — the display list draws $BC at the base y
  and $AC 8px ABOVE: shaft on top, **head at the bottom**, leading the fall (the first
  ship had them inverted; user-caught). Phys `00 12 00`, script:
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

## Hidden blocks ($5F) + the block-bounce kill [2026-07-13 hardware feedback, a6c0e53]

- **Hidden blocks**: map tile `$5F` (blank in the BG charset, `<$60` = non-solid, so
  Mario passes through the cell) is an INVISIBLE block: bonkable from below only. The
  bonk materializes it — the hop shows the used block `$7F` — and pays out through the
  same contents table (bank3 $6536; the extractor already keyed rows off $80/$81/**$5F**).
  Once modded, the cell draws AND collides as `$7F`. **An UNLISTED $5F cell is fully
  INERT** — GB `Jump_000_187b` reads the content plane and plain-returns on 0: no bump,
  no coin, the jump passes through (unlike an unlisted $80/$81 ?-block, which pays a
  coin via $19E1). The port gates $5F bonks on find_block. Instances: 1-2 col 95
  row 11 = the 1-UP heart ($2A); col 215 row 11 = an inert leftover marker. 1-3 has
  cols 2 & 150 row 9 with **value $07 (unidentified — RE at the 1-3 round)** and
  col 193 row 8 = a hidden MULTI-COIN ($C0). CAVEAT for 1-3: the live multi-coin's
  draws-as-brick rule (`@mcchk`) only fires for raw $80/$81 — the hidden multi-coin
  needs the $5F case added there.
- **Block-bounce kill** (`bonk_kill_above`): any hopping bonk (?-block, hidden block,
  brick hop or smash, multi-coin re-bonk) kills an enemy standing on the bonked cell:
  the walkers' own ground rule (`o_y>>3 == mrow`) + |enemy centre − cell centre| < 10
  → dead-flip corpse keeping its walk direction + the class kill score (100 walkers /
  400 fly / 800 bunbun). Plain used/solid bonks (no hop) don't kill.

## Round 2: spawn retry, goal stones live-verified, the flicker fix [2026-07-14, 41b8be4]

- **Spawn entries retry when the pool is full** (they were being consumed and lost —
  the user's H platform and second goal stone vanished until a respawn rewound the
  list). Deviation: the GB consumes-on-full but has 10 slots vs the port's 8.
- **Goal stones live-captured on the GB**: two adjacent static 8px stones; riding one
  morphs $36→$37 on overlap, ~8-frame beat, 1px/f fall carrying Mario (his y tracks
  the stone), DESPAWNS at y≈190 — one-shot, no wrap/stream. Port behavior confirmed
  exact once both spawn.
- **Flicker with 2+ bees** (measured 176% of the 65574-cycle budget): bees/arrows now
  move 2px every other frame (same trajectories — fly still 40px/40-tick phase, drop
  at tick 57; arrows on their bee's parity so a bee+arrow pair never seeds the
  overlap-dirty chain on its off-frames); per-type anim tokens (`anim_token`: bee flap
  slot-staggered, arrows/stones token-constant); `sprite_blit_subpx` rewritten on
  boot-built shift tables (`shtab_lo/hi[subx][b]` = b<<(2·subx), 2K RAM) with per-row
  masks M(shifted) — M commutes with 2-bit-aligned shifts. Worst synthetic 176%→130%,
  realistic runs under budget. Boot frame pixel-identical before/after.
- HARNESS LESSON (twice now): rebuild build/dbg.txt after ANY code move — a stale
  main_loop symbol makes the py65 frame loop "hang" (it waits on a dead address).

## Round 3: the end-area cast needs TEN slots [2026-07-14, c68e5a1 — 1-2 user-confirmed]

GB capture of 1-2's goal area (parked at cab $84): BOTH bees drop arrows continuously —
peak cast `42,42,45,45,45,45` = 6 objects, 6 arrow spawns in 900f — plus the vertical
platform and 2 stones once cab $85/$88/$89 fire: NINE concurrent objects. The port's
8-slot pool silently dropped the arrows (bunbun_drop found no slot) and starved the
second stone. Pool is now `OBJ_MAX = 10` like the GB's $D100-$D190. With that + the
render budget (docs/22), the whole area is hardware-confirmed ("flicker is gone, the
ending area works fine") — **WORLD 1-2 COMPLETE**.

## The kill THUMP: VM `F9 03` in the corpse scripts [2026-07-15]

The user heard a missing "noise-like" sound. Hooked GB capture (PyBoy `hook_register`
on every `ld [$dfXX],a` site — the mailboxes are consumed same-frame, so per-frame
sampling NEVER sees them): killing the bee fires `$dfe0=$03` (the chirp, ported) AND
**`$dff8=$03`** simultaneously. Site $2828 = the AI VM's **`F9 nn` opcode** (write nn
to $dff8; `FA nn` → $dfe0 at $282C) — decode_ai_scripts.py now decodes both (they were
mis-read as velocity bytes!). Ground truth per kill chain:
- Chibibo `$01`/kicked `$11`, Nokobon `$05`/`$12`: **NO sound opcode** — silent (the
  stomp chirp only). Port was already correct.
- Fly `$15` and Bunbun `$44`: **`F9 03`** — the kill thump plays when the corpse
  MORPHS: immediately on star/ball/bounce kills, ~24-32f AFTER a stomp (the flat
  squash frames run first).
Port: `kill_flip` plays `SFX_DFF8_03` for corpse kinds >= 2 (fly/bunbun); the stomped
fly/bee thump moved to the squash-expiry (`upd_squash`, `o_vx` == FLY_SQ/BUN_SQ) —
the fly's old stomp-time override (24f early) is gone. py65: chirp at the stomp,
thump exactly 32f later.
Also: the bee's ARROW drop is SILENT on the GB (hooked capture, 4 drops, zero
triggers), and so is riding/falling with a goal stone.

## PORT: the 1-3 kit — Suu, spiky ball, Gao, Batadon + the hidden-block secret [2026-07-16]

All five GB-capture-verified (PyBoy slot traces + the $3186 contact table at stride 5:
+0 stomp morph, +1 ball morph, +2 touch (0 harmless / $FF hurt), +3 star morph
($FF = silent despawn), +4 block-bonk morph). Port code lives in the bank-2-only
L3CODE overlay (copied to RAM $1500 by load_level; see docs/24).

- **Pipe/column FLOWER $02 → OBJ_SUU 23** (8x16, tiles $92/$93, frame B $94/$95):
  sits ON pipes and rock columns; 200f cycle — 62f retracted (hidden INSIDE the
  column: GB OAM behind-BG priority; port clips its quads at the rim, base in
  o_vy), 16f rise, 105f up with the pose toggling ~15f, 16f descend. CLASSIC
  PLANT RULE (captured: held at 12px, emerges at 14): stays down while Mario is
  flush with the column (centre dx < 10). Contact: side/below hurts; the STOMP
  side is a NO-EFFECT exit on the GB (+0 = 0) — Mario passes through the head
  zone and lands on the solid column (l3_hurt; also covers rock/fireball/shot/
  moai). Star = silent despawn (+3=$FF) + 100; ball no effect. Port verified:
  cycle 80..96 far, held at 96 flush, harmless from above.
  [Shipped first as "Suu the spider, any contact hurts" — user-caught: visible
  inside the column + dying on stomp attempts.]
- **Spiky ball $0C → OBJ_ROCK 23** (16x8, tiles $DD+$DE): hangs at its spawn
  height ~174f, then falls 1px/f THROUGH terrain, despawns at the bottom (GB
  y>=192). Any contact hurts; star/ball no effect (row 00 00 FF 00 00 — the
  arrow's class). Port: fall at f174, despawn f325 (GB 175/327).
- **Gao $3F → OBJ_GAO 24** (16x16, $A4/$A5/$B4/$B5; mouth open +2): static;
  137f cycle, fires at tick 89: SFX dff8=$04 + fireball from the muzzle.
  **Fireball $23 → OBJ_FIRE 25** (8x8 $E2): 1px/f horizontal toward Mario,
  0.5px/f vertical toward Mario's side of the muzzle at spawn (both aims
  capture-verified with Mario above AND below). Stomp → **OBJ_GSQ 29** (flat
  pair $B9+$B8, 48f) → thump + **OBJ_GCORP 30** (the statue Y-flipped, 7f hop
  then +2px/f fall, 1px/f drift) — the $40→$41→fall chain. Ball/star/bonk →
  the corpse directly. Score class 2 = 800.
- **KING TOTOMESU $08 → OBJ_BAT 27** — the Birabuto BOSS (user-identified from
  his 800-per... no: from gameplay; first shipped mislabeled "the moai flyer").
  32x24 in THREE rows, 9 tiles/frame (full-window OAM capture): head $CD $CE
  (shared), face CA CB CC BA / AB C6 C7 AA, base DA DB DC / BB D6 D7. Port
  anchors o_y at the HEAD row (spawn oy-8) so the tall erase (o_pvy-8, 2-3
  rows) covers all 24px. Hops at fixed x on a 162f cycle (hold ~80f with a
  ~31f frame toggle, 17px up at 0.5px/f and back), breathes fire at ticks 64
  and 121 (SFX $04). **Fire $1B→$1E → OBJ_BULL 28** (16x8, $C4/$C5 alt $D4/$D5
  every 8f): 1px/f horizontal toward Mario at launch. NOT stompable (head zone
  passes through); star → explosion + 5000; SUPERBALL: 5-hit HP (user-verified
  ~5; o_hp + l3_boss_hit): hits 1-4 chirp + the ball expires, hit 5 = the
  burst (OBJ_BOOM + dff8 $01) + 2000 (GB capture: 800 gao + 2000 = 2800).
  Port-verified: hp 1..4 absorbed, 5th = boom + 002000; hop/shot ticks exact.
- **Hidden-block LIFT $07→$13→$14 → OBJ_GIFT 22** (8x8 tile $E6): block
  content $07 (cols 2 + 150 in 1-3) emerges 4px on top of the block and sits.
  It is a RIDEABLE — the same ride-morph pattern as the stone ($36's contact
  +0 = $37 = "landed-on morph"; $13's +0 = $14): LANDING on it arms the rise,
  and it carries Mario up 0.5px/f ~64px to the level's top row (the secret
  upper corridors at both columns), holds ~229f, then pops with the kill
  thump — the rider falls, NO score. Walk-through from the side; the star
  does not clear it; a block-bonk under it launches it riderless.
  [First shipped as a stomp-bounce — user-caught: "the elevator ascends
  alone". OBJ_GIFT renumbered to 22, adjacent to OBJ_STONE 21, so
  plat_land/plat_xover/ride_support accept the 8px-rideable pair as one
  class. Port-verified: lockstep carry 64px, ~220f hold, pop at f358.]
- **Hidden multi-coin (1-3 col 193 row 8)**: a $5F cell with content $C0 — the
  mc draws-as-brick rule now accepts $5F raw tiles too (read_map_tile).
- **Water shimmer** (GB $d014 / VBlank_AnimateTiles): BG tile $5D's high
  bitplane swaps every 8 frames between the ROM pattern at $3fc4 (per world)
  and the original. Port: l3_water re-blits visible $5D cells (rows 4-6, max 3
  on screen) with a build-time alt tile (water_alt.svt) on the same 8f cadence;
  cells under a drawn sprite skip a tick (sprite-erase safety).
