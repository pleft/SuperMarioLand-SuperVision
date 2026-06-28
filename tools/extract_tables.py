#!/usr/bin/env python3
"""
Extract game physics/data tables from the user's own ROM (rule 5 — these are
ROM-derived, so they ship as build artifacts, never committed).

  jumparc.bin  : Mario's jump/gravity arc, 27 bytes @ $216D (per-frame |dY|; $7F = apex).
                 See docs/08-player.md.

Usage: python3 tools/extract_tables.py [rom] [--out build/data]
"""
import sys, os, hashlib

EXPECT_SHA1 = "418203621b887caa090215d97e3f509b79affd3e"
JUMPARC_ADDR = 0x216D     # bank 0 (file offset == addr)
JUMPARC_LEN  = 27
SPEEDTAB_ADDR = 0x1ECE    # horizontal walk speed table (px/frame), indexed by $C20E+toggle
SPEEDTAB_LEN  = 6

def main():
    rom = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "super-mario-land-gb.gb"
    out = "build/data"
    if "--out" in sys.argv:
        out = sys.argv[sys.argv.index("--out") + 1]
    d = open(rom, "rb").read()
    if hashlib.sha1(d).hexdigest() != EXPECT_SHA1:
        print("WARNING: ROM SHA1 mismatch")
    os.makedirs(out, exist_ok=True)
    arc = d[JUMPARC_ADDR:JUMPARC_ADDR + JUMPARC_LEN]
    with open(os.path.join(out, "jumparc.bin"), "wb") as f:
        f.write(arc)
    print(f"jumparc.bin: {len(arc)} bytes -> {out}/  ({' '.join(f'{b:02X}' for b in arc)})")
    spd = d[SPEEDTAB_ADDR:SPEEDTAB_ADDR + SPEEDTAB_LEN]
    with open(os.path.join(out, "speedtab.bin"), "wb") as f:
        f.write(spd)
    print(f"speedtab.bin: {len(spd)} bytes -> {out}/  ({' '.join(f'{b:02X}' for b in spd)})")

if __name__ == "__main__":
    main()
