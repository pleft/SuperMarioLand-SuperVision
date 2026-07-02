# Blocks & Coins, Power-ups / Big Mario, Dynamic HUD (Phase 5 tasks #2/#4/#3)

Ported from RE of bank 0 (`Player_CeilingCheck`, `Call_000_0166` score, `VBlank_UpdateDisp_DA00/DA15`)
and the bank-3 metasprite table `$4C37`. Implemented in `src/main.s`; data via
`tools/extract_tables.py`.

## Tile semantics (World 1-1, verified from the extracted level map)
### ?-block contents come from a TABLE, not the tile value [CORRECTED]
The tile value (`$80`/`$81`) does **not** decide coin-vs-mushroom. During level decode
`Call_000_2321` looks each special tile up in a per-level table (**bank3 `$6536`**, 3-byte
`[segment, col-in-seg, value]` entries) and stores the content `value`. Blocks NOT listed hold
a single **coin**. World 1-1 lists 5: cols 22 & 95 = `$28` **power-up**; col 83 = `$2a` **1-UP
HEART**; col 174 = `$2c` **STAR**; col 259 = `$c0` **multi-coin**. [CORRECTED 2026-07-02: an
earlier note had `$2a`=star / `$2c`=superball — wrong. Tile `$84` is a heart and its pickup
routes to `$c0a3`, the +1-life trigger; the star is `$2c`, tile `$86`.] (Columns are −20 vs the
pre-2026-06-30 values, after the seg-3 play-start fix in `docs/10`.) Extracted to
`level_NN_blocks.bin` (`decode_blocks`), looked up at hit time by `find_block (col,row)`.

| Hit tile | Content (table) | Reaction (head-bonk from below) |
|----------|-----------------|---------------------------------|
| `$80`/`$81` | unlisted | **spinning coin pop** + `+1` coin + `+100` score |
| `$80`/`$81` | `$28` | **Super Mushroom** entity (or **Superball Flower** if already big) |
| `$80`/`$81` | `$2a` | **1-UP heart** entity (walks like the mushroom; pickup = +1 life) |
| `$80`/`$81` | `$2c` | **star** entity (bounces away; pickup = ~16s invincibility) |
| `$80`/`$81` | `$c0` | **multi-coin block** (see below) |
| `$82` | brick | big Mario → smash into **4 flying shards** (+50); small → the brick **hops** |

