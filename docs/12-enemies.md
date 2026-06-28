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

## Type tables (indexed by `$FFC0` object type, ~28 types `$00–$1B`)
- **`AIScriptPtrTable` @ `$349E`** — per-type pointer to a **movement-script** (below).
- **`PhysicsParamTable` @ `$3375`** — per-type 2 bytes: `[accel, param]` loaded into the
  ballistic engine (`$FFC7` etc.). Same engine as `ObjectPhysics_Integrate` ($2975).

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
