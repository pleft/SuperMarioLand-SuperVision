#!/usr/bin/env python3
"""
Pack level banks into the 64K Supervision image (post-link step).

The linker emits [BANK0][BANK1=fill][BANK2=fill][FIXED]. BANK0 = common prefix
(audio engine + data, BG charset, banked code, tables, title) followed by
level_hdr + World 1-1's data. This script rewrites BANK1/BANK2 as:

    [ identical common prefix ][ level_hdr' + level N data ]

with the header at the SAME offset as bank 0's level_hdr, so all prefix symbols
and level_hdr resolve identically whichever bank SYS_CTRL maps at $8000.
Header format must match src/leveldata.s / load_level (18 bytes):

    +0  .addr map    +2 .word cols   +4/+6/+8 .addr room0..2
    +10 .addr pipes  +12 .byte pipe_count
    +13 .addr blocks +15 .byte block_count   +16 .addr spawns

RULE 5: reads only gitignored build artifacts; output is gitignored.
Usage: pack_banks.py <image.sv> <mapfile> <level:bank> [<level:bank> ...]
"""
import os, re, sys

BANK = 0x4000
BASE = 0x8000

def main():
    img_path, map_path = sys.argv[1], sys.argv[2]
    jobs = [tuple(int(x) for x in a.split(":")) for a in sys.argv[3:]]
    img = bytearray(open(img_path, "rb").read())
    # the L3CODE overlay (the 1-3 kit) is linked at BANK2's start; bank 2 is laid
    # out below as [prefix][L3 blob @ TITLE0][header][level data] — load_level
    # finds the header at TITLE0 + __L3CODE_SIZE__
    mm = re.search(r"L3CODE\s+[0-9A-Fa-f]{6}\s+[0-9A-Fa-f]{6}\s+([0-9A-Fa-f]{6})",
                   open(map_path).read())
    l3 = bytes(img[2 * BANK:2 * BANK + int(mm.group(1), 16)]) if mm else b""
    # banks 1+ place their level region where bank 0 keeps the TITLE0 segment (the
    # title runs only with bank 0 mapped, so its range is free in every other bank)
    m = re.search(r"TITLE0\s+([0-9A-Fa-f]{6})", open(map_path).read())
    if not m:
        sys.exit("pack_banks: TITLE0 segment not found in the map file")
    hdr_addr = int(m.group(1), 16)
    hdr_off = hdr_addr - BASE               # offset of the level region within banks 1+
    prefix = img[0:hdr_off]                 # bank 0's common prefix, byte-identical everywhere

    for level, bank in jobs:
        lvl_hdr_addr = hdr_addr + (len(l3) if bank == 2 else 0)
        lv = f"build/levels/level_{level:02d}"
        blobs = {}
        for key, suffix in (("map", ".bin"), ("pipes", "_pipes.bin"),
                            ("blocks", "_blocks.bin"), ("spawns", "_spawns.bin")):
            blobs[key] = open(lv + suffix, "rb").read()
        rooms = []
        for r in range(3):
            p = f"{lv}_room{r}.bin"
            rooms.append(open(p, "rb").read() if os.path.exists(p) else b"")

        assert len(blobs["pipes"]) <= 15,  f"level {level}: >3 pipes"
        assert len(blobs["blocks"]) <= 40, f"level {level}: >10 ?-blocks"
        assert len(blobs["spawns"]) <= 256, f"level {level}: spawn list > 256 bytes"
        assert len(blobs["map"]) % 16 == 0

        # lay out: header, then map, rooms, pipes, blocks, spawns
        addr = lvl_hdr_addr + 18
        place = {}
        for key, data in [("map", blobs["map"]), ("room0", rooms[0]), ("room1", rooms[1]),
                          ("room2", rooms[2]), ("pipes", blobs["pipes"]),
                          ("blocks", blobs["blocks"]), ("spawns", blobs["spawns"])]:
            place[key] = addr if data else 0
            addr += len(data)
        assert addr <= BASE + BANK, f"level {level}: data overflows the bank by {addr - BASE - BANK} bytes"

        cols = len(blobs["map"]) // 16
        hdr = bytearray()
        for v in (place["map"], cols, place["room0"], place["room1"], place["room2"], place["pipes"]):
            hdr += bytes((v & 0xFF, v >> 8))
        hdr.append(len(blobs["pipes"]) // 5)
        hdr += bytes((place["blocks"] & 0xFF, place["blocks"] >> 8))
        hdr.append(len(blobs["blocks"]) // 4)
        hdr += bytes((place["spawns"] & 0xFF, place["spawns"] >> 8))
        assert len(hdr) == 18

        region = hdr + blobs["map"] + rooms[0] + rooms[1] + rooms[2] \
                     + blobs["pipes"] + blobs["blocks"] + blobs["spawns"]
        if bank == 2:
            region = l3 + region
        bank_img = prefix + region
        assert len(bank_img) <= BANK, \
            f"level {level}: bank {bank} overflows by {len(bank_img) - BANK} bytes"
        bank_img += b"\xFF" * (BANK - len(bank_img))
        img[bank * BANK:(bank + 1) * BANK] = bank_img
        print(f"pack_banks: level {level} -> bank {bank} "
              f"({cols} cols, {len(region)} bytes at ${hdr_addr:04X}, "
              f"{BANK - hdr_off - len(region)} free)")

    open(img_path, "wb").write(bytes(img))

if __name__ == "__main__":
    main()
