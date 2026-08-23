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
    # 1-3 water shimmer: BG tile $5D with its HIGH bitplane replaced by the
    # world-1 pattern at $3fc4 (VBlank_AnimateTiles swaps tile $5D's high plane
    # between this and the original every 8 frames; the port swaps the whole
    # 16-byte SV tile source instead).
    base = bank_file(WORLD_BANK[1], BG_SRC) + 0x5D * 16
    tile = []
    for row in range(8):
        lo = d[base + row * 2]; hi = d[0x3fc4 + row]
        tile.append([((lo >> (7 - x)) & 1) | (((hi >> (7 - x)) & 1) << 1) for x in range(8)])
    with open(os.path.join(out, "water_alt.svt"), "wb") as f:
        f.write(sv_pack([tile]))
    # The x-3 rescue scene loads its OWN OBJ overlay at $8A00 (the per-world
    # region): the MOTH the fake Daisy becomes = tiles $A0-$A3/$B0-$B3 of that
    # overlay. Located by dumping VRAM at state $26 and matching ROM bytes:
    # bank 2, file 0x8A32 + (tile-$A0)*16 (tops) / 0x8B32 + (tile-$B0)*16
    # (bottoms). Emitted as an 8-tile sheet in port draw order
    # [A0 A1 A2 A3 B0 B1 B2 B3] (flying pair first, sitting pair second row).
    moth = []
    for off in (0x8A32, 0x8A42, 0x8A52, 0x8A62, 0x8B32, 0x8B42, 0x8B52, 0x8B62):
        moth += decode_tiles(d, off, 1)
    with open(os.path.join(out, "moth.svt"), "wb") as f:
        f.write(sv_pack(moth))
    # The 2-3 rescue creature (what the fake Daisy becomes in world 2): same
    # $A0-$A3/$B0-$B3 metasprite layout, per-world pixel data. Located by
    # dumping VRAM at 2-3's state $26 and byte-matching ROM: bank 1, file
    # 0x4032 + (tile-$A0)*16 (tops) / 0x4132 + (tile-$B0)*16 (bottoms).
    # Same 8-tile port draw order as the moth; the room machine copies this
    # sheet over the moth tiles (bank 6 $B900) when ending13 == 2.
    creat = []
    for off in (0x4032, 0x4042, 0x4052, 0x4062, 0x4132, 0x4142, 0x4152, 0x4162):
        creat += decode_tiles(d, off, 1)
    with open(os.path.join(out, "creature23.svt"), "wb") as f:
        f.write(sv_pack(creat))
    # 2-3's BOSS SHOT (Dragonzamasu's ball). The arena runs a SECOND 256-tile
    # OBJ sheet -- bank 2, file 0x8032 + tile*16, exactly one bank above the
    # common sheet (0x4032) and the same sheet the rescue moth comes from. So
    # the ball is NOT the $E2/$E3 of the common $8000 sheet: those bytes are a
    # striped BG pattern, which is what the port was drawing. OAM-measured in
    # the arena: tiles $E2/$E3 alternate every 4 frames ($FE = a blank tile,
    # the 3 frames the shot spends inside his mouth).
    dsh = decode_tiles(d, 0x8032 + 0xE2 * 16, 2)
    with open(os.path.join(out, "dshot23.svt"), "wb") as f:
        f.write(sv_pack(dsh))
    # 3-3's rescue creature: same 2x2 metasprite ($A0/$A1/$B0/$B1, x-flipped
    # pair), sourced from WORLD 3's bank -- VRAM-dumped at 3-3's state $26 and
    # byte-matched to bank 3 0xC032 (tops) / 0xC132 (bottoms).
    creat3 = []
    for off in (0xC032, 0xC042, 0xC052, 0xC062, 0xC132, 0xC142, 0xC152, 0xC162):
        creat3 += decode_tiles(d, off, 1)
    with open(os.path.join(out, "creature33.svt"), "wb") as f:
        f.write(sv_pack(creat3))
    # ONE-WAY PLATFORM caps (GB $1A93 per-world jump-through lists; ceiling AND
    # wall checks pass them, floor stands): the port remaps the cap tile ids to
    # $F9-$FF (extract_levels.py) so the raw <$60/>=F4 threshold checks do the
    # work; the PIXELS must therefore live at those ids in the SHARED hi sheet
    # (chardata second half). Free slots verified: $F6-$F8 = coin spin; $F5,
    # $F9-$FF unused. W1 caps $68/$69/$6A -> $F9/$FA/$FB, 7C -> $FF; W2 caps
    # $60/$61/$63 (pixels inside ovl_9310, base id $31) -> $FC/$FD/$FE.
    # WORLD 3 needs tiles $F9/$FA/$FB/$FE for the moai pillar's missile -- the
    # very ids the one-way-cap remap below overwrites in the shared sheet. Keep
    # the originals here; gen_w3data routes them through W3's overlay slice, so
    # the caps keep their ids and the missile keeps its pixels.
    obj0 = open(os.path.join(out, "w1_obj_8000.svt"), "rb").read()
    with open(os.path.join(out, "w3_hi.svt"), "wb") as f:
        for t in (0xF9, 0xFA, 0xFB, 0xFE):
            f.write(obj0[t * 16:(t + 1) * 16])
    def slot(path, idx):
        return open(path, "rb").read()[idx * 16:(idx + 1) * 16]
    obj = bytearray(open(os.path.join(out, "w1_obj_8000.svt"), "rb").read())
    bg  = os.path.join(out, "w1_bg_9000.svt")
    ov2 = os.path.join(out, "w2_ovl_9310.svt")
    for dst, src in ((0xF9, slot(bg, 0x68)), (0xFA, slot(bg, 0x69)),
                     (0xFB, slot(bg, 0x6A)), (0xFF, slot(bg, 0x7C)),
                     (0xFC, slot(ov2, 0x60 - 0x31)), (0xFD, slot(ov2, 0x61 - 0x31)),
                     (0xFE, slot(ov2, 0x63 - 0x31))):
        obj[dst * 16:(dst + 1) * 16] = src
    with open(os.path.join(out, "w1_obj_8000.svt"), "wb") as f:
        f.write(bytes(obj))
    print("  one-way caps -> hi-sheet slots $F9-$FF")
    print(f"Extracted tile sheets -> {out}/ (gitignored)")

if __name__ == "__main__":
    main()
