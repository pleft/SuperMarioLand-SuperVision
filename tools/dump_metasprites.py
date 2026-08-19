#!/usr/bin/env python3
"""Decode the GB enemy metasprite display lists ($2FE2 right / $30B4 left,
param*2 -> [control byte, tile byte...] $FF-terminated; control bit3/2 = y-8/+8,
bit1/0 = x-8/+8, upper bits -> OAM attr; tile bytes have bit7 set) and render
each param as a PNG from a world's OBJ sheet. Gives the PORT its exact tile
list per animation frame without a live capture.

Usage: dump_metasprites.py <world> <param> [<param>...]
RULE 5: reads the user's ROM only as a build input; output is gitignored.
"""
import sys, os
from PIL import Image

ROM = open("super-mario-land-gb.gb", "rb").read()
RIGHT, LEFT = 0x2FE2, 0x30B4
OUT = "build/gfx/metasprites"
os.makedirs(OUT, exist_ok=True)

# world -> the ROM file offsets of the OBJ tile blocks the game loads at
# $8000 (base sheet) and $8A00 (per-world overlay). From extract_gfx.py.
WORLD_OBJ = {1: 0x4000 + 0x1000, 3: None}


def entries(base, param):
    """decode one display list -> [(dy, dx, attr, tile)]"""
    ptr = base + param * 2
    lp = ROM[ptr] | (ROM[ptr + 1] << 8)
    off = lp - 0x4000 + 0x4000 * 1 if lp >= 0x4000 else lp   # bank 0/1 flat
    out, dy, dx, attr = [], 0, 0, 0
    i = off
    guard = 0
    while guard < 64:
        guard += 1
        b = ROM[i]; i += 1
        if b == 0xFF:
            break
        if b & 0x80:                      # tile byte
            out.append((dy, dx, attr, b & 0x7F if False else b))
        else:                             # control byte
            dy += (-8 if b & 8 else 0) + (8 if b & 4 else 0)
            dx += (-8 if b & 2 else 0) + (8 if b & 1 else 0)
            attr = (b & 0xF0)
    return out


def main():
    params = [int(a, 16) for a in sys.argv[1:]]
    for p in params:
        for side, base in (("R", RIGHT), ("L", LEFT)):
            e = entries(base, p)
            print(f"param ${p:02X} {side}: {[(d[0], d[1], f'${d[3]:02X}', f'${d[2]:02X}') for d in e]}")


if __name__ == "__main__":
    main()
