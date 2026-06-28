# Graphics Format & Extraction (Task #9)

## GB 2bpp tile format
Each tile is 8×8 px, **16 bytes**. For each of the 8 rows: byte A = low bitplane,
byte B = high bitplane. Pixel value (0–3) = `(bitA) | (bitB<<1)`, MSB = leftmost px.
0 = lightest … 3 = darkest (DMG palette via `rBGP`/`rOBP0`/`rOBP1`).

## Where the tiles are (source → VRAM loads)
From the VRAM-copy calls (`Memcpy_HL_to_DE_BC`):
| Source (bank) | → VRAM | size | content |
|---------------|--------|------|---------|
| `$4032`       | `$8000` | `$1000` (256 tiles) | OBJ sprites (Mario, enemies) + UI/font |
| `$5032`       | `$9000` | `$0800` (128 tiles) | BG tiles (font + world scenery/blocks) |
| `$791A`/`$7E1A` | `$9300`/`$8800` | title/UI graphics |
The source addresses are in the **per-world data bank** (W1=2, W2/W4=1, W3=3).
World-specific graphics are additionally loaded via `SelectWorldBank` ($0D6D)
through pointer tables at **`$0DED`** and **`$0DF3`** → VRAM `$8A00`/`$9310`.

## Extraction — `tools/extract_gfx.py`
Reads the user's ROM, decodes 2bpp → PNG tile sheets (16 wide, 3× scale) into
`build/gfx/` (gitignored — ROM-derived; rule 5).

**VERIFIED:** World 1 (bank 2) sheets decode to correct, recognizable graphics —
Mario poses, enemies, coins, "THE END", score/`1UP`/`TOP` UI digits (OBJ sheet);
the full font `0-9 A-Z` punctuation and the Egyptian (Birabuto) BG tiles (BG sheet).
This confirms the 2bpp decoder and source addresses.

## Per-world extraction (refined — task #11 done)
`SelectWorldBank` ($0D6D) + the State_11 loads define exactly what each world loads,
all from the world's data bank (W1=2, W2/W4=1, W3=3):
| Sheet | Source | → VRAM | Tiles | Notes |
|-------|--------|--------|-------|-------|
| common OBJ | `$4032` | `$8000` | 256 | Mario, enemies, UI, "THE END" (leading tiles shared) |
| common BG  | `$5032` | `$9000` | 128 | font + scenery |
| overlay 1 (W2-4) | `$0DED[(world-2)]` | `$8A00` | **61** (`$3D0`) | world-specific OBJ |
| overlay 2 (W2-4) | `$0DF3[(world-2)]` | `$9310` | **63** (`$3F0`) | world-specific BG |

`$0DED` = `$4032, $4032, $47F2` (W2/3/4); `$0DF3` = `$4402, $4402, $4BC2`. Lengths come
from the copy-loop terminators in `SelectWorldBank` (carry at VRAM `$8DD0` / `h==$97`).

`tools/extract_gfx.py` now emits, per world: `wN_obj_8000`, `wN_bg_9000`, and (W2-4)
`wN_ovl_8A00`, `wN_ovl_9310`. **Verified:** W1 sheets = Mario/UI/font/Egypt tiles;
W3 overlay = the sea-world enemy sprites. (Trailing tiles of the 256-tile common OBJ
sheet may be unused for banks that don't fill all 256 — the meaningful tiles are the
leading shared set + the overlays.)

## Status
- ✅ DONE. Decoder validated; per-world extraction (common + world overlays) correct.
- ✅ Music/SFX extraction completed separately (`tools/extract_music.py`, docs/13).

## For the port
Tiles decode to 0–3 indices that map directly to the Watara Supervision's 4-gray
output. The port reuses these exact tile bitmaps (extracted at build time, never
committed); only the blit mechanism changes (framebuffer vs GB PPU).
