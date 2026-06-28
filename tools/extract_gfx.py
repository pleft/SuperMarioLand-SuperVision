#!/usr/bin/env python3
"""
Extract Super Mario Land tile graphics from the user's own ROM and decode the
standard Game Boy 2bpp format into PNG tile sheets.

RULE 5: this script ships; its PNG output (ROM-derived) does NOT — written under
build/gfx/ which is gitignored.

GB 2bpp: each 8x8 tile = 16 bytes; for each of 8 rows, byte A = low bitplane,
byte B = high bitplane; pixel = (bitA>>x&1) | ((bitB>>x&1)<<1)  -> 0..3.

Tile source regions (from VRAM-load calls; see docs):
  $4032 -> VRAM $8000, 0x1000 (256 tiles): OBJ (sprites incl. Mario) + BG
  $5032 -> VRAM $9000, 0x800  (128 tiles): BG tiles
These live in the per-world data banks (W1=2, W2/W4=1, W3=3).

Usage: python3 tools/extract_gfx.py [rom] [--out build/gfx]
"""
import sys, os, hashlib
try:
    import png
except ImportError:
    sys.exit("needs pypng:  pip3 install pypng")

EXPECT_SHA1 = "418203621b887caa090215d97e3f509b79affd3e"
# DMG 4-gray palette (0=light .. 3=dark), as RGB for the PNG.
PAL = [(224, 248, 208), (136, 192, 112), (52, 104, 86), (8, 24, 32)]

def bank_file(bank, gb): return bank * 0x4000 + (gb - 0x4000)

def sv_pack(tiles):
    """Repack tiles (8x8 of 0..3) into Watara Supervision linear 2bpp:
    16 bytes/tile, 2 bytes/row; within a byte bits1:0=leftmost px, 3:2,5:4,7:6.
    (GB is planar; SV is linear 4px/byte — see docs/20.)"""
    out = bytearray()
    for t in tiles:
        for row in t:                      # 8 rows
            a = row[0] | (row[1] << 2) | (row[2] << 4) | (row[3] << 6)  # left 4 px
            b = row[4] | (row[5] << 2) | (row[6] << 4) | (row[7] << 6)  # right 4 px
            out.append(a); out.append(b)
    return bytes(out)

def decode_tiles(d, off, ntiles):
    """Return list of tiles; each tile is 8 rows x 8 cols of 0..3."""
    tiles = []
    for t in range(ntiles):
        base = off + t * 16
        tile = []
        for row in range(8):
            lo = d[base + row * 2]; hi = d[base + row * 2 + 1]
            line = []
            for x in range(8):
                bit = 7 - x
                line.append(((lo >> bit) & 1) | (((hi >> bit) & 1) << 1))
            tile.append(line)
        tiles.append(tile)
    return tiles

def sheet_png(tiles, path, cols=16, scale=1):
    """Write tiles to a PNG sheet, `cols` tiles wide."""
    rows = (len(tiles) + cols - 1) // cols
    W, H = cols * 8, rows * 8
    img = [[PAL[0]] * W for _ in range(H)]
    for i, tile in enumerate(tiles):
        tx, ty = (i % cols) * 8, (i // cols) * 8
        for r in range(8):
            for c in range(8):
                img[ty + r][tx + c] = PAL[tile[r][c]]
    # flatten to RGB rows, apply integer scale
    flat = []
    for r in range(H):
        rowpx = []
        for c in range(W):
            rowpx.extend(img[r][c])
        for _ in range(scale):
            flat.append(rowpx * 1 if scale == 1 else
                        [v for c in range(W) for v in img[r][c] for _ in range(scale)])
    w = png.Writer(W * scale, H * scale, greyscale=False)
    with open(path, "wb") as f:
        w.write(f, flat)

# Per-world graphics (from SelectWorldBank $0D6D and the State_11 loads):
#  - common OBJ tiles  $4032 -> VRAM $8000, $1000 (256 tiles): Mario, enemies, UI, font
#  - common BG tiles   $5032 -> VRAM $9000, $0800 (128 tiles): font + world scenery
#  - world overlay 1   $0DED[(world-2)] -> VRAM $8A00, $03D0 (61 tiles)  [worlds 2-4]
#  - world overlay 2   $0DF3[(world-2)] -> VRAM $9310, $03F0 (63 tiles)  [worlds 2-4]
# all sourced from the world's data bank (W1=2, W2/W4=1, W3=3).
WORLD_BANK = {1: 2, 2: 1, 3: 3, 4: 1}
OBJ_SRC, OBJ_N = 0x4032, 256
BG_SRC,  BG_N  = 0x5032, 128
OVL1_TBL, OVL1_N = 0x0DED, 61          # bank0 table -> $8A00
OVL2_TBL, OVL2_N = 0x0DF3, 63          # bank0 table -> $9310

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    rom = args[0] if args else "super-mario-land-gb.gb"
    out = "build/gfx"
    if "--out" in sys.argv: out = sys.argv[sys.argv.index("--out") + 1]
    d = open(rom, "rb").read()
    if hashlib.sha1(d).hexdigest() != EXPECT_SHA1:
        print("WARNING: ROM SHA1 mismatch (continuing)")
    os.makedirs(out, exist_ok=True)

    def u16(fo): return d[fo] | (d[fo + 1] << 8)
    def dump(label, bank, gb, n):
        tiles = decode_tiles(d, bank_file(bank, gb), n)
        p = os.path.join(out, f"{label}.png")
        sheet_png(tiles, p, cols=16, scale=3)
        with open(os.path.join(out, f"{label}.svt"), "wb") as f:   # SV-packed tiles for the port
            f.write(sv_pack(tiles))
        print(f"  {label}: {n} tiles from bank{bank}:${gb:04X} -> {p} (+.svt)")

    for world in (1, 2, 3, 4):
        bank = WORLD_BANK[world]
        dump(f"w{world}_obj_8000", bank, OBJ_SRC, OBJ_N)   # common OBJ (Mario/enemies/UI)
        dump(f"w{world}_bg_9000",  bank, BG_SRC,  BG_N)    # common BG (font/scenery)
        if world >= 2:                                     # world-specific overlays
            i = (world - 2) * 2
            ovl1 = u16(OVL1_TBL + i)                       # bank0 table, source in world bank
            ovl2 = u16(OVL2_TBL + i)
            dump(f"w{world}_ovl_8A00", bank, ovl1, OVL1_N)
            dump(f"w{world}_ovl_9310", bank, ovl2, OVL2_N)
    print(f"Extracted tile sheets -> {out}/ (gitignored)")

if __name__ == "__main__":
    main()
