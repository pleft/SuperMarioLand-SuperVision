#!/usr/bin/env python3
"""World 4's fireball tiles $E2/$E3 (the Nyololin shot / Roto Disc metasprite $45,
also $C4/$C5/$D4/$D5 from the overlay). build/gfx/w4_obj_8000.svt holds a star and
stripes at $E2/$E3 (dumped from a state whose $8E20 was not World 4's): the GB's
4-1/4-2/4-3 VRAM at $8E20/$8E30 is byte-identical to ROM 0x8E52/0x8E62 (bank 2
$4E52). Emit those two tiles in SV linear 2bpp -> build/gfx/w4_fire_8E52.svt;
pack_w4's tile() takes $E2/$E3 from it (docs/45, user: "stars instead of fireballs").
    python3 tools/extract_w4fire.py super-mario-land-gb.gb
"""
import sys
rom = open(sys.argv[1], "rb").read()
OFF = 0x8E52
out = bytearray()
for t in range(2):
    tile = rom[OFF + t * 16:OFF + (t + 1) * 16]
    for y in range(8):
        lo, hi = tile[2 * y], tile[2 * y + 1]
        row = [((lo >> (7 - x)) & 1) | (((hi >> (7 - x)) & 1) << 1) for x in range(8)]
        out.append(row[0] | (row[1] << 2) | (row[2] << 4) | (row[3] << 6))
        out.append(row[4] | (row[5] << 2) | (row[6] << 4) | (row[7] << 6))
open("build/gfx/w4_fire_8E52.svt", "wb").write(bytes(out))
print(f"extract_w4fire: 2 tiles ($E2/$E3) from ROM {OFF:#x} -> build/gfx/w4_fire_8E52.svt")
