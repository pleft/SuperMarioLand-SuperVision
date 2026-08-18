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
| `$E0–$EF` | — | set `$FFC8` = low nibble. DECODED ($2676): $FFC8 is a TICK COUNTDOWN, not a mode: each tick (paced by the $FFC9 divider: hi nibble counts to lo nibble) applies the current velocity via the mover ($2879) and DECREMENTS $FFC8; at 0 the next script byte is fetched. With $FFC7 bit1 set, the floor probe ($2BBB) overrides: airborne -> y++ (gravity) and the tick stalls; grounded -> y snaps &$F8. So a script is: [set vel] [run it N ticks] ... e.g. the $0A platform: vel Y=1, 14+15*3 ticks down, F0-flip, 60 up = the exact measured 60px patrol |
| `$F0 nn` | 1 | **direction control** (FULLY decoded 2026-07-25, $2711): bit7 = set Y-dir ($FFC5 bit1) toward Mario (sign of objY-$C201); bit6 = set X-dir (bit0) toward Mario (obj x + (($FFCA&$70)>>2) vs $C202); bits3-2 = XOR-flip the dirs (>>2); bit5 = FORCE Y-dir := bit1 of nn; bit4 = FORCE X-dir := bit0. Pure direction -- never waits |
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
  burst (OBJ_BOOM + dff8 $01) + 5000 (user-verified on GB; an earlier 2000 was
  a wrong decomposition of a capture). Port-verified: hp 1-4 absorbed, 5th =
  boom + 005000; hop/shot ticks exact.
  REFINEMENTS (all user-caught on hardware, a59fced + d7359f9): his 24px body
  needs o_pw bit6 = EXTRA-TALL (+1 erase row; width mask $3F) or rising leaves
  a base-row shadow; the hop-cycle wrap SNAPS o_y to the o_vy base (the bob's
  parity stepping drifted — and note o_vy already stores the ADJUSTED head-row
  base, no extra -8: that bug made him rise 8px/cycle); the breath always goes
  his FACING (left), never aimed behind; only his FRONT half hurts (mario_dx <
  14) — Mario passes over the back/tail like the GB.

## PORT: the 1-3 collapsing bridge (stones $36 over the shaft) [2026-07-17]

Five spawn entries, but the GB shows FOUR: the first rests on the left pillar
top and its sprite's behind-BG priority hides it in the bricks — the port
drops that entry (SKIP_SPAWNS in extract_levels.py; it adds no usable support).
Crossing physics: each stone Mario leaves has begun sinking, so he steps off
below the neighbour's top; plat_land's crossing test carries a **3px slop**
(descent-only) — calibrated three times against the user's GB observations:
RUNNING crosses the bridge, WALKING falls mid-shaft, exactly like the GB.
(6px let walkers cross once the two-point foot probes shifted the handoff
timing.) The two-point probes themselves (grounded + landing test BOTH feet,
+4/+12, after the centre) are the GB's own leniency: Mario stands when his
body is mostly over a ledge — single-centre probing dropped him off pillar
edges his body still covered.
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

## RE CORRECTION: the superball-vs-object system (2026-07-21, disasm-verified)

The old reading of the $3186 contact table ("+1 ball morph, +3 star morph") was
WRONG, discovered when the user proved the pipe flower dies to a superball
(port had it immune). The REAL system, from Call_000_200a / Call_000_2a68:

- **Call_000_200a** (called per live ball right after its move, $1F92): loops
  the 10 slots. Skip if slot byte **+$0A bit7** set (ball-immune flag; low
  bits = the hitbox code fed to the overlap test $0AAF). Ball box = tiny
  **4x3 px** ([x..x+4] x [y..y+3]) — why sim balls whiff so easily.
