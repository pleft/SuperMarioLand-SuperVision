# Player (Mario) Physics & State (Task #4)

All [FACT] are verified against bytes (line refs into `disasm/`). [INFERRED]/[OPEN]
flagged. 1-1 port requires these constants exact.

## Player struct — base `$C200`
| Addr | Meaning | Conf | Evidence |
|------|---------|------|----------|
| $C200 | sprite attr / visibility+flip (xor $80 = invincibility flash; $80=hidden) | High | bank_000:~6012; bank_003 OAM |
| **$C201** | **Y position** (vertical) | **FACT** | scroll math uses $ffa4 on $C202 not $C201 (bank_000 `Call_000_1aad`); descent `inc[hl]`×3 here |
| **$C202** | **X position** (horizontal) | **FACT** | gets scroll `$FFA4` added (`Call_000_1aad`); OAM-X in State_03 |
| $C203 | walk anim (low nibble frame 0–8) + facing/speed (high nibble); $18 = special (duck) | High | $1D26; jump pose `or $04` bank_003:49E? |
| $C204 | cleared on cleanup; $80 on pipe-entry | Low | writes only |
| $C205 | sprite orientation flags (bit5 → OAM offset $F8/$02) | Med | bank_003:~2425 |
| $C206 | UNKNOWN | — | |
| **$C207** | **vertical state: 0=grounded/falling, 1=ascending, 2=blocked/bonk** | **FACT** | jump gate==0; ascend==1; bonk sets 2 |
| $C208 | jump hold-counter (set $0F / $02; paired w/ C209) | Med | bank_003 jr_003_4966 |
| $C209 | jump hold-counter partner | Med | bank_003:~2149 |
| **$C20A** | **on-ground flag (1=grounded, 0=airborne)** | **FACT** | jump gate (must be ≠0); cleared on fall; set on land |
| $C20B | animation/pose counter (inc/dec each frame) | High | $1D26 |
| **$C20C** | dual: **horizontal accel counter 0..6** (grounded) / **jump-force seed** ($30 jump, $20 down) | **FACT** | $1D26 accel; bank_003:49ED `ld [hl],$30` |
| $C20D | horiz sub-state/direction ($01/$10/$20) | High | $1D26 |
| $C20E | horizontal speed-table index (0/2/4…); set to 2 on jump | High | `Call_000_1EB4` |
| $C20F | horizontal speed-table toggle (`xor 1`, sub-pixel) | High | `Call_000_1EB4` |

## Horizontal movement — `Player_HorizControl` @ `$1D26` (bank 0) [FACT]
- Reads held buttons `$FF80`: bit4=Right, bit5=Left, bit7=Down(duck).
- Acceleration counter `$C20C` increments 0→6 while a direction is held (capped 6);
  decrements when released (deceleration / skid).
- Speed magnitude comes from **`Player_SpeedTable` @ `$1ECE`** via `Call_000_1EB4`,
  indexed by `$C20E` with a sub-pixel alternation toggle `$C20F` (xor 1) → fractional
  speeds. (Extract the exact table bytes during data-extraction; it defines run speed.)
- Down (`bit7`) while grounded+big → duck (`$C203=$18`).

## Jump trigger — `Bank3_JumpControl_498B` @ `03:498B` [FACT]
Gates (all required to start a jump):
- A button held (`$FF80` bit0) AND freshly pressed (`$FF81` bit0)  [edge-triggered]
- `$C207 == 0` (not already airborne)
- `$C20A != 0` (on ground)

On jump start:
- `$C20A = 0` (leave ground)
- `$C203` low nibble `= 4` (jump pose; preserves facing high nibble)
- `$C20E = 2`, `$C208 = 2`
- **`$C20C = $30`** (jump-force seed)  — `bank_003` `jr_003_49ED: ld [hl],$30`
- `$C207 = 1` (ascending)
- launch horizontal speed index chosen from run accumulation `$C20C` (`cp $03` → 2 vs 4)
- Down press uses a different force seed `$C20C = $20` (`Jump_003_4A77`).

