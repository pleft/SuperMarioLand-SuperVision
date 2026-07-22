#!/usr/bin/env python3
"""
Pack level banks into the 128K Supervision image (post-link step).

The linker emits [BANK0][BANK1=fill][BANK2=fill][BANK3..6=fill][FIXED] (FIXED is
the LAST 16K: Potator maps $C000 from programRomSize-0x4000 whatever the size,
and the $8000 window = SYS_CTRL bits7:5 * 16K mod size). BANK0 = common prefix
(audio engine + data, BG charset, banked code, tables, title) followed by
level_hdr + World 1-2's data. This script rewrites the other banks as:

    [ common prefix (with per-WORLD data swaps) ][ level region ]

with the level header at a per-bank offset load_level can derive, so all prefix
symbols resolve identically whichever bank SYS_CTRL maps at $8000.

Header format must match src/leveldata.s / load_level (20 bytes):
    +0  .addr map    +2 .word cols   +4/+6/+8 .addr room0..2
    +10 .addr pipes  +12 .byte pipe_count
    +13 .addr blocks +15 .byte block_count   +16 .addr spawns
    +18 .addr quad-tile $A0-$DC base (chardata for W1; in-bank blob-$A00 for W2+)

World 2 banks (levels 3-5 -> banks 3-5), per docs/11 (GB SelectWorldBank $0D6D:
worlds 2-4 load ONLY two overlays over W1's base sheets):
  - prefix copy gets the W2 BG overlay (w2_ovl_9310.svt) patched over
    bg_chardata tiles $31-$6F, and the W2 music track written into the W1
    level-theme's byte-space (music_data+304, 511B: $08 Muda for 2-1/2-2,
    $05 Marine Pop for 2-3) with slot 0's list pointers repointed.
  - the region is [header(20)][level data][w2_ovl_8A00 blob (61 tiles)],
    header+18 = blob_addr - $A00 so quad tiles $A0-$DC hit the overlay.

RULE 5: reads only gitignored build artifacts; output is gitignored.
Usage: pack_banks.py <image.sv> <mapfile> <level:bank> [<level:bank> ...]
"""
import os, re, json, sys

BANK = 0x4000
BASE = 0x8000
NBANKS = 8                                  # 128K cart: banks 0-6 + FIXED (last)
HDR_SIZE = 20
W1_THEME_OFF = 304                          # track $07's offset in music_data
W1_THEME_SIZE = 511                         # its byte-space (the W2 donor slot)

def exports(mapf):
    """symbol -> value: map-file exports (imported ones only) merged with the
    -Ln label dump next to the map (ld65 omits un-imported exports from the map)."""
    sect = mapf.split("Exports list by name:")[1].split("Exports list by value:")[0]
    syms = {m.group(1): int(m.group(2), 16)
            for m in re.finditer(r"(\S+)\s+([0-9A-Fa-f]{6})\s+R", sect)}
    lbl = os.path.splitext(sys.argv[2])[0] + ".lbl"
    if os.path.exists(lbl):
        for line in open(lbl):
            p = line.split()               # "al 00A123 .music_data"
            if len(p) == 3 and p[0] == "al":
                syms.setdefault(p[2].lstrip("."), int(p[1], 16))
    return syms