- **Call_000_2a68** (on overlap): slot byte **+$0C & $3F = HP**. HP>0: DEC,
  and for types **$08/$32** play **$dff0=1** (the hit clink — the mailbox we
  had mislabeled "wave effect, UNHOOKED"); ball expires, no kill. HP==0:
  morph target = **$3186 row +3** (the column we mislabeled "star"): $00 =
  ball passes with NO effect (ret), **$FF = despawn**, else morph to that
  type + Call_000_2cbb (re-init the slot's phys bytes for the new type).
- Slot byte $0C inits from **phys byte2** ($3375): Totomesu $C4 -> HP 4 =
  four absorbed clinks + the killing 5th ball = the user's hardware count,
  EXACTLY. Gao $80 -> HP 0, morph $41 = one-ball corpse. Flower $00 -> HP 0,
  morph $FF = one-ball silent despawn (+100, class 0) — wiki: upward Piranha
  100, downward (W2+) 400.
- The ball engine: spawn $4A0C on **$ff81 & 3 (A OR B pressed)**, gated on
  $ffb5 (the superball FORM flag — $ff99=2 just means BIG); THREE ball slots
  in state $0D (the demo/special mode) vs one in play; data $c000 [y,x,tile,
  attr] (the OAM shadow head), list $ffa9 ($09/$0A = direction+bounce bits),
  lifetime $c0a9=$FF, despawn at y >= $A2; mover $1F2D, tile test $1FD2
  ($F4 coins collect +100 with a popup at the cell, $ffed=$c0).

PORT: flower ball-kill shipped (poking-out gate = o_y < o_vy, silent despawn,
+100 tag at the pipe via award_kill_at); Totomesu hit sound corrected to
SFX_DFF0_01. LESSON (harness): a teleported $c000 ball can miss type-specific
hitbox windows — calibrate against a known-killable type AND treat "no effect"
as unproven until a NATURAL hit reproduces or the code path is read.

## GB ground-support geometry, MEASURED (2026-07-22)

In-room + surface measurements on the real GB (PyBoy; states + world-x
alignment; the pipe-entry state pulse $ffb3=$09 is the in-room detector):

- Right-wall flush stop: c202 = wall_px + 2 (room1 col-19 wall at 152 ->
  c202 154). Port calibration: c202 == port spr_x + 16.
- LEFT-edge walk-off: falls at c202 = platform_start + 13 (measured 45 vs
  start 32) => outer support point ~ c202 - 13 (port: spr_x + 3).
- RIGHT-edge walk-off (surface pit at col 88, stable-ground gated): falls at
  wx = edge + 18 (721 vs last px 703) => inner support point ~ c202 - 17
  (port: spr_x + 1..2).
- => the GB's support is a ~+2/+3 pair (sprite coords), hard against the
  sprite's LEFT side: right-edge hangs ~15px, left hangs ~3px -- the famous
  left-biased SML hitbox. Its wall test is also NARROWER than the port's
  two-row body check (the corner-hole landing at c202 117-124 requires x
  inside our wall-clamped zone).

PORT DECISION: keep probes +6/+8. Adopting +2/+3 verbatim fails the
user-proven corner-hole fall because OUR wall check clamps x at 98 in all
airborne states -- matching the GB exactly here means harmonizing the whole
body geometry (body width, wall spans/rows, probe pair) in one project,
queued for the 128K era. +6/+8 reproduces every OBSERVED GB outcome:
corner-hole drop (port: walking + landing; GB: landing), bowl-shaft descent,
open 1-block holes swallow, full-height-wall slots bridge. Known deviation:
ledge hangs 10px right / 8px left vs the GB's 15/3.

## PORT: W2 Honen $10 + the leaper $24 — DONE, sim-verified [2026-07-29]
Both from their DECODED scripts ($36D1/$37EB) under the validated AI-VM:
- **Honen**: symmetric ~111px leap from the spawn line (UP 52f@2px + 7f@1 +
  3f hang; DOWN mirrored, clamped at the base = o_vy; ~36f rest), x fixed,
  ~15f wing-flap ($42/$43 -> port frames). Class 0 = 100.
- **Leaper**: same arc, x moves at the arc speed toward Mario (the VM drives
  both axes at the script velocity), re-aimed at hop start + dive (script's
  F0 $60/$62), dive plays $dff8=$04 (SFX_DFF8_04). Aims BEFORE the first hop
  (script order) — spawn runs aim_leap. Class 1 = 400.
- Corpses = kit types 33/34 (the kill_flip capture's 23 dy steps + 2px/f off,
  drift 1px/f along Mario's facing; drawn rows-swapped as the flip look).
  Ball kills route ball_hits -> rc_ball_kit (RCODE).
- Tiles: the packer ships a COMPACT 12-tile slice remapped to port ids
  $A4-$AF (leaper A/B quads, honen A/B pairs) — the full GB $A4-$D1 range
  didn't fit bank 3 (pack_banks W2_TILES).
- LESSONS (harness-verified): o_pdr is the ENGINE's was-drawn flag — the
  first leaper cut stored its aim there and ghost-erased map tiles; kit
  spawns must stz o_pdr (fresh slot = nothing to erase); mario_dx scratches
  tmpH2 — w2_foe derives the value code from o_type at award time instead.
- Unit tests (svharness, clean slot table): arc trace exact; homing dive/hop
  aim; stomp -> corpse + 100/400 credited; descending fish hurts; a riser
  under Mario foot-stomps (the GB positional rule, faithful).
- Bank 5 is at 96 bytes free — the next W2 code must earn its bytes.

## FIX: $24 is YURARIN BOO, not a hopper (user-caught) [2026-07-29]
The user: "it just moves vertically and shoots a big ball." Root cause of my
mis-port: the mover ($2879) applies the VELOCITY LOW NIBBLE to X — vel $20 has
X speed 0, so the F0 track-Mario bit only sets FACING. And F1 DOES take an
operand (the child TYPE: InitAccel_24D6 reads $D003) — the decoder's "23
velocity" after F1 is really "spawn type $23" = THE BALL:
- $23 script: param $45 (= single tile $E2, the common fireball — the OAM
  param rows are a BYTE STREAM: bit7-set bytes are tiles, others are
  position/attr flags; NOT strict pairs), F0 $C0 (aim BOTH dir signs at Mario
  once), FFC9=1 (half tick rate), vel $12 -> x 1px/f, y 0.5px/f, ~4s life,
  no gravity, no re-aim (flies past Mario).
- Port: $24 = vertical bob (unchanged arc) + facing-only aim + the shot at
  each dive (SFX_DFF8_04 + OBJ_WBALL=35: sign-aimed, x 1/f + y every other
  frame, hurts on any contact, culls at y<16/y>152 / camera-pass / ~4s).
- pair16/quad16/x_step moved to engine RCODE (banks full; RCRAM had room).
- decoder TODO: mark F1 as 1-operand; re-decode all 28 scripts for other
  F1 children (the fly/boss chains may hide more).
Verified (harness): Boo x constant through full cycles; ball spawns at the
dive from the mouth, correct signs/speeds toward Mario; honen stomp
regression 100 pts intact.

## RE: the $3186 table has TWO ball columns, switched by game state (2026-08-17)

User challenged "the superball can't kill Yurarin Boo" -- the deeper dig
(mgbdis of the collision handlers) settled the column map from the
instruction stream and found a real subtlety:

- **Call_000_2a68** (ball hit, NORMAL play): `type*5 + $3186 + 3` -> morph;
  `$00` = `and a / ret z` = literal no-op, the ball passes. Three `inc hl`,
  read from code.
- **Call_000_2aad** (ball hit, state **$0D**): same structure, FOUR `inc hl`
  -> column **+4**. The caller at $2052 dispatches on `$ffb3 == $0D`.
- **State $0D = the Marine Pop / Sky Pop VEHICLE mode** (docs/14's "likely
  the demo" guess corrected): 3 projectile slots (torpedoes) vs 1 ball,
  projectiles break blocks (gated on $0D -- torpedoes do), and the $0D
  handler's HP-clink specials are $1A/$61/$60 = Tamao + the Dragonzamasu
  chain, the 2-3 underwater cast fought from the submarine. Type $60 hit
  also writes $d007.

Consequences for the W2 cast (row `ff 00 ff 00 27` for $10 Honen / $24
Yurarin Boo -- nearly the only row where +3 != +4):
- On foot the superball does NOT kill Honen/Yurarin Boo (+3=$00). Stomp =
  silent despawn (+0=$FF, user-observed + ROM). Touch hurts (+2=$FF).
- From the submarine (2-3) torpedoes kill them -> corpse $27 (+4). The same
  $27 serves rows $2F/$30; $32 -> $4F.
- Column +1 (Chibibo $11 / Noko $12 / Fly $15 / Gao $41 / Yurarin $19,
  $00 for the fliers) = the block-bonk morph.

## RE: Mario contact geometry, ball motion, platform placement (2026-08-17)

PyBoy sweeps + OAM dumps + the $0aaf disassembly, chasing the user's "seahorse
is stiff" report. Several long-held conventions corrected:

- **$c201 = Mario's Y, $c202 = Mario's X** (OAM-ish space) -- inverted from
  every prior note. (Why "pin $c201" makes pinned-flight fly: it pins HEIGHT.)
  Object slot +2 = Y (bottom-tile OAM y), +3 = X (verified by pinning a slot
  and reading OAM).
- **Hitbox codes (phys byte1, slot +$0A): low nibble = HEIGHT in 8px tiles
  (box extends UP from slot y), high nibble = WIDTH (extends LEFT), bit7 =
  ball-immune.** Resolves the old platform puzzle: $B1 = 24 WIDE x 8 tall.
  Arrow $12 = 8 wide x 16 tall (a vertical dart). Ball $23 = $11 = 8x8.
  Honen $12, Boo/Yurarin/fly/Gao $22 = 16x16.
- **Mario's contact band is TINY** ($08c7 setup + empirical sweep, exact
  match): Y in [c201-2 (big, non-duck; small c201) .. c201+6], X in
  [c202-3 .. c202+2] -- a ~6px-wide strip. Sweep vs the Honen box: hurt
  windows objY-c201 in [-8..+14], objX-c202 in [-10..+2], matching the
  $0aaf math bit-exact.
- **Yurarin Boo's ball: vy = 0.5 px/f FIXED, vx PROPORTIONALLY AIMED** (axis
  labels corrected after the user caught the port ball feeling slow: the
  capture's columns were slot +2/+3 = Y/X): every shot is a straight line to
  Mario's launch position; horizontal closing speed up to ~2 px/f. Fire
  interval = 162 frames, metronome-constant. Lifetime = until offscreen.
- **Platform placement was 16px too low in the port** (2-1 slot capture: end
  V-platforms patrol screen 64..124; the port's spawn +16 rode them 80..140
  -- top short of the barrel jump, bottom inside the floor, user-reported).
  spawn_plat now uses the bin y directly (drawn = GBslotY-16); this also
  moves the W1 platforms to the 1-1 trace's exact 56..116.

PORT: rc_wball_aim/rc_wball_move (RCODE Bresenham: dx/dy pair-scaled, slope
cap 4, x steps on alternate frames), wball_box = the GB-exact tiny band
(X centre-dist < 7, o_y - spr_y in [-10..+6]), spawn_plat offset fix.

## PORT: MEKABON $16 (2-2) -- fully GB-captured (2026-08-17)

USER CORRECTION: $16 is MEKABON (the head-throwing robot; mariowiki/Mekabon),
not "Yurarin" as an old memory note claimed -- the user recognized the sprite.
The real Yurarin (seahorse) is presumably a 2-3 type, id TBD.

Cycle (capture): WALKS 1px/3f at constant height facing Mario ~120f (16x16
quad GB C4-C7/D4-D7, arm flap), then THROWS ITS HEAD and stands HEADLESS
~120f ($18; body = the D6/D7 pair alone), re-faces, repeats. THE HEAD IS A
BOOMERANG (second capture, Mario near): rises 38px at 1px/f, glides out
0.5px/f to ~+40px along the throw, then returns 1px/f while descending
1px/2f -- lands back on the neck at exactly t=120 as the body regrows.
$3186[$17] and [$18] all $FF: touch hurts; stomp/ball/star pop the head or
the headless body SILENTLY (+100). The WALKING body's row 1c/19/ff/19/19:
stomp -> $1C squash (D8/D9, HARMLESS, ~93f static) -> $19 (1f) -> $0D = the
kill_flip dead-fall (squash tiles Y-FLIPPED attr $40, the 23-delta hop with
ALL +23px away-drift during the arc, then 2px/f off-screen, 63f). Ball AND
star -> the same corpse chain: Mekabon IS superball-killable (+3=$19),
handled KIT-side (mek_ballhit inside the phase contact procs; zero engine
bytes).

Build: 2-2 gets its OWN blob variant (w2code22.bin, -D YUR22) + a per-level
tile slice (port $B0-$B9 = GB C4,C5,D4,D5,C6,C7,D6,D7,D8,D9) -- bank 3 can't
fit what only 2-2 uses; bank 4 lands at 4 bytes free. draw_leap's quad loop
became the shared draw_16q. Sim-verified vs both captures: walk/throw/hold/
resume + the head's 120f out-and-back landing on the neck.

## 2-3 MARINE POP -- GB State $0D + the whole level (2026-08-18, PyBoy + RE)
- **State $0D** = the vehicle gameplay state ($2376). Frame: LevelColumnStream,
  bank1 $4fb2 (autoscroll: cam +1 per 2f until c0d2>=7 = the tail columns
  streamed, i.e. cam_max 2720; the crush-dec pushes the sub left when a solid
  sits at (c201+5 row, c202+8); c202 forced $F0 at 0 -> $515e = forced-small
  death), $4fec (dpad: UP/DOWN 1px/f fall through into the horizontal = true
  diagonals; LEFT decs twice while the scroll runs; clamps c202 [16,160],
  c201 [48,148]), $5118 (torpedoes), bank3 $498b/$4a1a (fire: A or B pressed
  fires, held A autofires per c0ae=12; spawn OAM (c201-2, c202+2) tile $7A),
  $200a sweep -> $2aad: slot+$0C = HP (&$3F) decs with a clink (dff0=1 only
  for $1a/$61/$60) while nonzero; at 0 the $3186 col+4 morph applies.
- **Screen rows**: the GB playfield = BG rows 2-17; LEVEL row = screen row - 2.
  (An 8-hour detour: the live-scraped map "contradicted" the extractor until
  this offset surfaced. The extractor was right all along.)
- **The probes** ($50cc H / $5046 up / $5089 down): H at y+5 (+ y-3 when big),
  up at y-3/-4 two corners (+2/-4), down at y+10 two corners (-2/+2). $F4
  collects in passing (NOT from torpedoes in $0D), $E1/$83 -> jp $1b45.
- **$1b45 IS THE LEVEL CLEAR, not a hurt**: clear jingle = track $01, state
  $07 -> tally -> next level. Tile $E1 = THE SPHERE (2-3: col 357 row 9,
  behind a 2x3 brick wall + over-spike... no: over nothing -- the spike
  reading was wrong all along). d007 = the boss-kill auto-clear flag ($60
  Tatanga sets it; State_0D then fires 1b45; it also gates the $09f1 death
  -- the game's own god-mode during the 4-3 ending).
- **2-3 types** ($3186 stomp/bonk/touch/ball/torp + $3375 phys + scripts):
  $1D Torion 00/00/FF/00/27 hp$41: swims left 2px/3f, y-dir aimed once (400).
  $20 Gunion FF/00/FF/21/21 hp$82: bobs in place; killed -> $21 rises and
  spawns two $22 halves (level flight left 1px/f) then puffs (800).
  $2F Yurarin 00/00/FF/27/27: paces the scroll (+0.5px/f world), spits a $30
  every ~30-48f, the 3rd spit morphs it into $30 too (the school!). $30 =
  straight left 1px/f. Both draw params $2C/$2E (same look!).
  $48 TAMAO 00/00/FF/00/00 hp$FF phys$54: invincible 0.5px/f diagonal
  bouncer (torpedoes absorbed silently forever).
  $1A DRAGONZAMASU 00/00/FF/00/4F hp$D3 hitbox$24 (16 wide x 32 TALL),
  params $4F/$4E = 8-tile stacks: right-edge vertical patrol ~0.5px/f,
  spits $1F (rises ~2px/f ~16f, from FFC1 $70/$70/$40) -> morphs $58
  (level left 1px/f) every ~64f alternating slots. 19 clinks + the 20th
  kills: +5000 (class 3) AND the arena clears (Tamao + in-flight shots
  puff -- capture-observed).
- **The sub** = 16x16 OAM quad tiles $70-$73 (8x8 mode! LCDC $C3), constant
  (no propeller tile anim; big/small identical). Torpedo = tile $7A 8x8.
  Boss shots/halves = the $E2/$E3 blob pair.
- **PORT** (commit 1db1780): engine player_step + veh_vec dispatch; the level-5
  kit = kit_mar23.inc in three pieces (window $1500 <= $7D0 stored in BANK 6
  $B000 + the w2stub bank-crossing loader + W2FAR bank-resident at $A268) --
  bank5 has 0 bytes free (the 5.7K raw map). Cut for bytes: gunion/yura/
  tamao/dragon flap frames, the x-3 rescue scene (standard tally; wraps to
  1-1 until W3 exists).
