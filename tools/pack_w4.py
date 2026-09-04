#!/usr/bin/env python3
"""pack_w4 -- lay World 4 into MAGNUM pages 9 (resident) + 10 (cold).

World 3 lives on the bank PAIR (1, 6): bank 1 carries the LEVELS prefix, the
level headers at the W3HDR pin, pipes/blocks, the loader stub and the world's
BG charset; bank 6 carries the cold data (maps/rooms/spawns) plus the kit's
pinned blobs (window image, scripts, display lists, tile slice, the
bank-resident walk). Bank 1 has 25 bytes free and bank 6's cold region 292, so
World 4 gets its own pair -- pages 9 and 10 -- with exactly the same layout, its
own kit image (build/w4*) and its own sprite overlay. docs/45.

Runs on the 512K image, AFTER make_512k has created pages 8-15.
"""
import sys, os, re, hashlib
sys.path.insert(0, os.path.dirname(__file__))
import importlib.util
_spec = importlib.util.spec_from_file_location("pb", os.path.join(os.path.dirname(__file__), "pack_banks.py"))
pb = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(pb)

BASE, BANK, STRIDE, HDR_SIZE = pb.BASE, pb.BANK, pb.STRIDE, pb.HDR_SIZE
W3HDR, W3WIN, W3SPT = 0xB540, 0x8000, 0xB11E   # page-10 layout (docs/45), edge to edge:
                                                # x2 head, maps $83C8-$AA27, spt, window $AA30,
                                                # scripts $B128, dlists $B720, slice $B940
                                                # (76 slots -> $BE00), walk $BE00 (cfg/w4code.cfg)
W4SCR, W4DL, W4SLICE, W4X, W4DATA = 0xB124, 0xB71B, 0xB93C, 0xBE00, 0x8ABF
W4X2 = 0x86F8                                   # the stash head follows the window (cfg/w4code.cfg)
RES, COLD = 9, 10                       # World 4's page pair
LEVELS = (9, 10, 11)                    # 4-1, 4-2, 4-3

def seg(mapfile, name):
    m = re.search(rf"^{name}\s+([0-9A-F]+)\s+\S+\s+([0-9A-F]+)", open(mapfile).read(), re.M)
    return (int(m.group(1), 16), int(m.group(2), 16)) if m else (0, 0)

