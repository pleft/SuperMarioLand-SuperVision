#!/usr/bin/env python3
"""make_512k -- expand the 256K MAGNUM image to the 512K layout (docs/42).

$2021 is 4 bits = 16 x 32K pages; the 256K image only reaches pages 0-7. The
512K file keeps pages 0-7 byte-identical, leaves pages 8-14 blank ($FF) for
the aux content (the composite renderer's home), and places FIXED as the last
16K of the file (the core maps upperRomBank = end-16K; the old copy at the end
of page 7 stays where it was -- reachable only via SYS_CTRL bit5, which
banking never touches).

    python3 tools/make_512k.py [in.sv] [out.sv]

REAL-HW GATE: do not ship as the default image until the SuperPico firmware
is confirmed to accept a 512K UF2 and $2021 values 8-15 (docs/42).
"""
import sys
src = sys.argv[1] if len(sys.argv) > 1 else "build/super-mario-land.sv"
out = sys.argv[2] if len(sys.argv) > 2 else "build/super-mario-land-512k.sv"
img = open(src, "rb").read()
assert len(img) == 0x40000, f"{src}: expected 256K"
big = img + b"\xFF" * (0x80000 - 0x40000 - 0x4000) + img[-0x4000:]
assert len(big) == 0x80000
open(out, "wb").write(big)
print(f"wrote {out} (512K; pages 8-14 free, FIXED mirrored at the tail)")
