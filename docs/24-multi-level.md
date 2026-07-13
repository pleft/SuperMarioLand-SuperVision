# Multi-level architecture (Phase 6): banking, level headers, 1-2

Status 2026-07-13: **World 1-2 SHIPPED** (commits `1c4f533` + `7f62148`).
1-1 → 1-2 → wrap; everything below is capture- or py65-verified.

## GB level system (RE)

- **`$ffe4` = level id** (0..11). `LevelLoader_2442` seeds the spawn counter
  `$c0ab = $0C` and reads `LevelParamTable[$ffe4]` (bank0 `$07CE+..`? no —
  table at `LevelParamTable::` before the loader) → `$d014`.
- **`$d014` = animated-BG-tiles flag** (`VBlank_AnimateTiles` $23F5-ish: every
  8 frames swaps a tile's graphic from `$c600`/`$3fc4+world`). Per level:
  `00 00 01 01 01 00 00 01 01 00 01 00` — 1-3, 2-1, 2-2, 3-2, 3-3, 4-2 animate
  (water/lava). 1-1/1-2 don't.
- **Level progression** = `State_08`: `$ffe4 += 1` (wrap at 12), display BCD
  `$ffb4 += 1`, and when its low nibble hits 4, `+= $0D` (x-3 → (x+1)-1).
- **Start segment: `$ffe5 = 3` for EVERY level** — `Jump_000_0dd3` seeds it
  unconditionally on the single level-entry path (fresh game and State_08 both).
  PyBoy-verified on a forced 1-2 load. The extractor's per-level table is gone;
  `DEFAULT_START_SEG = 3`.
- **Per-level music** (bank0 table at `$07CE`, index `$ffe4`):
  `07 07 03 08 08 05 07 03 03 06 06 05` → 1-2 = track $07 (the 1-1 tune,
  already ported). 1-3 needs track $03.
- **Checkpoints generalize**: forced deaths in 1-2 respawn at cab
  $0C/$34/$5C/$84 = cameras 0/640/1280/1920 — the exact quantization the port
  already ships. No changes.
- **Spawn X rule** (`ObjectSpawnCheck` $249B): the spawner places an object at
  screen `$ffc3 = $D0 + x_off*4 − (cab−col)*16`, i.e. **world x = fire_cam +
  192 + x_off*4** (x_off = spawn-entry byte1 bits 6-7). This reproduces BOTH
  traced 1-1 platform positions exactly.

## Port architecture: 64K banked cart

File = `[BANK0][BANK1][BANK2][FIXED]`; SYS_CTRL ($2026) bits 7:5 map one 16K
bank at $8000 (level N = bank N; the write is safe mid-proc because the common
prefix is byte-identical in every bank).

- **BANK0** (linked): `LEVELS` segment = the **common prefix** (audio engine +
  sfx/music data, BG charset, banked code, engine tables) → `TITLE0` (title
  map+tiles, bank 0 ONLY) → `LEVEL0` (level_hdr + 1-1 data).
- **BANK1/BANK2** (written post-link by `tools/pack_banks.py`): the identical
  common prefix + `[header + level data]` at **TITLE0's address** — the title
  only runs with bank 0 mapped, so its 2.2K range is level space in every
  other bank. Free space: 1-2 → 2.5K, 1-3 → 2.2K.
- **Level header** (18 bytes; leveldata.s ↔ pack_banks.py must agree):
  `map ptr, cols(16), room0/1/2 ptrs, pipes ptr, pipe count, blocks ptr,
  block count, spawns ptr`.
- **`load_level`**: selects the bank, copies the header (bank0 = the linked
  `level_hdr`; banks 1+ = `__TITLE0_LOAD__`) into `hdr_buf`, binds
  `surf_map/lvl_cols/cam_max/fbmax_col`, and copies rooms ptrs + pipes +
  blocks + spawns to RAM (`room_tbl/pipe_tab/block_tab/spawn_tab`) so the
  engine keeps absolute indexed addressing. CAM_MAX/FB_MAX_COL are runtime
  (`cam_max`, `fbmax_col`).
- **`next_level`** = the GB State_08: `cur_level+1`, wrap at `NUM_LEVELS`(=2),
  fresh start at column 0 (the old stale-`cam_dead` checkpoint math is gone —
  checkpoints belong to `do_respawn` only). HUD stage digits (row 1 cols
  12/14) come from `world_tab/stage_tab[cur_level]`.
- **Spawn entries are 5 bytes**: `[fire_cam(16), o_y, type, x_off]`,
  $FFFF-terminated, INCLUDING platforms $0A/$0B (only hard-mode bit7 entries
  are skipped). `spawn_tab` RAM copy = 384 bytes; lists >51 entries (levels
  9-11) need a pointer-walk before those ship (extractor warns).

## Verification (py65 harness: scratchpad svharness.py, bank-aware)

- 1-2 loads via forced `next_level`: bank 1, 280 cols, cam_max 2080 (the goal
  fires exactly at cam_max in the GB sweep), pixel-faithful vs PyBoy.
- 1-1 regressions all green after every step: physics T1-T5, stomp, music
  1431/1431, platforms (see below), wrap 1-1→1-2→1-1.

## Deviations / notes

- 1-2's two ROM "rooms" are unreachable leftovers (its pipe list is empty in
  the ROM too); the port carries them as data but nothing links to them.
- Walker spawn x stays at the user-verified `cam+180` (not the exact
  `fire+192+x_off*4` rule) — new types + platforms use the exact rule.
- The GB spawns platforms when `cab` EXCEEDS the fire column (≈16px later than
  the port's `cam ≥ fire`); the position rule absorbs this (fire-based, not
  cam-based), only the entry timing differs by ≤16px of camera.
