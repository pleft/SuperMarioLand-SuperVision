# Multi-level architecture (Phase 6): banking, level headers, 1-2

Status 2026-07-14: **World 1-2 COMPLETE — user-verified on hardware** (commits
`1c4f533` → `c68e5a1`). 1-1 → 1-2 → wrap; everything below is capture- or
py65-verified, then hardware-confirmed.

## GB level system (RE)

- **`$ffe4` = level id** (0..11). `LevelLoader_2442` seeds the spawn counter
  `$c0ab = $0C` and reads `LevelParamTable[$ffe4]` (the 12-byte table right
  before the loader in bank 0) → `$d014`.
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
bank at $8000 (the write is safe mid-proc because the common prefix is
byte-identical in every bank). Level -> bank via `lvl_bank_tab` (.byte 1,0,2):
**bank 0 pairs the title with 1-2** — the SMALLEST W1 level — because bank 0
is the binding space constraint; 1-1 lives in bank 1 (written by the packer,
`pack_banks.py 0:1 2:2`). `load_level`'s linked-header case is `cur_level==1`.

- **BANK0** (linked): `LEVELS` segment = the **common prefix** (audio engine +
  sfx/music data, BG charset, banked code, engine tables) → `TITLE0` (title
  map+tiles, bank 0 ONLY) → `LEVEL0` (level_hdr + 1-2's data).
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
- **`next_level`** = the GB State_08: `cur_level+1`, wrap at `NUM_LEVELS` (=2
  until 1-3 ships),
  fresh start at column 0 (the old stale-`cam_dead` checkpoint math is gone —
  checkpoints belong to `do_respawn` only). HUD stage digits (row 1 cols
  12/14) come from `world_tab/stage_tab[cur_level]`.
- **Spawn entries are 5 bytes**: `[fire_cam(16), o_y, type, x_off]`,
  $FFFF-terminated, INCLUDING platforms $0A/$0B (only hard-mode bit7 entries
  are skipped). `spawn_tab` RAM copy = 384 bytes; lists >51 entries (levels
  9-11) need a pointer-walk before those ship (extractor warns). A FULL object
  pool does NOT consume an entry — spawn procs return carry and spawn_check
  retries next frame (spawn x is fire-based, so placement is unaffected).
- **Object pool = 10 slots** (`OBJ_MAX`), matching the GB's $D100-$D190: 1-2's
  goal area legitimately runs 9 objects (2 bees + 4 arrows + platform + 2
  stones, GB-capture-verified).
- **Render budget** (docs/22 has the perf story): render_all pass 1 walks the
  slots from a rotating origin and redraws at most 3 pure movers per frame;
  an over-budget mover keeps last frame's image. Combined with 30Hz staggered
  motion for bees/arrows, per-type anim tokens, and the table-driven
  `sprite_blit_subpx`, the natural 8-object goal scene runs p95 = 71% of the
  frame budget (worst 111%, 3/500 frames over — invisible under race-the-beam).

## Verification (py65 harness: tools/svharness.py, bank-aware)

- 1-2 loads via forced `next_level`: 280 cols, cam_max 2080 (the goal
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

## Harness notes (py65)

- `tools/svharness.py` = the bank-aware harness: remaps $8000 on SYS_CTRL
  writes; `boot_to_game()` presses Start at frame 240; enter any level by
  pushing `main_loop-1` and jumping to `next_level`.
- The FLAT `[bank][fixed]` views used by verify_music/stomp_test load
  `file[0x4000:0x8000] + file[-0x4000:]` — bank 1 holds 1-1 (the title draws
  garbage in that view, but Start works and load_level(0) reads 1-1's header).
- Rebuild `build/dbg.txt` after ANY code move: a stale `main_loop` symbol makes
  the frame loop wait on a dead address (looks like a hang).

## World 1-3 (2026-07-16): the L3CODE overlay + per-bank code layout

1-3 shipped with a new code-layout trick forced by the ROM budget: the 1-3 kit
(~1.9K: seven object types + the water shimmer) does NOT fit the every-bank
LEVELS prefix (bank 0 had ~430B free) nor FIXED (~17B free).

- **L3CODE** = a bank-2-only segment (`load BANK2 run L3RAM` in the cfg): ld65
  links it to RUN at RAM $1500 and emits the bytes at BANK2's start in the
  image. pack_banks lays bank 2 out as `[prefix][L3 blob @ TITLE0][header]
  [level data]`; load_level (cur_level==2) copies 8 pages from __TITLE0_LOAD__
  to $1500 and reads the header at __TITLE0_LOAD__ + __L3CODE_SIZE__.
  Dispatch: every engine hook is a range check (`o_type >= OBJ_SUU` -> jsr/jmp
  into $15xx) — those types only exist while 1-3 is loaded, so other levels
  never execute the RAM window.
- **L12** = a bank-0-only segment (like TITLE0) for the 1-2-only entities
  (bunbun + arrow: spawn/update/draw/corpse draw). They run only with bank 0
  mapped (1-2 is bank 0's resident level), so moving them out of the prefix
  freed ~470B in EVERY bank — that's what made room for 1-3's level data +
  overlay in bank 2 (83 bytes to spare). Stones/Nokobon stay in the prefix
  (1-3 uses both).
- Music track $03 extracted (TRACKS += 0x03) and model-verified in 1-3:
  690/690 APU writes identical. Per-level tune via lvl_track_tab (GB $07CE);
  the star-expiry restore path reads it too.
- SFX dff8=$04 (the Gao/Batadon shot) extracted; NUM_LEVELS = 3; the wrap is
  now 1-1 → 1-2 → 1-3 → 1-1.
- Segment budget after: bank0 ~0 free (L12 fills the tail), bank1 ~2.0K free,
  bank2 ~75B free, FIXED ~10B. The NEXT level (2-1) needs the 64K→128K cart
  step or another resident swap.
## The bank-overlay pattern, generalized (2026-07-17)

Three flavors now exist, all exploiting "this code only runs while bank N is
mapped (or is copied out of it first)":
- **TITLE0** (bank 0, in place): title code/data — runs only from the title.
- **L12** (bank 0, in place): the 1-2-only entities (bunbun/arrow) — 1-2 is
  bank 0's resident level.
- **L3CODE** (bank 2 -> RAM $1500): the 1-3 kit; copied by load_level.
- **L11CODE** (bank 1 -> RAM $1500): the BONUS GAME (~1.2K, freed FIXED from
  1 byte to ~1.1K); bonus_enter_copy maps bank 1 and copies the blob at the
  top-door goal path. The two RAM overlays SHARE the $1500 window — a bonus
  can never run mid-1-3-gameplay, and the next load_level restores whichever
  blob the next level needs.
Packer layout for banks 1 and 2: [prefix][blob @ TITLE0 addr][header][level];
load_level reads the header at __TITLE0_LOAD__ + __L11CODE_SIZE__/__L3CODE_SIZE__
by cur_level. Collision leniency shipped with the freed space: grounded support
and landings probe BOTH feet (+4/+12) after the centre, per the GB's dual-probe
floor test.

- **1-3's ending is NOT the door pattern**: the map dead-ends at the boss
  arena (bridge over spikes, wall + rope $EC at cols 297-298; no exit tiles).
  King Totomesu + the switch + the rescue scene are dedicated GB machinery
  (no spawn-list entry, never in $D100 — like the superball/bonus game) = the
  next RE phase. Until then l3_goal_chk (in the overlay) runs the standard
  clear sequence at the arena wall so the level completes and wraps.
