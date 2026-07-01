# Blocks & Coins, Power-ups / Big Mario, Dynamic HUD (Phase 5 tasks #2/#4/#3)

Ported from RE of bank 0 (`Player_CeilingCheck`, `Call_000_0166` score, `VBlank_UpdateDisp_DA00/DA15`)
and the bank-3 metasprite table `$4C37`. Implemented in `src/main.s`; data via
`tools/extract_tables.py`.

## Tile semantics (World 1-1, verified from the extracted level map)
### ?-block contents come from a TABLE, not the tile value [CORRECTED]
The tile value (`$80`/`$81`) does **not** decide coin-vs-mushroom. During level decode
`Call_000_2321` looks each special tile up in a per-level table (**bank3 `$6536`**, 3-byte
`[segment, col-in-seg, value]` entries) and stores the content `value`. Blocks NOT listed hold
a single **coin**. World 1-1 lists 5: cols 22 & 95 = `$28` **Super Mushroom**; cols 83/174/259
= `$2a`/`$2c`/`$c0` (star / superball / multi-coin). (Columns are −20 vs the pre-2026-06-30
values, after the seg-3 play-start fix in `docs/10`.) Extracted to `level_NN_blocks.bin`
(`decode_blocks`), looked up at hit time by `find_block (col,row)`.

| Hit tile | Content (table) | Reaction (head-bonk from below) |
|----------|-----------------|---------------------------------|
| `$80`/`$81` | unlisted | **launch a coin** (coin-pop entity) + `+1` coin + `+100` score |
| `$80`/`$81` | `$28` | **spawn a Super Mushroom entity** (slides out, Mario walks into it → big) |
| `$80`/`$81` | `$2a`/`$2c`/`$c0` | spawn mushroom (placeholder — real star/superball/multi-coin = TODO) |
| `$82` | brick | big Mario → smash (blank `$2C`, +50); small → just bonk |

Solidity rule is unchanged (`tile >= $60`). A used `?`-block stays solid (`$7F`); a smashed
brick becomes passable. The used-tile transform is now applied in **read_map_tile, draw_column
AND restore_bg**, so a bumped block stays a used block even when Mario walks over it or it is
re-streamed (earlier it reverted to `?`).

