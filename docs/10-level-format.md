# Level / Map Format & Loader (Task #5)

Verified from code + data, and validated end-to-end by `tools/extract_levels.py`
(parses all 12 levels distinctly).

## Level data is banked BY WORLD
`Call_000_0d6d` ($0D6D, called on level load) takes the world (high nibble of
`$FFB4`) and sets the gameplay ROM bank (`$2000`/`$FFFD`):

| World | Stages | Data bank |
|-------|--------|-----------|
| 1 | 1-1..1-3 | **2** |
| 2 | 2-1..2-3 | **1** |
| 3 | 3-1..3-3 | **3** |
| 4 | 4-1..4-3 | **1** |

So the gameplay bank is world-dependent. Within a bank, the per-level tables
(`$4000`/`$401A`) are indexed by the full level number `$FFE4`×2 (0–11); each bank
only holds valid entries for its own world(s). Worlds 2 & 4 share bank 1 at
different indices (3–5 vs 9–11). (Initially I assumed a fixed "bank 2"; the
extraction script's repeating output exposed the banking — see PROGRESS.)

## Key indices (HRAM)
| Var | Meaning |
|-----|---------|
| `$FFE4` | **level index 0–11** (12 levels = 4 worlds × 3 stages; wraps at `$0C` in `State_08`) |
| `$FFB4` | packed world-stage display value (e.g. 1-1,1-2,1-3,2-1…) |
| `$FFE5` | **segment index** within the level (selects a column-data stream) |
| `$C0AB` | current column counter (advances as the level scrolls right) |
| `$C0B0` | 16-byte column build buffer (consumed by VBlank scroll routine `$2258`) |
| `$D010/$D011` | running pointer into the current spawn list |
| `$D014` | per-level param byte (from `LevelParamTable`) |

## Tables
### `LevelParamTable` @ bank0 `$2436` (12 bytes)
One byte per level → `$D014` (gates tile-animation etc.). Values for L0–11:
`00 00 01 01 01 00 00 01 01 00 01 00`.

### `LevelSegPtrTable` @ **bank2 `$4000`** (12 × 2-byte pointers)
`LevelSegPtrTable[$FFE4]` → a per-level **segment-pointer table**. Indexed again by
`$FFE5` → pointer to the **column data** for that segment.
(Level 0 → `$6192` → segment ptrs `62BE 6817 68C7 62BE 6200 62BE`.)

### `LevelSpawnListTable` @ **bank2 `$401A`** (12 × 2-byte pointers)
`LevelSpawnListTable[$FFE4]` → per-level **object/enemy spawn list**. `LevelSpawnSeek`
($245C) scans it (3-byte stride) for the entry whose column ≥ `$C0AB`, saving the
pointer in `$D010/$D011`. (Level 0 list @ `$6002`.)

## Column data format (the map)
Streamed one column per 8 px of scroll by `LevelColumnStream` ($2198), which decodes
into the 16-tall buffer `$C0B0` (then the VBlank routine draws it to the BG map).

A column is a sequence of **(command, tiles…)** groups:
- **command byte** `HL`:
  - high nibble `H` = **starting Y offset** (0–15) within the 16-tile-tall column
  - low nibble `L` = **run length** (1–15; `0` ⇒ 16)
- followed by `L` **tile bytes**, written down the column from offset `H`.
- **`$FD <tile>`** = **RLE fill**: fill the REST of the current run with `<tile>`
  (NOT "end of run" — corrected 2026-06-28; the old reading left scattered blanks).
- **`$FE`** = **end of column**; **`$FF`** = segment-table terminator (see below).
- Cells not written default to tile **`$2C`** (blank).

### Segment model [CORRECTED 2026-06-28 — verified vs `LevelColumnStream` $2198]
A level is **reusable 20-column blocks**. The decoder advances the segment index
`$ffe5` **every 20 columns** (`$ffe6` counts to `$14`). Full surface = decode **20
columns from each segment pointer** in order, until the per-level segment table's
**`$FF`** low-byte terminator. Segment pointers REPEAT (W1-1 reuses `$62BE` 6×).
**Pipe/underground rooms** are also segments (columns start with a SOLID WALL — all
identical non-blank tiles); they are NOT in the surface scroll — entered only via pipes
(`State_0A`: `$ffe5=$fff4` down; `State_0B`: `$ffe5=$fff5` resume). The extractor skips
them (TODO: emit as pipe destinations when pipes/collision land).

**Play-start segment [added 2026-06-30 — trace-verified].** The surface does NOT begin at
segment 0. The level loader seeds `$ffe5` at level start, so the playable area begins partway
into the segment list; the leading segments are a lead-in *behind* the start (incl. the
pipe-rooms) that the camera never reaches (no left-scroll). For **1-1 the start routine `$0DD3`
does `ld a,$03; ldh [$ffe5],a` → play starts at segment 3.** seg0 (`$62BE`) + seg1/seg2
(pipe-rooms) sit behind the start. Confirmed live with `tools/trace_level.lua`: at `marioX=50`
(level start) the surface index is already ≥3 and never < 3 walking right. Symptom if ignored:
the opening `$62BE` (seg0) and the identical seg3 `$62BE` render as two near-duplicate first
screens. The extractor honours this via `LEVEL_START_SEG` (drops lead-in surface segments;
spawns/blocks auto-align because the game's column counter `$c0ab` starts at 0 == the start
segment). Other levels: their loaders' `$ffe5` seeds are still TODO (default 0).

Worked example (level 0, segment @ `$62BE`):
```
02 53 40 | D3 36 60 61 | FE     -> column: off0 ×2 = $53,$40 ; off13 ×3 = $36,$60,$61
02 53 40 | C4 70 72 60 61 | FE  -> next column: top $53,$40 ; off12 ×4 = $70,$72,$60,$61
...
```
(So the repeated `02 53 40` is the column top; the lower group is the ground/structure.)

### Special tile values (trigger metadata during decode)
While writing tiles, these call helper routines (set tile-type/object metadata in the
parallel `$C800` map shadow):
- `$70` → `Call_000_22A9`
- `$80`, `$5F`, `$81` → `Call_000_2321`
(Exact semantics — e.g. `?`-blocks, pipes, breakable — TODO; tie to task #6.)

## Spawn-list entry format (objects/enemies)
3 bytes each, ascending by column; consumed when the scroll reaches the column:
`[ column , position , type ]`  (corrected in task #6 — see `docs/12-enemies.md`)
- `column` = column index at which it spawns (compared to `$C0AB`)
- `position` = Y in bits 0–4 (`*8+$10`), X screen-offset in bits 6–7
- `type` = enemy/object type id (→ AI table `$349E`, physics `$3375`)
Level 0 sample: `0C,0F,00  0F,0F,80  13,0C,84  21,0C,00  25,0C,84  28,04,00 …`

## Loader entry points
- `LevelLoader_2442` ($2442) — (re)load level `$FFE4`: sets column counter, seeks spawn
  list (`LevelSpawnSeek`), loads param byte, inits object slots `$D100…`.
- `State_08_handler` ($0D49) — advance to next level (`$FFE4++`, update `$FFB4`).
- `LevelColumnStream` ($2198) — per-frame column streaming as the level scrolls.

## For the port / extraction (rule 5)
This fully specifies how to **extract** levels from the user's ROM at build time:
1. bank2 `$401A`/`$4000` give per-level spawn-list & segment pointers (12 levels).
2. Walk each segment's column data → reconstruct the tilemap (RLE columns above).
3. Walk each spawn list → object placements.
Emit neutral level files; the Supervision port re-streams them with the same column
model adapted to its framebuffer. (Extraction script = task #9.)

## TODO
- [ ] Enumerate object-type ids + the special-tile semantics (with task #6).
- [ ] Confirm how many segments per level and the `$FFE5` progression (level end / pipes).
- [ ] Map tile ids → graphics (tile-extraction; task #9).