def main():
    path = sys.argv[1]
    img = bytearray(open(path, "rb").read())
    assert len(img) == 0x80000, f"{path}: expected the 512K image (run after make_512k)"
    sym = pb.symbols(open("build/rom.map").read()) if hasattr(pb, "symbols") else {}

    # ---- the kit image, split at its linked segment boundaries ----------
    full = open("build/w4code.bin", "rb").read()
    w2c_sz = seg("build/w4code.map", "W2C")[1]
    far_at, far_sz = seg("build/w4code.map", "W2FAR")
    x_at, x_sz = seg("build/w4code.map", "W3X")
    x2_at, x2_sz = seg("build/w4code.map", "W3X2")
    win = full[:w2c_sz]
    far = full[w2c_sz:w2c_sz + far_sz]
    xcode = full[w2c_sz + far_sz:w2c_sz + far_sz + x_sz]
    x2code = full[w2c_sz + far_sz + x_sz:w2c_sz + far_sz + x_sz + x2_sz]
    assert len(win) <= 0x800, f"W4 window kit is {len(win)}B, the $1500 window is $800"
    assert far_at == 0xBE58 and x_at == W4X and (not x2_sz or x2_at == W4X2), \
        "W4 kit pins moved -- update pack_w4"
    assert W3WIN + len(win) <= W4X2 and W4X2 + x2_sz <= W4DATA, "W4 window/stash/data overlap"

    # ---- COLD page: maps/rooms/spawns + the kit's pinned blobs ----------
    cold = bytearray(b"\xFF" * BANK)
    surfs, rooms_raw, spawns, room_ids = [], {}, [], []
    for lv in LEVELS:
        p = f"build/levels/level_{lv:02d}"
        surfs.append(open(p + ".bin", "rb").read())
        spawns.append(open(p + "_spawns.bin", "rb").read())
        ids = []
        for r in range(3):
            f = f"{p}_room{r}.bin"
            if os.path.exists(f):
                d = open(f, "rb").read(); h = hashlib.md5(d).hexdigest()
                rooms_raw.setdefault(h, d); ids.append(h)
        room_ids.append(ids)
    grids = list(rooms_raw)
    tabs, pool = pb.dedup_maps(surfs + [rooms_raw[h] for h in grids], W4DATA)
    addr = W4DATA
    tab_at = []
    for t in tabs:
        tab_at.append(addr); addr += len(t)
    addr += len(pool)
    spawn_at = []
    for sp in spawns:
        assert len(sp) <= 384, f"W4 spawn list {len(sp)}B exceeds spawn_tab (384B)"
        spawn_at.append(addr); addr += len(sp)
    assert addr <= W3SPT, f"W4 cold data overruns ${W3SPT:04X} by {addr - W3SPT}"
    blob = b"".join(tabs) + pool + b"".join(spawns)
    cold[W4DATA - BASE:W4DATA - BASE + len(blob)] = blob
    spt = b"".join(bytes((a & 0xFF, a >> 8)) for a in spawn_at)
    cold[W3SPT - BASE:W3SPT - BASE + len(spt)] = spt
    assert W3WIN + len(win) <= W4SCR, "W4 window image runs into the scripts pin"
    cold[W3WIN - BASE:W3WIN - BASE + len(win)] = win
    pins = ((W4SCR, "build/w4scripts.bin"), (W4DL, "build/w4dlists.bin"),
            (W4SLICE, None))                  # tile slice below caps each blob's gap
    for (pin, path_), (nxt, _) in zip(pins, pins[1:]):
        d = open(path_, "rb").read()
        assert pin - BASE + len(d) <= BANK, f"W4 ${pin:04X} blob overruns the bank"
        assert pin + len(d) <= nxt, \
            f"W4 ${pin:04X} blob ({len(d)}B) runs into the ${nxt:04X} pin by {pin + len(d) - nxt}B"
        cold[pin - BASE:pin - BASE + len(d)] = d
    # tile slice: World 4's own overlay, same id-preserving order as W3's
    order = [int(t, 16) for t in open("build/w4tiles.txt").read().split()]
    ovl = open("build/gfx/w4_ovl_8A00.svt", "rb").read()
    obj = open("build/gfx/w4_obj_8000.svt", "rb").read()
    base = open("build/gfx/w1_obj_8000.svt", "rb").read()   # = the FIXED chardata sheet
    hi = open("build/gfx/w3_hi.svt", "rb").read()
    HI = {0xF9: 0, 0xFA: 1, 0xFB: 2, 0xFE: 3}
    def tile(t):
        if t in HI: return hi[HI[t] * 16:(HI[t] + 1) * 16]
        if 0xA0 <= t <= 0xDC: return ovl[(t - 0xA0) * 16:(t - 0xA0 + 1) * 16]
        if t >= 0xE4: return base[t * 16:(t + 1) * 16]   # "stays chardata" ids ($E6/$EE/$EF..):
        return obj[t * 16:(t + 1) * 16]                 # the engine draws them from the FIXED sheet
    slice_ = b"".join(tile(t) for t in order)
    assert W4SLICE + len(slice_) <= W4X, f"W4 tile slice ({len(slice_)}B) runs into the walk pin at ${W4X:04X}"
    cold[W4SLICE - BASE:W4SLICE - BASE + len(slice_)] = slice_
    assert W4X + len(xcode) <= 0xC000, "W4 walk overruns the page"
    cold[W4X - BASE:W4X - BASE + len(xcode)] = xcode
    if x2code: cold[W4X2 - BASE:W4X2 - BASE + len(x2code)] = x2code
    img[COLD * STRIDE:COLD * STRIDE + BANK] = cold

    # ---- RESIDENT page: prefix + headers/pipes/blocks + stub + charset + far
    res = bytearray(img[1 * STRIDE:1 * STRIDE + BANK])      # bank 1 = prefix + W3 tail
    res[W3HDR - BASE:] = b"\xFF" * (BANK - (W3HDR - BASE))  # drop W3's tail, keep the prefix
    ball = open("build/w4ball.bin", "rb").read()            # w3_ballt pin ($B520): the copy
    res[pb.W3BALL - BASE:W3HDR - BASE] = b"\xFF" * (W3HDR - pb.W3BALL)  # above inherited W3's
    res[pb.W3BALL - BASE:pb.W3BALL - BASE + len(ball)] = ball           # rows; paste W4's
    w3t_at, w3t_sz = seg("build/w4code.map", "W3TAB")      # the per-type tables (docs/45):
    if w3t_sz:                                              # LAST in the kit .bin, resident
        assert w3t_at == 0xB000, "W3TABM moved -- update pack_w4"   # at $B000 (W3's copy from
        w3t = full[len(full) - w3t_sz:]                     # bank 1 sits there: replace it)
        assert w3t_at + w3t_sz <= pb.W3BALL, f"W4 tables run into the ball pin by {w3t_at + w3t_sz - pb.W3BALL}"
        res[w3t_at - BASE:pb.W3BALL - BASE] = b"\xFF" * (pb.W3BALL - w3t_at)
        res[w3t_at - BASE:w3t_at - BASE + w3t_sz] = w3t
    # the engine finds a header at W3HDR + (level-6)*24, so slot 3 is level 9's:
    # reserve every slot UP TO the highest level here, or the pipes/blocks that
    # follow land inside the header region and the header write then clobbers
    # them (4-1's first pipe pointed at the header's own bytes -- user: "mario
    # cannot enter" the first bonus room).
    nslots = max(LEVELS) - 6 + 1
    tail = bytearray(b"\x00" * (nslots * HDR_SIZE))
    # World 4's levels are 9-11 -> header slots 3-5 (engine pin W3HDR+(lvl-6)*24);
    # slots 0-2 (World 3's 6-8) never exist in this bank, so their HDR_SIZE bytes
    # are a free hole. Pack the small pieces (pipes/blocks/sentinel) into it before
    # spilling past the header region -- that reclaims (min(LEVELS)-6)*24 bytes and
    # keeps the resident tail under the far kit at $BE50 with 4-2 (and eases 4-3).
    # the small header-pointed pieces (pipes/blocks/sentinel/stub) go into the
    # HOLE above the per-type tables in this page ($B000+tables .. $B51F, ~940 B
    # free) instead of the tail: with three levels the tail (headers + stub +
    # charset) ran 31 B into the far kit at $BE58 (docs/45). Header slots 0-2
    # (World 3's 6-8) stay zero: the engine pin is W3HDR + (level-6)*24.
    hole = [0xB000 + (w3t_sz if w3t_sz else 0)]
    def place(d):
        if not d:
            return 0
        at = hole[0]
        assert at + len(d) <= pb.W3BALL, f"W4 resident hole runs into the ball pin by {at + len(d) - pb.W3BALL}"
        assert all(b == 0xFF for b in res[at - BASE:at - BASE + len(d)]), f"W4 hole at ${at:04X} not free"
        res[at - BASE:at - BASE + len(d)] = d
        hole[0] += len(d)
        return at
    pieces = {}
    for i, lv in enumerate(LEVELS):
        p = f"build/levels/level_{lv:02d}"
        for key, suf, per in (("pipes", "_pipes.bin", 5), ("blocks", "_blocks.bin", 4)):
            d = open(p + suf, "rb").read()
            pieces[(i, key)] = (place(d), len(d) // per)
    sent_at = place(b"\xFF\xFF")
    stub = open("build/w4stub.bin", "rb").read()
    stub_at = place(stub)
    bgc_at = W3HDR + len(tail)
    # the SHARED charset (font + common scenery) already sitting in the prefix we
    # copied, with World 4's overlay over $31-$6F -- exactly what pack_w3 does for
    # World 3. (Building it from w4_bg_9000.svt instead rendered the whole level
    # as dithered garbage: that dump has its own arrangement.)
    lblmap = {m.group(2): int(m.group(1), 16) for m in
              re.finditer(r'al 00([0-9A-F]{4}) \.(\w+)', open("build/rom.lbl").read())}
    bg_off = lblmap["bg_chardata"] - BASE
    # base = the SHARED sheet the prefix ships (== w1_bg_9000), with World 4's
    # $31-$6F overlay on top -- exactly what pack_w3 does. Verified against the
    # GB's live VRAM during 4-1: it matches world 1's $5032 sheet in 67 of 128
    # tiles, the other 61 being the $9310 overlay. (Using w4_bg_9000.svt as the
    # base instead is wrong -- the extractor sources it from bank 1, which is
    # World 2's sheet, and 4-1 then renders almost blank.)
    bg = bytearray(res[bg_off:bg_off + 0x800])
    ovl2 = open("build/gfx/w4_ovl_9310.svt", "rb").read()
    assert len(ovl2) == 63 * 16, "w4_ovl_9310.svt: expected 63 tiles"
    bg[0x31 * 16:0x31 * 16 + len(ovl2)] = ovl2
    tail += bg
    for i, lv in enumerate(LEVELS):
        cols = len(surfs[i]) // 16
        r = [tab_at[len(LEVELS) + grids.index(h)] for h in room_ids[i]]
        while len(r) < 3: r.append(r[-1] if r else 0)
        hdr = bytearray()
        for v in (tab_at[i], cols, r[0], r[1], r[2], pieces[(i, "pipes")][0]):
            hdr += bytes((v & 0xFF, v >> 8))
        hdr.append(pieces[(i, "pipes")][1])
        hdr += bytes((pieces[(i, "blocks")][0] & 0xFF, pieces[(i, "blocks")][0] >> 8))
        hdr.append(pieces[(i, "blocks")][1])
        quad_base = W4SLICE - 0xA0 * 16
        for v in (sent_at, quad_base, stub_at, bgc_at):
            hdr += bytes((v & 0xFF, v >> 8))
        assert len(hdr) == HDR_SIZE, f"header is {len(hdr)}B, expected {HDR_SIZE}"
        slot = lv - 6                                        # the engine's pin: W3HDR + (lvl-6)*24
        assert (slot + 1) * HDR_SIZE <= nslots * HDR_SIZE, "header slot outside the reserved area"
        tail[slot * HDR_SIZE:(slot + 1) * HDR_SIZE] = hdr
    assert W3HDR + len(tail) <= 0xBE58, \
        f"W4 resident tail runs into the far kit by {W3HDR + len(tail) - 0xBE58} bytes"
    res[W3HDR - BASE:W3HDR - BASE + len(tail)] = tail
    res[0xBE58 - BASE:0xBE58 - BASE + len(far)] = far
    img[RES * STRIDE:RES * STRIDE + BANK] = res

    open(path, "wb").write(bytes(img))
    print(f"pack_w4: levels {list(LEVELS)} -> page {RES} (resident, tail {len(tail)}B) "
          f"+ page {COLD} (cold, data {len(blob)}B, window {len(win)}B, slice {len(slice_)}B)")

if __name__ == "__main__":
    main()
