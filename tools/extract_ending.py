#!/usr/bin/env python3
"""extract_ending -- the 38 sprite tiles of the GAME ENDING (docs/46: Mario and
Daisy in the room, the kiss poses, the heart, the Sky Pop with both riders, the
clouds) from the user's ROM, repacked into Supervision linear 2bpp for the E43
ending blob. RULE 5: reads the ROM at build time; nothing derived is committed.
Offsets were located once by matching the GB's ending VRAM (OAM capture,
docs/46) back into the ROM; tile $2C is blank in VRAM and is emitted as zeros.
    python3 tools/extract_ending.py [rom] [--out build/gfx]
Writes build/gfx/ending.svt (38 tiles, 16 B each, in GB-id order) and
build/ending_map.inc (E43T_xx = slot for each GB tile id)."""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from extract_gfx import decode_tiles, sv_pack
OFFS = {0x0e:0x8112,0x1e:0x8212,0x20:0x8232,0x21:0x8242,0x24:0x8272,0x25:0x8282,0x26:0x8292,0x27:0x82a2,
        0x2c:None,0x2d:0x8302,0x2e:0x8312,0x2f:0x8322,0x30:0x8332,0x31:0x8342,0x34:0x8372,0x35:0x8382,
        0x3c:0x83f2,0x3d:0x8402,0x3e:0x8412,0x3f:0x8422,0x48:0x84b2,0x49:0x84c2,0x4a:0x84d2,0x4b:0x84e2,
        0x4c:0x84f2,0x4d:0x8502,0x4e:0x8512,0x4f:0x8522,0x50:0x8532,0x51:0x8542,0x61:0x4512,0x6f:0x4522,
        0x7b:0x4532,0x7c:0x4542,0x7d:0x4552,0x7e:0x4562,0x7f:0x4572,0x84:0x8872}
def main():
    rom = "super-mario-land-gb.gb"; out = "build/gfx"
    a = sys.argv[1:]
    if a and not a[0].startswith("--"): rom = a.pop(0)
    if "--out" in a: out = a[a.index("--out") + 1]
    d = open(rom, "rb").read()
    tiles = []; inc = []
    for slot, (gid, off) in enumerate(sorted(OFFS.items())):
        if off is None: tiles.append([[0]*8 for _ in range(8)])
        else: tiles.append(decode_tiles(d, off, 1)[0])
        inc.append(f"E43T_{gid:02X} = {slot}")
    os.makedirs(out, exist_ok=True)
    open(os.path.join(out, "ending.svt"), "wb").write(sv_pack(tiles))
    open("build/ending_map.inc", "w").write("; GB ending sprite tile id -> slot in build/gfx/ending.svt (tools/extract_ending.py)\n" + "\n".join(inc) + "\n")
    print(f"extract_ending: {len(tiles)} tiles -> {out}/ending.svt, build/ending_map.inc")
main()
