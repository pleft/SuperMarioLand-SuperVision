#!/usr/bin/env python3
"""
Extract the TITLE SCREEN from the user's own ROM by booting it headless (PyBoy)
and dumping the rendered tilemap + the exact tile graphics from VRAM.
RULE 5: output goes to gitignored build/; nothing ROM-derived is committed.

Emits:
  build/levels/title_map.bin   -- 20x18 bytes, each = index into the packed tile set
  build/gfx/title_tiles.svt    -- the used tiles, SV-packed (16 bytes each)
"""
import os, sys
sys.path.insert(0, os.path.dirname(__file__))
from extract_gfx import sv_pack
from pyboy import PyBoy

ROM = os.path.join(os.path.dirname(__file__), "..", "super-mario-land-gb.gb")
OUT_L = os.path.join(os.path.dirname(__file__), "..", "build", "levels")
OUT_G = os.path.join(os.path.dirname(__file__), "..", "build", "gfx")

pb = PyBoy(ROM, window="null")
for _ in range(400):
    pb.tick()                        # sit on the title screen
m = pb.memory

lcdc = m[0xFF40]
signed_mode = not (lcdc & 0x10)      # LCDC.4=0 -> tiles at $8800 signed ($9000 base)

def tile_addr(idx):
    if signed_mode and idx < 0x80:
        return 0x9000 + idx * 16
    return 0x8000 + idx * 16

vmap = [[m[0x9800 + r * 32 + c] for c in range(20)] for r in range(18)]
used = sorted({t for row in vmap for t in row})
remap = {t: i for i, t in enumerate(used)}

tiles = []
for t in used:
    base = tile_addr(t)
    tile = []
    for row in range(8):
        lo, hi = m[base + row * 2], m[base + row * 2 + 1]
        tile.append([((lo >> (7 - x)) & 1) | (((hi >> (7 - x)) & 1) << 1) for x in range(8)])
    tiles.append(tile)
pb.stop()

os.makedirs(OUT_L, exist_ok=True); os.makedirs(OUT_G, exist_ok=True)
with open(os.path.join(OUT_L, "title_map.bin"), "wb") as f:
    for row in vmap:
        f.write(bytes(remap[t] for t in row))
with open(os.path.join(OUT_G, "title_tiles.svt"), "wb") as f:
    f.write(sv_pack(tiles))
print(f"title: {len(used)} tiles, 20x18 map (signed_mode={signed_mode})")