## Descent / gravity — `Player_FloorCheck` @ `$17BC` (bank 0) [FACT]
Runs each frame when `$C207 != 1`. When airborne with no solid tile under the feet:
- **`$C201 += 3` per frame** (`bank_000:4637-39`, three `inc [hl]`), then `$C20A = 0`.
- **Constant velocity: there is NO acceleration and NO terminal-velocity clamp** in the
  descent path. Fall speed is a flat 3 px/frame.

## Landing — `Player_LandSnap` @ `$185D` (bank 0) [FACT]
On landing on a solid tile: align `$C201` to a tile boundary (`dec;dec;and $FC;or $06`),
set `$C207 = 0`, `$C20A = 1`.

## Run rule — `Player_FloorCheck` $17EC [FACT, 2026-07-24]
The floor check probes TWO points: x-2 and x-2+b. b = 4 normally; **b = 8 when
`$C20E` (speed index) == 4 (full run) AND `$C207` == 0 (grounded)**. An 8px
probe spread cannot fit inside a 1-tile hole, so RUNNING BRIDGES 1-block holes
deterministically while walking falls in (GB-measured on 2-2's comb, cols
26-32: walk falls in the first gap, run crosses flat at y=110).
Port: the second walk-support probe widens +8 -> +14 when h_idx==4 (grounded
path only; landing/airborne probes unchanged).

