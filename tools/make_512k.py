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
big = bytearray(img + b"\xFF" * (0x80000 - 0x40000 - 0x4000) + img[-0x4000:])
# PAGE 8 = the aux page (docs/42): the bank-1 (W3 resident) image, so the
# W3-flavour common prefix sits at its normal addresses, with the AUX blob
# pasted at $A620 over the (dead in this copy) level region.
import os
P8 = 8 * 0x8000
big[P8:P8 + 0x4000] = img[1 * 0x8000:1 * 0x8000 + 0x4000]   # bank 1 = page 1 low
# v2 (docs/42): the composer runs under page 8 and needs, at their NORMAL
# addresses, the prefix + bank-1 charset (bgc) -- the full bank-1 copy gives
# both -- plus the W3 sprite slice, mirrored from bank 6 $B740 over the
# bank-1 tail (scripts: never read during a draw), and its own code at $BB00.
B6 = 6 * 0x8000
# The bank-1 TAIL ($B540+) holds the W3 bg charset (bgc) -- it must stay
# intact. The level-header region $A5EE-$B53F is dead during a draw: the
# slice mirror goes to $A600 and the composer blob to $A9C0.
big[P8 + 0x2600:P8 + 0x2600 + 960] = img[B6 + 0x3740:B6 + 0x3740 + 960]   # slice mirror at $A600
aux = "build/w3aux.bin"
if os.path.exists(aux):
    blob = open(aux, "rb").read()
    assert len(blob) <= 0x0B80, "w3aux blob exceeds the AUX window ($A9C0-$B53F)"
    big[P8 + 0x29C0:P8 + 0x29C0 + len(blob)] = blob
assert len(big) == 0x80000
open(out, "wb").write(bytes(big))
print(f"wrote {out} (512K; page 8 = aux [bank-1 prefix + {os.path.getsize(aux) if os.path.exists(aux) else 0}B blob], 9-14 free)")