def main():
    img_path, map_path = sys.argv[1], sys.argv[2]
    jobs = [tuple(int(x) for x in a.split(":")) for a in sys.argv[3:]]
    img = bytearray(open(img_path, "rb").read())
    assert len(img) == NBANKS * BANK, \
        f"pack_banks: image is {len(img)} bytes, expected {NBANKS * BANK} (128K) — " \
        "linker config out of sync (FIXED must be the LAST 16K of the file)"
    for level, bank in jobs:
        assert 0 <= bank < NBANKS - 1, f"level {level}: bank {bank} is not a switchable bank"
    mapf = open(map_path).read()
    sym = exports(mapf)
    chardata = sym["chardata"]
    # the L3CODE overlay (the 1-3 kit) is linked at BANK2's start; bank 2 is laid
    # out below as [prefix][L3 blob @ TITLE0][header][level data] — load_level
    # finds the header at TITLE0 + __L3CODE_SIZE__
    mm = re.search(r"L3CODE\s+[0-9A-Fa-f]{6}\s+[0-9A-Fa-f]{6}\s+([0-9A-Fa-f]{6})", mapf)
    l3 = bytes(img[2 * BANK:2 * BANK + int(mm.group(1), 16)]) if mm else b""
    # same scheme for bank 1: the L11CODE blob (the bonus game) precedes the header
    mm = re.search(r"L11CODE\s+[0-9A-Fa-f]{6}\s+[0-9A-Fa-f]{6}\s+([0-9A-Fa-f]{6})", mapf)
    l11 = bytes(img[1 * BANK:1 * BANK + int(mm.group(1), 16)]) if mm else b""
    # the x-3 ending blob follows L11CODE in bank 1 (copied to the RAM window at the wipe)
    mm = re.search(r"L13E\s+[0-9A-Fa-f]{6}\s+[0-9A-Fa-f]{6}\s+([0-9A-Fa-f]{6})", mapf)
    l11 += bytes(img[1 * BANK + len(l11):1 * BANK + len(l11) + int(mm.group(1), 16)]) if mm else b""
    # banks 1+ place their level region where bank 0 keeps the TITLE0 segment (the
    # title runs only with bank 0 mapped, so its range is free in every other bank)
    hdr_addr = sym["__TITLE0_LOAD__"]
    hdr_off = hdr_addr - BASE               # offset of the level region within banks 1+
    prefix = img[0:hdr_off]                 # bank 0's common prefix, byte-identical everywhere

    # --- W2 per-world data, loaded lazily (only if a W2 job is present) ---
    w2_prefix = None
    w2_ovl1 = None
    if any(level >= 3 for level, _ in jobs):
        w2_ovl1 = open("build/gfx/w2_ovl_8A00.svt", "rb").read()
        assert len(w2_ovl1) == 61 * 16, "w2_ovl_8A00.svt: expected 61 tiles"
        ovl2 = open("build/gfx/w2_ovl_9310.svt", "rb").read()
        assert len(ovl2) == 63 * 16, "w2_ovl_9310.svt: expected 63 tiles"
        w2_prefix = bytearray(prefix)
        bg_off = sym["bg_chardata"] - BASE
        w2_prefix[bg_off + 0x31 * 16: bg_off + 0x31 * 16 + len(ovl2)] = ovl2
        w2music = json.load(open("build/audio/w2music.json"))

    def w2_bank_prefix(track):
        """the W2 prefix with `track` ('08'/'05') in the W1-theme slot."""
        p = bytearray(w2_prefix)
        blob = open(f"build/audio/w2_t{track}.bin", "rb").read()
        meta = w2music[track]
        assert len(blob) <= W1_THEME_SIZE, f"track ${track} won't fit the theme slot"
        moff = sym["music_data"] - BASE + W1_THEME_OFF
        p[moff:moff + len(blob)] = blob
        for i, l in enumerate(meta["lists"]):     # slot 0 = MUS_LEVEL: repoint its lists
            v = l + 512                            # list offsets carry the +512 bias
            p[sym[f"mus_l{i+1}_lo"] - BASE] = v & 0xFF
            p[sym[f"mus_l{i+1}_hi"] - BASE] = v >> 8
        assert meta["lt"] == 512, "unexpected length-table offset (slot patch too small)"
        return p

    for level, bank in jobs:
        pre = prefix
        preblob = l3 if bank == 2 else l11 if bank == 1 else b""
        if level >= 3:
            pre = w2_bank_prefix("05" if level == 5 else "08")
        lvl_hdr_addr = hdr_addr + len(preblob)
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

        # lay out: header, then map, rooms, pipes, blocks, spawns [, W2 quad overlay]
        addr = lvl_hdr_addr + HDR_SIZE
        place = {}
        for key, data in [("map", blobs["map"]), ("room0", rooms[0]), ("room1", rooms[1]),
                          ("room2", rooms[2]), ("pipes", blobs["pipes"]),
                          ("blocks", blobs["blocks"]), ("spawns", blobs["spawns"])]:
            place[key] = addr if data else 0
            addr += len(data)
        if level >= 3:
            quad_base = addr - 0xA00            # blob serves quad tiles $A0-$DC
            ovl_at = addr
            addr += len(w2_ovl1)
        else:
            quad_base = chardata
        assert addr <= BASE + BANK, f"level {level}: data overflows the bank by {addr - BASE - BANK} bytes"

        cols = len(blobs["map"]) // 16
        hdr = bytearray()
        for v in (place["map"], cols, place["room0"], place["room1"], place["room2"], place["pipes"]):
            hdr += bytes((v & 0xFF, v >> 8))
        hdr.append(len(blobs["pipes"]) // 5)
        hdr += bytes((place["blocks"] & 0xFF, place["blocks"] >> 8))
        hdr.append(len(blobs["blocks"]) // 4)
        hdr += bytes((place["spawns"] & 0xFF, place["spawns"] >> 8))
        hdr += bytes((quad_base & 0xFF, quad_base >> 8))
        assert len(hdr) == HDR_SIZE

        region = hdr + blobs["map"] + rooms[0] + rooms[1] + rooms[2] \
                     + blobs["pipes"] + blobs["blocks"] + blobs["spawns"]
        if level >= 3:
            region += w2_ovl1
        region = preblob + region
        bank_img = pre + region
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