## One-way platforms — `Call_000_1A6B` + per-world lists @ `$1A93` [FACT, 2026-07-24]
The CEILING check ($198C) and the WALL check (the $1AC5 horizontal probe) both
pass any tile found in the current world's list at `$1A93` (FD-terminated):
W1: 68 69 6A 7C (1-2 tree platforms), W2: 60 61 63 7C (Muda caps + GROUND),
W3/W4: 7C. The floor check does NOT consult the list -> solid from above only.
Port: the extractor REMAPS these ids above the coin ($F9-$FF; pixels planted in
the hi charset's free slots -- $F6-$F8 are the coin spin), so the raw threshold
checks do the work: ceiling passes >=$F4, wall_solid passes >=$F4, read_solid
keeps >=$60 standable. The superball bounces off caps on the GB too (its $1FD2
check has no list) -- port matches.

## Ceiling / head-bonk — `Player_CeilingCheck` @ `$198C` (bank 0) [FACT]
Runs each frame when `$C207 == 1`. Reads tiles above Mario (offsets via `$FFAD/$FFAE`);
on special tiles ($5F/$60/$80/$81/$82/$F4) handles block-hit/coin/pipe; on a solid
ceiling sets `$C207 = 2` (bonk → start falling). It does collision only — **not** the
upward movement itself.

## Top-level per-frame player update order [FACT]
Dispatched from `State_00_handler` ($0644 area). Order:
`map/col load → enemy-vs-player → sprite build (bank3 $48FC/$490D×5/$4A94/$498B/$4AEA)
→ $1F2D → enemy update → CeilingCheck($198C, if ascending) → anim+HorizControl($16F5→$1D26)
→ FloorCheck($17BC, descent) → platform landing($0AEA) → $0A2D → invinc-flash($1F03)`.

## ✅ SOLVED — jump/gravity arc (`Bank3_ApplyGravityArc` $490D + `JumpArcTable` $216D)
Resolved by **dynamic trace** (SameBoy watchpoint `watch $c201 if new < old` → broke at
PC `$4928`, `BC=$C201`, `HL=$216F`), then confirmed against the static table.

**How it works.** `$490D` is a **generic ballistic axis-mover**. The caller passes
`BC = object+8` (the velocity-table *index* field) and `HL = $216D` (the arc table),
then the routine walks `BC` down to `object+7` (state) and `object+1` (Y). It is
called each frame for Mario (`BC=$C208`) and 4 objects (`$C218/$C228/$C238/$C248`).

Per frame, using the object's index field and `state`:
- **state 0** → return (no table move; free-fall handled by FloorCheck `+3`).
- **state 1 (ascending)** → `Y -= JumpArcTable[idx]`; `idx++`.
- **state 2 (descending)** → `Y += JumpArcTable[idx]`; `idx--` (walks the table backwards).
- table entry **`$7F` = apex** → switch state 1→2; `idx=$FF` (underflow) → land/terminal.

**For Mario:** `$C208` = arc index (jump sets it to 2), `$C207` = state, `$C201` = Y.

### JumpArcTable @ `$216D` (27 bytes; per-frame |dY|) — EXACT
```
idx:  0  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 | 26
|dY|: 4  4  3  3  2  2  2  2  2  2  2  2  2  1  1  1  1  1  1  1  0  1  0  1  0  0 | 7F
```
- Rise begins at idx 2 (vel 3) and **decelerates** (3→2→1→0) to the apex marker.
- Fall re-reads the table **backwards**, so it **accelerates** symmetrically (max 4),
  then idx underflows → constant `+3` free-fall (FloorCheck) takes over.
- **Variable jump height**: the `$C208/$C209` hold-counters (A held) control how far the
  index advances before release — releasing A early jumps the index ahead, cutting the
  rise short. (Indices 0–1 = vel 4 are reachable for a higher/running jump start.)
- Trace confirmation: broke at idx 2, vel 3, Y `$86→$83` (−3). Exact match.

### Two distinct fall behaviors (now reconciled)
- **Jump fall** = table-driven (state 2, accelerates to 4) — the arc above.
- **Walk-off-ledge fall** = constant `+3`/frame (FloorCheck `$1801`, state 0).

### Methodology lesson
`$490D` reads/writes its target only through `BC`/`HL` passed by the caller — it never
names `$C2xx` literally, so a pure static scan for "`$C201` writes" missed it. **When a
routine moves data through caller-supplied pointers, a dynamic watchpoint (capturing the
pointer register) is the right tool.** Recorded so we reach for it sooner next time.

---
### Appendix — disproven static hypotheses (kept so we don't repeat them)

**Disproven:**
- ❌ "Rise is in bank-3 `$490C–$495B`." Hand-disassembled from raw bytes (`$48FC`
  ends `ret` at `$490C`; `$490D` is a clean pointer/collision helper using `BC`/`HL`
  with **no `$C2xx` access at all**). ⚠ CORRECTION: this region WAS the ascent — it
  moves Y through caller-supplied `BC`/`HL` pointers, which a literal `$C2xx` scan
  cannot see. The dynamic trace caught `BC=$C201`. See the SOLVED section above.
- ❌ `$C20C` (jump-force `$30`) is a velocity applied to `$C201`. Grepped all banks:
  `$C20C` is only set/compared, never added to `$C201`. It gates horizontal speed
  during the jump, not vertical position.
- ❌ Bank-3 `$498B`/`$48FC`/`$4A94`/`$4AEA` move `$C201`. `$498B` only touches the
  `$C208/$C209` hold-counters; `$4A94` is the attract **demo player** (replays inputs
  into `$FF80/81`); `$4AEA` handles the `$C210` bonus-object array.

**Established (exhaustive `$C201`-write census, all banks):** the ONLY code paths
that *decrease* `$C201` are:
1. `State_30_handler` ($12C2) — a **scripted cutscene** ("Mario rises" every other
   frame until `Y==$58"). Not gameplay jump.
2. `ObjectPhysics_Integrate` ($2975) — the **enemy/ridden-platform** ballistic engine
   (`$FFC1`=velocity, `$FFC7`=accel from table `$3375`, accumulator `$FFC2`); it also
   moves `$C201` only when `$FFCB`≠0 (Mario riding/standing on that object). `$FFCB`
   is only ever *cleared* in the paths read, so this does not drive normal jumps.

**Conclusion (now resolved):** the jump-rise wasn't a *literal* `$C201` write — it goes
through caller-supplied pointers in `$490D`. The dynamic trace revealed this; see the
**SOLVED** section above for the exact table/constants. (The State_30 cutscene and the
`$2975` object engine remain separate, correctly-identified Y movers.)

### Useful by-product (feeds task #6 enemies)
`PhysicsParamTable_3375` + `ObjectPhysics_Integrate` ($2975) is the generic
**object ballistic physics** (velocity `$FFC1` + gravity-accel `$FFC7` from the
2-byte-per-type table at `$3375`, sub-pixel accumulator `$FFC2`). Documented here
because it was found while chasing the jump; it is the enemies' movement engine.

## Port implications
- All constants above (speed table $1ECE, jump force $30, descent +3, hold-counters)
  must be reproduced exactly on the 65C02. Positions are whole-pixel for vertical;
  horizontal uses a sub-pixel toggle. No floating point — straightforward to port.

## Horizontal movement: the FULL state machine (RE'd 2026-07-10, capture-verified)

`Player_HorizControl` ($1D1E) + the walk-anim advance ($1701) + the B-rule
(bank 3 $4975). Four state variables:

| var | meaning |
|-----|---------|
| `$C20C` | momentum: +1 per held frame (skip when ==6, $1DD8), −1 per neutral frame; also reused as the 8-frame brake timer |
| `$C20D` | last motion direction: $10 right, $20 left, $01 = braking, 0 = none. Survives neutral frames until `$C20C` hits 0 ($1D6B) |
| `$C20E` | speed index into `Player_SpeedTable` ($1ECE, +`$C20F` sub-pixel toggle, $1EB4): 0 slow (0.5 px/f), 2 walk (1), 4 run (1.5). PERSISTENT state |
| `$C20B` | walk-anim tick; pose advances when moving and `($C20B & 3)==0` |

Per-frame flow (order matters):
1. **Brake state** (`$C20D==1`): decrement `$C20C`; input is IGNORED and Mario is
   frozen. At 0: `$C20D=0`, pose→stand, `$C20B=1`, `$C20E=0` ($1D71).
2. **Accel bump** ($1D3A): `$C20C==6 && $C20E==0` → `$C20E=2`. Runs mid-air too
   (capture T2: air ramp 0.5 px/f for 6 frames, then 1 px/f).
3. **B rule** (bank 3 $4975): B held + grounded → `$C20E = ($C20C<3) ? 2 : 4`;
   B not held → a 4 decays to 2 (NOT grounded-gated: releasing B mid-air slows a
   run-jump). Run-jumps carry 4 into the air because nothing updates it airborne.
4. **Duck** ($1D87→$1DA6): big+grounded+Down → duck, clears `$C20C` only.
5. **Direction held**: if `$C20D` = the opposite → **skid** ($1E48): `$C20D=1`,
   `$C20C=8`, pose = **metasprite 5** if grounded (old facing kept — `$C205`
   untouched). Else: facing set, `$C20C` inc (skip when ==6), `$C20D` stored, move
   at `$C20E`.
6. **Neutral**: `$C20E=0` every frame ($1D5E), `$C20C`−−, then RE-DISPATCH with
   `$C20D` as input but the REAL pad re-read inside skips the inc/store paths →
   **Mario glides on at idx 0** until `$C20C`=0 (≈3 px walk-off slide; same in air,
   x freezes when it runs out). The walk anim cycles through the last glide frame
   and stands the frame `$C20D` clears.

Walk cycle ($1701): pose `$C203` low nibble cycles metasprites **1→2→3** every 4
moving frames (`inc`, wrap at 4 back to 1). Metasprite tile map (bank 3 $4C37):
stand 0, walk 1/2/3, jump 4, **skid 5** (tiles $0A/$0B/$1A/$1B; big set = +16,
big skid = 21). The skid is a DISTINCT lean sprite — an earlier port shipped
"walkB with new facing", which is a frame the walk cycle already shows (invisible).

**Capture-refuted disasm reading:** bank 3's jump path that sets `$C20C=$30` and
floors `$C20E` to 2 ($49ED) does NOT run in normal gameplay — a standing jump has
`$C20C=0` and ramps from idx 0 in air (PyBoy capture). Never port a disasm-only
conclusion without a capture.

Port (src/main.s): `move_t`/`mdir`/`h_idx`/`walk_t`+`walk_i` mirror the four vars;
`skid_t` = the brake timer; `calc_step` = speedtab[h_idx+toggle] verbatim. Verified
frame-by-frame vs PyBoy: walk release +3px/6f, tap +1px/3f, B 2→4 at momentum 3,
air ramp + bump at 6, air-release drift, 8-frame skid at dpad-roll gaps 0–6, none
at 7+. Capture pitfalls hit: the first pipe wall pins x at 81; the first goomba
kills a >100-frame rightward run — fresh boot per trial.

**Neutral with NO remembered direction drains `$c20c` in ONE frame (2026-09-06).**
The $1D52 neutral path is `dec $c20c; re-dispatch with $c20d as the pad`; when
`$c20d` is 0 the re-dispatch has no direction bit set and lands in the same
neutral path again, so the loop runs until `$c20c` is 0 within the frame.
Capture (1-1, per-frame `$c20c`): standing jump -> `30` on the jump frame, `00`
the next; RIGHT pressed mid-air then ramps `01..06` and bumps `$c20e` to 2 on
the 7th frame -- the same 6-frame ramp as on the ground. The port's neutral
path decayed the seed one per frame (`$2F, $2E, ...`) so the bump never came
before landing: 0.5 px/f for the whole fall after a standing jump or a
walk-off (4-2 shaft, user report). `move_player` now clears `move_t` when
`mdir` is 0. Known residual: the GB's first slow step is on the press frame
(sub-pixel toggle starts on 1), the port's on the frame after -- the ramp is
1 px behind throughout. Also known: the GB's ceiling probe is two points
(Player_CeilingCheck: `$ffae = scroll + $c202 + 2`, then `-4`; OAM x 43 for
`$c202` 50 puts them at visual-left +9 and +5), the port probes the centre once.

## ✅ The RUN jump is 41px, the walk jump 33 (ported 2026-08-28)

The line above -- "indices 0-1 = vel 4 are reachable for a higher/running jump
start" -- was never ported: `@startjump` seeded `arc_idx = 2` unconditionally,
so **every** port jump was the walk jump. GB-measured (PyBoy, 1-1, A held 34f):

    walk (R+A)   $c20e=2  $c208 seeded 2   y 134 -> 101   rise 33px
    run  (R+B+A) $c20e=4  $c208 stays 0    y 134 ->  93   rise 41px

The mechanism is in `Bank3_JumpControl_498B` ($49BF..): at the jump start

    ld a,[$c20e] / cp $04 / jr z,$49ED      ; RUNNING: skip BOTH writes
    ld a,$02 / ld [$c20e],a / ld [$c208],a  ; walking: speed AND arc index = 2

`$c208` is the JumpArcTable index and it is 0 while grounded, so a run jump
starts on the table's two `04` entries -- exactly the 8px difference
(`jumparc` sums: from 0 = 41, from 2 = 33).

Port: `@startjump` now does `lda h_idx / cmp #4 / beq :+ / lda #2 / sta h_idx
/ : / and #$02 / sta arc_idx` -- `h_idx AND 2` is 0 for the run and 2 for the
walk, so the rule costs the same bytes as the old one (FIXED had none spare).

Verified after the change: walk rise 33 (GB 33), run rise 41 (GB 41), arcs
frame-matched. Gates: battery31 10/10 (its room prefix had to be re-recorded --
E23 -- and now lives in `docs/routes/roomscript_31.txt` so a fresh scratch dir
cannot silently skip those two tests), svgold 9/9 unchanged (its `R900` run
never jumps).