## Object engine (mushroom / coin-pop entities)
A minimal SoA slot system (`OBJ_MAX=4`) in `src/main.s`: `update_objects` (physics each frame),
`erase_objects`+`draw_objects` (repaint bg at the old spot — shifted with the DMA scroll like
Mario — then draw at the new spot). World-X coordinates convert to VRAM-X via
`o_x - cam_x + scroll_s` (same mapping as Mario's `mario_vx`).
- **Mushroom** — physics RE'd from the real object engine (type `$28`): PhysicsParam table
  `$3375` (3 bytes/type, `type*3`) entry `24 11 00` → `$ffc7=$24`, and `$24 & $0c = $04` =
  **reverse direction on a horizontal wall hit**. AI script `$349E[$28]` @ `$387F` =
  `F4 01 F8 16 F0 31 70 11 E5 01 11 01…`: `70` = velocity hi-nibble 7 (the upward **pop** out
  of the block), settling to `$01`/`$11` = **X speed 1 px/frame**. The integrator
  (`ObjectPhysics_Integrate $2975` + horizontal `$2879`): velocity hi-nibble=Y speed,
  lo-nibble=X speed; `$ffc5` bit0/1 = X/Y direction; on a wall, `$ffc7 & $0c == $04` reverses.
  Port (`upd_mush`): emerge = rise up ~12 px (pure-up, matching the script's `$70`-then-`$01`),
  then walk 1 px/frame, **reverse at walls** (check the tile ahead at the body row), fall under
  gravity (cap 3) onto the floor. Mario overlap (`|dx|<14`,`|dy|<16`) → grow big (`+1000`).
  Consuming it — not the block hit — is what makes Super Mario. (Full script VM + integrator
  port deferred to the enemies task; this replicates type `$28`'s behaviour faithfully.)
- **Coin-pop**: launches up (`vy=-6`) + gravity, lives ~24 frames, cosmetic (coin/score are
  awarded on the hit). Drawn with the real BG coin tile `$5F`.
- Objects are cleared on death and on every pipe transition.
- **Mushroom sprite = OBJ tile `$83`** (single 8×8). Confirmed via a SameBoy OAM+VRAM dump of
  the real game: with a mushroom on screen, the only non-Mario sprite is tile `$83`, and it's
  already present (byte-identical) in `w1_obj_8000.svt` — it was never dynamically loaded, I'd
  just had the wrong index. Drawn at the feet line (`o_y + 8`) since `o_y` uses Mario's 16px
  convention. (SML sprites are 8×8 mode; LCDC `$C3`.)

### Modified-tile bitmap
The level map is in ROM (read-only), so block state lives in a 640-byte RAM bitmap
`tile_mod` (1 bit per surface `(col,row)`, index `col*16+row`). `read_map_tile` applies the
transform on the surface only (`room_mode==0`): a set bit turns `$80/$81 → $7F` and
`$82 → $2C`. So both collision and the on-screen redraw see the post-hit tile, and a block
can't be re-bumped. The bitmap is cleared on level restart (`clear_tile_mod`). It is NOT
persisted across a full re-render after a pipe trip back to the same spot (minor;
blocks bumped before entering a pipe re-appear as `?` on return — TODO).

## Big ("Super") Mario
SML big Mario is a **16×16 pose swap**, not a taller metasprite: the big poses fill the full
cell (small Mario only fills ~12px), drawn at the same feet position so he visually grows
**upward**. Big poses = bank-3 metasprite indices `[16,19,17,20,22]` (stand, walkA, walkB,
jump, duck), the `+$20` tile-offset parallel of the small set `[0,3,1,4]`. Extracted to
`build/data/mario_big_poses.bin`.

- **Grow**: bumping an item block (`$80`) grows small→big directly. (Faithful SML pops a
  mushroom *object* Mario then walks into; the object engine isn't ported yet — TODO once
  enemies land.)
- **Brick break**: only big Mario smashes `$82`.
- **Duck**: big Mario, grounded, holding **Down** → duck pose, no horizontal move (small
  Mario never ducks — authentic, confirmed by the user).
- **Shrink on damage**: deferred (needs enemy contact). Death (pit) resets to small.
- Head-bonk collision row is unchanged (small-Mario calibration); jump height is identical
  so the reachable block is the same.

## Dynamic HUD
Status bar template (`bank0 $3F9C`) renders once with blank placeholders; `draw_hud` pokes
live digit tiles over it (font maps digit value → tile number directly: `'0'`=`$00`).
Layout reverse-engineered from the GB BG-map writes:

| Field | Source (SML) | HUD cells |
|-------|--------------|-----------|
| score | `score` ← `$c0a0` (3-byte BCD) | row 1, cols 0–5 (`$9820`) |
| **lives** | `lives` ← `$da15` (BCD) | row 0, cols 6–7 (`$9806/7`), after the Mario-head icon |
| **coins** | `coins` ← `$fffa` (BCD) | row 1, cols 9–10 (`$9829/a`), after the coin icon |
| time  | `timer`/`timer+1` BCD ← `$da01/2` | row 1, cols 17–19 (`$9831–33`) |

**Lives vs coins (corrected after first cut):** I initially put coins in the lives slot.
`$da15` is **lives** (decrement to 0 → game over; +1 only on a 1-up); `$fffa` is **coins**.
A coin (`?`-block or pickup) gives **+1 coin and +100 score** (`Call_000_1bff`); the **100th
coin** rolls the counter to 00 and grants a **1-up** (+1 life). Lives never increase from a
plain `?`-block — only a 1-up (100 coins, or a heart power-up once objects land). Start = 2
spare lives; a pit death costs one (`lose_life`; game-over at 0 = TODO).

The raster split renders HUD rows 0–15 at `XSCROLL=0`, so digits stay pinned. `draw_hud`
runs when `hud_dirty` is set (a value changed, or after a transition re-stamps the template).
The clock counts down (`tick_timer`, `TIMER_RATE`=40 frames/unit = SML's `$da00` reload `$28`,
starts at 400) and clamps at 000 (time-up death = TODO). All counters use 65C02 decimal mode (`sed`/`cld`); the ISRs do
no ADC/SBC, so the BCD blocks are interrupt-safe.

## Big Mario: grow animation + duck sprite [added 2026-06-30 — trace-verified]
**Grow (small→big).** Triggered when small Mario eats a `$28` mushroom (`jr_000_09ba`:
`$ff99=1` growing, `$ffa6=$50`=80 timer; states `$ff99` 0=small/1=growing/2=big/3=star). The
grow is an **80-frame FROZEN animation** — `tools/trace_grow.lua` shows Mario's `y` constant
the whole time and his sprite **alternating big↔small every 4 frames: big when `$ffa6 & $04`,
small otherwise**, then settling big when the timer hits 0 (`$ff99` 1→2). Port: a `mario_grow`
timer (80→0) freezes the main loop (skips movement/objects/clock/scroll, just counts down +
redraws); `draw_player` picks the big tileset on `(mario_grow & $04)`, small otherwise; sets
`mario_big` at 0. Reset on death.

**Duck sprite.** Big-Mario crouch = metasprite **idx 24** (`$40-$43`), verified by rendering
the table vs the original. (An earlier guess of idx 22 / `$2C,$2D,$3C,$3D` rendered as garbage.)
`extract_tables.py:BIG_POSE_INDICES = [16,19,17,20,24]` (stand,walkA,walkB,jump,duck).

## Power-up size branch + Superball Flower [added 2026-07-01 — trace-verified]
A power-up block spawns **mushroom if Mario is small, Superball Flower (`$2D`) if he is already
big** (`Jump_000_1888`; the port checks `mario_big` at `hit_qblock`). The flower **item** RE'd
from `tools/trace_flower.lua`: object type `$2D` morphs to `$2E`; physics params `00 11 00` —
byte0 `$00` = **no gravity, no wall-collision**, so it never moves. It **rises ~7px out of the
block over ~20 frames** while flashing, then **sits animating in place**, cycling two frames
(`$1A`/`$1B`) every ~8 frames. Its tiles are **`$E0`/`$E5`**, already in the obj set at
`$4E32`/`$4E82` (they SV-decode as the flower; an earlier GB-planar mis-decode made them look
like garbage). Port: `OBJ_FLOWER` (spawn_flower/upd_flower), draw flashes `$E0`↔`$E5`. Object
Y vs map Y: a map tile row `r` renders at `dy=(r+2)*8` but an object at `o_y` renders at
`dy=o_y+8`, so "sitting one tile on top of a block at row `mrow`" is **`o_y = mrow*8`**. Pickup
scores +1000 and despawns (Mario already big). **Superball projectile ability = still TODO.**

## TODO / not-yet-faithful
- Coin/mushroom **bounce animations** (mushroom entity + grow are done & trace-faithful).
- Floating coins / coin rooms (W1-1 surface has none; coins come from blocks).
- Persisting block state across pipe-trip re-renders.
- Time-up and damage-shrink (need death sequence / enemies).
- 1-up at 100 coins.
- `$2a`/`$2c`/`$c0` block contents (star / superball / multi-coin) still stubbed as mushroom.
