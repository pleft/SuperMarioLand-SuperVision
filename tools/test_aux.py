#!/usr/bin/env python3
"""test_aux -- bit-exact unit tests for the save-under composer (docs/42).

Runs aux_compose / aux_uncompose in the py65 harness with fabricated
contexts, tiles and VRAM, and compares every touched byte against a python
reference that mirrors the assembly's own math (shtab pages, MASKTAB,
set_dst's ring). Any mismatch prints the first differing cell."""
import sys, re
sys.path.insert(0, 'tools')
from svharness import Harness

CTX0, AUX_TILES = 0x1C60, 0x1FA0
AXV = 0x01C6
SCRATCH = 0x0136
TMPL = 0x20

h = Harness()
h.boot_to_game()
lbl = open('build/w3aux.lbl').read()
sym = {n: int(a, 16) for a, n in re.findall(r'al 00([0-9A-F]{4}) \.([A-Za-z_][A-Za-z0-9_]*)$', lbl, re.M)}
RING_B = 0x11F0

def map8():
    h.mem[0x2022] = 0; h.mem[0x2021] = 8; h._bank_check(); h.mem[0x2022] = 0x0F

def call(addr, budget=200000):
    h.mpu.sp = 0xF0
    h.mem[0x1F1] = 0xFD; h.mem[0x1F2] = 0xFF
    h.mpu.pc = addr
    for _ in range(budget):
        h.mpu.step()
        if h.mpu.pc >= 0xFFF0:
            return
    raise SystemExit("call ran away")

def cell_addr(dcol, dy):
    ring = h.mem[RING_B] | (h.mem[RING_B + 1] << 8)
    return ((dy * 48 + dcol + ring) % 0x1FE0) + 0x4000

def read_cell(dcol, dy):
    a = cell_addr(dcol, dy)
    return [h.mem[a + r * 0x30 + b] for r in range(8) for b in range(2)]

def write_cell(dcol, dy, data):
    a = cell_addr(dcol, dy)
    for r in range(8):
        for b in range(2):
            h.mem[a + r * 0x30 + b] = data[r * 2 + b]

def shifted(row2, dx):
    """the assembly's per-row shift: (s_j, target col) pairs"""
    sub = dx & 3
    case = (dx + 8) >> 2
    b0, b1 = row2
    lo = lambda b: h.mem[0x0200 + sub * 256 + b]
    hi = lambda b: h.mem[0x0600 + sub * 256 + b]
    s0 = lo(b0)
    s1 = hi(b0) | lo(b1)
    s2 = hi(b1)
    return {0: [(s2, 0)], 1: [(s1, 0), (s2, 1)],
            2: [(s0, 0), (s1, 1)], 3: [(s0, 1)]}[case]

def mix(buf, idx, s):
    if s == 0:
        return
    m = h.mem[0x0600 + s]
    buf[idx] = (buf[idx] & (m ^ 0xFF)) | s

def compose_ref(saved_bg, tiles, box):
    """per new cell: expected 16 bytes"""
    cols, rows = box['cols'], box['rows']
    out = {}
    for rj in range(rows):
        for ci in range(cols):
            buf = list(saved_bg[(ci, rj)])
            for (tx, ty, px) in tiles:
                dx, dy = tx - ci * 8, ty - rj * 8
                if not (-8 < dx < 8 and -8 < dy < 8):
                    continue
                for r in range(8):
                    br = r + dy
                    if not (0 <= br < 8):
                        continue
                    for s, c in shifted(px[r * 2:r * 2 + 2], dx):
                        mix(buf, br * 2 + c, s)
            out[(ci, rj)] = buf
    return out

def setup(box, tiles, active_ctx=None):
    h.mem[TMPL] = CTX0 & 0xFF; h.mem[TMPL + 1] = CTX0 >> 8
    h.mem[AXV + 0] = box['dcol0']; h.mem[AXV + 1] = box['dy0']
    h.mem[AXV + 2] = box['cols']; h.mem[AXV + 3] = box['rows']
    h.mem[AXV + 4] = len(tiles)
    for i, (tx, ty, px) in enumerate(tiles):
        h.mem[AXV + 5 + i] = tx & 0xFF
        h.mem[AXV + 9 + i] = ty & 0xFF
        for j, b in enumerate(px):
            h.mem[AUX_TILES + i * 16 + j] = b
    if active_ctx is None:
        h.mem[CTX0] = 0