Every `?`-block bonk also plays the **block-bounce** animation (below).

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
scores +1000 and despawns, and sets **`mario_superball`** (the fire ability; original's `$ffb5`).

## Superball projectiles [added 2026-07-01 — trace-verified]
Superball Mario fires with **B** (`pad_pressed & $02`), gated on `mario_superball` + **one ball
on-screen at a time** (matches bank3's `b=$01` at `$4a0c`). The ball is NOT a `$d100`-style level
object in the original (it's a dedicated OAM/`$ffa9` list), but the port models it as an
`OBJ_BALL` slot. RE'd from `tools/trace_superball.lua` (OAM tile@x,y each frame): tile **`$60`**,
launches from Mario's nose at **45°** (`vx=±2` by facing, `vy=+2` down), **2 px/frame every frame**
(not the every-other-frame object rate). It bounces off the **floor** (reverse vy up) and
**ceiling/wall** (reverse vy down / vx), then **climbs off-screen** — there is NO fixed bounce
height (an early guess; the trace's mid-air turnaround was really a block/ceiling hit). Expires on
lifetime or off-screen (X or Y). Gotcha fixed: the wall test must be **one row above the feet**,
else the flat floor reads as a wall and the ball yo-yos in place. Lost on death. It bounces off `?`-blocks as solid geometry but does **not** activate them —
correct: `?`-blocks are bonked only by Mario's head (`hit_qblock`), never by the superball, in
the original too.

**Superball collects floating coins [added 2026-07-02, RE `Call_000_1fd2`]:** the ball's
per-axis tile test compares `$f4`, queues the coin award through the same `$ffee=$c0` VBlank
path as a bonked block-coin (coin sound `$05`), then falls through to the `cp $60` solidity
check with `A=$f4` — so the collected coin acts **solid**: the ball **bounces off the coin it
grabs** and keeps flying (it persists; user gameplay memory + source both confirm). Port:
`ball_solid` wraps the ball's three axis tests (wall/floor/ceiling) — a `$f4` cell is collected
(`mod_set` + blank + `award_coin`) and returns solid, so the ball ricochets exactly like the
original. Test: the col-87 coin stack, cols 266-277, or the 18-coin pipe rooms.
**TODO: superball kills enemies (needs enemies).**

## Coins: pop + collectible floating coins [added 2026-07-02]
**Coin tile is `$F4`** (round with a hole), for BOTH the `?`-block pop and floating coins.
`$5F` was a wrong guess (garbage in the BG set → invisible pop). The **pop** (`OBJ_COIN`,
`spawn_coin`/`upd_coin`) launches up (`vy=-6`) under gravity with a **12-frame** life so it
arcs up ~2 tiles and vanishes near the block (was 24 → gravity dragged it off the screen
bottom into the HUD strip).

**Floating coins** (`$F4`) exist on the 1-1 surface (col-87 stack rows 3-9; cols 266-277) and
18 per pipe-room. They're now **walk-through + collectible**:
- `read_solid` excludes `$F4` (not floor); the jump ceiling check in `jump_player` also excludes
  it (was a raw `cmp #$60`, so a coin above Mario blocked his jump).
- `coin_collect` (main loop, every frame): at Mario's centre column × his two body rows, any
  `$F4` → `mod_set` the cell + blank it on screen + `award_coin` (+100, 1-up at 100).

**Used-tile transform (`read_map_tile`)** now runs on the surface AND in rooms, and is
**tile-specific**: `$80/$81`→`$7F` (used block), `$82`→blank, `$F4`→blank (collected), and
**anything `<$80` is left RAW**. The last clause is critical — the earlier `else→$7F` turned any
room cell carrying a stray mod bit into a solid block (the "coins became blocks in the pipe
rooms" bug). Now only a genuine `?`-block can ever become a used block.

## ROM layout / banking [added 2026-07-02]
The fixed bank (`$C000-$FFFF`) filled up (CODE+CHARS+LEVELS), overflowing by a byte. The 16K
**selectable bank 0 (`$8000-$BFFF`) was empty**, so `cfg/supervision.cfg` now loads the `LEVELS`
segment there. Boot already selects `SYSCTRL_BANK0` (`$2026` bits7:5), so bank 0 is mapped at
`$8000` and the level-data labels resolve normally — no bank-switching code needed for a 32K cart.
Result: **~5.6K free in the fixed bank** for code. To scale further (enemies), page more data
through `$8000` (up to 128K / 8 banks).

## 1-UP heart + star + multi-coin block [added 2026-07-02 — RE + trace verified]
**Heart (`$2a` → object types `$2A`/`$2B`).** Identical physics + AI script to the mushroom
(`$28`/`$29`) — hop out, drop, walk, reverse at walls; only the sprite param differs (`$17` →
tile **`$84`**, confirmed emerging in the gameplay trace). Pickup → `$c0a3`=1 = **+1 life** (the
same trigger the 100-coin 1-up uses; drives the lives HUD). Port: `OBJ_HEART` through the shared
`spawn_walker`/`upd_mush` engine.

**Star (`$2c` → type `$2C` rise, morph `$34`).** Rises 8px out of the block (2 updates × 4px,
script vel `$40`×2), then **bounces forward in small arcs**: the `$34` script encodes the hop as
a per-update vy ramp (up 3,2,1,1,0 then falling), X speed 1 throughout; floor restarts the ramp,
walls reverse. Tile **`$86`** twinkling with `$85`. Pickup → `$c0d3`=`$f8`: **248 ticks,
decremented every 4th frame (~16s), Mario's sprite toggling visible/invisible each tick** (port:
`mario_starT`/`star_flash`, `draw_player` skips the off phase; the every-frame erase keeps it
clean). While `$c0d3`≠0 object collisions take the kill-enemy path (hooks in with enemies).
The port's vy ramp (`star_vy`) is a linearization of the script — flag if the arc looks off.

**Multi-coin (`$c0`, RE of `Jump_000_1888`/`18a4`/`19e1`).** First bonk: coin + a **hard
255-frame window** (`$c0ce`, NOT reset by re-bonks) + the block **draws as a brick `$82`** but
stays live. Re-bonks (the `$82` ceiling path checks content `$c0` FIRST, so big Mario cannot
smash it): another coin each. First bonk after expiry: final coin + converts to used. Port:
single global `mc_tmr`/`mc_cell` (like the original), `read_map_tile` returns `$82` for the live
cell, `jump_player`'s brick path routes that cell back to `hit_qblock`. Reset on respawn.

## Block bounce, spinning coin-pop, score popups, brick shards [added 2026-07-02 — trace-exact]
All from `tools/trace_bounce.lua` + the bank2 popup engine (`$5892` place / `$59a5` move):
- **Block bounce**: a bonked `?`-block hops as a sprite of its own pre-bonk tile, offsets
  **−2,−2,+1,+2** (~5 frames), then the final tile stands. `OBJ_BOUNCE`; all `?`-bonks (the
  multi-coin cell is registered before the hop so even the first bonk hops as `$82`) and
  small-Mario brick bonks. Deviation: the final tile is stamped under the hop sprite during the
  ~5 frames (the original blanks the cell) — covered by the sprite, invisible in practice.
- **Coin-pop**: block coins are `$c0`-marked popups — they rise **1px every frame for 32
  frames**, spinning tiles **`$F6`→`$F7`→`$F8`→`$F7`** (1 step/frame). (Earlier `$F4` +
  gravity-arc pop was wrong.) `upd_coin` rewritten to match.
- **Score popups**: pickups queue a 2-glyph floating text at Mario (`$ffeb/ec/ed`): value `$10`
  → tiles `$59`+`$57` = **"1000"** (mushroom/flower/star), `$ff` → `$5E`+`$5F` = **"1UP"**
  (heart). Rises **1px every 2 frames, 32 ticks** (64 frames). Glyph tiles `$57-$5F` are the
  packed score-text set ("00","0","10".."80","1U","P."). `OBJ_POPUP`, hooked into all pickups.
- **Brick shards**: a smashed brick bursts into **4 sprites, all tile `$62`**, x ±1px EVERY
  frame from the brick's halves, y stepping along **Mario's own jump-arc table** — high pair
  from arc index 7 (21px rise), low pair from index 11 (13px), hold at the `$7F` apex, then fall
  down the mirrored table (the original steps `$c218/28/38/48` along `JumpArcTable` per frame).
  Port: `OBJ_DEBRIS` driven by the extracted `jumparc.bin` with the same indices. A second break
  **recycles the shard slots** (the original's 4 fixed slots mean the new set replaces the old —
  SML never shows 8 shards); this is also what keeps double-breaks inside the frame budget
  (see `docs/22`).
- **Object pool** grown to **8 slots** (a brick break spawns 4 shards on top of a live item).
- **Top clip**: `draw_objects` skips anything whose `dy=o_y+8` lands above y=16 — a high
  coin-pop/popup can no longer stamp the HUD rows (o_y wrap included).

## TODO / not-yet-faithful
- Persisting block state across pipe-trip re-renders (mod bitmap is shared surface/room; fine for
  1-1 since there's no col/row collision, but not general).
- Time-up and damage-shrink (need death sequence / enemies).
- Superball: kills enemies (needs enemies). (Coin-collect: DONE, see the superball section.)
- Star: enemy invulnerability effect (needs enemies); vy ramp is a script linearization.
- Block-bounce cell blanking (see deviation above) if it ever reads wrong.
- Pickup jingles / star music (audio phase).
