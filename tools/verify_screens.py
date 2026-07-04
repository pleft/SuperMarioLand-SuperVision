#!/usr/bin/env python3
"""
CELL-BY-CELL screen verification: the ORIGINAL (PyBoy) vs the PORT (py65).
Renders the original's live tilemap+tiles into expected SV pixels and diffs the
port's framebuffer against them. Reports every mismatching cell. (Rule 0b.)
Usage: python3 tools/verify_screens.py [title|bonus|level|all]
"""
import os, re, sys
sys.path.insert(0, os.path.dirname(__file__))
ROOT = os.path.join(os.path.dirname(__file__), "..")

def gb_tile_pixels(m, idx, signed_mode):
    base = (0x9000 + idx*16) if (signed_mode and idx < 0x80) else (0x8000 + idx*16)
    rows = []
    for r in range(8):
        lo, hi = m[base+r*2], m[base+r*2+1]
        rows.append([((lo>>(7-x))&1) | (((hi>>(7-x))&1)<<1) for x in range(8)])
    return rows

def sv_cell(rows):
    out = []
    for r in rows:
        out.append(r[0] | (r[1]<<2) | (r[2]<<4) | (r[3]<<6))
        out.append(r[4] | (r[5]<<2) | (r[6]<<4) | (r[7]<<6))
    return out                                   # 16 bytes: 2 per scanline

def boot_port():
    from py65.devices.mpu65c02 import MPU
    dbg = open(os.path.join(ROOT,"build/dbg.txt")).read()
    sym = lambda n: int(re.search(r'name="%s",[^\n]*val=(0x[0-9A-Fa-f]+)'%n, dbg).group(1),16)
    mem = bytearray(0x10000)
    mem[0x8000:0x10000] = open(os.path.join(ROOT,"build/super-mario-land.sv"),"rb").read()
    mpu = MPU(); mpu.memory = mem
    def dma():
        if mem[0x200D]&0x80:
            s=mem[0x2008]|(mem[0x2009]<<8); d=mem[0x200A]|(mem[0x200B]<<8); n=mem[0x200C]*16
            for i in range(n): mem[(d+i)&0xFFFF]=mem[(s+i)&0xFFFF]
            mem[0x200D]&=0x7F
    def run(steps, pad=0xFF):
        mem[0x2020]=pad; n=0
        while n<steps:
            mpu.step(); n+=1
            if n%120_000==0: mem[0]=1; mem[1]=(mem[1]+1)&0xFF
            dma()
    mpu.pc = mem[0xFFFC]|(mem[0xFFFD]<<8)
    return mem, mpu, sym, run

def diff(expected_cells, mem, row_map, mask, label):
    """expected_cells: {(gbrow,col): 16 bytes}; row_map: gbrow -> SV tile row."""
    bad = []
    for (gr,c), exp in expected_cells.items():
        if (gr,c) in mask: continue
        sr = row_map(gr)
        if sr is None: continue
        got = []
        for y in range(sr*8, sr*8+8):
            base = 0x4000 + y*0x30 + c*2
            got.append(mem[base]); got.append(mem[base+1])
        if bytes(got) != bytes(exp):
            bad.append((gr, c))
    print(f"{label}: {len(expected_cells)-len(mask)} cells checked, {len(bad)} mismatches"
          + (f" -> {bad[:12]}" if bad else ""))
    return bad

def capture_original(setup):
    from pyboy import PyBoy
    pb = PyBoy(os.path.join(ROOT,"super-mario-land-gb.gb"), window="null")
    m = pb.memory
    setup(pb, m)
    signed = not (m[0xFF40] & 0x10)
    cells = {}
    for r in range(18):
        for c in range(20):
            idx = m[0x9800 + r*32 + c]
            cells[(r,c)] = sv_cell(gb_tile_pixels(m, idx, signed))
    pb.stop()
    return cells

def case_title():
    def setup(pb, m):
        for _ in range(400): pb.tick()
    cells = capture_original(setup)
    mem, mpu, sym, run = boot_port()
    run(3_000_000)                                # sits on the title
    diff(cells, mem, lambda gr: gr+1, set(), "TITLE (GB rows -> SV rows+1)")

def case_bonus():
    def setup(pb, m):
        for _ in range(300): pb.tick()
        pb.button_press("start")
        for _ in range(10): pb.tick()
        pb.button_release("start")
        for _ in range(240): pb.tick()
        m[0xFFB3] = 0x12
        for _ in range(40): pb.tick()
    cells = capture_original(setup)
    mem, mpu, sym, run = boot_port()
    run(6_000_000, 0x7F)                          # through the title into play
    mem[sym('lives')] = 2                         # match the original's boot lives
    mpu.pc = sym('bonus_start')
    mem[0x01FE]=0xFF; mem[0x01FF]=0xFF; mpu.sp=0xFD
    run(3_000_000)
    mask  = {(r,18) for r in (6,9,12,15)}         # prize wheel: rotation is timing-based
    mask |= {(r,c) for r in range(5,17) for c in (9,10,11)}  # the cycling ladder + Mario
    mask |= {(r,c) for r in range(4,8) for c in range(0,4)}  # original Mario sprite area (OAM, not map)
    diff(cells, mem, lambda gr: gr, mask, "BONUS init (rows 1:1)")

def case_level():
    def setup(pb, m):
        for _ in range(300): pb.tick()
        pb.button_press("start")
        for _ in range(10): pb.tick()
        pb.button_release("start")
        for _ in range(240): pb.tick()
    cells = capture_original(setup)
    mem, mpu, sym, run = boot_port()
    run(6_000_000, 0x7F)
    run(1_000_000, 0xFF)
    mask  = {(0,c) for c in range(20)} | {(1,c) for c in range(20)}   # HUD digits tick (time)
    # Mario: OAM sprite in the original, composited into the fb in the port
    sx, sy = mem[sym('spr_x')], mem[sym('spr_y')]
    mask |= {(r,c) for r in range(sy//8, sy//8+3) for c in range(sx//8, sx//8+3)}
    diff(cells, mem, lambda gr: gr if gr>=2 else None, mask, "LEVEL 1-1 start view (playfield rows)")

if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv)>1 else "all"
    if which in ("title","all"): case_title()
    if which in ("bonus","all"): case_bonus()
    if which in ("level","all"): case_level()
