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
HDR_SIZE = 24                               # +22/23 = bg charset base (docs/33)
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

def dedup_maps(maps, base):
    """Unique-column pool format (docs/33): each map becomes a 2-bytes-per-
    column table of ABSOLUTE column addresses; the pool holds every distinct
    16-byte column once, shared across the given maps (surface + rooms).
    `base` = the address where the first table will be placed. Returns
    (tables, pool); the pool follows the tables contiguously."""
    ncols = [len(m) // 16 for m in maps]
    pool_at = base + sum(n * 2 for n in ncols)
    pool = bytearray()
    index = {}
    tabs = []
    for m, n in zip(maps, ncols):
        t = bytearray()
        for c in range(n):
            col = bytes(m[c * 16:(c + 1) * 16])
            if col not in index:
                index[col] = pool_at + len(pool)
                pool += col
            a = index[col]
            t += bytes((a & 0xFF, a >> 8))
        tabs.append(bytes(t))
    # decode-back byte-assert: the packed form must reproduce the raw maps
    for m, t, n in zip(maps, tabs, ncols):
        for c in range(n):
            a = t[c * 2] | (t[c * 2 + 1] << 8)
            off = a - pool_at
            assert bytes(pool[off:off + 16]) == bytes(m[c * 16:(c + 1) * 16]), \
                "dedup decode mismatch"
    return tabs, bytes(pool)

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

    win23_img = None
    carve23 = b""
    spawns23 = b""
    w3_jobs = [j for j in jobs if j[0] >= 6]
    jobs = [j for j in jobs if j[0] < 6]
    for level, bank in jobs:
        pre = prefix
        preblob = l3 if bank == 2 else l11 if bank == 1 else b""
        if level >= 3:
            pre = w2_bank_prefix("05" if level == 5 else "08")

        lvl_hdr_addr = hdr_addr + len(preblob)
        lv = f"build/levels/level_{level:02d}"
        blobs = {}  # BISECT-EXPERIMENT truncation below
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

        if level == 5:
            rooms = [b"", b"", b""]      # 2-3 has no pipes: the extractor's "rooms"
                                         # are lead-in artifacts -- reclaim the bank
        # lay out: header, then map, rooms, pipes, blocks, spawns [, W2 quad overlay]
        addr = lvl_hdr_addr + HDR_SIZE
        far23 = b""
        if level == 5:
            # the far kit is BANK-RESIDENT at a fixed $A260 (cfg W2FARM):
            # place it FIRST so the level data starts after it
            m23 = open("build/w2code23.map").read()
            w2c_sz = int(re.search(r"^W2C\s+\S+\s+\S+\s+([0-9A-F]+)", m23, re.M).group(1), 16)
            far_m = re.search(r"^W2FAR\s+([0-9A-F]+)\s+\S+\s+([0-9A-F]+)", m23, re.M)
            far_at, far_sz = int(far_m.group(1), 16), int(far_m.group(2), 16)
            fv_m = None  # the BG-tile carve is DEAD: the HUD font lives in "unused" bg tiles
            fv_at, fv_sz = (int(fv_m.group(1), 16), int(fv_m.group(2), 16)) if fv_m else (0, 0)
            full23 = open("build/w2code23.bin", "rb").read()
            win23_img = full23[:w2c_sz]
            assert len(win23_img) <= 0x800, "2-3 window kit exceeds the $800 window"
            far23 = full23[w2c_sz:w2c_sz + far_sz]
            carve23 = full23[w2c_sz + far_sz:w2c_sz + far_sz + fv_sz]
            assert far_at == 0xA2C0, "W2FARM moved -- update pack_banks"
            if fv_sz:
                # the carve = bank5 chardata tiles $20-$4F (Mario poses; he
                # never draws in the sub level). Guard the address drift.
                assert fv_at == sym["bg_chardata"], \
                    f"W2CARV != bg_chardata (${sym['bg_chardata']:04X}) -- update cfg/w2code.cfg"
                assert fv_sz <= 0x2C0, "carve kit exceeds BG tiles $00-$2B"
                lvl5 = open("build/levels/level_05.bin", "rb").read()
                hot = set(b for b in lvl5 if b < 0x2C)
                assert not hot, f"2-3 map uses carved BG tiles: {sorted(hot)}"
            assert addr <= far_at, "level 5 header overlaps the far kit"
            addr = far_at + len(far23)
            # (the spawn list used to ride bank 6 behind a loader stub: bank 5
            # had no room for the kit before maps were column-deduped. It does
            # now, so 2-3 loads like every other level -- no stub, no detour.)
            if carve23:
                pre = bytearray(pre)
                co = sym["bg_chardata"] - BASE
                assert co + len(carve23) <= len(pre)
                pre[co:co + len(carve23)] = carve23
                pre = bytes(pre)
        place = {}
        maps = [blobs["map"], rooms[0], rooms[1], rooms[2]]
        tabs, pool = dedup_maps(maps, addr)
        for key, raw, tab in zip(("map", "room0", "room1", "room2"), maps, tabs):
            place[key] = addr if raw else 0
            addr += len(tab)
        addr += len(pool)
        for key in ("pipes", "blocks", "spawns"):
            place[key] = addr if blobs[key] else 0
            addr += len(blobs[key])
        w2blob = b""
        if level >= 3:
            # per-world quad tiles $A0-$DC: ship only the slice current enemies
            # use. THIS iteration's W2 kit (suu/rock/lift) draws COMMON tiles
            # only -> no slice; when Honen/the leaper land, set their range.
            # COMPACT slice: only the tiles the W2 kit draws, remapped to the
            # contiguous PORT ids $A4-$AF (ids are port-internal; w2code.s's
            # LEAP_TA/HON_TA must match this order):
            #   $A4-$A7 leaper frame A (GB A4,A5,B4,B5)
            #   $A8-$AB leaper frame B (GB A6,A7,B6,B7)
            #   $AC/$AD honen frame A top/bottom (GB C0,D0)
            #   $AE/$AF honen frame B top/bottom (GB C1,D1)
            W2_TILES = [0xA4,0xA5,0xB4,0xB5, 0xA6,0xA7,0xB6,0xB7,
                        0xC0,0xD0, 0xC1,0xD1]
            if level == 4:
                # 2-2 only: Yurarin $16 -- port ids $B0.. (w2code YUR_TA):
                #   $B0-$B3 swim frame A (GB C4,C5,D4,D5)
                #   $B4-$B7 swim frame B (GB C6,C7,D6,D7; child = C6,C7)
                #   $B8-$B9 squash/corpse (GB D8,D9)
                W2_TILES += [0xC4,0xC5,0xD4,0xD5, 0xC6,0xC7,0xD6,0xD7,
                             0xD8,0xD9]
            if level == 5:
                # 2-3 Marine Pop (kit_mar23.inc port ids $B0..):
                #   $B0-$B7 gunion quads A/B (GB a0,a1,b0,b1 / a2,a3,b2,b3)
                #   $B8-$BB seahorse pairs A/B (GB a8,a9 / b8,b9)
                #   $BC-$BD tamao pair (GB aa,ab)
                #   $BE-$CD dragon 16x32 frames A/B (upper+lower halves)
                # tamao ships PRE-MIRRORED (TL,TR,BL,BR for draw_16q;
                # a negative id = x-mirror the tile in python)
                W2_TILES += [0xA0,0xA1,0xB0,0xB1,
                             0xA8,0xA9, 0xB8,0xB9,
                             0xAA,-0xAA, 0xAB,-0xAB,
                             0xAE,0xAF,0xBE,0xBF, 0xCE,0xCF,0xBC,0xBD]
            OVL_LO = 0xA4
            def _mir(td):
                # SV 2bpp: 2 bytes/row, 4 px/byte -> mirror = swap bytes +
                # reverse the 2-bit groups within each
                out = bytearray()
                for r in range(8):
                    def rev(b):
                        return ((b & 3) << 6) | ((b >> 2 & 3) << 4) | ((b >> 4 & 3) << 2) | (b >> 6 & 3)
                    out += bytes((rev(td[r*2+1]), rev(td[r*2])))
                return bytes(out)
            def _tile(t):
                td = w2_ovl1[(abs(t)-0xA0)*16:(abs(t)-0xA0+1)*16]
                return _mir(td) if t < 0 else td
            sl = b"".join(_tile(t) for t in W2_TILES)
            assert len(sl) == len(W2_TILES)*16
            quad_base = addr - OVL_LO*16
            addr += len(sl)
            if False:
                quad_base = chardata            # $A0-$DC unused by this build
            if level == 5:
                w2blob = win23_img          # the kit itself, in its own bank
            else:
                w2blob = open("build/w2code22.bin" if level == 4 else
                              "build/w2code.bin", "rb").read()
            assert len(w2blob) <= 0x800, "w2code blob exceeds the $1500 window"
            ovl_code_at = addr                  # the W2 kit overlay (header +20/21)
            addr += len(w2blob)
        else:
            quad_base = chardata
            ovl_code_at = 0
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
        hdr += bytes((ovl_code_at & 0xFF, ovl_code_at >> 8))
        bgc = sym["bg_chardata"]                # W1/W2: the prefix charset
        hdr += bytes((bgc & 0xFF, bgc >> 8))
        assert len(hdr) == HDR_SIZE

        region = hdr
        if level == 5:
            region += b"\xFF" * (0xA2C0 - (lvl_hdr_addr + HDR_SIZE)) + far23
        region += b"".join(tabs) + pool \
                     + blobs["pipes"] + blobs["blocks"] + blobs["spawns"]
        if level >= 3:
            region += sl + w2blob
        region = preblob + region
        bank_img = pre + region
        assert len(bank_img) <= BANK, \
            f"level {level}: bank {bank} overflows by {len(bank_img) - BANK} bytes"
        bank_img += b"\xFF" * (BANK - len(bank_img))
        # final-image decode assert: every map read back from the BANK IMAGE
        # must equal the raw extract (assert the CONTENT landed, not the build)
        for key, raw in zip(("map", "room0", "room1", "room2"), maps):
            if not raw:
                continue
            ta = place[key] - BASE
            for c in range(len(raw) // 16):
                a = bank_img[ta + c * 2] | (bank_img[ta + c * 2 + 1] << 8)
                assert bytes(bank_img[a - BASE:a - BASE + 16]) == bytes(raw[c * 16:(c + 1) * 16]), \
                    f"level {level} {key} col {c}: image decode mismatch"
        img[bank * BANK:(bank + 1) * BANK] = bank_img
        print(f"pack_banks: level {level} -> bank {bank} "
              f"({cols} cols, {len(region)} bytes at ${hdr_addr:04X}, "
              f"{BANK - hdr_off - len(region)} free)")

    if win23_img is not None:
        # the rescue creature sheet: pinned in BANK 5's tail (2-3's own bank);
        # the L13E room machine copies it over the moth tiles (main.s @pdone)
        creat = open("build/gfx/creature23.svt", "rb").read()
        assert len(creat) == 128, "creature23.svt must be 8 tiles (128B)"
        coff = 5 * BANK + 0xBF00 - BASE
        assert all(b == 0xFF for b in img[coff:coff + 128]), \
            "bank 5 $BF00 not free for the creature sheet"
        img[coff:coff + 128] = creat
        print(f"pack_banks: 2-3 kit in its own bank; creature (128B) -> bank 5 $BF00")
    if w3_jobs:
        pack_w3(img, sym)
    open(img_path, "wb").write(bytes(img))

W3HDR = 0xB540                                  # main.s W3HDR (load_level pin)
W3WIN = 0xA800                                  # bank 6: kit window image (w3stub pin)
W3SPT = 0xA7C0                                  # bank 6: 3x .addr spawn lists (w3stub pin)

def pack_w3(img, sym):
    """World 3 (docs/33): levels 6-8 are RESIDENT on bank 1 -- headers, pipes,
    blocks, the stub and a W3-patched full bg charset live in its tail (from
    W3HDR) -- while the cold data (map pools/tables, the 2 shared room grids,
    spawn lists, the kit window image) lives in BANK 6, reached only through
    the stub at load and the window map reader at play."""
    BNK6 = 6 * BANK
    # --- bank 6 cold data: maps + rooms + spawns + kit image ---
    surfs, rooms_raw, spawns = [], {}, []
    room_ids = []
    import hashlib
    for lv in (6, 7, 8):
        p = f"build/levels/level_{lv:02d}"
        surfs.append(open(p + ".bin", "rb").read())
        spawns.append(open(p + "_spawns.bin", "rb").read())
        ids = []
        for r in range(3):
            d = open(f"{p}_room{r}.bin", "rb").read()
            h = hashlib.md5(d).hexdigest()
            rooms_raw.setdefault(h, d)
            ids.append(h)
        room_ids.append(ids)
    grids = list(rooms_raw)                     # unique room grids (2 for W3)
    maps = surfs + [rooms_raw[h] for h in grids]
    addr = BASE + 0x400                         # past the boot-staged RCODE/BOOT6
                                                # images at bank 6 $8000-$83CB
    tabs, pool = dedup_maps(maps, addr)
    tab_at = []
    for t in tabs:
        tab_at.append(addr)
        addr += len(t)
    addr += len(pool)
    spawn_at = []
    for sp in spawns:
        assert len(sp) <= 256, "W3 spawn list exceeds the stub copy"
        spawn_at.append(addr)
        addr += len(sp)
    assert addr <= W3SPT, f"W3 cold data overruns ${W3SPT:04X} by {addr - W3SPT}"
    cold = b"".join(tabs) + pool + b"".join(spawns)
    assert all(b == 0xFF for b in img[BNK6 + 0x400:BNK6 + 0x400 + len(cold)]), "bank 6 head not free"
    img[BNK6 + 0x400:BNK6 + 0x400 + len(cold)] = cold
    spt = b"".join(bytes((a & 0xFF, a >> 8)) for a in spawn_at)
    assert all(b == 0xFF for b in img[BNK6 + W3SPT - BASE:BNK6 + W3WIN - BASE]), \
        "bank 6 spawn-table slot not free"
    img[BNK6 + W3SPT - BASE:BNK6 + W3SPT - BASE + len(spt)] = spt
    # scripts / display lists / the compact tile slice, at the kit's pins
    for pin, path in ((0xB000, "build/w3scripts.bin"), (0xB520, "build/w3dlists.bin")):
        d = open(path, "rb").read()
        off = BNK6 + pin - BASE
        assert all(b == 0xFF for b in img[off:off + len(d)]), f"bank 6 ${pin:04X} busy"
        img[off:off + len(d)] = d
    ovl = open("build/gfx/w3_ovl_8A00.svt", "rb").read()
    order = [int(t, 16) for t in open("build/w3tiles.txt").read().split()]
    slice_ = b"".join(ovl[(t - 0xA0) * 16:(t - 0xA0 + 1) * 16] for t in order)
    off = BNK6 + 0xB780 - BASE
    assert all(b == 0xFF for b in img[off:off + len(slice_)]), "bank 6 $B780 busy"
    img[off:off + len(slice_)] = slice_
    full3 = open("build/w3code.bin", "rb").read()
    m3 = open("build/w3code.map").read()
    w3c_sz = int(re.search(r"^W2C\s+\S+\s+\S+\s+([0-9A-F]+)", m3, re.M).group(1), 16)
    fm = re.search(r"^W2FAR\s+([0-9A-F]+)\s+\S+\s+([0-9A-F]+)", m3, re.M)
    far3_at, far3 = (int(fm.group(1), 16), full3[w3c_sz:w3c_sz + int(fm.group(2), 16)]) if fm else (0, b"")
    win = full3[:w3c_sz]
    assert len(win) <= 0x800, "W3 kit exceeds the $800 window"
    assert all(b == 0xFF for b in img[BNK6 + W3WIN - BASE:BNK6 + W3WIN - BASE + 0x800]), \
        "bank 6 $A400 window slot not free"
    img[BNK6 + W3WIN - BASE:BNK6 + W3WIN - BASE + len(win)] = win

    # --- bank 1 tail: headers, pipes/blocks, sentinel, stub, bg charset ---
    tail = bytearray()
    t_at = lambda: W3HDR + len(tail)
    tail += b"\x00" * (3 * HDR_SIZE)           # headers written below
    pieces = {}
    for i, lv in enumerate((6, 7, 8)):
        p = f"build/levels/level_{lv:02d}"
        for key, suf, per in (("pipes", "_pipes.bin", 5), ("blocks", "_blocks.bin", 4)):
            d = open(p + suf, "rb").read()
            pieces[(i, key)] = (t_at() if d else 0, len(d) // per)
            tail += d
    sent_at = t_at()
    tail += b"\xFF\xFF"                        # the header spawn sentinel
    stub = open("build/w3stub.bin", "rb").read()
    stub_at = t_at()
    tail += stub
    # W3 bg charset: the full prefix charset with the W3 overlay over $31-$6F
    bgc_at = t_at()
    bg_off = sym["bg_chardata"] - BASE
    bgset = bytearray(img[1 * BANK + bg_off:1 * BANK + bg_off + 0x800])
    ovl = open("build/gfx/w3_ovl_9310.svt", "rb").read()
    assert len(ovl) == 63 * 16, "w3_ovl_9310.svt: expected 63 tiles"
    bgset[0x31 * 16:0x31 * 16 + len(ovl)] = ovl
    tail += bgset
    assert W3HDR + len(tail) <= BASE + BANK, \
        f"W3 bank-1 tail overflows by {W3HDR + len(tail) - BASE - BANK}"
    for i, lv in enumerate((6, 7, 8)):
        cols = len(surfs[i]) // 16
        r = [tab_at[3 + grids.index(h)] for h in room_ids[i]]
        hdr = bytearray()
        for v in (tab_at[i], cols, r[0], r[1], r[2], pieces[(i, "pipes")][0]):
            hdr += bytes((v & 0xFF, v >> 8))
        hdr.append(pieces[(i, "pipes")][1])
        hdr += bytes((pieces[(i, "blocks")][0] & 0xFF, pieces[(i, "blocks")][0] >> 8))
        hdr.append(pieces[(i, "blocks")][1])
        quad_base = 0xB780 - 0xA0 * 16          # port ids $A0.. -> the slice
        for v in (sent_at, quad_base, stub_at, bgc_at):
            hdr += bytes((v & 0xFF, v >> 8))
        assert len(hdr) == HDR_SIZE
        tail[i * HDR_SIZE:(i + 1) * HDR_SIZE] = hdr
    toff = 1 * BANK + (W3HDR - BASE)
    assert all(b == 0xFF for b in img[toff:toff + len(tail)]), \
        "bank 1 tail not free for W3 (1-1 region grew past W3HDR?)"
    img[toff:toff + len(tail)] = tail
    if far3:
        assert far3_at == 0xBE40, "W3FAR moved -- update pack_banks"
        foff = 1 * BANK + far3_at - BASE
        assert all(b == 0xFF for b in img[foff:foff + len(far3)]), \
            f"bank 1 ${far3_at:04X} not free for the W3 far kit"
        img[foff:foff + len(far3)] = far3
    print(f"pack_banks: W3 far kit {len(far3)}B at $BE40")
    print(f"pack_banks: W3 -> bank 6 cold {len(cold) + len(spt) + len(win)}B, "
          f"bank 1 tail {len(tail)}B at ${W3HDR:04X} "
          f"({BASE + BANK - W3HDR - len(tail)} free)")

if __name__ == "__main__":
    main()
