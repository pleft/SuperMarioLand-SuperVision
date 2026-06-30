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

# Mario metasprite poses. The metasprite pointer table is at bank 3 $4C37 (idx*2 ->
# 4-byte struct; struct[0:2] = tile-data ptr). Each tile-data entry is
# [oam-list ptr:2][4 tile numbers][$FF]. We take the 4 tile numbers for the 4 poses the
# port uses, in its order: stand, walkA, walkB, jump = metasprite indices 0, 3, 1, 4.
META_TABLE   = 0x4C37     # bank 3
POSE_INDICES = [0, 3, 1, 4]
# Big ("Super") Mario uses a parallel pose set (same 16x16 metasprite shape, +$20 tile
# offset, filling the full cell vs small Mario's ~12px). Same order as small, plus a duck:
# stand, walkA, walkB, jump, duck = metasprite indices 16, 19, 17, 20, 24 (idx 24 = the
# real big-Mario crouch, tiles $40-$43; verified by rendering vs the original).
BIG_POSE_INDICES = [16, 19, 17, 20, 24]

# Status-bar template: 2 rows x 20 tiles at bank 0 $3F9C (the HUD-init at $060F copies it
# to BG map $9800). Static labels + zero/blank placeholders for the dynamic values.
STATUSBAR_ADDR = 0x3F9C   # bank 0 (file offset == addr)
STATUSBAR_LEN  = 40

def bank_off(bank, addr): return bank * 0x4000 + (addr - 0x4000)
def u16(d, o):            return d[o] | (d[o + 1] << 8)

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

    poses = bytearray()
    for idx in POSE_INDICES:
        struct_ptr = u16(d, bank_off(3, META_TABLE) + idx * 2)
        tiledata   = u16(d, bank_off(3, struct_ptr))      # struct[0:2] = tile-data ptr
        tdo        = bank_off(3, tiledata)
        poses += d[tdo + 2:tdo + 6]                        # 4 tiles after the oam-list ptr
    with open(os.path.join(out, "mario_poses.bin"), "wb") as f:
        f.write(poses)
    print(f"mario_poses.bin: {len(poses)} bytes -> {out}/  ({' '.join(f'{b:02X}' for b in poses)})")

    big = bytearray()
    for idx in BIG_POSE_INDICES:
        struct_ptr = u16(d, bank_off(3, META_TABLE) + idx * 2)
        tiledata   = u16(d, bank_off(3, struct_ptr))
        tdo        = bank_off(3, tiledata)
        big += d[tdo + 2:tdo + 6]
    with open(os.path.join(out, "mario_big_poses.bin"), "wb") as f:
        f.write(big)
    print(f"mario_big_poses.bin: {len(big)} bytes -> {out}/  ({' '.join(f'{b:02X}' for b in big)})")

    sb = d[STATUSBAR_ADDR:STATUSBAR_ADDR + STATUSBAR_LEN]
    with open(os.path.join(out, "statusbar.bin"), "wb") as f:
        f.write(sb)
    print(f"statusbar.bin: {len(sb)} bytes -> {out}/  ({' '.join(f'{b:02X}' for b in sb)})")

if __name__ == "__main__":
    main()