fails = 0
def chk(name, ok):
    global fails
    print(("PASS " if ok else "FAIL ") + name)
    if not ok: fails += 1

# deterministic pseudo-bg + a recognisable tile
import random
rnd = random.Random(7)
def fill_vram(box):
    bg = {}
    for rj in range(box['rows']):
        for ci in range(box['cols']):
            data = [rnd.randrange(256) for _ in range(16)]
            write_cell(box['dcol0'] + ci * 2, box['dy0'] + rj * 8, data)
            bg[(ci, rj)] = data
    return bg

TILE = [0xC3, 0x00, 0x81, 0x00, 0x81, 0x00, 0xFF, 0xFC,
        0xFF, 0x03, 0x81, 0x00, 0x81, 0x00, 0xC3, 0xC0]   # arbitrary, holes incl.

map8()

# ---- test 1: FRESH compose, 3x3 box, 4-tile quad at subpixel offset ----
box = {'dcol0': 10, 'dy0': 64, 'cols': 3, 'rows': 3}
tiles = [(3, 5, TILE), (11, 5, TILE), (3, 13, TILE), (11, 13, TILE)]
bg = fill_vram(box)
setup(box, tiles)
call(sym['aux_compose'])
want = compose_ref(bg, tiles, box)
ok = True
for (ci, rj), w in want.items():
    got = read_cell(box['dcol0'] + ci * 2, box['dy0'] + rj * 8)
    if got != w:
        print("  cell", ci, rj, "got", bytes(got).hex(), "want", bytes(w).hex()); ok = False; break
# ctx must hold the pristine bg
for (ci, rj), w in bg.items():
    base = CTX0 + 8 + (rj * 3 + ci) * 16
    if [h.mem[base + k] for k in range(16)] != w:
        print("  ctx saved wrong at", ci, rj); ok = False; break
chk("fresh compose (3x3, 4 tiles)", ok and h.mem[CTX0] == 0x80)

# ---- test 2: STILL box, tiles moved 1px -> old sprite pixels must vanish ----
tiles2 = [(4, 6, TILE), (12, 6, TILE), (4, 14, TILE), (12, 14, TILE)]
setup(box, tiles2, active_ctx=True)
call(sym['aux_compose'])
want = compose_ref(bg, tiles2, box)
ok = all(read_cell(box['dcol0'] + ci * 2, box['dy0'] + rj * 8) == w for (ci, rj), w in want.items())
chk("still box, sprite +1px (old pixels restored)", ok)

# ---- test 3: box moves one cell right: vacated column restored pristine ----
box3 = {'dcol0': 12, 'dy0': 64, 'cols': 3, 'rows': 3}
# new rightmost column is fresh VRAM: give it known content
newbg = {}
for rj in range(3):
    data = [rnd.randrange(256) for _ in range(16)]
    write_cell(box3['dcol0'] + 4, box3['dy0'] + rj * 8, data)
    newbg[(2, rj)] = data
for rj in range(3):
    for ci in range(2):
        newbg[(ci, rj)] = bg[(ci + 1, rj)]
setup(box3, tiles, active_ctx=True)
call(sym['aux_compose'])
want = compose_ref(newbg, tiles, box3)
ok = all(read_cell(box3['dcol0'] + ci * 2, box3['dy0'] + rj * 8) == w for (ci, rj), w in want.items())
# the vacated left column (old ci=0) must be pristine bg again
for rj in range(3):
    if read_cell(box['dcol0'], box['dy0'] + rj * 8) != bg[(0, rj)]:
        print("  vacated col not restored at rj", rj); ok = False
chk("box moved +1 cell (vacated column restored)", ok)

# ---- test 4: uncompose -> everything pristine ----
call(sym['aux_uncompose'])
ok = all(read_cell(box3['dcol0'] + ci * 2, box3['dy0'] + rj * 8) == newbg[(ci, rj)]
         for rj in range(3) for ci in range(3))
chk("uncompose restores all", ok and h.mem[CTX0] == 0)

print("\n" + ("ALL PASS" if fails == 0 else f"{fails} FAILURES"))
sys.exit(1 if fails else 0)
